//! Firecracker microVMs: the API client, one VM's lifecycle, TAP networking
//! and the warm pool.

pub mod api;
pub mod firecracker;
pub mod network;
pub mod pool;

pub use firecracker::{Vm, VmConfig, VmError, VmState};
pub use pool::{FirecrackerLauncher, PoolConfig, PoolError, VmLauncher, VmLease, VmPool};
