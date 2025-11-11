#!/bin/sh

# Reusable single image verification script
# Usage: verify_single_img.sh <image_file> [--silent]

IMAGE_FILE="$1"
SILENT_MODE=false

if [ "$2" = "--silent" ]; then
    SILENT_MODE=true
fi

if [ -z "$IMAGE_FILE" ]; then
    echo "Usage: $0 <image_file> [--silent]"
    echo "  --silent : Suppress output (only return exit code)"
    exit 1
fi

if [ ! -f "$IMAGE_FILE" ]; then
    if [ "$SILENT_MODE" = false ]; then
        echo "Error: Image file not found: $IMAGE_FILE"
    fi
    exit 1
fi

# Determine partition type from filename
filename=$(basename "$IMAGE_FILE")
partition_type=$(echo "$filename" | sed 's/\.img$//')

# Use partition-specific verification logic
verify_cmd="python3 tools/avbtool.py verify_image --image $IMAGE_FILE"

case "$partition_type" in
    "vbmeta")
        verify_cmd="$verify_cmd --key tools/pem/testkey_rsa4096.pem --follow_chain_partitions"
        ;;
    "boot")
        verify_cmd="$verify_cmd --key tools/pem/testkey_rsa4096.pem"
        ;;
    "init_boot")
        # init_boot uses hash verification only (no key needed)
        verify_cmd="$verify_cmd"
        ;;
    *)
        # Default: try without key first, fallback to with key
        if [ "$SILENT_MODE" = false ]; then
            echo "Warning: Unknown partition type '$partition_type', trying default verification"
        fi
        verify_cmd="$verify_cmd"
        ;;
esac

# Execute verification
if [ "$SILENT_MODE" = true ]; then
    eval "$verify_cmd" >/dev/null 2>&1
    exit $?
else
    if eval "$verify_cmd" >/dev/null 2>&1; then
        echo "✓ $filename verification passed"
        exit 0
    else
        echo "ERROR: $filename verification failed!"
        exit 1
    fi
fi