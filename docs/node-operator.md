# Node Operator Workflow Documentation

## Overview

The node_operator is a compute node service that manages Firecracker VMs for executing Claude Code tasks. It maintains a warm pool of pre-started VMs for fast task assignment and communicates with VMs via vsock.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Node Operator                             │
├─────────────────────────────────────────────────────────────────┤
│  main.zig                                                        │
│    ├── SnapshotManager (snapshot/manager.zig)                   │
│    ├── VmPool (vm/firecracker.zig)                              │
│    │     ├── warm_vms: []Vm (pre-started, ready)                │
│    │     └── active_vms: HashMap<VmId, Vm> (running tasks)      │
│    ├── HeartbeatClient (heartbeat/heartbeat.zig)                │
│    └── VsockHandler (vsock/handler.zig)                         │
└─────────────────────────────────────────────────────────────────┘
```

## Component Details

### 1. Entry Point (`main.zig`)

```zig
main() -> void
  1. Initialize GeneralPurposeAllocator
  2. Load config from environment (NodeOperatorConfig)
  3. Create SnapshotManager
  4. Create VmPool with snapshot_mgr reference
  5. Enter main loop (currently a placeholder)
```

### 2. VM Lifecycle (`vm/firecracker.zig`)

**State Machine:**
```
creating → ready → running → stopped
              ↓        ↓
           failed   failed
```

**Vm struct:**
- `id: VmId` - 32-byte unique identifier
- `state: VmState` - current lifecycle state
- `process: ?std.process.Child` - Firecracker process handle
- `socket_path: []const u8` - Unix socket for Firecracker API
- `vsock_cid: u32` - Context ID for vsock (3 to 0xFFFFFFFF)
- `task_id: ?TaskId` - assigned task (if running)
- `start_time: ?i64` - timestamp for uptime tracking

**Key operations:**
- `init()` - allocate VM, generate random ID and CID
- `start(config)` - cold start from kernel/rootfs
- `startFromSnapshot(mgr, config)` - restore from snapshot
- `stop()` - kill process, wait, transition to stopped
- `assignTask(task_id)` - mark as running
- `releaseTask()` - return to ready state

### 3. VM Pool (`vm/firecracker.zig`)

**VmPool struct:**
- `warm_vms: ArrayListUnmanaged(*Vm)` - ready VMs awaiting tasks
- `active_vms: AutoHashMap(VmId, *Vm)` - VMs running tasks
- `mutex: Thread.Mutex` - protects both collections

**Operations:**
- `warmPool(target)` - pre-start VMs to maintain warm pool size
- `acquire()` - pop from warm_vms, add to active_vms
- `release(vm_id)` - remove from active_vms, destroy VM
- `warmCount()` / `activeCount()` / `totalCount()` - pool statistics

### 4. Snapshot Management (`snapshot/manager.zig`)

**SnapshotManager struct:**
- `base_path: []const u8` - directory containing snapshots
- `snapshots: StringHashMap(SnapshotInfo)` - discovered snapshots
- `mutex: Thread.Mutex` - protects snapshot map

**Snapshot validation:**
- Requires both `snapshot` and `mem` files in directory
- Scans `base_path` on init for valid snapshots
- Creates directory if not found

**Operations:**
- `getSnapshot(name)` - lookup by name
- `getDefaultSnapshot()` - returns "base" snapshot
- `listSnapshots()` - return all registered snapshots

### 5. Vsock Communication (`vsock/handler.zig`)

**Message Protocol (binary, big-endian):**
```
┌──────────┬──────────┬─────────────┐
│ Type (1) │ Len (4)  │ Payload (N) │
└──────────┴──────────┴─────────────┘
```

**Message Types:**
| Type | Name | Payload |
|------|------|---------|
| 0x01 | Output | stdout/stderr data |
| 0x02 | Metrics | input_tokens(u32) + output_tokens(u32) + cost_usd(f64) |
| 0x03 | Complete | exit_code(i32) + optional pr_url |
| 0x04 | Error | error message string |

**VsockHandler:**
- Connects to VM via vsock (CID + port)
- Reads messages in loop
- Decodes and dispatches by type
- Aggregates metrics for metering

### 6. Heartbeat (`heartbeat/heartbeat.zig`)

**HeartbeatClient:**
- Reports node status to orchestrator periodically
- Collects: hostname, available VMs, active tasks, memory/CPU stats
- Runs in background thread
- Stop flag for graceful shutdown

## Task Execution Flow

```
1. Orchestrator assigns task to node
         ↓
2. Node calls vmPool.acquire()
         ↓
3. VM popped from warm_vms → active_vms
         ↓
4. vm.assignTask(task_id)
         ↓
5. VsockHandler connects to VM
         ↓
6. VM Agent executes Claude Code
         ↓
7. Messages flow back via vsock:
   - Output (streaming stdout/stderr)
   - Metrics (token counts, costs)
   - Complete or Error (final status)
         ↓
8. vmPool.release(vm_id)
         ↓
9. VM destroyed, new VM warmed up
```

## Thread Safety

All shared state protected by mutexes:
- `VmPool.mutex` - warm_vms and active_vms access
- `SnapshotManager.mutex` - snapshot map access

Pattern used: `self.mutex.lock(); defer self.mutex.unlock();`

## Error Handling

- Snapshot restore failure → falls back to cold start
- VM start failure → logged, skipped (pool may be undersized)
- Vsock connection failure → task marked failed
- Process kill failure → ignored in cleanup (catch {})

## Configuration (`common/config.zig`)

```zig
NodeOperatorConfig:
  - listen_address/port
  - orchestrator_address/port
  - firecracker_bin, kernel_path, rootfs_path, snapshot_path
  - total_vm_slots, warm_pool_target
```

## Verification

```bash
# Run all node_operator tests
zig build test

# Run with coverage
make coverage-node-operator
```
