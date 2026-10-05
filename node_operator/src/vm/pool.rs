//! Warm VM pool and slot accounting.
//!
//! The pool keeps up to `warm_pool_target` booted VMs waiting for work and
//! never holds more than `total_vm_slots` VMs (warm, running, or still
//! booting). A VM that served a task is always destroyed, because its agent
//! has exited; the pool then boots a replacement if it is below target.
//!
//! VMs boot through a [`VmLauncher`]: [`FirecrackerLauncher`] in production,
//! a fake in tests.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use common::config::NodeOperatorConfig;
use common::{TaskId, VmId};
use futures::future::BoxFuture;

use super::firecracker::{Vm, VmConfig, VmError};
use crate::metrics;
use crate::snapshot::SnapshotManager;

/// Boots a freshly created [`Vm`].
pub trait VmLauncher: Send + Sync + 'static {
    /// Boot `vm`. On success it is ready for a task and its
    /// `vsock_uds_path` reaches the guest agent.
    fn launch<'a>(&'a self, vm: &'a mut Vm) -> BoxFuture<'a, Result<(), VmError>>;

    /// A new, not yet booted VM.
    fn create(&self) -> Vm {
        Vm::new()
    }
}

/// Boots VMs with Firecracker, from the base snapshot when restore is
/// enabled.
pub struct FirecrackerLauncher {
    config: VmConfig,
    snapshots: Arc<SnapshotManager>,
}

impl FirecrackerLauncher {
    pub fn new(config: VmConfig, snapshots: Arc<SnapshotManager>) -> Self {
        Self { config, snapshots }
    }
}

impl VmLauncher for FirecrackerLauncher {
    fn launch<'a>(&'a self, vm: &'a mut Vm) -> BoxFuture<'a, Result<(), VmError>> {
        Box::pin(vm.start_from_snapshot(&self.snapshots, &self.config))
    }
}

/// Pool sizing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PoolConfig {
    pub total_vm_slots: u32,
    pub warm_pool_target: u32,
}

impl Default for PoolConfig {
    fn default() -> Self {
        let c = NodeOperatorConfig::default();
        Self {
            total_vm_slots: c.total_vm_slots,
            warm_pool_target: c.warm_pool_target,
        }
    }
}

impl From<&NodeOperatorConfig> for PoolConfig {
    fn from(c: &NodeOperatorConfig) -> Self {
        Self {
            total_vm_slots: c.total_vm_slots,
            warm_pool_target: c.warm_pool_target,
        }
    }
}

/// No VM could be handed out.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PoolError {
    #[error("no available VM: all {0} slots are in use")]
    NoSlots(u32),
    #[error("no available VM: {0}")]
    LaunchFailed(String),
}

/// What a task needs from the VM it was given.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VmLease {
    pub vm_id: VmId,
    pub vsock_uds_path: PathBuf,
    pub vsock_cid: u32,
}

impl VmLease {
    fn of(vm: &Vm) -> Self {
        Self {
            vm_id: vm.id,
            vsock_uds_path: vm.vsock_uds_path.clone(),
            vsock_cid: vm.vsock_cid,
        }
    }
}

#[derive(Default)]
struct PoolState {
    warm: Vec<Vm>,
    active: HashMap<VmId, Vm>,
    /// VMs booting outside the lock; they count toward the slots.
    starting: u32,
}

impl PoolState {
    fn occupied(&self) -> u32 {
        u32::try_from(self.warm.len() + self.active.len())
            .unwrap_or(u32::MAX)
            .saturating_add(self.starting)
    }
}

/// Stop treating the slot as booting when dropped.
struct StartingSlot<'a> {
    pool: &'a VmPool,
}

impl Drop for StartingSlot<'_> {
    fn drop(&mut self) {
        let mut s = self.pool.lock();
        s.starting = s.starting.saturating_sub(1);
    }
}

/// The node's VMs.
pub struct VmPool {
    launcher: Arc<dyn VmLauncher>,
    config: PoolConfig,
    state: Mutex<PoolState>,
}

impl VmPool {
    pub fn new(launcher: Arc<dyn VmLauncher>, config: PoolConfig) -> Self {
        Self {
            launcher,
            config,
            state: Mutex::new(PoolState::default()),
        }
    }

    pub fn config(&self) -> PoolConfig {
        self.config
    }

    fn lock(&self) -> MutexGuard<'_, PoolState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn update_gauges(state: &PoolState) {
        let m = metrics::global();
        m.warm_vms
            .set(i64::try_from(state.warm.len()).unwrap_or(i64::MAX));
        m.active_vms
            .set(i64::try_from(state.active.len()).unwrap_or(i64::MAX));
    }

    /// Reserve a slot for a VM about to boot, if one is free and `admit`
    /// accepts the current state.
    fn reserve(&self, admit: impl FnOnce(&PoolState) -> bool) -> Option<StartingSlot<'_>> {
        let mut s = self.lock();
        if s.occupied() >= self.config.total_vm_slots || !admit(&s) {
            return None;
        }
        s.starting += 1;
        Some(StartingSlot { pool: self })
    }

    /// Boot one VM in a reserved slot.
    async fn boot(&self, _slot: &StartingSlot<'_>) -> Result<Vm, VmError> {
        let mut vm = self.launcher.create();
        match self.launcher.launch(&mut vm).await {
            Ok(()) => Ok(vm),
            Err(e) => {
                vm.stop().await;
                Err(e)
            }
        }
    }

    /// Boot VMs until `target` are warm. Stops after 3 consecutive boot
    /// failures, or when every slot is taken.
    pub async fn warm_pool(&self, target: u32) {
        const MAX_CONSECUTIVE_FAILURES: u32 = 3;
        let op = common::telemetry::Operation::start("warm_pool");
        let mut failures = 0;
        loop {
            let Some(slot) = self
                .reserve(|s| u32::try_from(s.warm.len()).unwrap_or(u32::MAX) + s.starting < target)
            else {
                break;
            };
            match self.boot(&slot).await {
                Ok(vm) => {
                    failures = 0;
                    let mut s = self.lock();
                    s.warm.push(vm);
                    Self::update_gauges(&s);
                }
                Err(e) => {
                    failures += 1;
                    tracing::error!(parent: op.span(), error = %e, failures, "failed to start warm VM");
                    if failures >= MAX_CONSECUTIVE_FAILURES {
                        tracing::error!(parent: op.span(), failures, "warm pool: consecutive failures, aborting");
                        break;
                    }
                }
            }
            drop(slot);
        }
        tracing::info!(parent: op.span(), target, warm = self.warm_count(), "warm pool done");
        op.finish();
    }

    /// Take a warm VM, if any.
    pub fn acquire(&self) -> Option<VmLease> {
        let mut s = self.lock();
        let vm = s.warm.pop()?;
        let lease = VmLease::of(&vm);
        s.active.insert(vm.id, vm);
        Self::update_gauges(&s);
        Some(lease)
    }

    /// Take a warm VM, or boot one when a slot is free.
    pub async fn acquire_or_create(&self) -> Result<VmLease, PoolError> {
        if let Some(lease) = self.acquire() {
            return Ok(lease);
        }
        let slot = self
            .reserve(|_| true)
            .ok_or(PoolError::NoSlots(self.config.total_vm_slots))?;
        tracing::info!(
            operation = "acquire_vm",
            "no warm VMs available, creating on-demand"
        );
        let vm = self.boot(&slot).await.map_err(|e| {
            tracing::error!(operation = "acquire_vm", error = %e, "failed to start on-demand VM");
            PoolError::LaunchFailed(e.to_string())
        })?;
        let lease = VmLease::of(&vm);
        {
            let mut s = self.lock();
            s.active.insert(vm.id, vm);
            Self::update_gauges(&s);
        }
        // Drop the booting slot only after the VM is counted as active, so
        // the slot count never dips below the real number of VMs.
        drop(slot);
        Ok(lease)
    }

    /// Put a warm VM in the pool directly (custom launchers and tests).
    pub fn insert_warm(&self, vm: Vm) {
        let mut s = self.lock();
        s.warm.push(vm);
        Self::update_gauges(&s);
    }

    /// Record which task a leased VM runs.
    pub fn assign_task(&self, vm_id: VmId, task_id: TaskId) {
        if let Some(vm) = self.lock().active.get_mut(&vm_id) {
            vm.assign_task(task_id);
        }
    }

    /// Destroy a used VM, then boot a replacement if the pool is below its
    /// warm target.
    pub async fn release(&self, vm_id: VmId) {
        let vm = {
            let mut s = self.lock();
            let vm = s.active.remove(&vm_id);
            Self::update_gauges(&s);
            vm
        };
        let Some(mut vm) = vm else {
            return;
        };
        vm.stop().await;
        drop(vm);

        let target = self.config.warm_pool_target;
        let Some(slot) =
            self.reserve(|s| u32::try_from(s.warm.len()).unwrap_or(u32::MAX) + s.starting < target)
        else {
            return;
        };
        match self.boot(&slot).await {
            Ok(vm) => {
                let mut s = self.lock();
                s.warm.push(vm);
                Self::update_gauges(&s);
            }
            Err(e) => {
                tracing::warn!(operation = "replenish_pool", error = %e, "failed to replenish warm pool")
            }
        }
    }

    pub fn warm_count(&self) -> usize {
        self.lock().warm.len()
    }

    pub fn active_count(&self) -> usize {
        self.lock().active.len()
    }

    pub fn total_count(&self) -> usize {
        self.warm_count() + self.active_count()
    }

    /// Stop every VM.
    pub async fn shutdown(&self) {
        let vms: Vec<Vm> = {
            let mut s = self.lock();
            let mut vms: Vec<Vm> = std::mem::take(&mut s.warm);
            vms.extend(s.active.drain().map(|(_, vm)| vm));
            Self::update_gauges(&s);
            vms
        };
        for mut vm in vms {
            vm.stop().await;
        }
    }
}

#[cfg(test)]
pub(crate) mod testing {
    use super::*;

    /// A launcher that marks VMs ready without booting anything, or fails.
    pub struct NoopLauncher {
        pub fail: bool,
        pub dir: PathBuf,
    }

    impl VmLauncher for NoopLauncher {
        fn launch<'a>(&'a self, vm: &'a mut Vm) -> BoxFuture<'a, Result<(), VmError>> {
            Box::pin(async move {
                if self.fail {
                    Err(VmError::Launch("no firecracker".into()))
                } else {
                    vm.mark_ready();
                    Ok(())
                }
            })
        }

        fn create(&self) -> Vm {
            Vm::in_dir(&self.dir)
        }
    }

    pub fn pool(fail: bool, total_vm_slots: u32, warm_pool_target: u32) -> VmPool {
        VmPool::new(
            Arc::new(NoopLauncher {
                fail,
                dir: std::env::temp_dir(),
            }),
            PoolConfig {
                total_vm_slots,
                warm_pool_target,
            },
        )
    }

    pub fn ready_vm() -> Vm {
        let mut vm = Vm::in_dir(&std::env::temp_dir());
        vm.mark_ready();
        vm
    }
}

#[cfg(test)]
mod tests {
    use super::testing::{pool, ready_vm};
    use super::*;

    // Port of Zig `test "pool acquire returns null when empty"`.
    #[test]
    fn acquire_returns_none_when_empty() {
        let p = pool(true, 10, 0);
        assert_eq!(p.warm_count(), 0);
        assert!(p.acquire().is_none());
    }

    // Port of Zig `test "pool counts start at zero"`.
    #[test]
    fn counts_start_at_zero() {
        let p = pool(true, 10, 0);
        assert_eq!(p.total_count(), 0);
        assert_eq!(p.warm_count(), 0);
        assert_eq!(p.active_count(), 0);
    }

    // Port of Zig `test "pool release with manual vm insertion"`.
    #[tokio::test]
    async fn release_with_manual_vm_insertion() {
        let p = pool(true, 10, 0);
        p.insert_warm(ready_vm());
        assert_eq!(p.warm_count(), 1);
        let lease = p.acquire().unwrap();
        assert_eq!(p.warm_count(), 0);
        assert_eq!(p.active_count(), 1);
        p.release(lease.vm_id).await;
        // Used VM destroyed; nothing replenished (target 0).
        assert_eq!(p.warm_count(), 0);
        assert_eq!(p.active_count(), 0);
    }

    // Port of Zig `test "pool release always destroys used vm"`.
    #[tokio::test]
    async fn release_always_destroys_used_vm() {
        let p = pool(true, 5, 0);
        p.insert_warm(ready_vm());
        p.insert_warm(ready_vm());
        let lease = p.acquire().unwrap();
        assert_eq!(p.warm_count(), 1);
        assert_eq!(p.active_count(), 1);
        p.release(lease.vm_id).await;
        assert_eq!(p.warm_count(), 1);
        assert_eq!(p.active_count(), 0);
    }

    // Port of Zig `test "pool acquire after release gets different vm"`.
    #[tokio::test]
    async fn acquire_after_release_gets_different_vm() {
        let p = pool(true, 10, 0);
        p.insert_warm(ready_vm());
        p.insert_warm(ready_vm());
        let first = p.acquire().unwrap();
        p.release(first.vm_id).await;
        let next = p.acquire().unwrap();
        assert_ne!(next.vm_id, first.vm_id);
    }

    #[tokio::test]
    async fn release_replenishes_below_target() {
        let p = pool(false, 5, 2);
        p.insert_warm(ready_vm());
        let lease = p.acquire().unwrap();
        p.release(lease.vm_id).await;
        assert_eq!(p.warm_count(), 1, "one replacement booted");
        assert_eq!(p.active_count(), 0);
    }

    #[tokio::test]
    async fn release_failed_replenish_leaves_pool_empty() {
        let p = pool(true, 5, 2);
        p.insert_warm(ready_vm());
        let lease = p.acquire().unwrap();
        p.release(lease.vm_id).await;
        assert_eq!(p.total_count(), 0);
    }

    #[tokio::test]
    async fn release_unknown_vm_is_noop() {
        let p = pool(false, 5, 2);
        p.release(VmId::random()).await;
        assert_eq!(p.total_count(), 0);
    }

    #[tokio::test]
    async fn warm_pool_boots_to_target() {
        let p = pool(false, 10, 0);
        p.warm_pool(3).await;
        assert_eq!(p.warm_count(), 3);
        p.warm_pool(2).await;
        assert_eq!(p.warm_count(), 3, "never shrinks");
    }

    #[tokio::test]
    async fn warm_pool_respects_slots() {
        let p = pool(false, 2, 0);
        p.warm_pool(5).await;
        assert_eq!(p.warm_count(), 2);
    }

    #[tokio::test]
    async fn warm_pool_stops_after_three_failures() {
        let p = pool(true, 10, 0);
        p.warm_pool(5).await;
        assert_eq!(p.warm_count(), 0);
        assert_eq!(p.lock().starting, 0);
    }

    #[tokio::test]
    async fn warm_pool_retries_after_a_failure() {
        // Fails twice, then succeeds: fewer than 3 consecutive failures.
        struct Flaky(std::sync::atomic::AtomicU32);
        impl VmLauncher for Flaky {
            fn launch<'a>(&'a self, vm: &'a mut Vm) -> BoxFuture<'a, Result<(), VmError>> {
                Box::pin(async move {
                    if self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst) < 2 {
                        Err(VmError::Launch("flaky".into()))
                    } else {
                        vm.mark_ready();
                        Ok(())
                    }
                })
            }
            fn create(&self) -> Vm {
                Vm::in_dir(&std::env::temp_dir())
            }
        }
        let p = VmPool::new(
            Arc::new(Flaky(std::sync::atomic::AtomicU32::new(0))),
            PoolConfig {
                total_vm_slots: 5,
                warm_pool_target: 0,
            },
        );
        p.warm_pool(2).await;
        assert_eq!(p.warm_count(), 2);
    }

    #[tokio::test]
    async fn acquire_or_create_prefers_warm() {
        let p = pool(false, 2, 0);
        let vm = ready_vm();
        let id = vm.id;
        p.insert_warm(vm);
        assert_eq!(p.acquire_or_create().await.unwrap().vm_id, id);
    }

    #[tokio::test]
    async fn acquire_or_create_boots_on_demand_within_slots() {
        let p = pool(false, 2, 0);
        let a = p.acquire_or_create().await.unwrap();
        let b = p.acquire_or_create().await.unwrap();
        assert_ne!(a.vm_id, b.vm_id);
        assert_eq!(p.active_count(), 2);
        assert_eq!(p.acquire_or_create().await, Err(PoolError::NoSlots(2)));
        p.release(a.vm_id).await;
        assert!(p.acquire_or_create().await.is_ok());
    }

    #[tokio::test]
    async fn acquire_or_create_reports_launch_failure() {
        let p = pool(true, 2, 0);
        assert!(matches!(
            p.acquire_or_create().await,
            Err(PoolError::LaunchFailed(_))
        ));
        assert_eq!(p.total_count(), 0);
        // The failed boot gave its slot back.
        assert_eq!(p.lock().starting, 0);
    }

    #[tokio::test]
    async fn assign_task_marks_vm_running() {
        let p = pool(false, 2, 0);
        p.insert_warm(ready_vm());
        let lease = p.acquire().unwrap();
        let task = TaskId::random();
        p.assign_task(lease.vm_id, task);
        let s = p.lock();
        let vm = &s.active[&lease.vm_id];
        assert_eq!(vm.task_id, Some(task));
        assert_eq!(vm.state, crate::vm::firecracker::VmState::Running);
    }

    #[tokio::test]
    async fn shutdown_stops_everything() {
        let p = pool(false, 4, 0);
        p.warm_pool(2).await;
        let _ = p.acquire().unwrap();
        p.shutdown().await;
        assert_eq!(p.total_count(), 0);
    }

    #[test]
    fn pool_config_from_node_config() {
        let c = PoolConfig::from(&NodeOperatorConfig {
            total_vm_slots: 7,
            warm_pool_target: 3,
            ..NodeOperatorConfig::default()
        });
        assert_eq!(
            c,
            PoolConfig {
                total_vm_slots: 7,
                warm_pool_target: 3
            }
        );
        assert_eq!(
            PoolConfig::default(),
            PoolConfig {
                total_vm_slots: 10,
                warm_pool_target: 5
            }
        );
    }
}
