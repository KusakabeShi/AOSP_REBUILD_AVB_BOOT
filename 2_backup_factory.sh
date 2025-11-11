#!/bin/sh

IMG_BAK_PATH=backups
NEW_BAK_PATH=new_backups
TMP_DIR=tmp

BLOCK_PATH=/dev/block/by-name
A_SUFFIX=_a
B_SUFFIX=_b
BOOT=boot
INIT=init_boot
META=vbmeta

# Parse command line arguments
DRY_RUN=false
FORCE_BACKUP=false

while [ $# -gt 0 ]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force-backup)
            FORCE_BACKUP=true
            shift
            ;;
        *)
            echo "Usage: $0 [--dry-run] [--force-backup]"
            echo "  --dry-run     : Only check differences, don't backup"
            echo "  --force-backup : Backup without confirmation"
            exit 1
            ;;
    esac
done

# Create directories
mkdir -p $TMP_DIR
mkdir -p $NEW_BAK_PATH

# Function to calculate hash of partition
calculate_partition_hash() {
    local partition_path=$1
    local output_file=$2
    
    if [ ! -b "$partition_path" ]; then
        echo "Error: Partition $partition_path does not exist!"
        exit 1
    fi
    
    # Get partition size and calculate hash
    partition_size=$(blockdev --getsize64 "$partition_path")
    dd if="$partition_path" bs=4096 count=$((partition_size/4096)) 2>/dev/null | sha256sum | cut -d' ' -f1 > "$output_file"
}

# Function to backup single partition
backup_partition() {
    local partition=$1
    local suffix=$2
    local partition_path="$BLOCK_PATH/${partition}${suffix}"
    local backup_img="$NEW_BAK_PATH/${partition}${suffix}.img"
    
    if [ ! -b "$partition_path" ]; then
        echo "Warning: Partition $partition_path does not exist, skipping..."
        return 0
    fi
    
    echo "Backing up ${partition}${suffix}..."
    
    if [ "$DRY_RUN" = true ]; then
        echo "  DRY RUN: Would backup $partition_path to $backup_img"
        return 0
    fi
    
    if [ "$FORCE_BACKUP" = false ]; then
        echo -n "Backup $partition_path to $backup_img? (y/N): "
        read -r response
        case $response in
            [yY]|[yY][eE][sS])
                ;;
            *)
                echo "  Skipped backing up ${partition}${suffix}"
                return 0
                ;;
        esac
    fi
    
    if dd if="$partition_path" of="$backup_img" bs=4096; then
        echo "  Successfully backed up ${partition}${suffix}"
    else
        echo "Error: Failed to backup ${partition}${suffix}"
        exit 1
    fi
}

echo "Checking for changes in partitions..."

# Check if original backups exist
changes_detected=false
if [ ! -d "$IMG_BAK_PATH" ]; then
    echo "No original backups found. This appears to be the first backup."
    changes_detected=true
else
    echo "Comparing current partitions with original backups..."
    
    # Calculate hashes for current partitions and compare with original backups
    for suffix in $A_SUFFIX $B_SUFFIX; do
        for partition in $BOOT $INIT $META; do
            partition_path="$BLOCK_PATH/${partition}${suffix}"
            backup_img="$IMG_BAK_PATH/${partition}${suffix}.img"
            current_hash_file="$TMP_DIR/current_${partition}${suffix}.hash"
            backup_hash_file="$TMP_DIR/backup_${partition}${suffix}.hash"
            
            if [ ! -b "$partition_path" ]; then
                echo "Warning: Partition $partition_path does not exist, skipping..."
                continue
            fi
            
            if [ ! -f "$backup_img" ]; then
                echo "  ${partition}${suffix}: Original backup missing, change detected"
                changes_detected=true
                continue
            fi
            
            # Calculate current partition hash
            calculate_partition_hash "$partition_path" "$current_hash_file"
            
            # Calculate original backup hash
            sha256sum "$backup_img" | cut -d' ' -f1 > "$backup_hash_file"
            
            # Compare hashes
            if cmp -s "$current_hash_file" "$backup_hash_file"; then
                echo "  ${partition}${suffix}: No changes detected"
            else
                echo "  ${partition}${suffix}: Changes detected"
                changes_detected=true
            fi
        done
    done
fi

echo ""
echo "========================================="
echo "BACKUP DECISION SUMMARY"  
echo "========================================="

if [ "$changes_detected" = false ]; then
    echo "No changes detected in any partition."
    echo ""
    echo "========================================="
    echo "WARNING: OTA UPDATE MAY NOT BE COMPLETE"
    echo "========================================="
    echo "This usually means:"
    echo "  1. OTA update has not been applied yet"
    echo "  2. OTA update made no changes to boot/init_boot/vbmeta partitions"
    echo ""
    echo "RECOMMENDATION:"
    echo "Please ensure OTA update is properly completed before proceeding."
    echo "If OTA is truly complete, you can patch with existing backups."
    echo ""
    echo "Backup operation cancelled - no new backup needed."
    echo "========================================="
    exit 0
else
    echo "Changes detected in partitions - OTA update appears to be applied!"
    echo "Now dumping partitions and verifying signatures..."
fi

# Perform backup of all partitions
echo ""
echo "Backing up current partitions..."
for suffix in $A_SUFFIX $B_SUFFIX; do
    for partition in $BOOT $INIT $META; do
        backup_partition "$partition" "$suffix"
    done
done

# Verify new backup images integrity
echo ""
echo "Verifying backup image integrity..."
if ! sh verify_images.sh $NEW_BAK_PATH; then
    echo "Backup image integrity check failed! Not proceeding."
    exit 1
fi

# Verify signatures of the new partitions
echo ""
echo "========================================="
echo "SIGNATURE VERIFICATION"
echo "========================================="
echo "Verifying signatures of post-OTA partitions..."

signature_valid=true
for suffix in $A_SUFFIX $B_SUFFIX; do
    for partition in $BOOT $INIT $META; do
        backup_img="$NEW_BAK_PATH/${partition}${suffix}.img"
        
        if [ ! -f "$backup_img" ]; then
            continue
        fi
        
        echo "Checking signature for ${partition}${suffix}..."
        
        if ! python3 tools/avbtool.py verify_image --image "$backup_img" >/dev/null 2>&1; then
            echo "  ERROR: Invalid signature for ${partition}${suffix}"
            signature_valid=false
        else
            echo "  OK: Valid signature for ${partition}${suffix}"
        fi
    done
done

if [ "$signature_valid" = false ]; then
    echo ""
    echo "========================================="
    echo "CRITICAL ERROR: SIGNATURE VERIFICATION FAILED"
    echo "========================================="
    echo "One or more partitions have invalid signatures!"
    echo ""
    echo "This could indicate:"
    echo "  1. OTA package integrity issues"
    echo "  2. Corrupted OTA installation"
    echo "  3. Manual modifications made to partitions"
    echo "  4. Patching was applied without proper signing"
    echo ""
    echo "RECOMMENDATIONS:"
    echo "  1. Verify OTA package integrity and re-apply OTA"
    echo "  2. Check for any manual modifications or patches"
    echo "  3. Do NOT proceed with patching until this is resolved"
    echo ""
    echo "Backup operation CANCELLED for safety."
    echo "========================================="
    exit 1
fi

echo ""
echo "All signatures verified successfully!"

# Replace original backups with new ones
if [ "$DRY_RUN" = false ]; then
    echo "Signature verification passed. Replacing original backups..."
    
    # Backup old backups if they exist
    if [ -d "$IMG_BAK_PATH" ]; then
        mv "$IMG_BAK_PATH" "${IMG_BAK_PATH}.old.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Move new backups to original location
    mv "$NEW_BAK_PATH" "$IMG_BAK_PATH"
    
    echo ""
    echo "========================================="
    echo "SUCCESS - POST-OTA BACKUP COMPLETE"
    echo "========================================="
    echo "✓ OTA changes detected and verified"
    echo "✓ Signatures validated"
    echo "✓ New backup created successfully"
    echo ""
    echo "NEXT STEPS:"
    echo "You can now safely proceed to patch with:"
    echo "  • Magisk/KernelSU/APatch/SukiSU"
    echo "  • Run './3_patch.sh' to apply patches"
    echo "  • Use './1_restore_factory.sh' to restore anytime"
    echo "========================================="
else
    echo "DRY RUN: Would replace original backups with signature-verified new backups."
    echo ""
    echo "========================================="
    echo "DRY RUN - BACKUP WOULD BE COMPLETE"
    echo "========================================="
    echo "✓ OTA changes would be detected and verified"
    echo "✓ Signatures would be validated"  
    echo "✓ New backup would be created successfully"
    echo ""
    echo "NEXT STEPS (after actual backup):"
    echo "You can safely proceed to patch with:"
    echo "  • Magisk/KernelSU/APatch/SukiSU"
    echo "  • Run './3_patch.sh' to apply patches" 
    echo "  • Use './1_restore_factory.sh' to restore anytime"
    echo "========================================"
fi

# Cleanup temporary files
echo ""
echo "Cleaning up temporary files..."
if [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
    echo "✓ Temporary files cleaned up"
else
    echo "✓ No temporary files to clean up"
fi

# Clean up new backup directory if it still exists (dry run or failure cases)
if [ -d "$NEW_BAK_PATH" ] && [ "$DRY_RUN" = true ]; then
    rm -rf "$NEW_BAK_PATH"
    echo "✓ Dry run backup directory cleaned up"
fi

# Clean up any temporary image files in project root
for img in *.img; do
    if [ -f "$img" ]; then
        rm -f "$img"
        echo "✓ Cleaned up temporary image file: $img"
    fi
done