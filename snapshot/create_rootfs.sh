#!/bin/bash
set -euo pipefail

ROOTFS_DIR="${1:-rootfs}"
ROOTFS_SIZE="${2:-4G}"
OUTPUT="${3:-rootfs.ext4}"

echo "Creating Marathon VM rootfs..."
echo "  Directory: $ROOTFS_DIR"
echo "  Size: $ROOTFS_SIZE"
echo "  Output: $OUTPUT"

if [ ! -x "$ROOTFS_DIR/bin/busybox" ]; then
    rm -rf "$ROOTFS_DIR"
    echo "Creating rootfs directory structure..."
    mkdir -p "$ROOTFS_DIR"/{bin,sbin,usr/bin,usr/sbin,lib,lib64,etc,dev,proc,sys,tmp,root,workspace,var/log}

    echo "Installing base system (Alpine Linux)..."
    ALPINE_VERSION="3.21"
    ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"

    TMPDIR_ROOTFS="$(mktemp -d)"
    trap "rm -rf '$TMPDIR_ROOTFS'" EXIT

    wget -q "${ALPINE_MIRROR}/v${ALPINE_VERSION}/main/x86_64/APKINDEX.tar.gz" -O "$TMPDIR_ROOTFS/APKINDEX.tar.gz"
    tar -xzf "$TMPDIR_ROOTFS/APKINDEX.tar.gz" -C "$TMPDIR_ROOTFS" APKINDEX
    APK_TOOLS_VER=$(awk '/^P:apk-tools-static/{getline; print}' "$TMPDIR_ROOTFS/APKINDEX" | sed 's/V://')
    wget -q "${ALPINE_MIRROR}/v${ALPINE_VERSION}/main/x86_64/apk-tools-static-${APK_TOOLS_VER}.apk" -O "$TMPDIR_ROOTFS/apk-tools.apk"
    tar -xzf "$TMPDIR_ROOTFS/apk-tools.apk" -C "$TMPDIR_ROOTFS"

    "$TMPDIR_ROOTFS/sbin/apk.static" \
        -X "${ALPINE_MIRROR}/v${ALPINE_VERSION}/main" \
        -X "${ALPINE_MIRROR}/v${ALPINE_VERSION}/community" \
        -U --allow-untrusted --root "$ROOTFS_DIR" --initdb \
        add alpine-base busybox bash openssh git curl jq nodejs npm

    echo "Installing Claude Code CLI..."
    cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
    chroot "$ROOTFS_DIR" npm install -g @anthropic-ai/claude-code

    echo "Installing jj (Jujutsu VCS)..."
    JJ_VERSION="0.23.0"
    wget -q "https://github.com/martinvonz/jj/releases/download/v${JJ_VERSION}/jj-v${JJ_VERSION}-x86_64-unknown-linux-musl.tar.gz" -O "$TMPDIR_ROOTFS/jj.tar.gz"
    tar -xzf "$TMPDIR_ROOTFS/jj.tar.gz" -C "$ROOTFS_DIR/usr/local/bin"

    echo "Installing GitHub CLI..."
    GH_VERSION="2.43.1"
    wget -q "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" -O "$TMPDIR_ROOTFS/gh.tar.gz"
    tar -xzf "$TMPDIR_ROOTFS/gh.tar.gz" -C "$TMPDIR_ROOTFS"
    cp "$TMPDIR_ROOTFS"/gh_*/bin/gh "$ROOTFS_DIR/usr/local/bin/"

    echo "Configuring system..."

    cat > "$ROOTFS_DIR/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/sh
EOF

    cat > "$ROOTFS_DIR/etc/group" << 'EOF'
root:x:0:
EOF

    cat > "$ROOTFS_DIR/etc/hosts" << 'EOF'
127.0.0.1   localhost
::1         localhost
EOF

    cat > "$ROOTFS_DIR/etc/resolv.conf" << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

    mkdir -p "$ROOTFS_DIR/root/.config/claude-code"
    cat > "$ROOTFS_DIR/root/.config/claude-code/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["*"],
    "deny": []
  }
}
EOF

    # Create marathon user for running Claude Code (can't use --dangerously-skip-permissions as root)
    echo "marathon:x:1000:1000:Marathon:/home/marathon:/bin/bash" >> "$ROOTFS_DIR/etc/passwd"
    echo "marathon:x:1000:" >> "$ROOTFS_DIR/etc/group"
    echo "marathon:!:19000:0:99999:7:::" >> "$ROOTFS_DIR/etc/shadow" 2>/dev/null || true
    mkdir -p "$ROOTFS_DIR/home/marathon/.config/claude-code"
    cp "$ROOTFS_DIR/root/.config/claude-code/settings.json" "$ROOTFS_DIR/home/marathon/.config/claude-code/"
    mkdir -p "$ROOTFS_DIR/workspace"
    chown -R 1000:1000 "$ROOTFS_DIR/home/marathon" "$ROOTFS_DIR/workspace"

    cat > "$ROOTFS_DIR/etc/init.d/marathon-agent" << 'EOF'
#!/sbin/openrc-run

name="marathon-agent"
description="Marathon VM Agent"
command="/usr/local/bin/marathon-vm-agent"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/marathon-agent.log"
error_log="/var/log/marathon-agent.log"

depend() {
    need localmount
    after bootmisc marathon-network
}

start_pre() {
    chown marathon:marathon /workspace
}
EOF
    chmod +x "$ROOTFS_DIR/etc/init.d/marathon-agent"

    # Network configuration script - configures eth0 on boot
    # Uses MAC address last byte to determine subnet: 172.16.X.2/30 where X = last octet of MAC
    cat > "$ROOTFS_DIR/etc/init.d/marathon-network" << 'NETEOF'
#!/sbin/openrc-run

name="marathon-network"
description="Configure VM network"

depend() {
    before marathon-agent
    need localmount
}

start() {
    ebegin "Configuring network"
    # Extract VM index from kernel cmdline
    VM_INDEX=$(cat /proc/cmdline 2>/dev/null | tr ' ' '\n' | grep 'marathon.vm_index=' | cut -d= -f2 || echo "0")
    [ -z "$VM_INDEX" ] && VM_INDEX=0
    GATEWAY="172.16.${VM_INDEX}.1"
    GUEST_IP="172.16.${VM_INDEX}.2"

    ip link set eth0 up 2>/dev/null
    ip addr add "${GUEST_IP}/30" dev eth0 2>/dev/null || true
    ip route add default via "${GATEWAY}" 2>/dev/null || true
    eend $?
}
NETEOF
    chmod +x "$ROOTFS_DIR/etc/init.d/marathon-network"

    mkdir -p "$ROOTFS_DIR/etc/runlevels/default"
    ln -sf /etc/init.d/marathon-network "$ROOTFS_DIR/etc/runlevels/default/marathon-network"
    ln -sf /etc/init.d/marathon-agent "$ROOTFS_DIR/etc/runlevels/default/marathon-agent"

    echo "Installing marathon-vm-agent..."
    if [ -f "../zig-out/bin/marathon-vm-agent" ]; then
        cp ../zig-out/bin/marathon-vm-agent "$ROOTFS_DIR/usr/local/bin/"
    else
        echo "Warning: marathon-vm-agent not found, skipping"
    fi
fi

echo "Creating ext4 filesystem image..."
truncate -s "$ROOTFS_SIZE" "$OUTPUT"
mkfs.ext4 -d "$ROOTFS_DIR" "$OUTPUT"

echo "Done! Rootfs created at: $OUTPUT"
echo ""
echo "To use this rootfs with Firecracker:"
echo "  firecracker --api-sock /tmp/firecracker.sock"
echo "  curl --unix-socket /tmp/firecracker.sock -X PUT 'http://localhost/drives/rootfs' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"drive_id\": \"rootfs\", \"path_on_host\": \"$OUTPUT\", \"is_root_device\": true}'"
