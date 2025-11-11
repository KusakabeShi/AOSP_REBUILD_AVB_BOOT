#!/bin/sh

PATCHED_PATH=patched
SIGNED_PATH=patched_signed
IMG_BAK_PATH=backups
REBUILD_AVB_PATH=.
TMP_DIR=tmp

# Parse command line arguments
DRY_RUN=false
FORCE_SIGN=false

while [ $# -gt 0 ]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force-sign)
            FORCE_SIGN=true
            shift
            ;;
        *)
            echo "Usage: $0 [--dry-run] [--force-sign]"
            echo "  --dry-run     : Show what would be signed without actually signing"
            echo "  --force-sign  : Sign without confirmation"
            exit 1
            ;;
    esac
done

# Create directories
mkdir -p "$SIGNED_PATH"
mkdir -p "$TMP_DIR"

echo "========================================"
echo "ANDROID IMAGE SIGNER"
echo "========================================"
echo "Preparing to sign all patched Android images..."
echo ""

# Check if patched directory exists
if [ ! -d "$PATCHED_PATH" ]; then
    echo "ERROR: Patched directory not found: $PATCHED_PATH"
    echo "Please run './3_patch.sh' first to create patched images."
    exit 1
fi

# Check if any patched images exist
patched_images=$(find "$PATCHED_PATH" -name "*.img" 2>/dev/null)
if [ -z "$patched_images" ]; then
    echo "ERROR: No .img files found in $PATCHED_PATH"
    echo "Please run './3_patch.sh' first to create patched images."
    exit 1
fi

# Check if rebuild_avb.py exists
if [ ! -f "rebuild_avb.py" ]; then
    echo "ERROR: rebuild_avb.py not found in project directory"
    echo "Please ensure the rebuild_avb.py is in the current directory"
    exit 1
fi

echo "Found patched images:"
for img in $patched_images; do
    echo "  ✓ $(basename "$img")"
done
echo "✓ rebuild_avb.py: rebuild_avb.py"
echo ""

# Confirmation prompt
if [ "$FORCE_SIGN" = false ] && [ "$DRY_RUN" = false ]; then
    echo "About to sign all patched images with rebuild_avb.py"
    echo "Images will be copied to current directory, signed, then moved to $SIGNED_PATH"
    echo -n "Continue with signing? (y/N): "
    read -r response
    case $response in
        [yY]|[yY][eE][sS])
            echo "Proceeding with signing..."
            ;;
        *)
            echo "Signing cancelled by user"
            exit 0
            ;;
    esac
fi

echo ""
echo "========================================"
echo "SIGNING PROCESS"
echo "========================================"

echo "Copying patched images to current directory for signing..."

# Copy all patched images to current directory
copied_files=""
for img in $patched_images; do
    filename=$(basename "$img")
    if [ "$DRY_RUN" = true ]; then
        echo "  DRY RUN: Would copy $img to ./$filename"
    else
        cp "$img" "./$filename"
        if [ $? -eq 0 ]; then
            echo "  ✓ Copied $filename"
            copied_files="$copied_files $filename"
        else
            echo "ERROR: Failed to copy $filename"
            exit 1
        fi
    fi
done

if [ "$DRY_RUN" = false ]; then
    echo "✓ All patched images copied to current directory"
fi

# Determine rebuild_avb parameters (automatically detect partitions)
rebuild_params=""
if [ "$DRY_RUN" = false ]; then
    # Check if vbmeta.img exists in current directory
    vbmeta_exists=false
    if [ -f "vbmeta.img" ]; then
        vbmeta_exists=true
        echo "  ✓ vbmeta.img found - regular mode available"
    else
        echo "  ⚠ vbmeta.img not found - chained mode will be used"
    fi
    
    # Auto-detect partitions from copied files
    partitions=""
    has_init_boot=false
    for file in $copied_files; do
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
else
    rebuild_params=""
fi

echo "Using rebuild_avb parameters: $rebuild_params"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "DRY RUN: Would execute the following signing process:"
    echo "  1. python3 rebuild_avb.py $rebuild_params"
    echo "  2. Move signed images to $SIGNED_PATH"
    echo "  3. Verify signed images"
    echo "  4. Clean up working files"
else
    echo "Starting signing process..."
    echo ""
    
    echo "Executing: python3 rebuild_avb.py $rebuild_params"
    if python3 "rebuild_avb.py" $rebuild_params; then
        echo "✓ rebuild_avb.py execution completed successfully"
    else
        echo "ERROR: rebuild_avb.py execution failed"
        # Clean up copied files on failure
        for file in $copied_files; do
            rm -f "./$file"
        done
        exit 1
    fi
    
    echo ""
    echo "Moving signed images to output directory..."
    
    # Move all .img files to signed directory
    signed_count=0
    for file in $copied_files; do
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
    echo "DRY RUN: Would verify signed images in $SIGNED_PATH:"
    for img in $patched_images; do
        filename=$(basename "$img")
        echo "  sh verify_single_img.sh $SIGNED_PATH/$filename"
    done
else
    echo "Verifying signed images..."
    
    verification_failed=false
    for file in $copied_files; do
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
fi

echo ""
echo "========================================"
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN COMPLETE"
    echo "========================================"
    echo "Would have created signed images in $SIGNED_PATH:"
    for img in $patched_images; do
        filename=$(basename "$img")
        echo "  ✓ $filename"
    done
else
    echo "SIGNING COMPLETE"
    echo "========================================"
    echo "Successfully created and verified signed images in $SIGNED_PATH:"
    for file in $copied_files; do
        if [ -f "$SIGNED_PATH/$file" ]; then
            echo "  ✓ $file"
        fi
    done
    echo ""
    echo "NEXT STEPS:"
    echo "1. Use './5_flash.sh' to flash these signed images to your device"
    echo "2. Or manually flash using fastboot from $SIGNED_PATH directory"
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

# Clean up any image files copied to project root (most important for this script)
if [ "$DRY_RUN" = false ]; then
    for img in *.img; do
        if [ -f "$img" ]; then
            rm -f "$img"
            echo "✓ Cleaned up temporary image file: $img"
        fi
    done
fi
