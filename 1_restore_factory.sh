#!/bin/sh

IMG_BAK_PATH=backups
KEY_FILE="tools/pem/testkey_rsa4096.pem"
TMP_DIR=tmp

BLOCK_PATH=/dev/block/by-name
A_SUFFIX=_a
B_SUFFIX=_b
BOOT=boot
INIT=init_boot
META=vbmeta


# Create tmp directory for hash calculations
mkdir -p $TMP_DIR

# Parse command line arguments
DRY_RUN=false
FORCE_FLASH=false

while [ $# -gt 0 ]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force-flash)
            FORCE_FLASH=true
            shift
            ;;
        *)
            echo "Usage: $0 [--dry-run] [--force-flash]"
            echo "  --dry-run     : Only verify images, don't flash"
            echo "  --force-flash : Flash without confirmation"
            exit 1
            ;;
    esac
done

# Verify backup images using shared verification script
echo "Verifying backup images..."
if ! sh verify_images.sh $IMG_BAK_PATH; then
    echo "Backup image verification failed!"
    exit 1
fi

# Check partition availability
echo "Checking partition availability..."
missing_partitions=0
for suffix in $A_SUFFIX $B_SUFFIX; do
    for partition in $BOOT $INIT $META; do
        partition_path="$BLOCK_PATH/${partition}${suffix}"
        if [ ! -b "$partition_path" ]; then
            echo "Warning: Partition $partition_path does not exist"
            missing_partitions=$((missing_partitions + 1))
        fi
    done
done

if [ $missing_partitions -gt 0 ]; then
    echo ""
    echo "========================================="
    echo "IMPORTANT: Missing partitions detected!"
    echo "========================================="
    echo "This script is designed to run on an Android phone with root access."
    echo "Please ensure you are running this script on the target Android device"
    echo "with the following requirements:"
    echo "  1. Root access (su permissions)"
    echo "  2. Android device with A/B partition scheme"
    echo "  3. Run from a terminal emulator or ADB shell"
    echo ""
    echo "If you are on the correct device and still see missing partitions,"
    echo "some partitions may not be available on your device model."
    echo "The script will skip missing partitions automatically."
    echo "========================================="
    echo ""
fi

# Check partition sizes before proceeding
echo "Checking partition sizes..."
size_errors=0
for suffix in $A_SUFFIX $B_SUFFIX; do
    for partition in $BOOT $INIT $META; do
        partition_path="$BLOCK_PATH/${partition}${suffix}"
        backup_img="$IMG_BAK_PATH/${partition}${suffix}.img"
        
        # Skip if partition or backup doesn't exist
        if [ ! -b "$partition_path" ] || [ ! -f "$backup_img" ]; then
            continue
        fi
        
        # Compare sizes
        backup_size=$(stat -c%s "$backup_img")
        partition_size=$(blockdev --getsize64 "$partition_path")
        
        if [ "$backup_size" -ne "$partition_size" ]; then
            echo "ERROR: Size mismatch for ${partition}${suffix}:"
            echo "  Backup image: $backup_size bytes"
            echo "  Partition:    $partition_size bytes"
            size_errors=$((size_errors + 1))
        else
            echo "  ${partition}${suffix}: Size OK ($backup_size bytes)"
        fi
    done
done

if [ $size_errors -gt 0 ]; then
    echo ""
    echo "========================================="
    echo "FATAL ERROR: Partition size mismatches detected!"
    echo "========================================="
    echo "Found $size_errors size mismatches. Cannot proceed with flashing."
    echo "This usually indicates:"
    echo "  1. Backup images are from a different device model"
    echo "  2. Backup images are corrupted"
    echo "  3. Wrong partition scheme (A-only vs A/B)"
    echo ""
    echo "Please verify your backup images are correct for this device."
    echo "========================================="
    exit 1
fi

echo "All partition sizes match. Proceeding..."
echo ""

flash_single_partition() {
    local partition_name=$1
    local backup_img="$IMG_BAK_PATH/${partition_name}.img"
    local partition_path="$BLOCK_PATH/${partition_name}"
    
    if [ "$FORCE_FLASH" = false ]; then
        echo -n "Flash $backup_img to $partition_path? (y/N): "
        read -r response
        case $response in
            [yY]|[yY][eE][sS])
                ;;
            *)
                echo "  Skipped flashing ${partition_name}"
                return 0
                ;;
        esac
    fi
    
    echo "  Flashing $backup_img to $partition_path..."
    if dd if="$backup_img" of="$partition_path" bs=4096; then
        echo "  Successfully flashed ${partition_name}"
    else
        echo "Error: Failed to flash ${partition_name}"
        exit 1
    fi
}

# Check all partitions first and collect differences
echo "Checking all partitions for differences..."
different_partitions=""
total_checked=0
total_different=0

for suffix in $A_SUFFIX $B_SUFFIX; do
    for partition in $BOOT $INIT $META; do
        partition_path="$BLOCK_PATH/${partition}${suffix}"
        backup_img="$IMG_BAK_PATH/${partition}${suffix}.img"
        
        if [ ! -b "$partition_path" ]; then
            echo "  ${partition}${suffix}: Partition not found, skipping..."
            continue
        fi
        
        if [ ! -f "$backup_img" ]; then
            echo "  ${partition}${suffix}: Backup image not found, skipping..."
            continue
        fi
        
        total_checked=$((total_checked + 1))
        
        # Compare content by hash (size already verified above)
        backup_size=$(stat -c%s "$backup_img")
        backup_hash=$(sha256sum "$backup_img" | cut -d' ' -f1)
        partition_hash=$(dd if="$partition_path" bs=4096 count=$((backup_size/4096)) 2>/dev/null | sha256sum | cut -d' ' -f1)
        
        if [ "$backup_hash" = "$partition_hash" ]; then
            echo "  ${partition}${suffix}: Content matches, no flash needed"
        else
            echo "  ${partition}${suffix}: Content differs, flash needed"
            different_partitions="$different_partitions ${partition}${suffix}"
            total_different=$((total_different + 1))
        fi
    done
done

echo ""
echo "========================================="
echo "PARTITION COMPARISON SUMMARY"
echo "========================================="
echo "Total partitions checked: $total_checked"
echo "Partitions needing flash: $total_different"

if [ $total_different -gt 0 ]; then
    echo "Different partitions:$different_partitions"
    echo ""
    
    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN mode: No actual flashing will be performed."
        for partition_name in $different_partitions; do
            echo "  Would flash: $IMG_BAK_PATH/${partition_name}.img -> $BLOCK_PATH/${partition_name}"
        done
    else
        echo "Proceeding with flashing different partitions..."
        for partition_name in $different_partitions; do
            flash_single_partition "$partition_name"
        done
    fi
else
    echo "All partitions match their backups. No flashing needed."
fi

echo "Success, you can perform OTA now."

# Cleanup temporary files
echo ""
echo "Cleaning up temporary files..."
if [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
    echo "✓ Temporary files cleaned up"
else
    echo "✓ No temporary files to clean up"
fi
