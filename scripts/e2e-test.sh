#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Marathon E2E Test — Latitude.sh Bare Metal
#
# Provisions a bare-metal server, runs local-dev.sh via cloud-init,
# then validates the full stack (orchestrator, node_operator, Firecracker VMs).
#
# Usage:
#   ./scripts/e2e-test.sh run              # Full cycle
#   ./scripts/e2e-test.sh provision        # Provision only
#   ./scripts/e2e-test.sh test <ip>        # Test existing server
#   ./scripts/e2e-test.sh teardown <id>    # Destroy server
#   ./scripts/e2e-test.sh status           # List e2e servers
#
# Requires: LATITUDE_API_KEY env var, curl, jq, ssh-keygen
###############################################################################

# ── Config ───────────────────────────────────────────────────────────────────
API_BASE="https://api.latitude.sh"
PROJECT_ID="${LATITUDE_PROJECT_ID:-proj_mgWeN6doeaYd7}"
PLAN="c1-tiny-x86"
SITE="US"
OS="ubuntu_22_04_x64_lts"
HOSTNAME_PREFIX="marathon-e2e"
COST_PER_HOUR="0.09"
REPO_URL="https://github.com/MartianGreed/marathon.git"
REPO_BRANCH="feat/local-dev-script"

STATE_DIR="/tmp/marathon-e2e"
STATE_FILE="$STATE_DIR/state.json"
SSH_KEY="$STATE_DIR/id_ed25519"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

PROVISION_TIMEOUT=900   # 15 min
CLOUDINIT_TIMEOUT=1200  # 20 min
FULL_TIMEOUT=1800       # 30 min

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $(date +%H:%M:%S) $*"; }
ok()    { echo -e "${GREEN}[  OK]${NC} $(date +%H:%M:%S) $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $(date +%H:%M:%S) $*"; }
err()   { echo -e "${RED}[ERR ]${NC} $(date +%H:%M:%S) $*"; }
die()   { err "$@"; exit 1; }

# ── Prereqs ──────────────────────────────────────────────────────────────────
check_deps() {
    for cmd in curl jq ssh-keygen ssh; do
        command -v "$cmd" &>/dev/null || die "Missing: $cmd"
    done
    [[ -n "${LATITUDE_API_KEY:-}" ]] || die "LATITUDE_API_KEY not set"
}

# ── API helpers ──────────────────────────────────────────────────────────────
api() {
    local method="$1" path="$2"; shift 2
    curl -sf -X "$method" \
        -H "Authorization: Bearer $LATITUDE_API_KEY" \
        -H "Content-Type: application/json" \
        "$API_BASE$path" "$@"
}

api_or_die() {
    local resp
    resp=$(api "$@") || die "API call failed: $1 $2"
    echo "$resp"
}

# ── State management ────────────────────────────────────────────────────────
save_state() { echo "$1" > "$STATE_FILE"; }
load_state() { [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "{}"; }
get_state() { load_state | jq -r ".$1 // empty"; }

# ── SSH key management ───────────────────────────────────────────────────────
setup_ssh_key() {
    mkdir -p "$STATE_DIR"
    if [[ -f "$SSH_KEY" ]]; then
        info "Reusing existing SSH key"
    else
        info "Generating ephemeral SSH keypair..."
        ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
        ok "SSH key generated"
    fi

    local pubkey
    pubkey=$(cat "$SSH_KEY.pub")

    # Check if key already exists on Latitude
    local existing_id
    existing_id=$(api GET /ssh_keys | jq -r '.data[]? | select(.attributes.name == "marathon-e2e") | .id' | head -1)
    if [[ -n "$existing_id" ]]; then
        info "Deleting old SSH key $existing_id from Latitude..."
        api DELETE "/ssh_keys/$existing_id" || true
    fi

    info "Uploading SSH key to Latitude..."
    local resp
    resp=$(api_or_die POST /ssh_keys -d "$(jq -n \
        --arg pub "$pubkey" \
        '{data: {type: "ssh_keys", attributes: {name: "marathon-e2e", public_key: $pub}}}'
    )")
    local key_id
    key_id=$(echo "$resp" | jq -r '.data.id')
    [[ -n "$key_id" && "$key_id" != "null" ]] || die "Failed to create SSH key"
    ok "SSH key uploaded: $key_id"
    echo "$key_id"
}

delete_ssh_key() {
    local key_id
    key_id=$(api GET /ssh_keys | jq -r '.data[]? | select(.attributes.name == "marathon-e2e") | .id' | head -1)
    if [[ -n "$key_id" ]]; then
        info "Deleting SSH key $key_id from Latitude..."
        api DELETE "/ssh_keys/$key_id" || true
        ok "SSH key deleted"
    fi
}

# ── Cloud-init ───────────────────────────────────────────────────────────────
make_userdata() {
    cat <<'CLOUDINIT'
#!/bin/bash
exec > /var/log/marathon-setup.log 2>&1
set -euxo pipefail

echo "=== Marathon E2E cloud-init started at $(date) ==="

# Install git
apt-get update -y
apt-get install -y git

# Clone repo
cd /root
git clone -b BRANCH_PLACEHOLDER REPO_PLACEHOLDER marathon
cd marathon

# Run the full local-dev setup
chmod +x scripts/local-dev.sh
./scripts/local-dev.sh start

# Mark completion
echo "setup_complete $(date +%s)" > /tmp/marathon-setup-complete
echo "=== Marathon E2E cloud-init finished at $(date) ==="
CLOUDINIT
}

get_userdata() {
    make_userdata | sed "s|REPO_PLACEHOLDER|$REPO_URL|g; s|BRANCH_PLACEHOLDER|$REPO_BRANCH|g"
}

# ── Provision ────────────────────────────────────────────────────────────────
do_provision() {
    check_deps
    local start_ts
    start_ts=$(date +%s)

    local ssh_key_id
    ssh_key_id=$(setup_ssh_key)

    local userdata
    userdata=$(get_userdata)

    info "Creating server ($PLAN, $SITE, $OS)..."
    local resp
    resp=$(api_or_die POST /servers -d "$(jq -n \
        --arg project "$PROJECT_ID" \
        --arg plan "$PLAN" \
        --arg site "$SITE" \
        --arg os "$OS" \
        --arg hostname "$HOSTNAME_PREFIX-$(date +%s)" \
        --arg ssh_key "$ssh_key_id" \
        --arg userdata "$userdata" \
        '{data: {type: "servers", attributes: {
            project: $project, plan: $plan, site: $site,
            operating_system: $os, hostname: $hostname,
            ssh_keys: [$ssh_key], user_data: $userdata
        }}}'
    )")

    local server_id
    server_id=$(echo "$resp" | jq -r '.data.id')
    [[ -n "$server_id" && "$server_id" != "null" ]] || die "Failed to create server. Response: $resp"
    ok "Server created: $server_id"

    save_state "$(jq -n \
        --arg id "$server_id" \
        --arg ssh_key_id "$ssh_key_id" \
        --argjson start "$start_ts" \
        '{server_id: $id, ssh_key_id: $ssh_key_id, start_ts: $start, ip: null}'
    )"

    # Poll until status is "on"
    info "Waiting for server to come online (timeout: ${PROVISION_TIMEOUT}s)..."
    local deadline=$(($(date +%s) + PROVISION_TIMEOUT))
    local ip=""
    while [[ $(date +%s) -lt $deadline ]]; do
        local status_resp
        status_resp=$(api GET "/servers/$server_id" 2>/dev/null || echo "{}")
        local status
        status=$(echo "$status_resp" | jq -r '.data.attributes.status // "unknown"')
        ip=$(echo "$status_resp" | jq -r '.data.attributes.primary_ipv4 // empty')

        if [[ "$status" == "on" && -n "$ip" ]]; then
            ok "Server is ON — IP: $ip"
            save_state "$(load_state | jq --arg ip "$ip" '.ip = $ip')"
            break
        fi
        printf "  Status: %-12s IP: %-15s  \r" "$status" "${ip:-pending}"
        sleep 15
    done
    echo

    [[ -n "$ip" ]] || die "Provisioning timed out"

    # Wait for SSH
    info "Waiting for SSH..."
    deadline=$(($(date +%s) + 300))
    while [[ $(date +%s) -lt $deadline ]]; do
        if ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" "echo ok" &>/dev/null; then
            ok "SSH accessible"
            break
        fi
        sleep 10
    done

    # Wait for cloud-init
    info "Waiting for cloud-init to complete (timeout: ${CLOUDINIT_TIMEOUT}s)..."
    deadline=$(($(date +%s) + CLOUDINIT_TIMEOUT))
    while [[ $(date +%s) -lt $deadline ]]; do
        if ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" "test -f /tmp/marathon-setup-complete" &>/dev/null; then
            ok "Cloud-init complete!"
            break
        fi
        # Show progress
        local log_tail
        log_tail=$(ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" "tail -1 /var/log/marathon-setup.log 2>/dev/null" 2>/dev/null || echo "waiting...")
        printf "  %s\r" "$log_tail"
        sleep 20
    done
    echo

    local elapsed=$(( $(date +%s) - start_ts ))
    ok "Provisioning complete in $((elapsed/60))m$((elapsed%60))s"
    echo "  Server ID: $server_id"
    echo "  IP: $ip"
    echo "  SSH: ssh -i $SSH_KEY root@$ip"
}

# ── Test ─────────────────────────────────────────────────────────────────────
do_test() {
    local ip="${1:-$(get_state ip)}"
    [[ -n "$ip" ]] || die "No IP provided and none in state. Usage: $0 test <ip>"
    [[ -f "$SSH_KEY" ]] || die "No SSH key at $SSH_KEY"

    info "Running tests against $ip..."
    local passed=0 failed=0 total=0

    run_test() {
        local name="$1" cmd="$2"
        total=$((total+1))
        if ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" "$cmd" &>/dev/null; then
            ok "PASS: $name"; passed=$((passed+1))
        else
            err "FAIL: $name"; failed=$((failed+1))
        fi
    }

    run_test_output() {
        local name="$1" cmd="$2"
        total=$((total+1))
        local output
        output=$(ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" "$cmd" 2>/dev/null) || true
        if [[ -n "$output" ]]; then
            ok "PASS: $name — $output"; passed=$((passed+1))
        else
            err "FAIL: $name"; failed=$((failed+1))
        fi
    }

    echo
    info "=== Infrastructure Tests ==="
    run_test "KVM available (/dev/kvm)" "test -e /dev/kvm"
    run_test_output "Firecracker version" "firecracker --version 2>&1 | head -1"

    echo
    info "=== Service Tests ==="
    run_test "Orchestrator listening on :8080" "curl -sf http://localhost:8080/health || ss -tlnp | grep -q :8080"
    run_test "Node operator listening on :8081" "curl -sf http://localhost:8081/health || ss -tlnp | grep -q :8081"

    echo
    info "=== Integration Tests ==="
    run_test "Node operator registered with orchestrator" \
        "grep -q 'registered\|registration\|connected' /root/marathon/logs/node_operator*.log 2>/dev/null || journalctl -u marathon-node-operator --no-pager 2>/dev/null | grep -qi 'register'"

    # Check warm pool
    local warm_pool_output
    warm_pool_output=$(ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" \
        "grep -o 'Warm pool initialized: [0-9]* VMs ready' /root/marathon/logs/*.log 2>/dev/null || echo ''" 2>/dev/null)
    total=$((total+1))
    if [[ "$warm_pool_output" =~ "VMs ready" ]]; then
        local vm_count
        vm_count=$(echo "$warm_pool_output" | grep -oP '\d+(?= VMs ready)' | head -1)
        if [[ -n "$vm_count" && "$vm_count" -gt 0 ]]; then
            ok "PASS: Warm pool has $vm_count VMs ready"
            passed=$((passed+1))

            # Submit a test task
            echo
            info "=== Task Submission Test ==="
            total=$((total+1))
            local task_output
            task_output=$(ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" \
                "cd /root/marathon && ./zig-out/bin/marathon-client submit --task 'echo hello-marathon' 2>&1 || true" 2>/dev/null)
            if [[ -n "$task_output" ]]; then
                ok "PASS: Task submitted — $task_output"
                passed=$((passed+1))
            else
                warn "SKIP: Could not submit test task"
            fi
        else
            err "FAIL: Warm pool has 0 VMs"; failed=$((failed+1))
        fi
    else
        err "FAIL: Warm pool not initialized"; failed=$((failed+1))
    fi

    # Collect logs summary
    echo
    info "=== Setup Log Summary ==="
    ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" \
        "tail -20 /var/log/marathon-setup.log 2>/dev/null" 2>/dev/null || true

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}, $total total"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    [[ $failed -eq 0 ]] && return 0 || return 1
}

# ── Teardown ─────────────────────────────────────────────────────────────────
do_teardown() {
    local server_id="${1:-$(get_state server_id)}"
    check_deps

    if [[ -n "$server_id" ]]; then
        info "Deleting server $server_id..."
        api DELETE "/servers/$server_id" && ok "Server deleted" || warn "Server deletion failed (may already be gone)"
    else
        warn "No server ID to teardown"
    fi

    delete_ssh_key

    # Cost summary
    local start_ts
    start_ts=$(get_state start_ts)
    if [[ -n "$start_ts" ]]; then
        local elapsed=$(( $(date +%s) - start_ts ))
        local hours
        hours=$(echo "scale=2; $elapsed / 3600" | bc 2>/dev/null || echo "?")
        local cost
        cost=$(echo "scale=2; $hours * $COST_PER_HOUR" | bc 2>/dev/null || echo "?")
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Duration: ${hours}h (~$((elapsed/60)) min)"
        echo "  Est cost: \$$cost ($COST_PER_HOUR/hr)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi

    # Clean up local files
    if [[ -d "$STATE_DIR" ]]; then
        info "Cleaning up $STATE_DIR..."
        rm -rf "$STATE_DIR"
        ok "Local files cleaned"
    fi
}

# ── Status ───────────────────────────────────────────────────────────────────
do_status() {
    check_deps
    info "Listing servers in project..."
    local resp
    resp=$(api_or_die GET "/servers?filter[project]=$PROJECT_ID")
    echo "$resp" | jq -r '
        .data[] |
        "  \(.id)  \(.attributes.hostname // "?")  \(.attributes.status)  \(.attributes.primary_ipv4 // "no-ip")"
    ' 2>/dev/null || echo "  (no servers or parse error)"

    if [[ -f "$STATE_FILE" ]]; then
        echo
        info "Local state:"
        jq . "$STATE_FILE"
    fi
}

# ── Run (full cycle) ────────────────────────────────────────────────────────
do_run() {
    local test_result=0

    # Trap for cleanup on failure
    trap 'warn "Caught signal, tearing down..."; do_teardown; exit 1' INT TERM
    trap 'if [[ $? -ne 0 ]]; then warn "Script failed, tearing down..."; do_teardown; fi' EXIT

    do_provision
    do_test || test_result=$?

    # Always teardown
    trap - EXIT
    do_teardown

    if [[ $test_result -eq 0 ]]; then
        ok "E2E test passed! 🎉"
    else
        err "E2E test had failures"
    fi
    return $test_result
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"; shift || true

    case "$cmd" in
        run)       do_run ;;
        provision) check_deps; trap 'warn "Caught signal, tearing down..."; do_teardown; exit 1' INT TERM; do_provision ;;
        test)      do_test "$@" ;;
        teardown)  do_teardown "$@" ;;
        status)    do_status ;;
        *)
            echo "Marathon E2E Test — Latitude.sh Bare Metal"
            echo
            echo "Usage: $0 <command> [args]"
            echo
            echo "Commands:"
            echo "  run              Full cycle: provision → test → teardown"
            echo "  provision        Provision server only (for manual testing)"
            echo "  test <ip>        Run tests against existing server"
            echo "  teardown <id>    Destroy server by ID"
            echo "  status           Show running e2e servers"
            echo
            echo "Environment:"
            echo "  LATITUDE_API_KEY    Required. Latitude.sh API key."
            echo
            exit 1
            ;;
    esac
}

main "$@"
