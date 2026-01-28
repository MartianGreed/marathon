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

- [Zig](https://ziglang.org/) 0.15.2+
- Docker (for containerized builds)
- Firecracker (for VM isolation)
- PostgreSQL 16+
- Redis 7+
- etcd 3.5+

## Quick Start

```bash
# Build
make build

# Run tests
make test

# Start infrastructure dependencies
docker compose up -d

# Run the orchestrator
./zig-out/bin/orchestrator

# Run a node operator
./zig-out/bin/node_operator
```

## Build Commands

```bash
make build              # Debug build
make build-release      # Release build with optimizations
make test               # Run all tests
make lint               # Check formatting
make format             # Auto-format code
make proto-check        # Validate protobuf definitions
make snapshot           # Create VM snapshots (kernel + rootfs)
make docker-build       # Build via Alpine Docker container
make install            # Install binaries to /usr/local/bin
```

## Configuration

Copy `.env.example` to `.env` and configure:

```bash
cp .env.example .env
```

Key environment variables:

| Variable | Description |
|----------|-------------|
| `MARATHON_ANTHROPIC_API_KEY` | API key for Claude |
| `MARATHON_ORCHESTRATOR_HOST` | Orchestrator address |
| `MARATHON_ORCHESTRATOR_PORT` | Orchestrator port |
| `MARATHON_NODE_ID` | Unique node identifier |
| `MARATHON_VM_SLOTS` | Max concurrent VMs per node |
| `MARATHON_POSTGRES_URL` | PostgreSQL connection string |
| `MARATHON_REDIS_URL` | Redis connection string |
| `GITHUB_TOKEN` | GitHub token for PR creation |

## Documentation

- [Node Operator Guide](docs/node-operator.md)
- [Zig Code Standards](docs/zig-guide.md)

## License

Apache License 2.0 - see [LICENSE](LICENSE) for details.
