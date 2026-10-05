//! Marathon node operator.
//!
//! Runs on each compute node: keeps a pool of Firecracker microVMs, holds a
//! heartbeat stream to the orchestrator that carries work, runs each task
//! in its own VM over vsock, and reports results and output back.
//!
//! - [`heartbeat`]: `NodeService` client, commands, reports, reconnect.
//! - [`task`]: the executor and the output buffer.
//! - [`vsock`]: the host side of the conversation with the VM agent.
//! - [`vm`]: Firecracker API, VM lifecycle, TAP networking, warm pool.
//! - [`snapshot`]: snapshots on disk.
//! - [`metrics`], [`trace`]: observability.

pub mod heartbeat;
pub mod metrics;
pub mod snapshot;
pub mod task;
pub mod trace;
pub mod vm;
pub mod vsock;
