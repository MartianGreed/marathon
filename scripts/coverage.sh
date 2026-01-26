#!/bin/bash
# Coverage script for Marathon
# Usage: ./scripts/coverage.sh <component> <output_dir>
# Components: node_operator, orchestrator, vm_agent, client, common, all

set -e

COMPONENT="${1:-all}"
OUTPUT_DIR="${2:-coverage}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_kcov() {
    if command -v kcov &> /dev/null; then
        return 0
    fi
    return 1
}

check_llvm_cov() {
    if command -v llvm-cov &> /dev/null; then
        return 0
    fi
    return 1
}

# Build test binary for a component
build_test_binary() {
    local component=$1
    local test_binary=".zig-cache/test-${component}"

    info "Building test binary for ${component}..."

    case "$component" in
        node_operator)
            zig test --test-no-exec \
                -ODebug \
                --dep common \
                -Mroot="${PROJECT_ROOT}/node_operator/src/main.zig" \
                -Mcommon="${PROJECT_ROOT}/common/src/root.zig" \
                --cache-dir .zig-cache \
                --name "test-${component}" \
                2>&1 || true
            ;;
        orchestrator)
            zig test --test-no-exec \
                -ODebug \
                --dep common \
                -Mroot="${PROJECT_ROOT}/orchestrator/src/main.zig" \
                -Mcommon="${PROJECT_ROOT}/common/src/root.zig" \
                --cache-dir .zig-cache \
                --name "test-${component}" \
                2>&1 || true
            ;;
        common)
            zig test --test-no-exec \
                -ODebug \
                -Mroot="${PROJECT_ROOT}/common/src/root.zig" \
                --cache-dir .zig-cache \
                --name "test-${component}" \
                2>&1 || true
            ;;
        *)
            error "Unknown component: ${component}"
            ;;
    esac
}

# Run tests with kcov
run_kcov_coverage() {
    local component=$1
    local output_dir=$2

    info "Running coverage with kcov for ${component}..."
    mkdir -p "${output_dir}"

    # Build test binary with debug info
    info "Building test binary with debug symbols..."
    local test_bin="${PROJECT_ROOT}/.zig-cache/coverage-test-${component}"

    case "$component" in
        node_operator)
            zig test \
                --dep common \
                -Mroot="${PROJECT_ROOT}/node_operator/src/main.zig" \
                -Mcommon="${PROJECT_ROOT}/common/src/root.zig" \
                -femit-bin="${test_bin}" \
                --test-no-exec \
                2>&1 || true
            ;;
        orchestrator)
            zig test \
                --dep common \
                -Mroot="${PROJECT_ROOT}/orchestrator/src/main.zig" \
                -Mcommon="${PROJECT_ROOT}/common/src/root.zig" \
                -femit-bin="${test_bin}" \
                --test-no-exec \
                2>&1 || true
            ;;
        common)
            zig test \
                -Mroot="${PROJECT_ROOT}/common/src/root.zig" \
                -femit-bin="${test_bin}" \
                --test-no-exec \
                2>&1 || true
            ;;
        *)
            error "Unknown component: ${component}"
            ;;
    esac

    if [ ! -f "${test_bin}" ]; then
        warn "Failed to build test binary, falling back to zig build test"
        kcov --include-pattern="${PROJECT_ROOT}/${component}/src" \
             "${output_dir}" \
             zig build test 2>&1 || true
    else
        info "Running kcov on test binary..."
        kcov --include-pattern="${PROJECT_ROOT}/${component}/src" \
             --exclude-pattern="/.zig-cache/,/common/src/" \
             "${output_dir}" \
             "${test_bin}" 2>&1 || true
        rm -f "${test_bin}"
    fi

    info "Coverage report generated at ${output_dir}/index.html"
}

# Generate coverage summary without kcov (fallback)
run_test_summary() {
    local component=$1
    local output_dir=$2

    info "Running tests for ${component} (coverage tool not available)..."
    mkdir -p "${output_dir}"

    # Run tests and capture output
    local test_output="${output_dir}/test_output.txt"
    zig build test 2>&1 | tee "${test_output}"

    # Count tests
    local passed=$(grep -c "passed" "${test_output}" 2>/dev/null || echo "0")
    local failed=$(grep -c "failed" "${test_output}" 2>/dev/null || echo "0")

    # Count source files and test functions
    local src_files=$(find "${PROJECT_ROOT}/${component}/src" -name "*.zig" 2>/dev/null | wc -l | tr -d ' ')
    local test_funcs=$(grep -r "^test \"" "${PROJECT_ROOT}/${component}/src" 2>/dev/null | wc -l | tr -d ' ')

    # Generate HTML report
    cat > "${output_dir}/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Coverage Report - ${component}</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 2px solid #007acc; padding-bottom: 10px; }
        .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 20px; margin: 20px 0; }
        .stat { background: #f8f9fa; padding: 20px; border-radius: 6px; text-align: center; }
        .stat-value { font-size: 2em; font-weight: bold; color: #007acc; }
        .stat-label { color: #666; margin-top: 5px; }
        .files { margin-top: 30px; }
        .file { padding: 10px; border-bottom: 1px solid #eee; }
        .file:hover { background: #f8f9fa; }
        .note { background: #fff3cd; padding: 15px; border-radius: 6px; margin-top: 20px; }
        .timestamp { color: #999; font-size: 0.9em; margin-top: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Coverage Report: ${component}</h1>

        <div class="summary">
            <div class="stat">
                <div class="stat-value">${src_files}</div>
                <div class="stat-label">Source Files</div>
            </div>
            <div class="stat">
                <div class="stat-value">${test_funcs}</div>
                <div class="stat-label">Test Functions</div>
            </div>
            <div class="stat">
                <div class="stat-value">$(echo "${test_funcs} ${src_files}" | awk '{if($2>0) printf "%.0f%%", ($1/$2)*100; else print "N/A"}')</div>
                <div class="stat-label">Test Density</div>
            </div>
        </div>

        <div class="files">
            <h2>Source Files</h2>
EOF

    # List source files with test counts
    find "${PROJECT_ROOT}/${component}/src" -name "*.zig" 2>/dev/null | sort | while read -r file; do
        local basename=$(basename "$file")
        local tests=$(grep -c '^test "' "$file" 2>/dev/null || echo "0")
        local lines=$(wc -l < "$file" | tr -d ' ')
        echo "            <div class=\"file\"><strong>${basename}</strong> - ${lines} lines, ${tests} tests</div>" >> "${output_dir}/index.html"
    done

    cat >> "${output_dir}/index.html" << EOF
        </div>

        <div class="note">
            <strong>Note:</strong> Full line coverage requires kcov (Linux) or llvm-cov.
            Install kcov for detailed coverage: <code>apt install kcov</code> or <code>brew install kcov</code>
        </div>

        <div class="timestamp">Generated: $(date)</div>
    </div>
</body>
</html>
EOF

    info "Test summary report generated at ${output_dir}/index.html"
}

# Main
cd "${PROJECT_ROOT}"
mkdir -p "${OUTPUT_DIR}"

if [ "$COMPONENT" = "all" ]; then
    components="common orchestrator node_operator"
else
    components="$COMPONENT"
fi

for comp in $components; do
    if [ "$COMPONENT" = "all" ]; then
        comp_output="${OUTPUT_DIR}/${comp}"
    else
        comp_output="${OUTPUT_DIR}"
    fi

    if check_kcov; then
        run_kcov_coverage "$comp" "$comp_output"
    else
        warn "kcov not found, generating test summary instead"
        run_test_summary "$comp" "$comp_output"
    fi
done

info "Coverage complete! Reports in ${OUTPUT_DIR}/"

# Generate index if multiple components
if [ "$COMPONENT" = "all" ]; then
    cat > "${OUTPUT_DIR}/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Marathon Coverage Reports</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 600px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; }
        h1 { color: #333; }
        ul { list-style: none; padding: 0; }
        li { margin: 10px 0; }
        a { color: #007acc; text-decoration: none; font-size: 1.2em; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Marathon Coverage Reports</h1>
        <ul>
            <li><a href="common/index.html">common</a></li>
            <li><a href="orchestrator/index.html">orchestrator</a></li>
            <li><a href="node_operator/index.html">node_operator</a></li>
        </ul>
    </div>
</body>
</html>
EOF
fi
