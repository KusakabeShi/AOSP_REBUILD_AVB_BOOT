#!/bin/sh

PATCHED_PATH=patched
TMP_DIR=tmp

BLOCK_PATH=/dev/block/by-name
A_SUFFIX=_a
B_SUFFIX=_b
BOOT=boot
INIT=init_boot
META=vbmeta

# Parse command line arguments
CURRENT_SLOT=""
TARGET_SLOT=""
SPECIFIC_PARTITION=""
DRY_RUN=false
FORCE_DUMP=false

while [ $# -gt 0 ]; do
    case $1 in
        --slot)
            TARGET_SLOT="$2"
            shift 2
            ;;
        --current-slot)
            CURRENT_SLOT="$2"
            shift 2
            ;;
        --partition)
            SPECIFIC_PARTITION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force-dump)
            FORCE_DUMP=true
            shift
            ;;
        *)
            echo "Usage: $0 [--slot a|b] [--current-slot a|b] [--partition boot|init_boot] [--dry-run] [--force-dump]"
            echo "  --slot        : Target slot to dump (a or b), defaults to inactive slot"
            echo "  --current-slot: Current active slot for auto-detection, auto-detect if not provided"
            echo "  --partition   : Dump specific partition only (boot or init_boot)"
            echo "  --dry-run     : Show what would be dumped without actually dumping"
            echo "  --force-dump  : Dump without confirmation"
            exit 1
            ;;
    esac
done

# Create directories
mkdir -p $TMP_DIR
mkdir -p $PATCHED_PATH

echo "========================================"
echo "USER PATCHED IMAGE DUMPER"
echo "========================================"
echo "Dumping user-patched images from root manager..."
echo ""

# Detect current slot if not provided
detect_current_slot() {
    if [ -n "$CURRENT_SLOT" ]; then
        echo "Using manually specified current slot: $CURRENT_SLOT"
        return 0
    fi
    
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

# Determine target slot (inactive slot by default)
determine_target_slot() {
    if [ -n "$TARGET_SLOT" ]; then
        echo "Using manually specified target slot: $TARGET_SLOT"
        return 0
    fi
    
    # Default to inactive slot (where user likely applied patches)
    if [ "$CURRENT_SLOT" = "a" ]; then
        TARGET_SLOT="b"
        echo "Auto-selected target slot: $TARGET_SLOT (inactive slot - likely patched by user)"
    elif [ "$CURRENT_SLOT" = "b" ]; then
        TARGET_SLOT="a"
        echo "Auto-selected target slot: $TARGET_SLOT (inactive slot - likely patched by user)"
    else
        echo "ERROR: Cannot determine target slot!"
        echo "Please specify target slot manually with --slot a or --slot b"
        exit 1
    fi
}

detect_current_slot
determine_target_slot

echo ""
echo "========================================"
echo "CONFIGURATION SUMMARY"
echo "========================================"
echo "Current active slot: $CURRENT_SLOT"
echo "Target slot to dump: $TARGET_SLOT"
if [ -n "$SPECIFIC_PARTITION" ]; then
    echo "Specific partition: $SPECIFIC_PARTITION"
else
    echo "Partitions to dump: boot, init_boot, vbmeta"
fi
echo ""

# Function to check if image is patched by comparing with backup
check_if_patched() {
    local image_file=$1
    local partition_name=$2
    local suffix=$3
    local backup_file="backups/${partition_name}${suffix}.img"
    
    echo "Checking if $partition_name is patched..."
    
    if [ ! -f "$backup_file" ]; then
        echo "  ⚠ No backup found for ${partition_name}${suffix}, assuming patched"
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        echo "  DRY RUN: Would compare $image_file with $backup_file"
        return 0
    fi
    
    # Compare hashes to detect if image was modified
    current_hash=$(dd if="$image_file" bs=4096 2>/dev/null | sha256sum | cut -d' ' -f1)
    backup_hash=$(sha256sum "$backup_file" | cut -d' ' -f1)
    
    if [ "$current_hash" = "$backup_hash" ]; then
        echo "  ✓ $partition_name matches backup (not patched)"
        return 1
    else
        echo "  ✓ $partition_name differs from backup (patched by user)"
        return 0
    fi
}

# Function to dump partition
dump_partition() {
    local partition=$1
    local suffix=$2
    local partition_path="$BLOCK_PATH/${partition}${suffix}"
    local output_file="$PATCHED_PATH/${partition}.img"
    
    if [ ! -b "$partition_path" ]; then
        echo "Warning: Partition $partition_path does not exist, skipping..."
        return 1
    fi
    
    echo "Dumping ${partition}${suffix}..."
    
    if dd if="$partition_path" of="$output_file" bs=4096 2>/dev/null; then
        echo "  ✓ Successfully dumped ${partition}${suffix} to $output_file"
        
        # Check if boot and init_boot are patched by comparing with backup (always keep vbmeta)
        if [ "$partition" = "$BOOT" ] || [ "$partition" = "$INIT" ]; then
            check_if_patched "$output_file" "$partition" "$suffix"
        elif [ "$partition" = "$META" ]; then
            echo "  ✓ vbmeta dumped (always kept for next step)"
        fi
        
        return 0
    else
        echo "  ERROR: Failed to dump ${partition}${suffix}"
        return 1
    fi
}

target_suffix="_${TARGET_SLOT}"

# Dumping safety control: dry-run skips, force-dump proceeds, otherwise ask  
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Skipping partition dump operation"
    echo ""
    echo "Would dump the following from slot $TARGET_SLOT:"
    if [ -n "$SPECIFIC_PARTITION" ]; then
        echo "  $SPECIFIC_PARTITION partition only"
    else
        echo "  boot, init_boot, vbmeta partitions"
    fi
    echo ""
    echo "Re-run without --dry-run to actually dump these partitions."
    exit 0
elif [ "$FORCE_DUMP" = true ]; then
    echo "FORCE DUMP: Proceeding without confirmation"
else
    echo "About to dump user-patched images from slot $TARGET_SLOT"
    echo ""
    echo "WARNING: This will access device partitions directly!"
    echo "This operation will read data from live device partitions."
    echo ""
    if [ -n "$SPECIFIC_PARTITION" ]; then
        echo "Will dump: $SPECIFIC_PARTITION only"
    else
        echo "Will dump: boot, init_boot, vbmeta"
    fi
    echo ""
    echo -n "Are you absolutely sure you want to continue? (type 'YES' to confirm): "
    read -r response
    if [ "$response" != "YES" ]; then
        echo "Dump operation cancelled for safety"
        echo ""
        echo "No partitions were accessed."
        exit 0
    fi
    echo "Proceeding with dump..."
fi

echo ""
echo "========================================"
echo "DUMPING PROCESS"
echo "========================================"

# Dump partitions based on user selection
dumped_count=0
if [ -n "$SPECIFIC_PARTITION" ]; then
    # Dump only specified partition
    case "$SPECIFIC_PARTITION" in
        "boot")
            if dump_partition "$BOOT" "$target_suffix"; then
                dumped_count=$((dumped_count + 1))
            fi
            ;;
        "init_boot")
            if dump_partition "$INIT" "$target_suffix"; then
                dumped_count=$((dumped_count + 1))
            fi
            ;;
        *)
            echo "ERROR: Invalid partition specified. Use 'boot' or 'init_boot'"
            exit 1
            ;;
    esac
else
    # Dump all partitions
    for partition in $BOOT $INIT $META; do
        if dump_partition "$partition" "$target_suffix"; then
            dumped_count=$((dumped_count + 1))
        fi
    done
fi

echo ""
echo "========================================"
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN COMPLETE"
    echo "========================================"
    echo "Would have dumped from slot $TARGET_SLOT:"
    if [ -n "$SPECIFIC_PARTITION" ]; then
        echo "  ✓ $SPECIFIC_PARTITION"
    else
        echo "  ✓ boot, init_boot, vbmeta"
    fi
    echo ""
    echo "Images would be checked against backups to verify patching"
    echo "vbmeta would be dumped as-is"
else
    echo "DUMPING COMPLETE"
    echo "========================================"
    if [ $dumped_count -gt 0 ]; then
        echo "Successfully dumped $dumped_count partition(s) from slot $TARGET_SLOT:"
        if [ -n "$SPECIFIC_PARTITION" ]; then
            echo "  ✓ $SPECIFIC_PARTITION"
        else
            for partition in $BOOT $INIT $META; do
                output_file="$PATCHED_PATH/${partition}.img"
                if [ -f "$output_file" ]; then
                    echo "  ✓ $partition"
                fi
            done
        fi
        echo ""
        echo "NEXT STEPS:"
        echo "1. Images are ready in $PATCHED_PATH/ directory"
        echo "2. Run './4_sign_patched.sh' to sign with your private key"
        echo "3. Use './5_flash.sh' to flash signed images"
    else
        echo "No partitions were successfully dumped"
        exit 1
    fi
fi
echo "========================================"

# Cleanup temporary files
echo ""
echo "Cleaning up temporary files..."
if [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
    echo "✓ Temporary files cleaned up"
else
    echo "✓ No temporary files to clean up"
fi

# Clean up any temporary image files in project root
for img in *.img; do
    if [ -f "$img" ]; then
        rm -f "$img"
        echo "✓ Cleaned up temporary image file: $img"
    fi
done