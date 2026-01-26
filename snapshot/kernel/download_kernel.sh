#!/bin/bash
set -euo pipefail

KERNEL_VERSION="${1:-5.10.217}"
OUTPUT_DIR="${2:-.}"

echo "Downloading Firecracker-compatible kernel..."
echo "  Version: $KERNEL_VERSION"
echo "  Output: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR"

KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.8/x86_64/vmlinux-${KERNEL_VERSION}"
KERNEL_FILE="$OUTPUT_DIR/vmlinux"

if [ -f "$KERNEL_FILE" ]; then
    echo "Kernel already exists at $KERNEL_FILE"
    exit 0
fi

echo "Downloading kernel from $KERNEL_URL..."
curl -fSL "$KERNEL_URL" -o "$KERNEL_FILE"

if [ ! -f "$KERNEL_FILE" ]; then
    echo "Error: Failed to download kernel"
    exit 1
fi

chmod 644 "$KERNEL_FILE"

echo ""
echo "Kernel downloaded successfully: $KERNEL_FILE"
echo "Size: $(du -h "$KERNEL_FILE" | cut -f1)"
