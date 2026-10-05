# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
make build              # Debug build
make build-release      # Release build with optimizations
make test               # Run all tests
make lint               # Check formatting and Clippy
make format             # Auto-format code
make proto-check        # Validate protobuf definitions
make snapshot           # Create VM snapshots (kernel + rootfs)
make docker-build       # Build via Alpine Docker container
make install            # Install binaries to /usr/local/bin
```

Rust direct commands:
```bash
cargo build --workspace
cargo test --workspace
cargo build --workspace --release --locked
cargo clippy --workspace --all-targets -- -D warnings
```

Use stable Rust, edition 2024, Rust 1.88 or newer, and protoc.

## Architecture

Marathon is a distributed Claude Code runner that executes tasks in isolated Firecracker VMs.

### Component Flow

```
Client CLI → Orchestrator → Node Operator → Firecracker VM → VM Agent (runs Claude Code)
```

### Components

**orchestrator/** - Central coordination service
- Scheduler: assigns tasks to nodes using capacity-based scoring
- Registry: tracks node health and capabilities
- Metering: tracks token usage and compute time
- Auth: account registration, password authentication, JWT sessions

**node_operator/** - Runs on compute nodes
- VM pool management with warm instances
- Snapshot restoration for fast VM startup
- Vsock communication with guest VMs
- Heartbeat reporting to orchestrator

**vm_agent/** - Runs inside guest VMs
- Wraps Claude Code execution
- Intercepts API calls for metering
- Communicates results via vsock

**client/** - CLI tool (`marathon` binary)
- Commands: register, login, logout, whoami, submit, status, cancel, usage

**common/** - Shared library
- Types, config, protocol definitions
- Task state machine, node scoring algorithms

### Communication

- Orchestrator ↔ Node Operator: bidirectional gRPC heartbeat stream over HTTP/2 (protobuf definitions in `proto/marathon/v1/`)
- Node Operator ↔ VM Agent: vsock with length-prefixed protobuf frames
- Client ↔ Orchestrator: gRPC

### Infrastructure Dependencies

- PostgreSQL: task persistence
- Redis and etcd: legacy compose infrastructure; current Rust services do not use them
- Firecracker: VM isolation

## Configuration

Key environment variables:
- `MARATHON_ANTHROPIC_API_KEY`: API key for Claude
- `MARATHON_ORCHESTRATOR_ADDRESS` / `MARATHON_ORCHESTRATOR_PORT`: orchestrator address
- `MARATHON_NODE_ID`: unique node identifier
- `MARATHON_TOTAL_VM_SLOTS`: max concurrent VMs per node
- `GITHUB_TOKEN`: for PR creation
- `MARATHON_POSTGRES_URL`: persistent orchestrator store
- `MARATHON_JWT_SECRET`: JWT signing secret
- `MARATHON_NODE_AUTH_KEY`: shared node authentication key
- `MARATHON_LISTEN_ADDRESS` / `MARATHON_LISTEN_PORT`: orchestrator listener, default `0.0.0.0:8080`
- `MARATHON_METRICS_PORT`: optional orchestrator Prometheus port

The node operator dials out and does not listen on a port. PostgreSQL tests need `MARATHON_TEST_POSTGRES_URL`; set `MARATHON_TEST_REQUIRE_POSTGRES=1` to require them. A real Firecracker end-to-end test on a KVM host is owed.

## Observability

When writing or modifying code, automatically add:

**Logging**
- Log at function entry/exit for public APIs with relevant parameters
- Log errors with context (operation, inputs, error details)
- Use structured logging with fields: `task_id`, `node_id`, `operation`, `duration_ms`
- Log levels: `error` for failures, `warn` for degraded states, `info` for state transitions, `debug` for internals

**Metrics**
- Counters: requests, errors, retries (with labels for type/status)
- Histograms: latency for RPC calls, VM operations, task execution
- Gauges: active VMs, queue depth, connection pool size

**Tracing**
- Propagate trace context across gRPC calls and vsock messages
- Create spans for: task lifecycle, VM operations, external service calls
- Include `task_id` and `node_id` as span attributes

## Rust Code Standards

See [docs/rust-guide.md](docs/rust-guide.md). Prefer borrowed data and avoid needless clones and allocations. Use `thiserror` for typed errors, `anyhow` at application boundaries, and `?` for propagation. Inherit workspace dependencies and lints, including `unsafe_code = "deny"`. Keep unit tests next to code and integration tests in `tests/`. Formatting and Clippy with `-D warnings` must pass.
