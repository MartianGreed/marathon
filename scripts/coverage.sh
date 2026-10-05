#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CARGO="${CARGO:-cargo}"
if ! "$CARGO" llvm-cov --version >/dev/null 2>&1; then
    echo "Coverage requires cargo-llvm-cov: cargo install cargo-llvm-cov --locked; rustup component add llvm-tools-preview" >&2
    exit 1
fi
component="${1:-all}"
output_dir="${2:-coverage}"
case "$component" in
    all) scope=(--workspace) ;;
    common) scope=(-p common) ;;
    node_operator) scope=(-p marathon-node-operator) ;;
    orchestrator) scope=(-p marathon-orchestrator) ;;
    vm_agent) scope=(-p marathon-vm-agent) ;;
    client) scope=(-p marathon-client) ;;
    *) echo "Unknown component: $component" >&2; exit 2 ;;
esac
"$CARGO" llvm-cov "${scope[@]}" --locked --html --output-dir "$output_dir"
