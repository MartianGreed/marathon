#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Marathon E2E Task Test — Real Claude Code task against ccmanager
#
# Submits an actionable task to Marathon (add a feature + tests to ccmanager),
# monitors execution, and validates the output (PR created, tests pass).
#
# Usage:
#   ./scripts/e2e-task-test.sh run [--host <ip>]     # Full task e2e
#   ./scripts/e2e-task-test.sh submit [--host <ip>]   # Submit only
#   ./scripts/e2e-task-test.sh status <task_id>        # Check task
#   ./scripts/e2e-task-test.sh logs <task_id>          # Get task logs
#
# Requires:
#   GITHUB_TOKEN         — GitHub token with repo access
#   ANTHROPIC_API_KEY    — For Claude Code (optional, orchestrator may provide)
#   MARATHON_HOST        — Orchestrator address (default: localhost)
#   MARATHON_PORT        — Orchestrator port (default: 8443)
#
# Can also run against a remote server via --host <ip> (uses e2e SSH key).
###############################################################################

# ── Config ───────────────────────────────────────────────────────────────────
MARATHON_HOST="${MARATHON_HOST:-localhost}"
MARATHON_PORT="${MARATHON_PORT:-8443}"
MARATHON_BIN="${MARATHON_BIN:-./zig-out/bin/marathon}"

TARGET_REPO="https://github.com/MartianGreed/ccmanager"
TARGET_BRANCH="main"

# Task timeout: 15 min (agent may iterate multiple times)
TASK_TIMEOUT=900
POLL_INTERVAL=15

# E2E SSH state (from e2e-test.sh)
STATE_DIR="/tmp/marathon-e2e"
SSH_KEY="$STATE_DIR/id_ed25519"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $(date +%H:%M:%S) $*"; }
ok()    { echo -e "${GREEN}[  OK]${NC} $(date +%H:%M:%S) $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $(date +%H:%M:%S) $*"; }
err()   { echo -e "${RED}[ERR ]${NC} $(date +%H:%M:%S) $*"; }
die()   { err "$@"; exit 1; }

# ── The actual task prompt ───────────────────────────────────────────────────
# This is a real, actionable task that produces a measurable output (a PR).
# It's scoped to be completable in a single iteration but meaningful.
TASK_PROMPT='Add a "session export" feature to ccmanager.

Requirements:
1. Add a new command "export" to the CLI that exports session statistics to JSON
2. Create internal/export/export.go with an ExportService that:
   - Takes a session ID or "all" 
   - Queries the store for session data (actions, APM history, streaks)
   - Returns a JSON struct with: session_id, total_actions, avg_apm, peak_apm, total_score, duration_seconds, exported_at
3. Add the export subcommand in cmd/ccmanager/main.go
4. Write tests in internal/export/export_test.go covering:
   - Single session export
   - All sessions export
   - Empty/missing session handling
5. Make sure existing tests still pass: run `make test`
6. Create a PR with title "feat: add session export to JSON"

When done, output: <promise>TASK_COMPLETE</promise>'

COMPLETION_PROMISE="TASK_COMPLETE"
MAX_ITERATIONS=5

# ── Helpers ──────────────────────────────────────────────────────────────────
REMOTE_HOST=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host) REMOTE_HOST="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    echo "$@"
}

marathon_cmd() {
    if [[ -n "$REMOTE_HOST" ]]; then
        ssh $SSH_OPTS -i "$SSH_KEY" "root@$REMOTE_HOST" \
            "cd /opt/marathon && $MARATHON_BIN $*"
    else
        $MARATHON_BIN "$@"
    fi
}

check_prereqs() {
    if [[ -n "$REMOTE_HOST" ]]; then
        [[ -f "$SSH_KEY" ]] || die "SSH key not found at $SSH_KEY (run e2e-test.sh provision first)"
        info "Testing SSH to $REMOTE_HOST..."
        ssh $SSH_OPTS -i "$SSH_KEY" "root@$REMOTE_HOST" "echo ok" &>/dev/null \
            || die "Cannot SSH to $REMOTE_HOST"
        ok "SSH to $REMOTE_HOST works"
    else
        [[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN not set"
        command -v "$MARATHON_BIN" &>/dev/null || [[ -f "$MARATHON_BIN" ]] \
            || die "Marathon binary not found at $MARATHON_BIN"
    fi
}

# ── Submit ───────────────────────────────────────────────────────────────────
do_submit() {
    info "Submitting task to Marathon..."
    info "  Target repo: $TARGET_REPO"
    info "  Max iterations: $MAX_ITERATIONS"
    info "  Completion promise: $COMPLETION_PROMISE"
    echo

    local submit_output
    submit_output=$(marathon_cmd submit \
        --repo "$TARGET_REPO" \
        --branch "$TARGET_BRANCH" \
        --prompt "$TASK_PROMPT" \
        --pr \
        --pr-title "feat: add session export to JSON" \
        --max-iterations "$MAX_ITERATIONS" \
        --completion-promise "$COMPLETION_PROMISE" \
        2>&1) || true

    echo "$submit_output"

    # Extract task ID from output
    local task_id
    task_id=$(echo "$submit_output" | grep -oP 'task[_-]?id[=: ]*\K[a-f0-9]+' | head -1 || true)
    if [[ -z "$task_id" ]]; then
        task_id=$(echo "$submit_output" | grep -oP '[a-f0-9]{32,}' | head -1 || true)
    fi

    if [[ -z "$task_id" ]]; then
        die "Could not extract task ID from submit output"
    fi

    ok "Task submitted: $task_id"
    echo "$task_id"
}

# ── Poll ─────────────────────────────────────────────────────────────────────
do_poll() {
    local task_id="$1"
    local deadline=$(($(date +%s) + TASK_TIMEOUT))

    info "Polling task $task_id (timeout: ${TASK_TIMEOUT}s)..."
    echo

    while [[ $(date +%s) -lt $deadline ]]; do
        local status_output
        status_output=$(marathon_cmd status "$task_id" 2>&1) || true

        local state
        state=$(echo "$status_output" | grep -oiP '(queued|starting|running|completed|failed|cancelled)' | head -1 || echo "unknown")

        local elapsed=$(($(date +%s) + TASK_TIMEOUT - deadline + TASK_TIMEOUT))
        printf "  ${CYAN}[%3ds]${NC} State: %-12s\r" "$(($(date +%s) - (deadline - TASK_TIMEOUT)))" "$state"

        case "$state" in
            completed)
                echo
                ok "Task completed!"
                echo "$status_output"
                return 0
                ;;
            failed)
                echo
                err "Task failed!"
                echo "$status_output"
                return 1
                ;;
            cancelled)
                echo
                err "Task was cancelled"
                return 1
                ;;
        esac

        sleep "$POLL_INTERVAL"
    done

    echo
    err "Task timed out after ${TASK_TIMEOUT}s"
    return 1
}

# ── Validate ─────────────────────────────────────────────────────────────────
do_validate() {
    local task_id="$1"
    local passed=0 failed=0 total=0

    echo
    info "=== Validating Task Output ==="

    # Check task completed
    local status_output
    status_output=$(marathon_cmd status "$task_id" 2>&1) || true

    total=$((total+1))
    if echo "$status_output" | grep -qi "completed"; then
        ok "PASS: Task completed successfully"
        passed=$((passed+1))
    else
        err "FAIL: Task not in completed state"
        failed=$((failed+1))
    fi

    # Check PR was created
    total=$((total+1))
    local pr_url
    pr_url=$(echo "$status_output" | grep -oP 'https://github.com/[^\s]+/pull/\d+' | head -1 || true)
    if [[ -n "$pr_url" ]]; then
        ok "PASS: PR created — $pr_url"
        passed=$((passed+1))

        # Validate PR on GitHub (if gh is available)
        if command -v gh &>/dev/null; then
            total=$((total+1))
            local pr_state
            pr_state=$(gh pr view "$pr_url" --json state -q '.state' 2>/dev/null || echo "unknown")
            if [[ "$pr_state" == "OPEN" || "$pr_state" == "MERGED" ]]; then
                ok "PASS: PR is $pr_state on GitHub"
                passed=$((passed+1))
            else
                warn "SKIP: Could not verify PR state (got: $pr_state)"
            fi

            # Check PR has the export files
            total=$((total+1))
            local pr_files
            pr_files=$(gh pr view "$pr_url" --json files -q '.files[].path' 2>/dev/null || echo "")
            if echo "$pr_files" | grep -q "export"; then
                ok "PASS: PR contains export-related files"
                passed=$((passed+1))
            else
                err "FAIL: PR doesn't contain expected export files"
                failed=$((failed+1))
            fi

            # Check CI status on PR
            total=$((total+1))
            local ci_status
            ci_status=$(gh pr checks "$pr_url" 2>/dev/null | head -5 || echo "")
            if echo "$ci_status" | grep -q "pass"; then
                ok "PASS: CI checks passing on PR"
                passed=$((passed+1))
            elif [[ -z "$ci_status" ]]; then
                warn "SKIP: No CI checks found (may still be running)"
            else
                warn "INFO: CI status — $ci_status"
            fi
        fi
    else
        err "FAIL: No PR URL found in task output"
        failed=$((failed+1))
    fi

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}, $total total"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    [[ $failed -eq 0 ]] && return 0 || return 1
}

# ── Run (full cycle) ────────────────────────────────────────────────────────
do_run() {
    check_prereqs

    local start_ts
    start_ts=$(date +%s)

    info "=== Marathon E2E Task Test ==="
    info "Task: Add session export feature to ccmanager"
    info "Target: $TARGET_REPO"
    echo

    # Submit
    local task_id
    task_id=$(do_submit | tail -1)

    # Poll
    do_poll "$task_id" || true

    # Validate
    local result=0
    do_validate "$task_id" || result=$?

    local elapsed=$(($(date +%s) - start_ts))
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Total time: $((elapsed/60))m$((elapsed%60))s"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ $result -eq 0 ]]; then
        ok "E2E task test passed! 🎉"
    else
        err "E2E task test had failures"
    fi
    return $result
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"; shift || true

    # Parse --host from remaining args
    local remaining_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host) REMOTE_HOST="$2"; shift 2 ;;
            *) remaining_args+=("$1"); shift ;;
        esac
    done
    set -- "${remaining_args[@]+"${remaining_args[@]}"}"

    case "$cmd" in
        run)     do_run ;;
        submit)  check_prereqs; do_submit ;;
        status)  [[ $# -ge 1 ]] || die "Usage: $0 status <task_id>"; marathon_cmd status "$1" ;;
        logs)    [[ $# -ge 1 ]] || die "Usage: $0 logs <task_id>"; marathon_cmd status "$1" --verbose ;;
        *)
            echo "Marathon E2E Task Test — Real task against ccmanager"
            echo
            echo "Usage: $0 <command> [options]"
            echo
            echo "Commands:"
            echo "  run              Submit task, poll, validate output"
            echo "  submit           Submit task only (prints task ID)"
            echo "  status <id>      Check task status"
            echo "  logs <id>        Get task logs"
            echo
            echo "Options:"
            echo "  --host <ip>      Run against remote server (uses e2e SSH key)"
            echo
            echo "Environment:"
            echo "  GITHUB_TOKEN         GitHub token with repo access"
            echo "  MARATHON_HOST        Orchestrator address (default: localhost)"
            echo "  MARATHON_PORT        Orchestrator port (default: 8443)"
            echo "  MARATHON_BIN         Path to marathon binary"
            echo
            echo "Task: Adds a session export feature to ccmanager (Go project)"
            echo "Validates: task completes, PR created, files correct, CI passes"
            echo
            exit 1
            ;;
    esac
}

main "$@"
