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
echo "APATCH KPM RE-SIGNER"
echo "========================================"
echo "Re-signing currently running partitions after KPM installation"
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

detect_current_slot
current_suffix="_${CURRENT_SLOT}"

# Check if rebuild_avb.py exists
if [ ! -f "rebuild_avb.py" ]; then
    echo "ERROR: rebuild_avb.py not found in project directory"
    echo "Please ensure rebuild_avb.py is in the current directory"
    exit 1
fi

echo ""
echo "========================================"
echo "PARTITION DUMPING"
echo "========================================"
echo "Dumping current partitions to project root for signing..."

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
    
    if [ "$DRY_RUN" = true ]; then
        echo "  DRY RUN: Would dump $partition_path to $output_file"
        return 0
    fi
    
    if dd if="$partition_path" of="$output_file" bs=4096 2>/dev/null; then
        echo "  ✓ Successfully dumped ${partition}${suffix} to $output_file"
        return 0
    else
        echo "  ERROR: Failed to dump ${partition}${suffix}"
        return 1
    fi
}

# Dump current partitions
dumped_files=""
dump_failed=false

for partition in $BOOT $INIT $META; do
    if dump_partition "$partition" "$current_suffix"; then
        if [ "$DRY_RUN" = false ]; then
            dumped_files="$dumped_files ${partition}.img"
        fi
    else
        echo "Warning: Could not dump ${partition}${current_suffix}"
    fi
done

if [ "$DRY_RUN" = false ] && [ -z "$dumped_files" ]; then
    echo "ERROR: No partitions were successfully dumped"
    exit 1
fi

echo ""
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Would have dumped current partitions:"
    for partition in $BOOT $INIT $META; do
        partition_path="$BLOCK_PATH/${partition}${current_suffix}"
        if [ -b "$partition_path" ]; then
            echo "  ✓ ${partition}.img"
        fi
    done
else
    echo "Successfully dumped partitions:"
    for file in $dumped_files; do
        if [ -f "$file" ]; then
            echo "  ✓ $file"
        fi
    done
fi

echo ""
echo "========================================"
echo "SIGNING PROCESS"
echo "========================================"

# Determine rebuild_avb parameters (automatically detect partitions)
rebuild_params=""
if [ "$DRY_RUN" = false ]; then
    # Auto-detect partitions from dumped files
    partitions=""
    for file in $dumped_files; do
        if echo "$file" | grep -q "boot\.img"; then
            partitions="$partitions boot"
        elif echo "$file" | grep -q "init_boot\.img"; then
            partitions="$partitions init_boot"
        fi
    done
    
    if [ -n "$partitions" ]; then
        rebuild_params="--partitions$partitions"
    else
        rebuild_params="--chained-mode"
    fi
else
    rebuild_params="--partitions <auto-detected>"
fi

echo "Using rebuild_avb parameters: $rebuild_params"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "DRY RUN: Would execute the following signing process:"
    echo "  1. python3 rebuild_avb.py $rebuild_params"
    echo "  2. Move signed images to $SIGNED_PATH"
    echo "  3. Verify signed images"
    echo "  4. Flash signed images back to current slot ($CURRENT_SLOT)"
    echo "  5. Clean up working files"
else
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
echo "SIGNATURE VERIFICATION"
echo "========================================"

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Would verify signed images in $SIGNED_PATH"
    for partition in $BOOT $INIT $META; do
        echo "  python3 tools/avbtool.py verify_image --image $SIGNED_PATH/${partition}.img"
    done
else
    echo "Verifying signed images..."
    
    verification_failed=false
    for file in $dumped_files; do
        signed_file="$SIGNED_PATH/$file"
        if [ -f "$signed_file" ]; then
            echo "Verifying $file..."
            if python3 tools/avbtool.py verify_image --image "$signed_file" >/dev/null 2>&1; then
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
fi

echo ""
echo "========================================"
echo "FLASH BACK TO CURRENT SLOT"
echo "========================================"

# Flash confirmation
if [ "$FORCE_FLASH" = false ] && [ "$DRY_RUN" = false ]; then
    echo "About to flash re-signed images back to current slot ($CURRENT_SLOT)"
    echo ""
    echo "WARNING: This will modify your currently running partitions!"
    echo "This is intended for APatch users after KPM installation."
    echo ""
    echo "Images to flash:"
    for file in $dumped_files; do
        signed_file="$SIGNED_PATH/$file"
        if [ -f "$signed_file" ]; then
            partition_name=$(echo "$file" | sed 's/\.img$//')
            partition_path="$BLOCK_PATH/${partition_name}${current_suffix}"
            echo "  $file -> $partition_path"
        fi
    done
    echo ""
    echo -n "Are you absolutely sure you want to continue? (type 'YES' to confirm): "
    read -r response
    if [ "$response" != "YES" ]; then
        echo "Flash operation cancelled for safety"
        exit 0
    fi
    echo "Proceeding with flash..."
fi

# Flash function
flash_image() {
    local source_image=$1
    local target_partition=$2
    local partition_name=$3
    
    echo "Flashing $partition_name to current slot..."
    
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

# Flash all signed images back to current slot
flash_failed=false
for file in $dumped_files; do
    signed_file="$SIGNED_PATH/$file"
    partition_name=$(echo "$file" | sed 's/\.img$//')
    partition_path="$BLOCK_PATH/${partition_name}${current_suffix}"
    
    if [ "$DRY_RUN" = true ] || [ -f "$signed_file" ]; then
        if [ "$DRY_RUN" = false ] && [ ! -b "$partition_path" ]; then
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

echo ""
echo "========================================"
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN COMPLETE"
    echo "========================================"
    echo "Would have re-signed and flashed current slot ($CURRENT_SLOT) partitions:"
    for partition in $BOOT $INIT $META; do
        partition_path="$BLOCK_PATH/${partition}${current_suffix}"
        if [ -b "$partition_path" ]; then
            echo "  ✓ $partition"
        fi
    done
    echo ""
    echo "This is intended for APatch users after KPM installation."
else
    echo "RE-SIGNING COMPLETE"
    echo "========================================"
    echo "Successfully re-signed and flashed current slot ($CURRENT_SLOT) partitions:"
    for file in $dumped_files; do
        partition_name=$(echo "$file" | sed 's/\.img$//')
        echo "  ✓ $partition_name"
    done
    echo ""
    echo "NEXT STEPS:"
    echo "1. Reboot your device to activate the re-signed partitions"
    echo "2. Monitor boot process to ensure APatch + KPM work correctly"
    echo "3. If issues occur, restore from backups using other scripts"
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