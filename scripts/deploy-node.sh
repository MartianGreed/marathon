#!/bin/bash
set -euo pipefail

FIRECRACKER_VERSION="1.8.0"
KERNEL_VERSION="5.10.217"
MARATHON_DIR="/var/lib/marathon"
CONFIG_DIR="/etc/marathon"
SYSTEMD_DIR="/etc/systemd/system"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_architecture() {
    ARCH=$(uname -m)
    if [[ "$ARCH" != "x86_64" ]]; then
        log_error "Only x86_64 architecture is supported (found: $ARCH)"
        exit 1
    fi
}

check_kvm() {
    if [[ ! -e /dev/kvm ]]; then
        log_error "KVM is not available. Please enable virtualization in BIOS."
        exit 1
    fi
    if [[ ! -r /dev/kvm ]] || [[ ! -w /dev/kvm ]]; then
        log_warn "Fixing /dev/kvm permissions"
        chmod 666 /dev/kvm
    fi
    log_info "KVM is available"
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS"
        exit 1
    fi
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log_warn "This script is designed for Ubuntu. Detected: $ID"
    fi
    if [[ "${VERSION_ID:-}" != "22.04" ]] && [[ "${VERSION_ID:-}" != "24.04" ]]; then
        log_warn "Recommended Ubuntu versions: 22.04, 24.04. Detected: ${VERSION_ID:-unknown}"
    fi
    log_info "OS: $PRETTY_NAME"
}

check_env_vars() {
    if [[ -z "${MARATHON_ORCHESTRATOR_ADDRESS:-}" ]]; then
        log_error "MARATHON_ORCHESTRATOR_ADDRESS is required"
        exit 1
    fi
    log_info "Orchestrator address: $MARATHON_ORCHESTRATOR_ADDRESS"

    if [[ -n "${MARATHON_NODE_AUTH_KEY:-}" ]]; then
        log_info "Node authentication key: configured"
    else
        log_warn "MARATHON_NODE_AUTH_KEY not set - heartbeats will not be authenticated"
    fi
}

install_dependencies() {
    log_info "Installing dependencies..."
    apt-get update -qq
    apt-get install -y -qq curl wget jq
}

install_firecracker() {
    if command -v firecracker &>/dev/null; then
        INSTALLED_VERSION=$(firecracker --version | head -1 | awk '{print $2}')
        if [[ "$INSTALLED_VERSION" == "$FIRECRACKER_VERSION" ]]; then
            log_info "Firecracker $FIRECRACKER_VERSION already installed"
            return
        fi
    fi

    log_info "Installing Firecracker $FIRECRACKER_VERSION..."

    RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases/download/v${FIRECRACKER_VERSION}/firecracker-v${FIRECRACKER_VERSION}-x86_64.tgz"
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    wget -q -O "$TEMP_DIR/firecracker.tgz" "$RELEASE_URL"
    tar -xzf "$TEMP_DIR/firecracker.tgz" -C "$TEMP_DIR"

    cp "$TEMP_DIR/release-v${FIRECRACKER_VERSION}-x86_64/firecracker-v${FIRECRACKER_VERSION}-x86_64" /usr/bin/firecracker
    cp "$TEMP_DIR/release-v${FIRECRACKER_VERSION}-x86_64/jailer-v${FIRECRACKER_VERSION}-x86_64" /usr/bin/jailer

    chmod +x /usr/bin/firecracker /usr/bin/jailer

    log_info "Firecracker installed: $(firecracker --version | head -1)"
}

create_directories() {
    log_info "Creating directory structure..."

    mkdir -p "$MARATHON_DIR/snapshots"
    mkdir -p "$MARATHON_DIR/rootfs"
    mkdir -p "$MARATHON_DIR/kernel"
    mkdir -p "$MARATHON_DIR/vms"
    mkdir -p "$MARATHON_DIR/logs"
    mkdir -p "$CONFIG_DIR"

    chmod 755 "$MARATHON_DIR"
    chmod 755 "$CONFIG_DIR"

    log_info "Directories created at $MARATHON_DIR"
}

download_kernel() {
    KERNEL_PATH="$MARATHON_DIR/kernel/vmlinux"

    if [[ -f "$KERNEL_PATH" ]]; then
        if file "$KERNEL_PATH" | grep -q "ELF"; then
            log_info "Kernel already exists at $KERNEL_PATH (verified ELF)"
            return
        fi
        log_warn "Existing kernel is not valid ELF, re-downloading..."
        rm -f "$KERNEL_PATH"
    fi

    log_info "Downloading kernel $KERNEL_VERSION..."

    KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.8/x86_64/vmlinux-${KERNEL_VERSION}"

    if ! wget -q -O "$KERNEL_PATH" "$KERNEL_URL"; then
        log_warn "Failed to download kernel from primary source, trying alternative..."
        KERNEL_URL="https://github.com/firecracker-microvm/firecracker/releases/download/v${FIRECRACKER_VERSION}/firecracker-v${FIRECRACKER_VERSION}-x86_64/vmlinux-${KERNEL_VERSION}"
        wget -q -O "$KERNEL_PATH" "$KERNEL_URL" || {
            log_error "Failed to download kernel"
            exit 1
        }
    fi

    if ! file "$KERNEL_PATH" | grep -q "ELF"; then
        log_error "Downloaded kernel is not a valid ELF binary"
        rm -f "$KERNEL_PATH"
        exit 1
    fi
    log_info "Kernel verified as valid ELF binary"

    chmod 644 "$KERNEL_PATH"
    log_info "Kernel downloaded to $KERNEL_PATH"
}

download_rootfs() {
    ROOTFS_PATH="$MARATHON_DIR/rootfs/rootfs.ext4"

    if [[ -f "$ROOTFS_PATH" ]]; then
        log_info "Rootfs already exists at $ROOTFS_PATH"
        return
    fi

    log_info "Downloading minimal Ubuntu rootfs for testing..."

    ROOTFS_URL="https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/rootfs/bionic.rootfs.ext4"

    if ! wget -q -O "$ROOTFS_PATH" "$ROOTFS_URL"; then
        log_warn "Failed to download rootfs - VM agent won't work without custom rootfs"
        log_warn "Build and deploy custom rootfs: make rootfs && scp rootfs.ext4 server:$ROOTFS_PATH"
        return 1
    fi

    chmod 644 "$ROOTFS_PATH"
    log_info "Rootfs downloaded to $ROOTFS_PATH"
    log_warn "Note: This is a minimal test rootfs. For production, build custom rootfs with 'make rootfs'"
}

create_snapshot() {
    SNAPSHOT_BASE="$MARATHON_DIR/snapshots/base"
    if [[ -f "$SNAPSHOT_BASE/snapshot" ]] && [[ -f "$SNAPSHOT_BASE/mem" ]]; then
        log_info "Base snapshot already exists"
        return
    fi

    KERNEL_PATH="$MARATHON_DIR/kernel/vmlinux"
    ROOTFS_PATH="$MARATHON_DIR/rootfs/rootfs.ext4"

    if [[ ! -f "$KERNEL_PATH" ]] || [[ ! -f "$ROOTFS_PATH" ]]; then
        log_warn "Kernel or rootfs not available, skipping snapshot creation"
        return
    fi

    if ! command -v firecracker &>/dev/null; then
        log_warn "Firecracker not installed, skipping snapshot creation"
        return
    fi

    log_info "Creating initial base snapshot..."
    mkdir -p "$SNAPSHOT_BASE"

    SOCKET="/tmp/marathon-snapshot-$$.sock"
    VSOCK_PATH="/tmp/marathon-snapshot-$$-vsock.sock"
    rm -f "$SOCKET" "$VSOCK_PATH"

    firecracker --api-sock "$SOCKET" &
    FC_PID=$!
    sleep 1

    if [[ ! -S "$SOCKET" ]]; then
        log_error "Firecracker socket not created for snapshot"
        kill $FC_PID 2>/dev/null || true
        return
    fi

    curl -s --unix-socket "$SOCKET" -X PUT 'http://localhost/boot-source' \
        -H 'Content-Type: application/json' \
        -d "{
            \"kernel_image_path\": \"$KERNEL_PATH\",
            \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off\"
        }"

    curl -s --unix-socket "$SOCKET" -X PUT 'http://localhost/drives/rootfs' \
        -H 'Content-Type: application/json' \
        -d "{
            \"drive_id\": \"rootfs\",
            \"path_on_host\": \"$ROOTFS_PATH\",
            \"is_root_device\": true,
            \"is_read_only\": false
        }"

    curl -s --unix-socket "$SOCKET" -X PUT 'http://localhost/vsock' \
        -H 'Content-Type: application/json' \
        -d "{
            \"vsock_id\": \"vsock0\",
            \"guest_cid\": 3,
            \"uds_path\": \"$VSOCK_PATH\"
        }"

    curl -s --unix-socket "$SOCKET" -X PUT 'http://localhost/machine-config' \
        -H 'Content-Type: application/json' \
        -d '{
            "vcpu_count": 2,
            "mem_size_mib": 512,
            "track_dirty_pages": true
        }'

    curl -s --unix-socket "$SOCKET" -X PUT 'http://localhost/actions' \
        -H 'Content-Type: application/json' \
        -d '{"action_type": "InstanceStart"}'

    log_info "Waiting for VM to boot..."
    sleep 10

    curl -s --unix-socket "$SOCKET" -X PATCH 'http://localhost/vm' \
        -H 'Content-Type: application/json' \
        -d '{"state": "Paused"}'

    curl -s --unix-socket "$SOCKET" -X PUT 'http://localhost/snapshot/create' \
        -H 'Content-Type: application/json' \
        -d "{
            \"snapshot_path\": \"$SNAPSHOT_BASE/snapshot\",
            \"mem_file_path\": \"$SNAPSHOT_BASE/mem\",
            \"snapshot_type\": \"Full\"
        }"

    kill $FC_PID 2>/dev/null || true
    rm -f "$SOCKET" "$VSOCK_PATH"

    log_info "Base snapshot created at $SNAPSHOT_BASE"
}

write_config() {
    log_info "Writing configuration..."

    # Auto-enable TLS for port 443 unless explicitly disabled
    local port="${MARATHON_ORCHESTRATOR_PORT:-8080}"
    local tls_enabled="${MARATHON_TLS_ENABLED:-}"
    if [[ -z "$tls_enabled" ]] && [[ "$port" == "443" ]]; then
        tls_enabled="true"
    fi

    cat >"$CONFIG_DIR/node-operator.env" <<EOF
MARATHON_ORCHESTRATOR_ADDRESS=${MARATHON_ORCHESTRATOR_ADDRESS}
MARATHON_ORCHESTRATOR_PORT=${port}
MARATHON_TOTAL_VM_SLOTS=${MARATHON_TOTAL_VM_SLOTS:-10}
MARATHON_WARM_POOL_TARGET=${MARATHON_WARM_POOL_TARGET:-5}
MARATHON_SNAPSHOT_PATH=${MARATHON_DIR}/snapshots
MARATHON_KERNEL_PATH=${MARATHON_DIR}/kernel/vmlinux
MARATHON_ROOTFS_PATH=${MARATHON_DIR}/rootfs/rootfs.ext4
MARATHON_FIRECRACKER_BIN=/usr/bin/firecracker
EOF

    if [[ -n "$tls_enabled" ]]; then
        echo "MARATHON_TLS_ENABLED=${tls_enabled}" >>"$CONFIG_DIR/node-operator.env"
    fi

    if [[ -n "${MARATHON_TLS_CA_PATH:-}" ]]; then
        echo "MARATHON_TLS_CA_PATH=${MARATHON_TLS_CA_PATH}" >>"$CONFIG_DIR/node-operator.env"
    fi

    if [[ -n "${MARATHON_NODE_AUTH_KEY:-}" ]]; then
        echo "MARATHON_NODE_AUTH_KEY=${MARATHON_NODE_AUTH_KEY}" >>"$CONFIG_DIR/node-operator.env"
    fi

    if [[ -n "${MARATHON_NODE_ID:-}" ]]; then
        echo "MARATHON_NODE_ID=${MARATHON_NODE_ID}" >>"$CONFIG_DIR/node-operator.env"
    fi

    chmod 600 "$CONFIG_DIR/node-operator.env"
    log_info "Configuration written to $CONFIG_DIR/node-operator.env"
}

create_systemd_service() {
    log_info "Creating systemd service..."

    cat >"$SYSTEMD_DIR/marathon-node-operator.service" <<EOF
[Unit]
Description=Marathon Node Operator
Documentation=https://github.com/your-org/marathon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=$CONFIG_DIR/node-operator.env
ExecStart=/usr/local/bin/marathon-node-operator
Restart=always
RestartSec=5
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
SyslogIdentifier=marathon-node-operator

# Security hardening
NoNewPrivileges=false
ProtectSystem=strict
RuntimeDirectory=marathon
ReadWritePaths=$MARATHON_DIR /dev/kvm /run/marathon

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_info "Systemd service created"
}

install_binary() {
    # Stop service if running to avoid "Text file busy" error
    if systemctl is-active --quiet marathon-node-operator 2>/dev/null; then
        log_info "Stopping marathon-node-operator service for upgrade..."
        systemctl stop marathon-node-operator
    fi

    if [[ -f "./zig-out/bin/marathon-node-operator" ]]; then
        log_info "Installing marathon-node-operator from local build..."
        cp "./zig-out/bin/marathon-node-operator" /usr/local/bin/
        chmod +x /usr/local/bin/marathon-node-operator
    elif [[ -f "/tmp/marathon-node-operator" ]]; then
        log_info "Installing marathon-node-operator from /tmp..."
        cp "/tmp/marathon-node-operator" /usr/local/bin/
        chmod +x /usr/local/bin/marathon-node-operator
    else
        log_warn "marathon-node-operator binary not found"
        log_warn "Please copy the binary to /usr/local/bin/marathon-node-operator"
        log_warn "Or run this script from the marathon repository root after 'make build-release'"
    fi
}

enable_service() {
    if [[ -f "/usr/local/bin/marathon-node-operator" ]]; then
        log_info "Enabling and starting marathon-node-operator service..."
        systemctl enable marathon-node-operator
        systemctl start marathon-node-operator
        sleep 2
        if systemctl is-active --quiet marathon-node-operator; then
            log_info "marathon-node-operator is running"
        else
            log_error "Failed to start marathon-node-operator"
            journalctl -u marathon-node-operator -n 20 --no-pager
        fi
    else
        log_warn "Binary not installed, skipping service start"
        log_warn "After installing the binary, run: systemctl enable --now marathon-node-operator"
    fi
}

print_summary() {
    echo ""
    log_info "=========================================="
    log_info "Marathon Node Operator deployment complete"
    log_info "=========================================="
    echo ""
    echo "Configuration: $CONFIG_DIR/node-operator.env"
    echo "Data directory: $MARATHON_DIR"
    echo "Systemd service: marathon-node-operator"
    echo ""
    echo "Useful commands:"
    echo "  systemctl status marathon-node-operator"
    echo "  journalctl -u marathon-node-operator -f"
    echo "  systemctl restart marathon-node-operator"
    echo ""
    if [[ ! -f "/usr/local/bin/marathon-node-operator" ]]; then
        echo "Next steps:"
        echo "  1. Copy marathon-node-operator binary to /usr/local/bin/"
        echo "  2. Run: systemctl enable --now marathon-node-operator"
        echo ""
    fi
}

main() {
    log_info "Marathon Node Operator Deployment Script"
    log_info "========================================"

    check_root
    check_architecture
    check_os
    check_kvm
    check_env_vars

    install_dependencies
    install_firecracker
    create_directories
    download_kernel
    download_rootfs || true
    create_snapshot
    write_config
    create_systemd_service
    install_binary
    enable_service

    print_summary
}

main "$@"
