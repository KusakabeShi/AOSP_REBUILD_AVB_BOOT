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

# Create temp directory (signed path will be handled later with safety checks)
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

# Always proceed with signing (not dangerous)
echo "Starting signing process..."

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

# Check if signed directory exists and has content
existing_signed_files=""
if [ -d "$SIGNED_PATH" ]; then
    existing_signed_files=$(find "$SIGNED_PATH" -name "*.img" 2>/dev/null)
fi

echo ""
echo "========================================"
echo "INSTALL SIGNED IMAGES"
echo "========================================"

# Installation safety control: dry-run skips, force-sign proceeds, otherwise ask
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Skipping installation to $SIGNED_PATH"
    echo ""
    echo "Signed images are ready in current directory:"
    for file in $copied_files; do
        if [ -f "./$file" ]; then
            echo "  ✓ $file"
        fi
    done
    echo ""
    if [ -n "$existing_signed_files" ]; then
        echo "Would overwrite existing signed images:"
        for file in $existing_signed_files; do
            echo "  ⚠ $(basename "$file")"
        done
        echo ""
    fi
    echo "Re-run without --dry-run to install these images to $SIGNED_PATH."
elif [ "$FORCE_SIGN" = true ]; then
    echo "FORCE SIGN: Installing without confirmation"
    mkdir -p "$SIGNED_PATH"
else
    echo "About to install signed images to $SIGNED_PATH"
    echo ""
    if [ -n "$existing_signed_files" ]; then
        echo "WARNING: This will overwrite existing signed images!"
        echo "Existing signed images:"
        for file in $existing_signed_files; do
            echo "  ⚠ $(basename "$file")"
        fi
        echo ""
    fi
    echo "New signed images to install:"
    for file in $copied_files; do
        if [ -f "./$file" ]; then
            echo "  ✓ $file"
        fi
    done
    echo ""
    echo -n "Are you absolutely sure you want to continue? (type 'YES' to confirm): "
    read -r response
    if [ "$response" != "YES" ]; then
        echo "Installation cancelled for safety"
        echo ""
        echo "Signed images remain in current directory for manual review."
        exit 0
    fi
    echo "Proceeding with installation..."
    mkdir -p "$SIGNED_PATH"
fi

if [ "$DRY_RUN" = false ]; then
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

echo "Verifying signed images..."

verification_failed=false
for file in $copied_files; do
    if [ "$DRY_RUN" = true ]; then
        # In dry-run, verify images in current directory
        signed_file="./$file"
    else
        # In normal mode, verify images in signed directory
        signed_file="$SIGNED_PATH/$file"
    fi
    
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

# Clean up temporary files in current directory if dry-run (since they won't be moved)
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "Cleaning up temporary signed images..."
    for file in $copied_files; do
        if [ -f "./$file" ]; then
            rm -f "./$file"
            echo "✓ Cleaned up temporary signed image: $file"
        fi
    done
fi

echo ""
echo "========================================"
if [ "$DRY_RUN" = true ]; then
    echo "OPERATION COMPLETE (DRY RUN)"
    echo "========================================"
    echo "✓ Successfully signed all patched images"
    echo "✓ Signatures verified"
    echo "✓ Temporary files cleaned up"
    echo ""
    echo "Installation to $SIGNED_PATH was skipped (dry-run mode)"
    echo ""
    echo "NEXT STEPS:"
    echo "Re-run without --dry-run to install signed images to $SIGNED_PATH."
else
    echo "SIGNING COMPLETE"
    echo "========================================"
    echo "✓ Successfully signed all patched images"
    echo "✓ Images installed in $SIGNED_PATH"
    echo "✓ Signatures verified"
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
