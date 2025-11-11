#!/bin/sh

PATCHED_PATH=patched
SIGNED_PATH=patched_signed
IMG_BAK_PATH=backups
REBUILD_AVB_PATH=.
TMP_DIR=tmp

# Parse command line arguments
DRY_RUN=false
FORCE_SIGN=false
PATCHED_IMAGE=""

while [ $# -gt 0 ]; do
    case $1 in
        --image)
            PATCHED_IMAGE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force-sign)
            FORCE_SIGN=true
            shift
            ;;
        *)
            echo "Usage: $0 --image <patched_image> [--dry-run] [--force-sign]"
            echo "  --image       : Path to patched image to sign (required)"
            echo "  --dry-run     : Show what would be signed without actually signing"
            echo "  --force-sign  : Sign without confirmation"
            exit 1
            ;;
    esac
done

# Check required parameters
if [ -z "$PATCHED_IMAGE" ]; then
    echo "ERROR: --image parameter is required"
    echo "Usage: $0 --image <patched_image> [--dry-run] [--force-sign]"
    exit 1
fi

# Create directories
mkdir -p "$SIGNED_PATH"
mkdir -p "$TMP_DIR"

echo "========================================"
echo "ANDROID IMAGE SIGNER"
echo "========================================"
echo "Preparing to sign patched Android images..."
echo ""

# Check if patched image exists
if [ ! -f "$PATCHED_IMAGE" ]; then
    echo "ERROR: Patched image not found: $PATCHED_IMAGE"
    exit 1
fi

# Check if rebuild_avb.py exists
if [ ! -f "rebuild_avb.py" ]; then
    echo "ERROR: rebuild_avb.py not found in project directory"
    echo "Please ensure the rebuild_avb.py is in the current directory"
    exit 1
fi

# Check if backup vbmeta exists
vbmeta_backup=""
if [ -f "$IMG_BAK_PATH/vbmeta_a.img" ]; then
    vbmeta_backup="$IMG_BAK_PATH/vbmeta_a.img"
elif [ -f "$IMG_BAK_PATH/vbmeta_b.img" ]; then
    vbmeta_backup="$IMG_BAK_PATH/vbmeta_b.img"
else
    echo "ERROR: No vbmeta backup found in $IMG_BAK_PATH"
    echo "Available files:"
    ls -la "$IMG_BAK_PATH/" 2>/dev/null || echo "  (directory empty or not found)"
    exit 1
fi

echo "✓ Patched image: $PATCHED_IMAGE"
echo "✓ VBMeta backup: $vbmeta_backup"
echo "✓ rebuild_avb.py: rebuild_avb.py"
echo ""

# Determine image type and parameters
image_basename=$(basename "$PATCHED_IMAGE")
image_type=""

if echo "$image_basename" | grep -q "boot"; then
    image_type="boot"
elif echo "$image_basename" | grep -q "init"; then
    image_type="init_boot"
else
    echo "ERROR: Cannot determine image type from filename: $image_basename"
    echo "Expected filename to contain 'boot' or 'init'"
    exit 1
fi

echo "Detected image type: $image_type"

# Generate output filename
timestamp=$(date +%Y%m%d_%H%M%S)
signed_image="$SIGNED_PATH/$(basename "$PATCHED_IMAGE" .img)_signed_${timestamp}.img"
signed_vbmeta="$SIGNED_PATH/vbmeta_signed_${timestamp}.img"

echo "Output files:"
echo "  Signed image: $signed_image"
echo "  Signed vbmeta: $signed_vbmeta"
echo ""

# Confirmation prompt
if [ "$FORCE_SIGN" = false ] && [ "$DRY_RUN" = false ]; then
    echo "About to sign $image_type image with rebuild_avb.py"
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

# Prepare rebuild_avb working directory
rebuild_work_dir="$TMP_DIR/rebuild_avb_work"
mkdir -p "$rebuild_work_dir"

echo "Copying files to rebuild_avb working directory..."

# Copy patched image to rebuild_avb directory with standard name
cp "$PATCHED_IMAGE" "$rebuild_work_dir/${image_type}.img"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to copy patched image"
    exit 1
fi

# Copy vbmeta backup to rebuild_avb directory  
cp "$vbmeta_backup" "$rebuild_work_dir/vbmeta.img"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to copy vbmeta backup"
    exit 1
fi

echo "✓ Copied patched image and vbmeta to working directory"

# Determine rebuild_avb parameters based on image type
rebuild_params="--partitions $image_type"

echo "Using rebuild_avb parameters: $rebuild_params"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "DRY RUN: Would execute the following signing process:"
    echo "  1. cd $rebuild_work_dir"
    echo "  2. python3 ../../rebuild_avb.py $rebuild_params"
    echo "  3. Copy signed images to $SIGNED_PATH"
    echo "  4. Verify signed images"
else
    echo "Starting signing process..."
    echo ""
    
    # Change to working directory and run rebuild_avb.py
    cd "$rebuild_work_dir" || exit 1
    
    echo "Executing: python3 ../../rebuild_avb.py $rebuild_params"
    if python3 "../../rebuild_avb.py" $rebuild_params; then
        echo "✓ rebuild_avb.py execution completed successfully"
    else
        echo "ERROR: rebuild_avb.py execution failed"
        cd - > /dev/null
        exit 1
    fi
    
    # Return to original directory
    cd - > /dev/null
    
    echo ""
    echo "Copying signed images to output directory..."
    
    # Copy signed image (rebuild_avb.py should have modified the original)
    if [ -f "$rebuild_work_dir/${image_type}.img" ]; then
        cp "$rebuild_work_dir/${image_type}.img" "$signed_image"
        echo "✓ Copied signed $image_type image"
    else
        echo "ERROR: Signed $image_type image not found after rebuild_avb.py"
        exit 1
    fi
    
    # Copy signed vbmeta (if it exists and was processed)
    if [ -f "$rebuild_work_dir/vbmeta.img" ]; then
        cp "$rebuild_work_dir/vbmeta.img" "$signed_vbmeta"
        echo "✓ Copied signed vbmeta image"
    else
        echo "Note: No vbmeta.img generated (chained partition mode)"
        # Create a placeholder or skip vbmeta
        touch "$signed_vbmeta"
        echo "✓ Created placeholder vbmeta file"
    fi
fi

echo ""
echo "========================================"
echo "SIGNATURE VERIFICATION"
echo "========================================"

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Would verify signed images:"
    echo "  python3 tools/avbtool.py verify_image --image $signed_image"
    if [ -s "$signed_vbmeta" ]; then
        echo "  python3 tools/avbtool.py verify_image --image $signed_vbmeta"
    fi
else
    echo "Verifying signed images..."
    
    # Verify signed image
    echo "Verifying signed $image_type image..."
    if python3 tools/avbtool.py verify_image --image "$signed_image" >/dev/null 2>&1; then
        echo "✓ Signed $image_type image verification passed"
    else
        echo "ERROR: Signed $image_type image verification failed!"
        exit 1
    fi
    
    # Verify signed vbmeta (only if it's a real file, not placeholder)
    if [ -s "$signed_vbmeta" ]; then
        echo "Verifying signed vbmeta image..."
        if python3 tools/avbtool.py verify_image --image "$signed_vbmeta" >/dev/null 2>&1; then
            echo "✓ Signed vbmeta image verification passed"
        else
            echo "ERROR: Signed vbmeta image verification failed!"
            exit 1
        fi
    else
        echo "✓ Skipping vbmeta verification (chained partition mode)"
    fi
fi

# Cleanup working directory
if [ "$DRY_RUN" = false ]; then
    rm -rf "$rebuild_work_dir"
    echo "✓ Cleaned up working directory"
fi

echo ""
echo "========================================"
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN COMPLETE"
    echo "========================================"
    echo "Would have created signed images:"
    echo "  Signed $image_type: $signed_image"
    if [ -s "$signed_vbmeta" ]; then
        echo "  Signed vbmeta: $signed_vbmeta"
    fi
else
    echo "SIGNING COMPLETE"
    echo "========================================"
    echo "Successfully created and verified signed images:"
    echo "  ✓ Signed $image_type: $signed_image"
    if [ -s "$signed_vbmeta" ]; then
        echo "  ✓ Signed vbmeta: $signed_vbmeta"
    fi
    echo ""
    echo "NEXT STEPS:"
    if [ -s "$signed_vbmeta" ]; then
        echo "1. Use './5_flash.sh' to flash these signed images to your device"
        echo "2. Or manually flash using fastboot:"
        echo "   fastboot flash $image_type $signed_image"
        echo "   fastboot flash vbmeta $signed_vbmeta"
    else
        echo "1. Flash only the signed $image_type image (chained partition mode):"
        echo "   fastboot flash $image_type $signed_image"
        echo "2. Or use './5_flash.sh --image $signed_image' (vbmeta not needed)"
    fi
fi
echo "========================================"