#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$PROJECT_DIR/logs"
PID_DIR="$LOG_DIR/pids"
ENV_FILE="$SCRIPT_DIR/local-dev.env"

MARATHON_DIR="/var/lib/marathon"
FIRECRACKER_VERSION="1.8.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[  OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR ]${NC} $*"; }

load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        set -a; source "$ENV_FILE"; set +a
    fi
}

ensure_dirs() {
    mkdir -p "$LOG_DIR" "$PID_DIR" "$MARATHON_DIR"/{snapshots,kernel,rootfs,vms} /run/marathon
}

# ─── Prerequisites ───────────────────────────────────────────────

check_kvm() {
    if [[ -e /dev/kvm ]]; then
        ok "KVM available"
        chmod 666 /dev/kvm 2>/dev/null || true
        export HAS_KVM=1
    else
        warn "No /dev/kvm — Firecracker VMs won't work. Orchestrator + node_operator will still run."
        export HAS_KVM=0
    fi
}

install_system_deps() {
    info "Checking system dependencies..."
    local missing=()
    command -v psql      &>/dev/null || missing+=(postgresql)
    command -v redis-cli &>/dev/null || missing+=(redis-server)
    command -v curl      &>/dev/null || missing+=(curl)
    command -v wget      &>/dev/null || missing+=(wget)
    command -v jq        &>/dev/null || missing+=(jq)

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing: ${missing[*]}"
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}"
    fi
    ok "System deps OK"
}

# ─── Zig ─────────────────────────────────────────────────────────

install_zig() {
    if command -v zig &>/dev/null; then
        ok "Zig: $(zig version)"
        return
    fi
    # Check common local install paths
    for p in /tmp/zig-x86_64-linux-*/zig /tmp/zig-linux-x86_64-*/zig /usr/local/bin/zig; do
        if [[ -x "$p" ]]; then
            export PATH="$(dirname "$p"):$PATH"
            ok "Zig: $(zig version)"
            return
        fi
    done
    info "Installing Zig 0.15.2..."
    cd /tmp
    curl -sL "https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz" -o zig.tar.xz
    tar xf zig.tar.xz && rm zig.tar.xz
    export PATH="/tmp/zig-x86_64-linux-0.15.2:$PATH"
    ok "Zig installed: $(zig version)"
}

# ─── Postgres ────────────────────────────────────────────────────

setup_postgres() {
    info "Setting up PostgreSQL..."
    if ! pg_isready -q 2>/dev/null; then
        systemctl start postgresql 2>/dev/null \
            || pg_ctlcluster 16 main start 2>/dev/null \
            || true
        sleep 2
    fi
    if ! pg_isready -q 2>/dev/null; then
        err "PostgreSQL not running"; return 1
    fi

    sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='marathon'" 2>/dev/null | grep -q 1 \
        || sudo -u postgres psql -c "CREATE USER marathon WITH PASSWORD 'marathon' CREATEDB;" 2>/dev/null
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='marathon'" 2>/dev/null | grep -q 1 \
        || sudo -u postgres createdb -O marathon marathon 2>/dev/null

    if PGPASSWORD=marathon psql -h localhost -U marathon -d marathon -c "SELECT 1" &>/dev/null; then
        ok "PostgreSQL ready"
    else
        err "Cannot connect to PostgreSQL as marathon user"; return 1
    fi
}

# ─── Redis ───────────────────────────────────────────────────────

setup_redis() {
    if redis-cli ping &>/dev/null; then
        ok "Redis ready"; return
    fi
    redis-server --daemonize yes 2>/dev/null \
        || systemctl start redis-server 2>/dev/null || true
    sleep 1
    if redis-cli ping &>/dev/null; then
        ok "Redis ready"
    else
        err "Cannot start Redis"; return 1
    fi
}

# ─── Firecracker ─────────────────────────────────────────────────

install_firecracker() {
    [[ "${HAS_KVM:-0}" == "1" ]] || return 0

    if command -v firecracker &>/dev/null; then
        ok "Firecracker: $(firecracker --version 2>&1 | head -1)"
        return
    fi

    info "Installing Firecracker $FIRECRACKER_VERSION..."
    local tmp=$(mktemp -d)
    wget -q -O "$tmp/fc.tgz" \
        "https://github.com/firecracker-microvm/firecracker/releases/download/v${FIRECRACKER_VERSION}/firecracker-v${FIRECRACKER_VERSION}-x86_64.tgz"
    tar -xzf "$tmp/fc.tgz" -C "$tmp"
    cp "$tmp/release-v${FIRECRACKER_VERSION}-x86_64/firecracker-v${FIRECRACKER_VERSION}-x86_64" /usr/bin/firecracker
    cp "$tmp/release-v${FIRECRACKER_VERSION}-x86_64/jailer-v${FIRECRACKER_VERSION}-x86_64" /usr/bin/jailer
    chmod +x /usr/bin/firecracker /usr/bin/jailer
    rm -rf "$tmp"
    ok "Firecracker $FIRECRACKER_VERSION installed"
}

# ─── Kernel + Rootfs + Snapshot ──────────────────────────────────

setup_kernel() {
    [[ "${HAS_KVM:-0}" == "1" ]] || return 0

    local kpath="$MARATHON_DIR/kernel/vmlinux"
    if [[ -f "$kpath" ]] && file "$kpath" | grep -q "ELF"; then
        ok "Kernel ready"; return
    fi

    info "Downloading Firecracker kernel..."
    wget -q -O "$kpath" \
        "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.8/x86_64/vmlinux-5.10.210" \
        || wget -q -O "$kpath" \
        "https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin"

    if file "$kpath" | grep -q "ELF"; then
        ok "Kernel downloaded"
    else
        err "Downloaded kernel is not valid ELF"
        rm -f "$kpath"; return 1
    fi
}

setup_rootfs() {
    [[ "${HAS_KVM:-0}" == "1" ]] || return 0

    local rpath="$MARATHON_DIR/rootfs/rootfs.ext4"
    if [[ -f "$rpath" ]]; then
        ok "Rootfs ready"; return
    fi

    # Build custom rootfs with vm-agent if binary exists
    if [[ -x "$PROJECT_DIR/zig-out/bin/marathon-vm-agent" ]]; then
        info "Building custom rootfs with vm-agent (this takes a few minutes)..."
        cd "$PROJECT_DIR/snapshot"
        if bash create_rootfs.sh rootfs 4G "$rpath" 2>&1 | tail -3; then
            if [[ -f "$rpath" ]]; then
                ok "Custom rootfs built"; return
            fi
        fi
        warn "Custom rootfs build failed, falling back to minimal image"
    fi

    info "Downloading minimal test rootfs..."
    wget -q -O "$rpath" \
        "https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/rootfs/bionic.rootfs.ext4"
    ok "Test rootfs downloaded"
    warn "For full e2e with vm-agent, build custom rootfs: make rootfs"
}

setup_snapshot() {
    [[ "${HAS_KVM:-0}" == "1" ]] || return 0

    local snap_dir="$MARATHON_DIR/snapshots/base"
    if [[ -f "$snap_dir/snapshot" && -f "$snap_dir/mem" ]]; then
        ok "Base snapshot ready"; return
    fi

    local kpath="$MARATHON_DIR/kernel/vmlinux"
    local rpath="$MARATHON_DIR/rootfs/rootfs.ext4"
    if [[ ! -f "$kpath" || ! -f "$rpath" ]]; then
        warn "Kernel or rootfs missing, skipping snapshot"; return
    fi

    info "Creating base VM snapshot (~15s)..."
    mkdir -p "$snap_dir"

    local sock="/run/marathon/snapshot-setup-$$.sock"
    local vsock="/run/marathon/snapshot-base-vsock.sock"
    rm -f "$sock" "$vsock"

    firecracker --api-sock "$sock" &
    local fc_pid=$!
    sleep 1

    if [[ ! -S "$sock" ]]; then
        err "Firecracker failed to create socket"
        kill $fc_pid 2>/dev/null || true; return 1
    fi

    curl -sf --unix-socket "$sock" -X PUT 'http://localhost/boot-source' \
        -H 'Content-Type: application/json' \
        -d "{\"kernel_image_path\":\"$kpath\",\"boot_args\":\"console=ttyS0 reboot=k panic=1 pci=off\"}"

    curl -sf --unix-socket "$sock" -X PUT 'http://localhost/drives/rootfs' \
        -H 'Content-Type: application/json' \
        -d "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$rpath\",\"is_root_device\":true,\"is_read_only\":false}"

    curl -sf --unix-socket "$sock" -X PUT 'http://localhost/vsock' \
        -H 'Content-Type: application/json' \
        -d "{\"vsock_id\":\"vsock0\",\"guest_cid\":3,\"uds_path\":\"$vsock\"}"

    curl -sf --unix-socket "$sock" -X PUT 'http://localhost/machine-config' \
        -H 'Content-Type: application/json' \
        -d '{"vcpu_count":2,"mem_size_mib":512,"track_dirty_pages":true}'

    curl -sf --unix-socket "$sock" -X PUT 'http://localhost/actions' \
        -H 'Content-Type: application/json' \
        -d '{"action_type":"InstanceStart"}'

    info "Waiting for VM boot..."
    sleep 10

    curl -sf --unix-socket "$sock" -X PATCH 'http://localhost/vm' \
        -H 'Content-Type: application/json' \
        -d '{"state":"Paused"}'

    curl -sf --unix-socket "$sock" -X PUT 'http://localhost/snapshot/create' \
        -H 'Content-Type: application/json' \
        -d "{\"snapshot_path\":\"$snap_dir/snapshot\",\"mem_file_path\":\"$snap_dir/mem\",\"snapshot_type\":\"Full\"}"

    kill $fc_pid 2>/dev/null || true
    rm -f "$sock" "$vsock"
    ok "Base snapshot created"
}

# ─── Build ───────────────────────────────────────────────────────

build_binaries() {
    local orch="$PROJECT_DIR/zig-out/bin/marathon-orchestrator"
    local node="$PROJECT_DIR/zig-out/bin/marathon-node-operator"

    if [[ -x "$orch" && -x "$node" ]]; then
        if [[ "$PROJECT_DIR/build.zig" -nt "$orch" ]]; then
            info "Source changed, rebuilding..."
        else
            ok "Binaries up to date"; return
        fi
    else
        info "Building binaries..."
    fi
    cd "$PROJECT_DIR" && zig build
    ok "Build complete"
}

# ─── Start / Stop / Status / Logs ───────────────────────────────

do_start() {
    load_env
    ensure_dirs

    echo ""
    echo -e "${BLUE}═══ Marathon Local Dev Setup ═══${NC}"
    echo ""

    check_kvm
    install_system_deps
    install_zig
    setup_postgres
    setup_redis
    install_firecracker
    setup_kernel
    setup_rootfs
    setup_snapshot
    build_binaries

    # Kill any existing
    do_stop_quiet

    # Set Firecracker env based on KVM
    if [[ "${HAS_KVM:-0}" == "1" ]]; then
        export MARATHON_WARM_POOL_TARGET="${MARATHON_WARM_POOL_TARGET:-5}"
        export MARATHON_KERNEL_PATH="$MARATHON_DIR/kernel/vmlinux"
        export MARATHON_ROOTFS_PATH="$MARATHON_DIR/rootfs/rootfs.ext4"
        export MARATHON_FIRECRACKER_BIN="/usr/bin/firecracker"
        export MARATHON_SNAPSHOT_PATH="$MARATHON_DIR/snapshots"
    else
        export MARATHON_WARM_POOL_TARGET=0
        export MARATHON_SNAPSHOT_PATH="/tmp/marathon-snapshots"
        mkdir -p /tmp/marathon-snapshots
    fi

    echo ""
    info "Starting orchestrator on :${MARATHON_ORCHESTRATOR_PORT:-8080}..."
    cd "$PROJECT_DIR"
    "$PROJECT_DIR/zig-out/bin/marathon-orchestrator" \
        > "$LOG_DIR/orchestrator.log" 2>&1 &
    echo $! > "$PID_DIR/orchestrator.pid"

    local tries=0
    while ! ss -tlnp 2>/dev/null | grep -q ":${MARATHON_ORCHESTRATOR_PORT:-8080} "; do
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            err "Orchestrator failed to start"
            tail -20 "$LOG_DIR/orchestrator.log" 2>/dev/null
            return 1
        fi
        sleep 1
    done
    ok "Orchestrator running (PID $(cat "$PID_DIR/orchestrator.pid"))"

    info "Starting node_operator..."
    "$PROJECT_DIR/zig-out/bin/marathon-node-operator" \
        > "$LOG_DIR/node_operator.log" 2>&1 &
    echo $! > "$PID_DIR/node_operator.pid"
    sleep 3

    if kill -0 "$(cat "$PID_DIR/node_operator.pid")" 2>/dev/null; then
        ok "Node operator running (PID $(cat "$PID_DIR/node_operator.pid"))"
    else
        err "Node operator crashed"
        tail -20 "$LOG_DIR/node_operator.log" 2>/dev/null
        return 1
    fi

    echo ""
    do_status
}

do_stop_quiet() {
    for svc in node_operator orchestrator; do
        local pidfile="$PID_DIR/${svc}.pid"
        if [[ -f "$pidfile" ]]; then
            local pid=$(cat "$pidfile")
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null
                for _ in $(seq 1 5); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
                kill -9 "$pid" 2>/dev/null || true
            fi
            rm -f "$pidfile"
        fi
    done
    # Kill strays (exact match to avoid killing shell)
    pkill -9 -f marathon-orchestrator 2>/dev/null || true
    pkill -9 -f marathon-node-operator 2>/dev/null || true
}

do_stop() {
    load_env; ensure_dirs
    info "Stopping Marathon services..."
    local stopped=0
    for svc in node_operator orchestrator; do
        local pidfile="$PID_DIR/${svc}.pid"
        if [[ -f "$pidfile" ]]; then
            local pid=$(cat "$pidfile")
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null
                for _ in $(seq 1 5); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
                kill -9 "$pid" 2>/dev/null || true
                ok "Stopped $svc (PID $pid)"
                stopped=$((stopped + 1))
            fi
            rm -f "$pidfile"
        fi
    done
    pkill -9 -f marathon-orchestrator 2>/dev/null || true
    pkill -9 -f marathon-node-operator 2>/dev/null || true
    [[ $stopped -eq 0 ]] && info "No services were running"
}

do_status() {
    load_env; ensure_dirs
    echo -e "${BLUE}═══ Marathon Local Dev Status ═══${NC}"
    echo ""

    for svc in orchestrator node_operator; do
        local pidfile="$PID_DIR/${svc}.pid"
        local port
        [[ "$svc" == "orchestrator" ]] && port="8080" || port="8081"
        if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
            echo -e "  ${GREEN}●${NC} $svc  PID=$(cat "$pidfile")  port=$port"
        else
            echo -e "  ${RED}●${NC} $svc  not running"
        fi
    done

    echo ""
    if [[ -e /dev/kvm ]]; then
        echo -e "  KVM:         ${GREEN}available${NC}"
        [[ -f "$MARATHON_DIR/kernel/vmlinux" ]] \
            && echo -e "  Kernel:      ${GREEN}ready${NC}" \
            || echo -e "  Kernel:      ${RED}missing${NC}"
        [[ -f "$MARATHON_DIR/rootfs/rootfs.ext4" ]] \
            && echo -e "  Rootfs:      ${GREEN}ready${NC}" \
            || echo -e "  Rootfs:      ${RED}missing${NC}"
        [[ -f "$MARATHON_DIR/snapshots/base/snapshot" ]] \
            && echo -e "  Snapshot:    ${GREEN}ready${NC}" \
            || echo -e "  Snapshot:    ${YELLOW}not created${NC}"
        command -v firecracker &>/dev/null \
            && echo -e "  Firecracker: ${GREEN}$(firecracker --version 2>&1 | head -1)${NC}" \
            || echo -e "  Firecracker: ${RED}not installed${NC}"
    else
        echo -e "  KVM: ${YELLOW}not available${NC} (Firecracker disabled)"
    fi
    echo ""
    echo "  Logs: $LOG_DIR/"
    echo ""
}

do_logs() {
    load_env; ensure_dirs
    case "${1:-all}" in
        orchestrator|orch) tail -f "$LOG_DIR/orchestrator.log" ;;
        node_operator|node|no) tail -f "$LOG_DIR/node_operator.log" ;;
        all|*) tail -f "$LOG_DIR/orchestrator.log" "$LOG_DIR/node_operator.log" ;;
    esac
}

# ─── Main ────────────────────────────────────────────────────────

case "${1:-help}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 1; do_start ;;
    status)  do_status ;;
    logs)    do_logs "${2:-all}" ;;
    *)
        echo "Marathon Local Dev"
        echo ""
        echo "Usage: $0 {start|stop|restart|status|logs}"
        echo ""
        echo "  start    Install deps, build, start orchestrator + node_operator"
        echo "  stop     Stop all services"
        echo "  restart  Stop then start"
        echo "  status   Show running services and infra status"
        echo "  logs     Tail logs [orchestrator|node|all]"
        echo ""
        echo "On KVM servers: also installs Firecracker, kernel, rootfs, snapshots."
        echo "Without KVM: orchestrator + node_operator run, but no VMs."
        echo ""
        echo "Config: $ENV_FILE"
        ;;
esac
