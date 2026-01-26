#!/bin/bash
set -euo pipefail

ROOTFS_DIR="${1:-rootfs}"
ROOTFS_SIZE="${2:-4G}"
OUTPUT="${3:-rootfs.ext4}"

echo "Creating Marathon VM rootfs..."
echo "  Directory: $ROOTFS_DIR"
echo "  Size: $ROOTFS_SIZE"
echo "  Output: $OUTPUT"

if [ ! -d "$ROOTFS_DIR" ]; then
    echo "Creating rootfs directory structure..."
    mkdir -p "$ROOTFS_DIR"/{bin,sbin,usr/bin,usr/sbin,lib,lib64,etc,dev,proc,sys,tmp,root,workspace,var/log}

    echo "Installing base system (Alpine Linux)..."
    ALPINE_VERSION="3.19"
    ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"

    wget -q "${ALPINE_MIRROR}/v${ALPINE_VERSION}/main/x86_64/apk-tools-static-2.14.0-r5.x86_64.apk" -O /tmp/apk-tools.apk
    tar -xzf /tmp/apk-tools.apk -C /tmp

    /tmp/sbin/apk.static -X "${ALPINE_MIRROR}/v${ALPINE_VERSION}/main" \
        -U --allow-untrusted --root "$ROOTFS_DIR" --initdb \
        add alpine-base busybox openssh git curl jq nodejs npm

    echo "Installing Claude Code CLI..."
    chroot "$ROOTFS_DIR" npm install -g @anthropic-ai/claude-code

    echo "Installing jj (Jujutsu VCS)..."
    JJ_VERSION="0.23.0"
    wget -q "https://github.com/martinvonz/jj/releases/download/v${JJ_VERSION}/jj-v${JJ_VERSION}-x86_64-unknown-linux-musl.tar.gz" -O /tmp/jj.tar.gz
    tar -xzf /tmp/jj.tar.gz -C "$ROOTFS_DIR/usr/local/bin"

    echo "Installing GitHub CLI..."
    GH_VERSION="2.43.1"
    wget -q "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" -O /tmp/gh.tar.gz
    tar -xzf /tmp/gh.tar.gz -C /tmp
    cp /tmp/gh_*/bin/gh "$ROOTFS_DIR/usr/local/bin/"

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

    cat > "$ROOTFS_DIR/etc/init.d/marathon-agent" << 'EOF'
#!/bin/sh
case "$1" in
    start)
        /usr/local/bin/marathon-vm-agent &
        ;;
    stop)
        killall marathon-vm-agent
        ;;
esac
EOF
    chmod +x "$ROOTFS_DIR/etc/init.d/marathon-agent"

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
