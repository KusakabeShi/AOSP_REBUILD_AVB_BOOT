#!/bin/sh

SIGNED_PATH=patched_signed
BLOCK_PATH=/dev/block/by-name
A_SUFFIX=_a
B_SUFFIX=_b

# Parse command line arguments
CURRENT_SLOT=""
TARGET_SLOT=""
MODE="ota"
DRY_RUN=false
FORCE_FLASH=false

while [ $# -gt 0 ]; do
    case $1 in
        --slot)
            TARGET_SLOT="$2"
            shift 2
            ;;
        --mode)
            MODE="$2"
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
            echo "Usage: $0 [--slot a|b] [--mode ota|current] [--dry-run] [--force-flash]"
            echo "  --slot        : Target slot to flash (a or b), overrides mode"
            echo "  --mode        : Flash mode - 'ota' (other slot, default) or 'current' (current slot)"
            echo "  --dry-run     : Show what would be flashed without actually flashing"
            echo "  --force-flash : Flash without confirmation"
            exit 1
            ;;
    esac
done

echo "========================================"
echo "ANDROID IMAGE FLASHER"
echo "========================================"
echo "Preparing to flash signed Android images..."
echo ""

# Check if signed directory exists
if [ ! -d "$SIGNED_PATH" ]; then
    echo "ERROR: Signed directory not found: $SIGNED_PATH"
    echo "Please run './4_sign_patched.sh' first to create signed images."
    exit 1
fi

# Check if any signed images exist
signed_images=$(find "$SIGNED_PATH" -name "*.img" 2>/dev/null)
if [ -z "$signed_images" ]; then
    echo "ERROR: No .img files found in $SIGNED_PATH"
    echo "Please run './4_sign_patched.sh' first to create signed images."
    exit 1
fi

echo "Found signed images:"
images_to_flash=""
vbmeta_image=""
for img in $signed_images; do
    filename=$(basename "$img")
    echo "  ✓ $filename"
    if [ "$filename" = "vbmeta.img" ]; then
        vbmeta_image="$img"
    else
        images_to_flash="$images_to_flash $img"
    fi
done
echo ""

# Detect current slot
detect_current_slot() {
    
    # Try to detect current slot
    if [ -f "/proc/cmdline" ]; then
        if grep -q "androidboot.slot_suffix=_a" /proc/cmdline; then
            CURRENT_SLOT="a"
        elif grep -q "androidboot.slot_suffix=_b" /proc/cmdline; then
            CURRENT_SLOT="b"
        fi
    fi
    
    # Alternative method: check ro.boot.slot_suffix
    if [ -z "$CURRENT_SLOT" ]; then
        slot_suffix=$(getprop ro.boot.slot_suffix 2>/dev/null)
        case "$slot_suffix" in
            "_a") CURRENT_SLOT="a" ;;
            "_b") CURRENT_SLOT="b" ;;
        esac
    fi
    
    # Alternative method: check current active slot
    if [ -z "$CURRENT_SLOT" ] && command -v bootctl >/dev/null 2>&1; then
        current=$(bootctl get-current 2>/dev/null)
        case "$current" in
            "0") CURRENT_SLOT="a" ;;
            "1") CURRENT_SLOT="b" ;;
        esac
    fi
    
    if [ -n "$CURRENT_SLOT" ]; then
        echo "Auto-detected current active slot: $CURRENT_SLOT"
    else
        echo "ERROR: Cannot detect current active slot!"
        echo "Please specify current slot manually with --current-slot a or --current-slot b"
        exit 1
    fi
}

# Determine target slot based on mode
determine_target_slot() {
    if [ -n "$TARGET_SLOT" ]; then
        echo "Using manually specified target slot: $TARGET_SLOT (overrides mode)"
        return 0
    fi
    
    # Validate mode parameter
    if [ "$MODE" != "ota" ] && [ "$MODE" != "current" ]; then
        echo "ERROR: Invalid mode: $MODE"
        echo "Mode must be 'ota' or 'current'"
        exit 1
    fi
    
    # Determine target slot based on mode
    if [ "$MODE" = "ota" ]; then
        # OTA mode: flash to other slot
        if [ "$CURRENT_SLOT" = "a" ]; then
            TARGET_SLOT="b"
        else
            TARGET_SLOT="a"
        fi
        echo "Target slot: $TARGET_SLOT (OTA mode - other slot)"
    else
        # Current mode: flash to current slot
        TARGET_SLOT="$CURRENT_SLOT"
        echo "Target slot: $TARGET_SLOT (current mode - same slot)"
    fi
}

detect_current_slot
determine_target_slot

# Validate target slot
if [ "$TARGET_SLOT" != "a" ] && [ "$TARGET_SLOT" != "b" ]; then
    echo "ERROR: Invalid target slot: $TARGET_SLOT"
    echo "Target slot must be 'a' or 'b'"
    exit 1
fi

# Build partition mapping
echo ""
echo "========================================"
echo "FLASH CONFIGURATION"
echo "========================================"
echo "Current active slot: $CURRENT_SLOT"
echo "Flash mode: $MODE"
echo "Target slot: $TARGET_SLOT"
echo ""

target_suffix="_${TARGET_SLOT}"
flash_list=""
partition_checks=""

# Process each image to flash
for img in $images_to_flash; do
    filename=$(basename "$img")
    if echo "$filename" | grep -q "boot\.img"; then
        partition_name="boot"
    elif echo "$filename" | grep -q "init_boot\.img"; then
        partition_name="init_boot"
    else
        echo "ERROR: Cannot determine partition type from filename: $filename"
        exit 1
    fi
    
    partition_path="${BLOCK_PATH}/${partition_name}${target_suffix}"
    echo "Will flash: $filename -> $partition_path"
    flash_list="$flash_list $img:$partition_path:$partition_name"
    partition_checks="$partition_checks $partition_path"
done

# Add vbmeta if present
if [ -n "$vbmeta_image" ]; then
    vbmeta_partition="${BLOCK_PATH}/vbmeta${target_suffix}"
    echo "Will flash: vbmeta.img -> $vbmeta_partition"
    flash_list="$flash_list $vbmeta_image:$vbmeta_partition:vbmeta"
    partition_checks="$partition_checks $vbmeta_partition"
else
    echo "Note: No vbmeta.img found (chained partition mode)"
fi

echo ""

# Check if target partitions exist
echo "Verifying target partitions..."
for partition in $partition_checks; do
    if [ ! -b "$partition" ]; then
        echo "ERROR: Target partition not found: $partition"
        echo "This script must be run on an Android device with root access"
        exit 1
    fi
    echo "  ✓ $partition"
done

# Validate sizes for all images
echo ""
echo "Size validation:"
size_validation_failed=false

for entry in $flash_list; do
    image_file=$(echo "$entry" | cut -d: -f1)
    partition_path=$(echo "$entry" | cut -d: -f2)
    partition_name=$(echo "$entry" | cut -d: -f3)
    
    image_size=$(stat -c%s "$image_file")
    partition_size=$(blockdev --getsize64 "$partition_path")
    
    echo "  $partition_name: $image_size bytes (partition: $partition_size bytes)"
    
    if [ "$image_size" -gt "$partition_size" ]; then
        echo "    ERROR: Image too large for partition!"
        size_validation_failed=true
    fi
done

if [ "$size_validation_failed" = true ]; then
    echo "ERROR: One or more images are too large for their partitions"
    exit 1
fi

echo "✓ Size validation passed"

# Flash safety control: dry-run skips, force-flash proceeds, otherwise ask
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Skipping flash operation"
    echo ""
    echo "Would flash the following images:"
    for entry in $flash_list; do
        image_file=$(echo "$entry" | cut -d: -f1)
        partition_path=$(echo "$entry" | cut -d: -f2)
        echo "  $(basename "$image_file") -> $partition_path"
    done
    echo ""
    echo "Re-run without --dry-run to actually flash these images."
    skip_flash=true
elif [ "$FORCE_FLASH" = true ]; then
    echo "FORCE FLASH: Proceeding without confirmation"
    skip_flash=false
else
    echo ""
    echo "========================================"
    echo "CRITICAL WARNING"
    echo "========================================"
    echo "You are about to flash signed images to device partitions!"
    echo "This will modify your device's boot process."
    echo ""
    echo "Target slot: $TARGET_SLOT"
    echo "Images to flash:"
    for entry in $flash_list; do
        image_file=$(echo "$entry" | cut -d: -f1)
        partition_path=$(echo "$entry" | cut -d: -f2)
        echo "  $(basename "$image_file") -> $partition_path"
    done
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
    skip_flash=false
fi

# Flash images (if not skipped)
if [ "$skip_flash" = false ]; then
    echo ""
    echo "========================================"
    echo "FLASHING PROCESS"
    echo "========================================"

    flash_image() {
        local source_image=$1
        local target_partition=$2
        local partition_name=$3
        
        echo "Flashing $partition_name..."
        echo "  Executing: dd if=$source_image of=$target_partition bs=4096"
        if dd if="$source_image" of="$target_partition" bs=4096 2>/dev/null; then
            echo "  ✓ Successfully flashed $partition_name"
        else
            echo "  ERROR: Failed to flash $partition_name"
            return 1
        fi
    }

    # Flash all images
    flash_failed=false
    for entry in $flash_list; do
        image_file=$(echo "$entry" | cut -d: -f1)
        partition_path=$(echo "$entry" | cut -d: -f2)
        partition_name=$(echo "$entry" | cut -d: -f3)
        
        if ! flash_image "$image_file" "$partition_path" "$partition_name"; then
            echo "ERROR: $partition_name flashing failed!"
            flash_failed=true
        fi
    done

    if [ "$flash_failed" = true ]; then
        echo "ERROR: One or more flash operations failed!"
        exit 1
    fi
fi

echo ""
echo "========================================"
if [ "$skip_flash" = true ]; then
    echo "OPERATION COMPLETE (DRY RUN)"
    echo "========================================"
    echo "Image validation completed successfully"
    echo "Flash operation was skipped (dry-run mode)"
    echo ""
    echo "Images are ready to flash to slot $TARGET_SLOT:"
    for entry in $flash_list; do
        partition_name=$(echo "$entry" | cut -d: -f3)
        echo "  ✓ $partition_name"
    done
    echo ""
    echo "Re-run without --dry-run to flash these images."
else
    echo "FLASHING COMPLETE"
    echo "========================================"
    echo "Successfully flashed to slot $TARGET_SLOT:"
    for entry in $flash_list; do
        partition_name=$(echo "$entry" | cut -d: -f3)
        echo "  ✓ $partition_name"
    done
    echo ""
    echo "NEXT STEPS:"
    echo "1. Reboot your device to test the changes"
    echo "2. Monitor the device boot process carefully"
    echo "3. If issues occur, use './1_restore_factory.sh' to recover"
fi
echo "========================================"

# Cleanup temporary files
echo ""
echo "Cleaning up temporary files..."
# Clean up any temporary image files in project root
for img in *.img; do
    if [ -f "$img" ]; then
        rm -f "$img"
        echo "✓ Cleaned up temporary image file: $img"
    fi
done