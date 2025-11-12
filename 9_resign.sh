#!/bin/sh

SIGNED_PATH=current_signed
TMP_DIR=tmp
REBUILD_AVB_PATH=.

BLOCK_PATH=/dev/block/by-name
A_SUFFIX=_a
B_SUFFIX=_b
BOOT=boot
INIT=init_boot
META=vbmeta

# Parse command line arguments
CURRENT_SLOT=""
TARGET_SLOT=""
MODE="current"
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
            echo "  --slot        : Target slot to resign (a or b), overrides mode"
            echo "  --mode        : Resign mode - 'current' (current slot, default) or 'ota' (other slot)"
            echo "  --dry-run     : Show what would be done without actually doing it"
            echo "  --force-flash : Flash without confirmation prompts"
            exit 1
            ;;
    esac
done

# Create directories
mkdir -p "$SIGNED_PATH"
mkdir -p "$TMP_DIR"

echo "========================================"
echo "ANDROID PARTITION RE-SIGNER"
echo "========================================"
echo "Re-signing Android partitions with custom AVB signatures"
echo "Primarily for KPM installation (current mode) or OTA updates (ota mode)"
echo ""

# Detect current slot
detect_current_slot() {
    CURRENT_SLOT=""
    
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
        echo "Detected current active slot: $CURRENT_SLOT"
    else
        echo "ERROR: Cannot detect current active slot!"
        echo "Please ensure you are running on an Android device with root access"
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
    if [ "$MODE" = "current" ]; then
        # Current mode: resign current slot
        TARGET_SLOT="$CURRENT_SLOT"
        echo "Target slot: $TARGET_SLOT (current mode - same slot)"
    else
        # OTA mode: resign other slot
        if [ "$CURRENT_SLOT" = "a" ]; then
            TARGET_SLOT="b"
        else
            TARGET_SLOT="a"
        fi
        echo "Target slot: $TARGET_SLOT (OTA mode - other slot)"
    fi
}

detect_current_slot
determine_target_slot
target_suffix="_${TARGET_SLOT}"

# Check if rebuild_avb.py exists
if [ ! -f "rebuild_avb.py" ]; then
    echo "ERROR: rebuild_avb.py not found in project directory"
    echo "Please ensure rebuild_avb.py is in the current directory"
    exit 1
fi

echo ""
echo "========================================"
echo "CONFIGURATION SUMMARY"
echo "========================================"
echo "Current active slot: $CURRENT_SLOT"
echo "Resign mode: $MODE"
echo "Target slot: $TARGET_SLOT"
echo ""

echo "========================================"
echo "PARTITION DUMPING"
echo "========================================"
echo "Dumping target slot partitions to project root for signing..."

# Function to dump partition
dump_partition() {
    local partition=$1
    local suffix=$2
    local partition_path="$BLOCK_PATH/${partition}${suffix}"
    local output_file="${partition}.img"
    
    if [ ! -b "$partition_path" ]; then
        echo "Warning: Partition $partition_path does not exist, skipping..."
        return 1
    fi
    
    echo "Dumping ${partition}${suffix}..."
    
    
    if dd if="$partition_path" of="$output_file" bs=4096 2>/dev/null; then
        echo "  ✓ Successfully dumped ${partition}${suffix} to $output_file"
        return 0
    else
        echo "  ERROR: Failed to dump ${partition}${suffix}"
        return 1
    fi
}

# Dump target partitions
dumped_files=""
dump_failed=false

for partition in $BOOT $INIT $META; do
    if dump_partition "$partition" "$target_suffix"; then
        dumped_files="$dumped_files ${partition}.img"
    else
        echo "Warning: Could not dump ${partition}${target_suffix}"
    fi
done

if [ -z "$dumped_files" ]; then
    echo "ERROR: No partitions were successfully dumped"
    exit 1
fi

echo ""
echo "Successfully dumped partitions:"
for file in $dumped_files; do
    if [ -f "$file" ]; then
        echo "  ✓ $file"
    fi
done

echo ""
echo "========================================"
echo "SIGNATURE VERIFICATION (PRE-RESIGN)"
echo "========================================"
echo "Checking if partitions are already properly signed..."

# Check if images are already signed
all_already_signed=true
for file in $dumped_files; do
    if [ -f "$file" ]; then
        echo "Verifying $file..."
        if sh verify_single_img.sh "$file" --silent; then
            echo "  ✓ $file is already properly signed"
        else
            echo "  → $file needs re-signing"
            all_already_signed=false
        fi
    fi
done

if [ "$all_already_signed" = true ]; then
    echo ""
    echo "✓ All images are already properly signed - no re-signing needed"
    echo ""
    echo "========================================"
    echo "OPERATION COMPLETE"
    echo "========================================"
    echo "Target slot ($TARGET_SLOT) partitions are already properly signed:"
    for file in $dumped_files; do
        partition_name=$(echo "$file" | sed 's/\.img$//')
        echo "  ✓ $partition_name"
    done
    echo ""
    echo "No action required - partitions are ready for use."
    
    # Clean up dumped files
    echo ""
    echo "Cleaning up temporary files..."
    for file in $dumped_files; do
        if [ -f "$file" ]; then
            rm -f "$file"
            echo "✓ Cleaned up temporary image file: $file"
        fi
    done
    
    exit 0
else
    skip_signing=false
fi

if [ "$skip_signing" = false ]; then
    echo ""
    echo "========================================"
    echo "SIGNING PROCESS"
    echo "========================================"
fi

if [ "$skip_signing" = false ]; then
    # Determine rebuild_avb parameters
    rebuild_params=""
    # Check if vbmeta.img exists
    vbmeta_exists=false
    if [ -f "vbmeta.img" ]; then
        vbmeta_exists=true
        echo "  ✓ vbmeta.img found - regular mode available"
    else
        echo "  ⚠ vbmeta.img not found - chained mode will be used"
    fi
    
    # Auto-detect partitions from dumped files
    partitions=""
    has_init_boot=false
    for file in $dumped_files; do
        if echo "$file" | grep -q "boot\.img"; then
            partitions="$partitions boot"
        elif echo "$file" | grep -q "init_boot\.img"; then
            partitions="$partitions init_boot"
            has_init_boot=true
        fi
    done
    
    # Determine mode based on vbmeta existence and partition types
    if [ "$vbmeta_exists" = true ] && [ -n "$partitions" ]; then
        # Regular mode: vbmeta exists and we have standard partitions
        echo "  → Using regular mode with vbmeta.img"
    elif [ "$has_init_boot" = true ] && [ "$vbmeta_exists" = false ]; then
        # Error: init_boot requires vbmeta.img
        echo ""
        echo "ERROR: init_boot.img found but vbmeta.img is missing"
        echo "init_boot partition requires vbmeta.img for proper verification"
        echo "Please ensure vbmeta.img is present in the current directory"
        exit 1
    elif [ -n "$partitions" ] && [ "$vbmeta_exists" = false ]; then
        # Chained mode: boot partition without vbmeta (assume it's chained)
        rebuild_params="--chained-mode"
        echo "  → Using chained mode (boot partition without vbmeta)"
    else
        # Fallback to chained mode for other partition types
        rebuild_params="--chained-mode"
        echo "  → Using chained mode (other partitions)"
    fi
    
    echo "Using rebuild_avb parameters: $rebuild_params"
    
    echo "Starting signing process..."
    echo ""
    
    echo "Executing: python3 rebuild_avb.py $rebuild_params"
    if python3 "rebuild_avb.py" $rebuild_params; then
        echo "✓ rebuild_avb.py execution completed successfully"
    else
        echo "ERROR: rebuild_avb.py execution failed"
        # Clean up dumped files on failure
        for file in $dumped_files; do
            rm -f "./$file"
        done
        exit 1
    fi
    
    echo ""
    echo "Moving signed images to output directory..."
    
    # Move all .img files to signed directory
    signed_count=0
    for file in $dumped_files; do
        if [ -f "./$file" ]; then
            mv "./$file" "$SIGNED_PATH/$file"
            echo "  ✓ Moved $file to $SIGNED_PATH/"
            signed_count=$((signed_count + 1))
        else
            echo "ERROR: Signed image not found: ./$file"
            exit 1
        fi
    done
    
    if [ $signed_count -eq 0 ]; then
        echo "ERROR: No signed images were created"
        exit 1
    fi
fi

echo ""
echo "========================================"
echo "SIGNATURE VERIFICATION (POST-RESIGN)"
echo "========================================"

echo "Verifying signed images..."

verification_failed=false
for file in $dumped_files; do
    signed_file="$SIGNED_PATH/$file"
    if [ -f "$signed_file" ]; then
        echo "Verifying $file..."
        
        if sh verify_single_img.sh "$signed_file" --silent; then
            echo "  ✓ $file verification passed"
        else
            echo "  ERROR: $file verification failed!"
            verification_failed=true
        fi
    fi
done

if [ "$verification_failed" = true ]; then
    echo "ERROR: One or more image verifications failed!"
    exit 1
fi

echo "✓ All signed images verified successfully"

echo ""
echo "========================================"
echo "FLASH TO TARGET SLOT"
echo "========================================"

# Flash safety control: dry-run skips, force-flash proceeds, otherwise ask
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Skipping flash operation"
    echo ""
    echo "Signed images are ready in $SIGNED_PATH:"
    for file in $dumped_files; do
        signed_file="$SIGNED_PATH/$file"
        if [ -f "$signed_file" ]; then
            echo "  ✓ $file"
        fi
    done
    echo ""
    echo "Re-run without --dry-run to flash these images to the device."
    skip_flash=true
elif [ "$FORCE_FLASH" = true ]; then
    echo "FORCE FLASH: Proceeding without confirmation"
    skip_flash=false
else
    echo "About to flash re-signed images to target slot ($TARGET_SLOT)"
    echo ""
    if [ "$TARGET_SLOT" = "$CURRENT_SLOT" ]; then
        echo "WARNING: This will modify your currently running partitions!"
        echo "This is intended for users after root solution installation."
    else
        echo "INFO: Flashing to inactive slot ($TARGET_SLOT) for OTA-style update."
        echo "You can switch to this slot after flashing."
    fi
    echo ""
    echo "Images to flash:"
    for file in $dumped_files; do
        signed_file="$SIGNED_PATH/$file"
        if [ -f "$signed_file" ]; then
            partition_name=$(echo "$file" | sed 's/\.img$//')
            partition_path="$BLOCK_PATH/${partition_name}${target_suffix}"
            echo "  $file -> $partition_path"
        fi
    done
    echo ""
    echo -n "Are you absolutely sure you want to continue? (type 'YES' to confirm): "
    read -r response
    if [ "$response" != "YES" ]; then
        echo "Flash operation cancelled for safety"
        echo ""
        echo "Signed images remain available in $SIGNED_PATH for manual flashing."
        exit 0
    fi
    echo "Proceeding with flash..."
    skip_flash=false
fi

# Flash function
flash_image() {
    local source_image=$1
    local target_partition=$2
    local partition_name=$3
    
    echo "Flashing $partition_name to target slot..."
    
    if [ "$DRY_RUN" = true ]; then
        echo "  DRY RUN: Would execute: dd if=$source_image of=$target_partition bs=4096"
    else
        echo "  Executing: dd if=$source_image of=$target_partition bs=4096"
        if dd if="$source_image" of="$target_partition" bs=4096 2>/dev/null; then
            echo "  ✓ Successfully flashed $partition_name"
        else
            echo "  ERROR: Failed to flash $partition_name"
            return 1
        fi
    fi
}

# Flash all signed images to target slot (if not skipped)
if [ "$skip_flash" = false ]; then
    flash_failed=false
    for file in $dumped_files; do
        signed_file="$SIGNED_PATH/$file"
        partition_name=$(echo "$file" | sed 's/\.img$//')
        partition_path="$BLOCK_PATH/${partition_name}${target_suffix}"
        
        if [ -f "$signed_file" ]; then
            if [ ! -b "$partition_path" ]; then
                echo "ERROR: Target partition not found: $partition_path"
                flash_failed=true
                continue
            fi
            
            if ! flash_image "$signed_file" "$partition_path" "$partition_name"; then
                echo "ERROR: $partition_name flashing failed!"
                flash_failed=true
            fi
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
    echo "Successfully dumped and re-signed target slot ($TARGET_SLOT) partitions:"
    for file in $dumped_files; do
        partition_name=$(echo "$file" | sed 's/\.img$//')
        echo "  ✓ $partition_name (dumped and signed)"
    done
    echo ""
    echo "Flash operation was skipped (dry-run mode)"
    echo "Mode: $MODE (target slot: $TARGET_SLOT)"
    echo ""
    echo "Signed images are ready in $SIGNED_PATH/"
    echo "Re-run without --dry-run to flash these images to the device."
else
    echo "OPERATION COMPLETE"
    echo "========================================"
    echo "Successfully re-signed and flashed target slot ($TARGET_SLOT) partitions:"
    for file in $dumped_files; do
        partition_name=$(echo "$file" | sed 's/\.img$//')
        echo "  ✓ $partition_name"
    done
    echo ""
    echo "NEXT STEPS:"
    if [ "$TARGET_SLOT" = "$CURRENT_SLOT" ]; then
        echo "1. Reboot your device to activate the re-signed partitions"
        echo "2. Monitor boot process to ensure everything works correctly"
    else
        echo "1. Set active slot to $TARGET_SLOT using bootctl or fastboot"
        echo "2. Reboot to test the updated partitions"
        echo "3. If successful, the device will boot from slot $TARGET_SLOT"
    fi
    echo "4. If issues occur, restore from backups using other scripts"
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

# Clean up any remaining image files in project root
for img in *.img; do
    if [ -f "$img" ]; then
        rm -f "$img"
        echo "✓ Cleaned up temporary image file: $img"
    fi
done