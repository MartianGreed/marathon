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
        log_info "Kernel already exists at $KERNEL_PATH"
        return
    fi

    log_info "Downloading kernel $KERNEL_VERSION..."

    KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux-${KERNEL_VERSION}.bin"

    if ! wget -q -O "$KERNEL_PATH" "$KERNEL_URL"; then
        log_warn "Failed to download kernel from primary source, trying alternative..."
        KERNEL_URL="https://github.com/firecracker-microvm/firecracker/releases/download/v${FIRECRACKER_VERSION}/vmlinux-${KERNEL_VERSION}"
        wget -q -O "$KERNEL_PATH" "$KERNEL_URL" || {
            log_error "Failed to download kernel"
            exit 1
        }
    fi

    chmod 644 "$KERNEL_PATH"
    log_info "Kernel downloaded to $KERNEL_PATH"
}

write_config() {
    log_info "Writing configuration..."

    # Auto-enable TLS for port 443 or 8443 unless explicitly disabled
    local port="${MARATHON_ORCHESTRATOR_PORT:-8080}"
    local tls_enabled="${MARATHON_TLS_ENABLED:-}"
    if [[ -z "$tls_enabled" ]] && [[ "$port" == "443" || "$port" == "8443" ]]; then
        tls_enabled="true"
    fi

    cat >"$CONFIG_DIR/node-operator.env" <<EOF
MARATHON_ORCHESTRATOR_ADDRESS=${MARATHON_ORCHESTRATOR_ADDRESS}
MARATHON_ORCHESTRATOR_PORT=${port}
MARATHON_TOTAL_VM_SLOTS=${MARATHON_TOTAL_VM_SLOTS:-10}
MARATHON_WARM_POOL_TARGET=${MARATHON_WARM_POOL_TARGET:-5}
MARATHON_SNAPSHOT_PATH=${MARATHON_DIR}/snapshots
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
StandardOutput=journal
StandardError=journal
SyslogIdentifier=marathon-node-operator

# Security hardening
NoNewPrivileges=false
ProtectSystem=strict
ReadWritePaths=$MARATHON_DIR /dev/kvm

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_info "Systemd service created"
}

install_binary() {
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
    write_config
    create_systemd_service
    install_binary
    enable_service

    print_summary
}

main "$@"
