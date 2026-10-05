# Marathon

A distributed Claude Code runner that executes tasks in isolated Firecracker VMs.

## Architecture

```
Client CLI → Orchestrator → Node Operator → Firecracker VM → VM Agent (runs Claude Code)
```

### Components

- **orchestrator/** - Central coordination service (task scheduling, node registry, metering, auth)
- **node_operator/** - Runs on compute nodes (VM pool management, snapshot restoration, vsock communication)
- **vm_agent/** - Runs inside guest VMs (wraps Claude Code execution, API interception for metering)
- **client/** - CLI tool (`marathon` binary)
- **common/** - Shared library (types, config, protocol definitions)

## Requirements

- Stable Rust via rustup, edition 2024, Rust 1.88+
- protoc for protobuf generation
- Docker (for containerized builds)
- Firecracker (for VM isolation)
- PostgreSQL 16+
- Redis and etcd remain in compose for legacy infrastructure; Rust services do not use them

## Quick Start

```bash
# Build
make build

# Run tests
make test

# Load local configuration, replacing the example secrets for deployment
cp .env.example .env
set -a; source .env; set +a

# Start infrastructure dependencies
docker compose up -d postgres

# Run the orchestrator
./target/debug/marathon-orchestrator

# Run a node operator
MARATHON_WARM_POOL_TARGET=0 ./target/debug/marathon-node-operator
```

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

`make docker-build` compiles on the container filesystem and copies the Linux binaries to `target/docker/release/`, keeping temporary artifacts off the shared mount and separate from host builds in `target/release/`.

## Configuration

Copy `.env.example` to `.env` and configure. The client reads `.env`; export variables for the orchestrator and node processes:

```bash
cp .env.example .env
set -a; source .env; set +a
```

Key environment variables:

| Variable | Description |
|----------|-------------|
| `MARATHON_ANTHROPIC_API_KEY` | API key for Claude |
| `MARATHON_ORCHESTRATOR_ADDRESS` | Orchestrator address |
| `MARATHON_ORCHESTRATOR_PORT` | Orchestrator port |
| `MARATHON_NODE_ID` | Unique node identifier |
| `MARATHON_TOTAL_VM_SLOTS` | Max concurrent VMs per node |
| `MARATHON_POSTGRES_URL` | PostgreSQL connection string |
| `MARATHON_REDIS_URL` | Redis connection string |
| `GITHUB_TOKEN` | GitHub token for PR creation |

Client and node APIs use tonic gRPC over HTTP/2; node heartbeats are bidirectional streams. Guest communication uses length-prefixed protobuf over vsock.

Set `MARATHON_JWT_SECRET` and a shared `MARATHON_NODE_AUTH_KEY`. Use a 32-character hexadecimal `MARATHON_NODE_ID`. The orchestrator defaults to port 8080; the node operator only opens outbound connections. Set `MARATHON_METRICS_PORT` to enable orchestrator metrics.

For required PostgreSQL integration tests (the driver test checks PostgreSQL 16 and the `postgres` user):
```bash
docker run -d --name marathon-test-pg -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:16-alpine
MARATHON_TEST_POSTGRES_URL=postgresql://postgres:postgres@localhost:5432/postgres MARATHON_TEST_REQUIRE_POSTGRES=1 make test
```

Coverage uses `cargo llvm-cov`; install `cargo-llvm-cov` and the `llvm-tools-preview` component, then run `make coverage`. The guest rootfs uses `target/x86_64-unknown-linux-musl/release/marathon-vm-agent`; `make rootfs` builds it first on a suitable Linux host.

## Local Development

Linux provisioning helper, requiring root on Ubuntu/Debian; installs Rust and build dependencies:

```bash
# Start everything (postgres, redis, firecracker setup, orchestrator, node_operator)
./scripts/local-dev.sh start

# Check status
./scripts/local-dev.sh status

# View logs
./scripts/local-dev.sh logs              # all services
./scripts/local-dev.sh logs orchestrator  # orchestrator only

# Stop everything
./scripts/local-dev.sh stop
```

**KVM detection:** The script checks for `/dev/kvm`. If available, it automatically:
- Downloads and installs Firecracker
- Downloads a compatible kernel (`vmlinux`)
- Builds the Alpine-based rootfs with Claude Code pre-installed
- Creates a Firecracker VM snapshot for fast restoration
- Sets `MARATHON_WARM_POOL_TARGET=5` for VM pre-warming

Without KVM (e.g., most cloud VMs), the script sets `MARATHON_WARM_POOL_TARGET=0` and skips all Firecracker setup. Orchestrator + node_operator still run for API/scheduling testing.

Edit `scripts/local-dev.env` to customize environment variables.

**Prerequisites:** PostgreSQL 16+, Redis 7+ (auto-installed on Ubuntu/Debian if missing).

A real Firecracker end-to-end test on an x86_64 KVM host is owed. macOS can exercise PostgreSQL, gRPC registration, and client APIs with warm pools disabled; VM execution needs Linux/KVM.

## Documentation

- [Node Operator Guide](docs/node-operator.md)
- [Rust code standards](docs/rust-guide.md)

## License

Apache License 2.0 - see [LICENSE](LICENSE) for details.
