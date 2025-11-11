#!/bin/sh

IMG_BAK_PATH=backups
PATCHED_PATH=patched
TMP_DIR=tmp

BLOCK_PATH=/dev/block/by-name
A_SUFFIX=_a
B_SUFFIX=_b
BOOT=boot
INIT=init_boot

# Parse command line arguments
CURRENT_SLOT=""
TARGET_SLOT=""
ROOT_SOLUTION=""
DRY_RUN=false
FORCE_PATCH=false

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
        --root)
            ROOT_SOLUTION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force-patch)
            FORCE_PATCH=true
            shift
            ;;
        *)
            echo "Usage: $0 [--slot a|b] [--current-slot a|b] [--root magisk|apatch|kernelsu-gki|kernelsu-lkm] [--dry-run] [--force-patch]"
            echo "  --slot        : Specify target slot to patch (a or b), defaults to inactive slot"
            echo "  --current-slot: Specify current active slot for auto-detection, auto-detect if not provided"
            echo "  --root        : Specify root solution, auto-detect if not provided"
            echo "  --dry-run     : Only show what would be patched, don't create patches"
            echo "  --force-patch : Patch without confirmation"
            exit 1
            ;;
    esac
done

# Create directories
mkdir -p $TMP_DIR
mkdir -p $PATCHED_PATH

echo "========================================"
echo "ANDROID ROOT PATCHER"
echo "========================================"
echo "Detecting current system configuration..."
echo ""

# Check if backup images exist
if [ ! -d "$IMG_BAK_PATH" ]; then
    echo "ERROR: Backup directory '$IMG_BAK_PATH' not found!"
    echo "Please run './2_backup_factory.sh' first to create backup images."
    exit 1
fi

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
    
    # Default to inactive slot for OTA compatibility
    if [ "$CURRENT_SLOT" = "a" ]; then
        TARGET_SLOT="b"
        echo "Auto-selected target slot: $TARGET_SLOT (inactive slot for OTA)"
    elif [ "$CURRENT_SLOT" = "b" ]; then
        TARGET_SLOT="a"
        echo "Auto-selected target slot: $TARGET_SLOT (inactive slot for OTA)"
    else
        echo "ERROR: Cannot determine target slot!"
        echo "Please specify target slot manually with --slot a or --slot b"
        exit 1
    fi
}

detect_current_slot
determine_target_slot

# Detect root solution if not provided
detect_root_solution() {
    if [ -n "$ROOT_SOLUTION" ]; then
        echo "Using manually specified root solution: $ROOT_SOLUTION"
        return 0
    fi
    
    echo "Auto-detecting installed root solution..."
    
    # Check for Magisk
    if [ -f "/system/bin/magisk" ] || [ -f "/system/xbin/magisk" ] || \
       [ -f "/data/adb/magisk/magisk" ] || [ -f "/sbin/magisk" ] || \
       [ -d "/data/adb/magisk" ]; then
        ROOT_SOLUTION="magisk"
        echo "Detected root solution: Magisk"
        return 0
    fi
    
    # Check for APatch
    if [ -f "/data/adb/ap/bin/apd" ] || [ -f "/data/adb/apatch" ] || \
       [ -d "/data/adb/ap" ]; then
        ROOT_SOLUTION="apatch"
        echo "Detected root solution: APatch"
        return 0
    fi
    
    # Check for KernelSU
    if [ -f "/data/adb/ksu/bin/ksud" ] || [ -f "/system/bin/ksud" ] || \
       [ -f "/data/adb/ksud" ]; then
        # Try to determine if it's GKI or LKM
        if [ -f "/proc/kernelsu_version" ] || grep -q "kernelsu" /proc/version 2>/dev/null; then
            ROOT_SOLUTION="kernelsu-gki"
            echo "Detected root solution: KernelSU (GKI)"
        else
            ROOT_SOLUTION="kernelsu-lkm"
            echo "Detected root solution: KernelSU (LKM)"
        fi
        return 0
    fi
    
    # Check for su binaries as fallback
    if [ -f "/system/bin/su" ] || [ -f "/system/xbin/su" ] || [ -f "/sbin/su" ]; then
        echo "Warning: Generic su detected, but cannot determine specific root solution"
        echo "Please specify root solution manually with --root parameter"
        ROOT_SOLUTION="unknown"
        return 1
    fi
    
    echo "No root solution detected!"
    echo "Please install a root solution first or specify manually with --root parameter"
    ROOT_SOLUTION="unknown"
    return 1
}

detect_root_solution

# Validate configuration
echo ""
echo "========================================"
echo "CONFIGURATION SUMMARY"
echo "========================================"
echo "Current active slot: $CURRENT_SLOT"
echo "Target slot to patch: $TARGET_SLOT"
echo "Root solution: $ROOT_SOLUTION"
echo ""

# Check if backup images exist for target slot
target_suffix="_${TARGET_SLOT}"
boot_backup="$IMG_BAK_PATH/${BOOT}${target_suffix}.img"
init_backup="$IMG_BAK_PATH/${INIT}${target_suffix}.img"
vbmeta_backup="$IMG_BAK_PATH/vbmeta${target_suffix}.img"

if [ ! -f "$boot_backup" ]; then
    echo "ERROR: Boot backup image not found: $boot_backup"
    exit 1
fi

if [ ! -f "$init_backup" ]; then
    echo "ERROR: Init boot backup image not found: $init_backup"
    exit 1
fi

if [ ! -f "$vbmeta_backup" ]; then
    echo "ERROR: VBMeta backup image not found: $vbmeta_backup"
    exit 1
fi

echo "✓ Boot backup found: $boot_backup"
echo "✓ Init boot backup found: $init_backup"
echo "✓ VBMeta backup found: $vbmeta_backup"
echo ""

# Function to patch with Magisk
patch_with_magisk() {
    local input_image=$1
    local output_image=$2
    local image_type=$3
    
    echo "Patching $image_type with Magisk..."
    
    # Find Magisk APK or script
    magisk_apk=""
    if [ -f "/data/adb/magisk/magisk.apk" ]; then
        magisk_apk="/data/adb/magisk/magisk.apk"
    elif [ -f "/data/app/com.topjohnwu.magisk*/base.apk" ]; then
        magisk_apk=$(find /data/app -name "*magisk*" -name "base.apk" | head -1)
    else
        echo "ERROR: Cannot find Magisk APK for patching"
        return 1
    fi
    
    # Use Magisk to patch the image
    if [ "$DRY_RUN" = true ]; then
        echo "  DRY RUN: Would patch $input_image with Magisk"
        echo "  DRY RUN: Output would be $output_image"
    else
        # Copy image to temp location for Magisk to work with
        temp_input="$TMP_DIR/magisk_input_$(basename $input_image)"
        cp "$input_image" "$temp_input"
        
        # Magisk patch command (this may vary based on Magisk version)
        if ! magisk --install "$temp_input" "$output_image" 2>/dev/null; then
            echo "ERROR: Magisk patching failed for $image_type"
            return 1
        fi
        
        echo "  ✓ Successfully patched $image_type with Magisk"
    fi
}

# Function to patch with APatch
patch_with_apatch() {
    local input_image=$1
    local output_image=$2
    local image_type=$3
    
    echo "Patching $image_type with APatch..."
    
    # Find APatch binary
    apatch_bin=""
    if [ -f "/data/adb/ap/bin/apd" ]; then
        apatch_bin="/data/adb/ap/bin/apd"
    elif [ -f "/data/adb/apatch" ]; then
        apatch_bin="/data/adb/apatch"
    else
        echo "ERROR: Cannot find APatch binary for patching"
        return 1
    fi
    
    if [ "$DRY_RUN" = true ]; then
        echo "  DRY RUN: Would patch $input_image with APatch"
        echo "  DRY RUN: Output would be $output_image"
    else
        # APatch patch command
        if ! "$apatch_bin" patch "$input_image" "$output_image" 2>/dev/null; then
            echo "ERROR: APatch patching failed for $image_type"
            return 1
        fi
        
        echo "  ✓ Successfully patched $image_type with APatch"
    fi
}

# Function to patch with KernelSU
patch_with_kernelsu() {
    local input_image=$1
    local output_image=$2
    local image_type=$3
    local ksu_type=$4
    
    echo "Patching $image_type with KernelSU ($ksu_type)..."
    
    if [ "$ksu_type" = "gki" ]; then
        # For GKI KernelSU, usually no patching needed as kernel is already built with KSU
        echo "  Note: GKI KernelSU typically doesn't require boot image patching"
        if [ "$DRY_RUN" = true ]; then
            echo "  DRY RUN: Would copy $input_image to $output_image (no patching needed)"
        else
            cp "$input_image" "$output_image"
            echo "  ✓ Copied $image_type (no patching required for GKI KernelSU)"
        fi
    else
        # For LKM KernelSU, find ksud binary
        ksud_bin=""
        if [ -f "/data/adb/ksu/bin/ksud" ]; then
            ksud_bin="/data/adb/ksu/bin/ksud"
        elif [ -f "/system/bin/ksud" ]; then
            ksud_bin="/system/bin/ksud"
        elif [ -f "/data/adb/ksud" ]; then
            ksud_bin="/data/adb/ksud"
        else
            echo "ERROR: Cannot find ksud binary for LKM patching"
            return 1
        fi
        
        if [ "$DRY_RUN" = true ]; then
            echo "  DRY RUN: Would patch $input_image with KernelSU LKM"
            echo "  DRY RUN: Output would be $output_image"
        else
            # KernelSU LKM patch command
            if ! "$ksud_bin" patch "$input_image" "$output_image" 2>/dev/null; then
                echo "ERROR: KernelSU LKM patching failed for $image_type"
                return 1
            fi
            
            echo "  ✓ Successfully patched $image_type with KernelSU LKM"
        fi
    fi
}

# Main patching logic
echo "========================================"
echo "STARTING PATCH PROCESS"
echo "========================================"

if [ "$ROOT_SOLUTION" = "unknown" ]; then
    echo "ERROR: Cannot proceed with unknown root solution"
    echo "Please specify a valid root solution with --root parameter"
    exit 1
fi

# Determine which images need to be patched based on root solution
patch_boot=false
patch_init=false
case "$ROOT_SOLUTION" in
    "magisk")
        patch_init=true
        echo "Magisk: will patch init_boot.img only"
        ;;
    "kernelsu-lkm")
        patch_init=true
        echo "KernelSU LKM: will patch init_boot.img only"
        ;;
    "kernelsu-gki")
        patch_boot=true
        echo "KernelSU GKI: will patch boot.img only"
        ;;
    "apatch")
        patch_boot=true
        echo "APatch: will patch boot.img only"
        ;;
esac

# Generate standard output filenames directly in patched directory
boot_patched="$PATCHED_PATH/boot.img"
init_patched="$PATCHED_PATH/init_boot.img"
vbmeta_patched="$PATCHED_PATH/vbmeta.img"

# Ask for confirmation unless force patch is enabled
if [ "$FORCE_PATCH" = false ] && [ "$DRY_RUN" = false ]; then
    echo "About to patch images with $ROOT_SOLUTION for target slot $TARGET_SLOT"
    echo "Source: slot $TARGET_SLOT backup images"
    echo "Output files:"
    if [ "$patch_boot" = true ]; then
        echo "  Will create: $boot_patched"
    fi
    if [ "$patch_init" = true ]; then
        echo "  Will create: $init_patched"
    fi
    echo "  Will copy: $vbmeta_patched"
    echo ""
    echo -n "Continue with patching? (y/N): "
    read -r response
    case $response in
        [yY]|[yY][eE][sS])
            echo "Proceeding with patch..."
            ;;
        *)
            echo "Patching cancelled by user"
            exit 0
            ;;
    esac
fi

echo ""
echo "Patching images..."

# Patch only the necessary images based on root solution
if [ "$patch_boot" = true ]; then
    echo "Patching boot image..."
    case "$ROOT_SOLUTION" in
        "apatch")
            patch_with_apatch "$boot_backup" "$boot_patched" "boot"
            ;;
        "kernelsu-gki")
            patch_with_kernelsu "$boot_backup" "$boot_patched" "boot" "gki"
            ;;
        *)
            echo "ERROR: Unsupported root solution for boot patching: $ROOT_SOLUTION"
            exit 1
            ;;
    esac
fi

if [ "$patch_init" = true ]; then
    echo "Patching init_boot image..."
    case "$ROOT_SOLUTION" in
        "magisk")
            patch_with_magisk "$init_backup" "$init_patched" "init_boot"
            ;;
        "kernelsu-lkm")
            patch_with_kernelsu "$init_backup" "$init_patched" "init_boot" "lkm"
            ;;
        *)
            echo "ERROR: Unsupported root solution for init_boot patching: $ROOT_SOLUTION"
            exit 1
            ;;
    esac
fi

# Copy vbmeta.img (always needed for next step)
echo "Copying vbmeta image..."
if [ "$DRY_RUN" = true ]; then
    echo "  DRY RUN: Would copy $vbmeta_backup to $vbmeta_patched"
else
    if cp "$vbmeta_backup" "$vbmeta_patched"; then
        echo "  ✓ Successfully copied vbmeta.img"
    else
        echo "ERROR: Failed to copy vbmeta.img"
        exit 1
    fi
fi

echo ""
echo "========================================"
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN COMPLETE"
    echo "========================================"
    echo "Would have created files:"
    if [ "$patch_boot" = true ]; then
        echo "  ✓ $boot_patched"
    fi
    if [ "$patch_init" = true ]; then
        echo "  ✓ $init_patched"
    fi
    echo "  ✓ $vbmeta_patched"
    echo ""
    echo "Root solution: $ROOT_SOLUTION"
    echo "Target slot: $TARGET_SLOT"
else
    echo "PATCHING COMPLETE"
    echo "========================================"
    echo "Successfully created files:"
    if [ "$patch_boot" = true ] && [ -f "$boot_patched" ]; then
        echo "  ✓ $boot_patched"
    fi
    if [ "$patch_init" = true ] && [ -f "$init_patched" ]; then
        echo "  ✓ $init_patched"
    fi
    if [ -f "$vbmeta_patched" ]; then
        echo "  ✓ $vbmeta_patched"
    fi
    echo ""
    echo "Root solution: $ROOT_SOLUTION"
    echo "Target slot: $TARGET_SLOT"
    echo ""
    echo "NEXT STEPS:"
    echo "1. Flash the images using fastboot"
    echo "2. Images are prepared for slot $TARGET_SLOT (OTA-compatible)"
    echo "3. vbmeta.img is ready for the next step"
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