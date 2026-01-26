# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

Zig direct commands:
```bash
zig build                    # Build all targets
zig build test               # Run all tests
zig build -Doptimize=ReleaseSafe  # Release build
```

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
- Auth: API key validation

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
- Commands: submit, status, cancel, usage

**common/** - Shared library
- Types, config, protocol definitions
- Task state machine, node scoring algorithms

### Communication

- Orchestrator ↔ Node Operator: gRPC (protobuf definitions in `proto/marathon/v1/`)
- Node Operator ↔ VM Agent: vsock
- Client ↔ Orchestrator: gRPC

### Infrastructure Dependencies

- PostgreSQL: task persistence
- Redis: caching, rate limiting
- etcd: distributed coordination
- Firecracker: VM isolation

## Configuration

Key environment variables:
- `MARATHON_ANTHROPIC_API_KEY`: API key for Claude
- `MARATHON_ORCHESTRATOR_HOST/PORT`: orchestrator address
- `MARATHON_NODE_ID`: unique node identifier
- `MARATHON_VM_SLOTS`: max concurrent VMs per node
- `GITHUB_TOKEN`: for PR creation

## Observability

When writing or modifying code, automatically add:

**Logging**
- Log at function entry/exit for public APIs with relevant parameters
- Log errors with context (operation, inputs, error details)
- Use structured logging with fields: `task_id`, `node_id`, `operation`, `duration_ms`
- Log levels: `err` for failures, `warn` for degraded states, `info` for state transitions, `debug` for internals

**Metrics**
- Counters: requests, errors, retries (with labels for type/status)
- Histograms: latency for RPC calls, VM operations, task execution
- Gauges: active VMs, queue depth, connection pool size

**Tracing**
- Propagate trace context across gRPC calls and vsock messages
- Create spans for: task lifecycle, VM operations, external service calls
- Include `task_id` and `node_id` as span attributes

## Zig Code Standards

See `docs/zig-guide.md` for comprehensive patterns and examples.

### Memory Allocation (prefer in order)

1. **No allocation** - comptime, stack variables, slices of existing data
2. **FixedBufferAllocator** - pre-sized buffer, no heap
3. **BoundedArray** - compile-time max, runtime length
4. **ArenaAllocator** - batch allocations, single bulk free
5. **GeneralPurposeAllocator** - debug builds only

### Required Patterns

```zig
// Always defer cleanup immediately
var buf = try allocator.alloc(u8, size);
defer allocator.free(buf);

// errdefer for partial cleanup
var a = try allocator.alloc(A, n);
errdefer allocator.free(a);
var b = try allocator.alloc(B, n); // if fails, a is freed

// Arena for request-scoped work
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
```

### Error Handling

- Use `try` to propagate errors up
- Use `catch` with switch for local handling
- Combine error sets with `||` operator
- `errdefer` for cleanup on error paths only

### Generics & Comptime

- Use `comptime` for compile-time computation
- Generic structs: `fn List(comptime T: type) type { return struct { ... }; }`
- Use `@This()` for self-reference in generic structs
- Type reflection via `@typeInfo(T)`

### Performance

- Prefer slices over pointers (bounds checking, length included)
- Use `inline` for hot small functions
- Use `@Vector` for SIMD operations
- Avoid heap allocation in hot paths
- Build with `ReleaseSafe` for production

### Data Structures

- `std.ArrayList(T)` - dynamic array, requires allocator
- `std.AutoHashMap(K, V)` - general hash map
- `std.StringHashMap(V)` - string-keyed map
- `std.BoundedArray(T, N)` - fixed max size, no allocator
