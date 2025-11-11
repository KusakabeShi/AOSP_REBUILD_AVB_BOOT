#!/bin/sh

# Reusable image verification script
# Usage: verify_images.sh <image_directory>

IMG_DIR="$1"
KEY_FILE="tools/pem/testkey_rsa4096.pem"
TMP_DIR=tmp

A_SUFFIX=_a
B_SUFFIX=_b
BOOT=boot
INIT=init_boot
META=vbmeta

if [ -z "$IMG_DIR" ]; then
    echo "Usage: $0 <image_directory>"
    exit 1
fi

# Create tmp directory for hash calculations
mkdir -p $TMP_DIR

verify_slot() {
    local suffix=$1
    local slot_name=$(echo $suffix | tr -d '_')
    
    echo "Verifying $slot_name slot image..."
    cp $IMG_DIR/vbmeta${suffix}.img vbmeta.img
    cp $IMG_DIR/boot${suffix}.img boot.img
    cp $IMG_DIR/init_boot${suffix}.img init_boot.img

    # Verify all images using unified verification script
    echo "  Verifying vbmeta signature..."
    if ! sh verify_single_img.sh vbmeta.img --silent; then
        echo "Error: vbmeta${suffix} verification failed!"
        exit 1
    fi

    echo "  Verifying boot signature..."
    if ! sh verify_single_img.sh boot.img --silent; then
        echo "Error: boot${suffix} verification failed!"
        exit 1
    fi

    echo "  Verifying init_boot hash..."
    if ! sh verify_single_img.sh init_boot.img --silent; then
        echo "Error: init_boot${suffix} verification failed!"
        exit 1
    fi

    # Verify hash chain: vbmeta -> boot/init_boot hashes
    echo "  Verifying boot hash against vbmeta..."
    if ! python3 tools/avbtool.py calculate_vbmeta_digest --image boot.img --hash_algorithm sha256 --output $TMP_DIR/boot_hash${suffix}.txt; then
        echo "Error: boot${suffix} hash calculation failed!"
        exit 1
    fi
    if ! python3 tools/avbtool.py calculate_vbmeta_digest --image init_boot.img --hash_algorithm sha256 --output $TMP_DIR/init_hash${suffix}.txt; then
        echo "Error: init_boot${suffix} hash calculation failed!"
        exit 1
    fi
}

# Check all required images exist
echo "Checking required images..."
missing_images=""

for suffix in $A_SUFFIX $B_SUFFIX; do
    for partition in $BOOT $INIT $META; do
        image_file="$IMG_DIR/${partition}${suffix}.img"
        if [ ! -f "$image_file" ]; then
            missing_images="$missing_images $image_file"
        fi
    done
done

if [ -n "$missing_images" ]; then
    echo "Error: Missing images:$missing_images"
    exit 1
fi
echo "All required images found."

# Verify both slots
verify_slot $A_SUFFIX
verify_slot $B_SUFFIX

echo "All images verified successfully."
