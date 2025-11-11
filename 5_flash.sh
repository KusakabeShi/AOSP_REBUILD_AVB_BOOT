#!/bin/sh

SIGNED_PATH=patched_signed
BLOCK_PATH=/dev/block/by-name
A_SUFFIX=_a
B_SUFFIX=_b

# Parse command line arguments
SIGNED_IMAGE=""
SIGNED_VBMETA=""
TARGET_SLOT=""
DRY_RUN=false
FORCE_FLASH=false

while [ $# -gt 0 ]; do
    case $1 in
        --image)
            SIGNED_IMAGE="$2"
            shift 2
            ;;
        --vbmeta)
            SIGNED_VBMETA="$2"
            shift 2
            ;;
        --slot)
            TARGET_SLOT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force-flash)
            FORCE_FLASH=true
            shift
            ;;
        *)
            echo "Usage: $0 --image <signed_image> --vbmeta <signed_vbmeta> [--slot a|b] [--dry-run] [--force-flash]"
            echo "  --image       : Path to signed image file (required)"
            echo "  --vbmeta      : Path to signed vbmeta file (required)"
            echo "  --slot        : Target slot (a or b), auto-detect if not provided"
            echo "  --dry-run     : Show what would be flashed without actually flashing"
            echo "  --force-flash : Flash without confirmation"
            exit 1
            ;;
    esac
done

# Check required parameters
if [ -z "$SIGNED_IMAGE" ]; then
    echo "ERROR: --image parameter is required"
    echo "Usage: $0 --image <signed_image> [--vbmeta <signed_vbmeta>] [--slot a|b] [--dry-run] [--force-flash]"
    echo "Note: --vbmeta is optional for chained partition mode"
    exit 1
fi

echo "========================================"
echo "ANDROID IMAGE FLASHER"
echo "========================================"
echo "Preparing to flash signed Android images..."
echo ""

# Check if signed images exist
if [ ! -f "$SIGNED_IMAGE" ]; then
    echo "ERROR: Signed image not found: $SIGNED_IMAGE"
    exit 1
fi

if [ -n "$SIGNED_VBMETA" ] && [ ! -f "$SIGNED_VBMETA" ]; then
    echo "ERROR: Signed vbmeta not found: $SIGNED_VBMETA"
    exit 1
fi

echo "✓ Signed image: $SIGNED_IMAGE"
if [ -n "$SIGNED_VBMETA" ] && [ -s "$SIGNED_VBMETA" ]; then
    echo "✓ Signed vbmeta: $SIGNED_VBMETA"
else
    echo "Note: No vbmeta image provided (chained partition mode)"
fi

# Determine image type from filename
image_basename=$(basename "$SIGNED_IMAGE")
if echo "$image_basename" | grep -q "boot"; then
    if echo "$image_basename" | grep -q "init"; then
        image_type="init_boot"
    else
        image_type="boot"
    fi
else
    echo "ERROR: Cannot determine image type from filename: $image_basename"
    echo "Expected filename to contain 'boot' or 'init'"
    exit 1
fi

echo "✓ Detected image type: $image_type"

# Detect current slot if not provided
detect_current_slot() {
    if [ -n "$TARGET_SLOT" ]; then
        echo "Using manually specified target slot: $TARGET_SLOT"
        return 0
    fi
    
    # Try to detect current slot to determine inactive slot
    current_slot=""
    
    # Try reading from /proc/cmdline
    if [ -f "/proc/cmdline" ]; then
        if grep -q "androidboot.slot_suffix=_a" /proc/cmdline; then
            current_slot="a"
        elif grep -q "androidboot.slot_suffix=_b" /proc/cmdline; then
            current_slot="b"
        fi
    fi
    
    # Alternative method: check ro.boot.slot_suffix
    if [ -z "$current_slot" ]; then
        slot_suffix=$(getprop ro.boot.slot_suffix 2>/dev/null)
        case "$slot_suffix" in
            "_a") current_slot="a" ;;
            "_b") current_slot="b" ;;
        esac
    fi
    
    if [ -n "$current_slot" ]; then
        # For A/B devices, flash to the inactive slot
        if [ "$current_slot" = "a" ]; then
            TARGET_SLOT="b"
        else
            TARGET_SLOT="a"
        fi
        echo "Auto-detected current slot: $current_slot"
        echo "Will flash to inactive slot: $TARGET_SLOT"
    else
        echo "WARNING: Cannot detect current slot!"
        echo "Please specify target slot manually with --slot a or --slot b"
        echo "IMPORTANT: For A/B devices, flash to the INACTIVE slot"
        exit 1
    fi
}

detect_current_slot

# Validate target slot
if [ "$TARGET_SLOT" != "a" ] && [ "$TARGET_SLOT" != "b" ]; then
    echo "ERROR: Invalid target slot: $TARGET_SLOT"
    echo "Target slot must be 'a' or 'b'"
    exit 1
fi

# Determine partition paths
target_suffix="_${TARGET_SLOT}"
image_partition="${BLOCK_PATH}/${image_type}${target_suffix}"
if [ -n "$SIGNED_VBMETA" ] && [ -s "$SIGNED_VBMETA" ]; then
    vbmeta_partition="${BLOCK_PATH}/vbmeta${target_suffix}"
else
    vbmeta_partition=""
fi

echo ""
echo "========================================"
echo "FLASH CONFIGURATION"
echo "========================================"
echo "Target slot: $TARGET_SLOT"
echo "Image type: $image_type"
echo "Target partitions:"
echo "  ${image_type}: $image_partition"
if [ -n "$vbmeta_partition" ]; then
    echo "  vbmeta: $vbmeta_partition"
else
    echo "  vbmeta: (not applicable - chained partition mode)"
fi
echo ""

# Check if target partitions exist
if [ ! -b "$image_partition" ]; then
    echo "ERROR: Target partition not found: $image_partition"
    echo "This script must be run on an Android device with root access"
    exit 1
fi

if [ -n "$vbmeta_partition" ] && [ ! -b "$vbmeta_partition" ]; then
    echo "ERROR: Target vbmeta partition not found: $vbmeta_partition"
    echo "This script must be run on an Android device with root access"
    exit 1
fi

echo "✓ Target partitions verified"

# Get partition sizes for validation
image_size=$(stat -c%s "$SIGNED_IMAGE")
image_partition_size=$(blockdev --getsize64 "$image_partition")

echo ""
echo "Size validation:"
echo "  ${image_type} image: $image_size bytes"
echo "  ${image_type} partition: $image_partition_size bytes"

if [ -n "$SIGNED_VBMETA" ] && [ -s "$SIGNED_VBMETA" ]; then
    vbmeta_size=$(stat -c%s "$SIGNED_VBMETA")
    vbmeta_partition_size=$(blockdev --getsize64 "$vbmeta_partition")
    echo "  vbmeta image: $vbmeta_size bytes"
    echo "  vbmeta partition: $vbmeta_partition_size bytes"
fi

# Validate sizes
if [ "$image_size" -gt "$image_partition_size" ]; then
    echo "ERROR: ${image_type} image too large for partition"
    exit 1
fi

if [ -n "$SIGNED_VBMETA" ] && [ -s "$SIGNED_VBMETA" ] && [ "$vbmeta_size" -gt "$vbmeta_partition_size" ]; then
    echo "ERROR: vbmeta image too large for partition"
    exit 1
fi

echo "✓ Size validation passed"

# Final confirmation
if [ "$FORCE_FLASH" = false ] && [ "$DRY_RUN" = false ]; then
    echo ""
    echo "========================================"
    echo "CRITICAL WARNING"
    echo "========================================"
    echo "You are about to flash signed images to device partitions!"
    echo "This will modify your device's boot process."
    echo ""
    echo "Target slot: $TARGET_SLOT"
    echo "Images to flash:"
    echo "  $SIGNED_IMAGE -> $image_partition"
    if [ -n "$SIGNED_VBMETA" ] && [ -s "$SIGNED_VBMETA" ]; then
        echo "  $SIGNED_VBMETA -> $vbmeta_partition"
    else
        echo "  (vbmeta not applicable - chained partition mode)"
    fi
    echo ""
    echo "Make sure you have backups and understand the risks!"
    echo ""
    echo -n "Are you absolutely sure you want to continue? (type 'YES' to confirm): "
    read -r response
    if [ "$response" != "YES" ]; then
        echo "Flash operation cancelled for safety"
        exit 0
    fi
    echo "Proceeding with flash..."
fi

echo ""
echo "========================================"
echo "FLASHING PROCESS"
echo "========================================"

# Flash images
flash_image() {
    local source_image=$1
    local target_partition=$2
    local image_name=$3
    
    echo "Flashing $image_name..."
    
    if [ "$DRY_RUN" = true ]; then
        echo "  DRY RUN: Would execute: dd if=$source_image of=$target_partition bs=4096"
    else
        echo "  Executing: dd if=$source_image of=$target_partition bs=4096"
        if dd if="$source_image" of="$target_partition" bs=4096 2>/dev/null; then
            echo "  ✓ Successfully flashed $image_name"
        else
            echo "  ERROR: Failed to flash $image_name"
            return 1
        fi
    fi
}

# Flash the images
if ! flash_image "$SIGNED_IMAGE" "$image_partition" "$image_type"; then
    echo "ERROR: ${image_type} flashing failed!"
    exit 1
fi

if [ -n "$SIGNED_VBMETA" ] && [ -s "$SIGNED_VBMETA" ]; then
    if ! flash_image "$SIGNED_VBMETA" "$vbmeta_partition" "vbmeta"; then
        echo "ERROR: vbmeta flashing failed!"
        exit 1
    fi
else
    echo "Skipping vbmeta flash (chained partition mode)"
fi

echo ""
echo "========================================"
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN COMPLETE"
    echo "========================================"
    echo "Would have flashed:"
    echo "  ✓ ${image_type} to slot $TARGET_SLOT"
    if [ -n "$SIGNED_VBMETA" ] && [ -s "$SIGNED_VBMETA" ]; then
        echo "  ✓ vbmeta to slot $TARGET_SLOT"
    fi
else
    echo "FLASHING COMPLETE"
    echo "========================================"
    echo "Successfully flashed:"
    echo "  ✓ ${image_type} to slot $TARGET_SLOT"
    if [ -n "$SIGNED_VBMETA" ] && [ -s "$SIGNED_VBMETA" ]; then
        echo "  ✓ vbmeta to slot $TARGET_SLOT"
    fi
    echo ""
    echo "IMPORTANT NEXT STEPS:"
    echo "1. Reboot your device to test the changes"
    echo "2. If you flashed to inactive slot, set it as active:"
    echo "   bootctl set-active-boot-slot $TARGET_SLOT"
    echo "3. Monitor the device boot process carefully"
    echo "4. If issues occur, use './1_restore_factory.sh' to recover"
fi
echo "========================================"