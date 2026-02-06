#!/bin/bash
set -euo pipefail

SOCKET="${1:-/tmp/firecracker.sock}"
SNAPSHOT_DIR="${2:-/var/lib/marathon/snapshots/base}"
KERNEL_PATH="${3:-/var/lib/marathon/kernel/vmlinux}"
ROOTFS_PATH="${4:-/var/lib/marathon/rootfs/rootfs.ext4}"

echo "Creating Firecracker snapshot..."
echo "  Socket: $SOCKET"
echo "  Snapshot dir: $SNAPSHOT_DIR"
echo "  Kernel: $KERNEL_PATH"
echo "  Rootfs: $ROOTFS_PATH"

mkdir -p "$SNAPSHOT_DIR"
mkdir -p /run/marathon

cleanup() {
    echo "Cleaning up..."
    curl -s --unix-socket "$SOCKET" -X PUT 'http://localhost/actions' \
        -H 'Content-Type: application/json' \
        -d '{"action_type": "SendCtrlAltDel"}' || true
}
trap cleanup EXIT

echo "Starting Firecracker..."
rm -f "$SOCKET"
firecracker --api-sock "$SOCKET" &
FC_PID=$!

sleep 1

if [ ! -S "$SOCKET" ]; then
    echo "Error: Firecracker socket not created"
    exit 1
fi

echo "Configuring boot source..."
curl -s --unix-socket "$SOCKET" -X PUT 'http://localhost/boot-source' \
    -H 'Content-Type: application/json' \
    -d "{
        \"kernel_image_path\": \"$KERNEL_PATH\",
        \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off\"
    }"

echo "Configuring rootfs..."
curl -s --unix-socket "$SOCKET" -X PUT 'http://localhost/drives/rootfs' \
    -H 'Content-Type: application/json' \
    -d "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"$ROOTFS_PATH\",
        \"is_root_device\": true,
        \"is_read_only\": false
    }"

echo "Configuring vsock..."
VSOCK_PATH="/run/marathon/snapshot-base-vsock.sock"
rm -f "$VSOCK_PATH"
VSOCK_RESP=$(curl -s --unix-socket "$SOCKET" -X PUT 'http://localhost/vsock' \
    -H 'Content-Type: application/json' \
    -d "{
        \"vsock_id\": \"vsock0\",
        \"guest_cid\": 3,
        \"uds_path\": \"$VSOCK_PATH\"
    }")
if echo "$VSOCK_RESP" | grep -q "fault_message"; then
    echo "Error: Vsock configuration failed: $VSOCK_RESP"
    exit 1
fi

echo "Configuring machine..."
curl -s --unix-socket "$SOCKET" -X PUT 'http://localhost/machine-config' \
    -H 'Content-Type: application/json' \
    -d '{
        "vcpu_count": 2,
        "mem_size_mib": 512,
        "track_dirty_pages": true
    }'

echo "Starting instance..."
curl -s --unix-socket "$SOCKET" -X PUT 'http://localhost/actions' \
    -H 'Content-Type: application/json' \
    -d '{"action_type": "InstanceStart"}'

echo "Waiting for VM to boot and agent to start..."
sleep 10

echo "Pausing VM..."
curl -s --unix-socket "$SOCKET" -X PATCH 'http://localhost/vm' \
    -H 'Content-Type: application/json' \
    -d '{"state": "Paused"}'

echo "Creating snapshot..."
curl -s --unix-socket "$SOCKET" -X PUT 'http://localhost/snapshot/create' \
    -H 'Content-Type: application/json' \
    -d "{
        \"snapshot_path\": \"$SNAPSHOT_DIR/snapshot\",
        \"mem_file_path\": \"$SNAPSHOT_DIR/mem\",
        \"snapshot_type\": \"Full\"
    }"

echo "Stopping Firecracker..."
kill $FC_PID 2>/dev/null || true

echo ""
echo "Snapshot created successfully at: $SNAPSHOT_DIR"
echo "  - Snapshot file: $SNAPSHOT_DIR/snapshot"
echo "  - Memory file: $SNAPSHOT_DIR/mem"
echo ""
echo "To restore this snapshot:"
echo "  firecracker --api-sock /tmp/firecracker-restore.sock"
echo "  curl --unix-socket /tmp/firecracker-restore.sock -X PUT 'http://localhost/snapshot/load' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"snapshot_path\": \"$SNAPSHOT_DIR/snapshot\", \"mem_file_path\": \"$SNAPSHOT_DIR/mem\", \"resume_vm\": true}'"
