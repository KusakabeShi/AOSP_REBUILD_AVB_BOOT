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

echo "========================================"
echo "POST-OTA BACKUP CREATOR"
echo "========================================"
echo "Dumping all 6 partitions and comparing with existing backups..."
echo ""

# Function to dump partition
dump_partition() {
    local partition=$1
    local suffix=$2
    local partition_path="$BLOCK_PATH/${partition}${suffix}"
    local backup_img="$NEW_BAK_PATH/${partition}${suffix}.img"
    
    if [ ! -b "$partition_path" ]; then
        echo "Warning: Partition $partition_path does not exist, skipping..."
        return 1
    fi
    
    echo "Dumping ${partition}${suffix}..."
    
    if dd if="$partition_path" of="$backup_img" bs=4096 2>/dev/null; then
        echo "  ✓ Successfully dumped ${partition}${suffix}"
        return 0
    else
        echo "  ERROR: Failed to dump ${partition}${suffix}"
        return 1
    fi
}

# Step 1: Dump all 6 partitions to new_backups
echo "========================================="
echo "DUMPING PARTITIONS"
echo "========================================="

dumped_count=0
for suffix in $A_SUFFIX $B_SUFFIX; do
    for partition in $BOOT $INIT $META; do
        if dump_partition "$partition" "$suffix"; then
            dumped_count=$((dumped_count + 1))
        fi
    done
done

if [ $dumped_count -eq 0 ]; then
    echo "ERROR: No partitions were successfully dumped"
    exit 1
fi

echo ""
echo "Successfully dumped $dumped_count partition(s)"

# Step 2: Compare 6 file hashes between backups (if exist, else skip)
echo ""
echo "========================================="
echo "COMPARING WITH EXISTING BACKUPS"
echo "========================================="

changes_detected=false
if [ ! -d "$IMG_BAK_PATH" ]; then
    echo "No existing backups found. This appears to be the first backup."
    changes_detected=true
else
    echo "Comparing dumped partitions with existing backups..."
    
    for suffix in $A_SUFFIX $B_SUFFIX; do
        for partition in $BOOT $INIT $META; do
            new_img="$NEW_BAK_PATH/${partition}${suffix}.img"
            old_img="$IMG_BAK_PATH/${partition}${suffix}.img"
            
            if [ ! -f "$new_img" ]; then
                continue
            fi
            
            if [ ! -f "$old_img" ]; then
                echo "  ${partition}${suffix}: No existing backup, change detected"
                changes_detected=true
                continue
            fi
            
            # Compare file hashes
            new_hash=$(sha256sum "$new_img" | cut -d' ' -f1)
            old_hash=$(sha256sum "$old_img" | cut -d' ' -f1)
            
            if [ "$new_hash" = "$old_hash" ]; then
                echo "  ${partition}${suffix}: No changes detected"
            else
                echo "  ${partition}${suffix}: Changes detected"
                changes_detected=true
            fi
        done
    done
fi

# Step 3: Verify signatures
echo ""
echo "========================================="
echo "SIGNATURE VERIFICATION"
echo "========================================="
echo "Verifying signatures of dumped partitions..."

# Verify backup integrity first
echo "Verifying backup image integrity..."
if ! sh verify_images.sh $NEW_BAK_PATH; then
    echo "Backup image integrity check failed! Not proceeding."
    exit 1
fi

# Verify signatures for each slot separately using verify_images.sh
signature_valid=true
for suffix in $A_SUFFIX $B_SUFFIX; do
    echo "Verifying slot ${suffix#_} signatures..."
    
    # Check if all three partition files exist for this slot
    boot_img="$NEW_BAK_PATH/boot${suffix}.img"
    init_img="$NEW_BAK_PATH/init_boot${suffix}.img"
    vbmeta_img="$NEW_BAK_PATH/vbmeta${suffix}.img"
    
    missing_files=""
    if [ ! -f "$boot_img" ]; then missing_files="$missing_files boot${suffix}.img"; fi
    if [ ! -f "$init_img" ]; then missing_files="$missing_files init_boot${suffix}.img"; fi
    if [ ! -f "$vbmeta_img" ]; then missing_files="$missing_files vbmeta${suffix}.img"; fi
    
    if [ -n "$missing_files" ]; then
        echo "  Skipping slot ${suffix#_} verification - missing files:$missing_files"
        continue
    fi
    
    # Create temporary directory for renamed files (required by avbtool.py)
    temp_verify_dir="$TMP_DIR/verify_slot_${suffix#_}"
    mkdir -p "$temp_verify_dir"
    
    # Copy and rename files to standard names required by avbtool.py
    cp "$boot_img" "$temp_verify_dir/boot.img"
    cp "$init_img" "$temp_verify_dir/init_boot.img" 
    cp "$vbmeta_img" "$temp_verify_dir/vbmeta.img"
    
    # Verify signatures using verify_images.sh
    if sh verify_images.sh "$temp_verify_dir"; then
        echo "  ✓ Slot ${suffix#_} signatures valid"
    else
        echo "  ERROR: Slot ${suffix#_} signature verification failed!"
        signature_valid=false
    fi
    
    # Clean up temporary verification directory
    rm -rf "$temp_verify_dir"
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

# Step 4: Hint user about changed partitions
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
    echo "New backup contains verified post-OTA images."
fi

# Step 5: Overwrite to original backups folder (dangerous part)
echo ""
echo "========================================="
echo "INSTALL NEW BACKUP"
echo "========================================="

# Installation safety control: dry-run skips, force-backup proceeds, otherwise ask
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Skipping backup replacement operation"
    echo ""
    echo "New verified backups are ready in $NEW_BAK_PATH:"
    for suffix in $A_SUFFIX $B_SUFFIX; do
        for partition in $BOOT $INIT $META; do
            backup_img="$NEW_BAK_PATH/${partition}${suffix}.img"
            if [ -f "$backup_img" ]; then
                echo "  ✓ ${partition}${suffix}.img"
            fi
        done
    done
    echo ""
    echo "Re-run without --dry-run to replace current backups."
elif [ "$FORCE_BACKUP" = true ]; then
    echo "FORCE BACKUP: Proceeding without confirmation"
    
    # Backup old backups if they exist
    if [ -d "$IMG_BAK_PATH" ]; then
        mv "$IMG_BAK_PATH" "${IMG_BAK_PATH}.old.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Move new backups to original location
    mv "$NEW_BAK_PATH" "$IMG_BAK_PATH"
else
    echo "About to replace current backup images with new post-OTA backups"
    echo ""
    if [ -d "$IMG_BAK_PATH" ]; then
        echo "WARNING: This will overwrite your current backup images!"
        echo "Current backups will be moved to ${IMG_BAK_PATH}.old.$(date +%Y%m%d_%H%M%S)"
    else
        echo "INFO: No existing backups found - creating initial backup."
    fi
    echo ""
    echo "New backups to install:"
    for suffix in $A_SUFFIX $B_SUFFIX; do
        for partition in $BOOT $INIT $META; do
            backup_img="$NEW_BAK_PATH/${partition}${suffix}.img"
            if [ -f "$backup_img" ]; then
                echo "  ✓ ${partition}${suffix}.img"
            fi
        done
    done
    echo ""
    echo -n "Are you absolutely sure you want to continue? (type 'YES' to confirm): "
    read -r response
    if [ "$response" != "YES" ]; then
        echo "Backup operation cancelled for safety"
        echo ""
        echo "New backups remain available in $NEW_BAK_PATH for manual review."
        exit 0
    fi
    echo "Proceeding with backup replacement..."
    
    # Backup old backups if they exist
    if [ -d "$IMG_BAK_PATH" ]; then
        mv "$IMG_BAK_PATH" "${IMG_BAK_PATH}.old.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Move new backups to original location
    mv "$NEW_BAK_PATH" "$IMG_BAK_PATH"
fi

echo ""
echo "========================================="
if [ "$DRY_RUN" = true ]; then
    echo "OPERATION COMPLETE (DRY RUN)"
    echo "========================================="
    echo "✓ OTA changes detected and verified"
    echo "✓ Signatures validated"  
    echo "✓ New backup created in $NEW_BAK_PATH"
    echo ""
    echo "Backup replacement was skipped (dry-run mode)"
    echo ""
    echo "NEXT STEPS:"
    echo "Re-run without --dry-run to install the new backups."
else
    echo "SUCCESS - POST-OTA BACKUP COMPLETE"
    echo "========================================="
    echo "✓ OTA changes detected and verified"
    echo "✓ Signatures validated"
    echo "✓ New backup installed successfully"
    echo ""
    echo "NEXT STEPS:"
    echo "You can now safely proceed to patch with:"
    echo "  • Magisk/KernelSU/APatch/SukiSU"
    echo "  • Run './3_patch.sh' to apply patches"
    echo "  • Use './1_restore_factory.sh' to restore anytime"
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

# Clean up new backup directory if it still exists (dry run cases only)
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