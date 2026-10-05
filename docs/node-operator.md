# Node operator

`marathon-node-operator` is a Rust process on an x86_64 Linux Firecracker host. It initializes snapshot storage, warms a bounded VM pool, and opens an outbound bidirectional gRPC heartbeat stream to the orchestrator. It does not bind a node RPC or metrics port. The orchestrator sends execute, cancel, drain, and warm-pool commands on that stream; the node reports status and task results.

## Lifecycle and capacity

`node_operator/src/main.rs` wires `SnapshotManager`, `FirecrackerLauncher`, `VmPool`, `TaskExecutor`, and `HeartbeatClient`. The pool reuses warm VMs or claims a free slot for an on-demand boot. Failed launches and cancelled tasks release capacity. Snapshot restoration uses Firecracker's Unix socket API; cold boot needs the configured kernel and rootfs.

`NodeStatus.active_vms` counts every occupied non-warm slot, including running VMs and slots still booting. Booting warm-pool reservations also count until they become warm. `warm_vms` counts ready unclaimed VMs. A task ID appears in `active_task_ids` only once its slot is claimed. This prevents the scheduler from treating an accepted task's booting slot as spare capacity.

Heartbeat intervals shorten while tasks are active. Reconnection uses bounded exponential backoff. Drain stops new work. Configure a persistent 32-character hexadecimal `MARATHON_NODE_ID`; otherwise startup chooses a random ID. `HOSTNAME` supplies the human-readable host label.

## Guest transport

The node connects to Firecracker's vsock Unix socket and performs its connection handshake. Node and guest then exchange length-prefixed protobuf frames from `common/src/vsock.rs`, with a four-byte length and a bounded message size. This transport carries task configuration, output, results, and trace context. It is separate from the HTTP/2 gRPC client and heartbeat APIs.

The Alpine guest rootfs needs the static x86_64 musl `marathon-vm-agent`. On x86_64 Linux with musl tools and protoc installed, run `make vm-agent-musl`, then `make rootfs`. `MARATHON_VM_AGENT_BIN` overrides the binary copied by `snapshot/create_rootfs.sh`. Creating rootfs images, snapshots, and real VMs requires host privileges and KVM.

## Configuration

| Variable | Meaning |
| --- | --- |
| `MARATHON_ORCHESTRATOR_ADDRESS` | Orchestrator hostname, default `127.0.0.1` |
| `MARATHON_ORCHESTRATOR_PORT` | gRPC port, default `8080` |
| `MARATHON_TLS_ENABLED` | `true` or `1` enables TLS; defaults on for port 443 |
| `MARATHON_TLS_CA_PATH` | Optional PEM CA for the server |
| `MARATHON_NODE_AUTH_KEY` | Shared heartbeat authentication key |
| `MARATHON_TOTAL_VM_SLOTS` | Pool capacity, default 10 |
| `MARATHON_WARM_POOL_TARGET` | Ready VM target, default 5; zero disables startup boots |
| `MARATHON_SNAPSHOT_PATH` | Snapshot directory |
| `MARATHON_KERNEL_PATH` | Kernel file |
| `MARATHON_ROOTFS_PATH` | Guest ext4 rootfs |
| `MARATHON_FIRECRACKER_BIN` | Firecracker executable, default `/usr/bin/firecracker` |

## Verification

`cargo test -p marathon-node-operator` exercises pool capacity, cancellation, heartbeat state, snapshot handling, and transport behavior. A macOS smoke can verify registration and client APIs with `MARATHON_WARM_POOL_TARGET=0`; submitted tasks cannot complete without a working Firecracker host. A real Firecracker end-to-end run on a KVM host is owed until its commands and results are recorded. Provisioning scripts can allocate billed bare metal; inspect them before execution.
