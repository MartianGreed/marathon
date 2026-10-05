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
use tokio_util::sync::CancellationToken;

use super::firecracker::{CopyJobs, Vm, VmConfig, VmError};
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
    #[error("no available VM: node is shutting down")]
    ShuttingDown,
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
    /// Set by `shutdown`: no new boots, and booted VMs are not kept.
    closing: bool,
}

/// Where a freshly booted VM goes.
enum Into {
    Warm,
    Active,
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
        {
            let mut s = self.pool.lock();
            s.starting = s.starting.saturating_sub(1);
        }
        self.pool.boots_done.notify_waiters();
    }
}

/// The node's VMs.
pub struct VmPool {
    launcher: Arc<dyn VmLauncher>,
    config: PoolConfig,
    state: Mutex<PoolState>,
    /// Woken whenever a booting slot is released.
    boots_done: tokio::sync::Notify,
    /// Cancelled by `shutdown` to abort boots in flight.
    closing_token: CancellationToken,
    /// Rootfs copy jobs of this pool's VMs.
    copy_jobs: Arc<CopyJobs>,
}

impl VmPool {
    pub fn new(launcher: Arc<dyn VmLauncher>, config: PoolConfig) -> Self {
        Self {
            launcher,
            config,
            state: Mutex::new(PoolState::default()),
            boots_done: tokio::sync::Notify::new(),
            closing_token: CancellationToken::new(),
            copy_jobs: Arc::new(CopyJobs::new()),
        }
    }

    /// This pool's rootfs copy jobs.
    pub fn copy_jobs(&self) -> &Arc<CopyJobs> {
        &self.copy_jobs
    }

    /// Keep a booted VM unless the pool is shutting down. A refused VM is
    /// handed back for the caller to stop.
    #[must_use]
    fn keep(&self, vm: Vm, into: Into) -> Option<Vm> {
        let mut s = self.lock();
        if s.closing {
            return Some(vm);
        }
        match into {
            Into::Warm => s.warm.push(vm),
            Into::Active => {
                s.active.insert(vm.id, vm);
            }
        }
        Self::update_gauges(&s);
        None
    }

    pub fn is_closing(&self) -> bool {
        self.lock().closing
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
        if s.closing || s.occupied() >= self.config.total_vm_slots || !admit(&s) {
            return None;
        }
        s.starting += 1;
        Some(StartingSlot { pool: self })
    }

    /// Boot one VM in a reserved slot.
    async fn boot(&self, _slot: &StartingSlot<'_>) -> Result<Vm, VmError> {
        let mut vm = self.launcher.create();
        vm.track_copy_jobs(self.copy_jobs.clone());
        let launched = tokio::select! {
            r = self.launcher.launch(&mut vm) => r,
            () = self.closing_token.cancelled() => {
                Err(VmError::Launch("pool shutting down".into()))
            }
        };
        match launched {
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
                    if let Some(mut vm) = self.keep(vm, Into::Warm) {
                        tracing::info!(parent: op.span(), vm_id = %vm.id, "pool shutting down, stopping freshly booted VM");
                        vm.stop().await;
                        break;
                    }
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
        let Some(vm) = s.warm.pop() else {
            metrics::global().vm_ops.inc("acquire", "empty");
            return None;
        };
        metrics::global().vm_ops.inc("acquire", "warm");
        tracing::debug!(operation = "acquire_vm", vm_id = %vm.id, node_id = %crate::identity::label(), "warm VM acquired");
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
        let Some(slot) = self.reserve(|_| true) else {
            metrics::global().vm_ops.inc("acquire", "no_slots");
            return Err(PoolError::NoSlots(self.config.total_vm_slots));
        };
        tracing::info!(
            operation = "acquire_vm",
            "no warm VMs available, creating on-demand"
        );
        let vm = self.boot(&slot).await.map_err(|e| {
            tracing::error!(operation = "acquire_vm", error = %e, "failed to start on-demand VM");
            metrics::global().vm_ops.inc("acquire", "launch_failed");
            PoolError::LaunchFailed(e.to_string())
        })?;
        metrics::global().vm_ops.inc("acquire", "on_demand");
        let lease = VmLease::of(&vm);
        let kept = self.keep(vm, Into::Active);
        // Drop the booting slot only after the VM is counted as active, so
        // the slot count never dips below the real number of VMs.
        if let Some(mut vm) = kept {
            vm.stop().await;
            drop(slot);
            return Err(PoolError::ShuttingDown);
        }
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
            tracing::debug!(operation = "release_vm", vm_id = %vm_id, "release of unknown VM ignored");
            return;
        };
        tracing::debug!(operation = "release_vm", vm_id = %vm_id, task_id = ?vm.task_id, node_id = %crate::identity::label(), "destroying used VM");
        metrics::global().vm_ops.inc("release", "destroyed");
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
                metrics::global().vm_ops.inc("replenish", "ok");
                if let Some(mut vm) = self.keep(vm, Into::Warm) {
                    vm.stop().await;
                }
            }
            Err(e) => {
                metrics::global().vm_ops.inc("replenish", "failed");
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

    /// Stop every VM. New boots are refused from now on; boots already in
    /// flight are waited for and their VMs stopped instead of kept.
    pub async fn shutdown(&self) {
        let op = common::telemetry::Operation::start("pool_shutdown");
        self.lock().closing = true;
        self.closing_token.cancel();
        loop {
            let done = self.boots_done.notified();
            tokio::pin!(done);
            // Register before checking, so a slot released in between
            // still wakes us.
            done.as_mut().enable();
            let starting = self.lock().starting;
            if starting == 0 {
                break;
            }
            tracing::info!(parent: op.span(), starting, "waiting for VM boots to finish");
            done.await;
        }
        // A cancelled boot may still be cleaning up its rootfs copy; a
        // released slot does not mean that cleanup is done.
        self.copy_jobs.wait_idle().await;
        let vms: Vec<Vm> = {
            let mut s = self.lock();
            let mut vms: Vec<Vm> = std::mem::take(&mut s.warm);
            vms.extend(s.active.drain().map(|(_, vm)| vm));
            Self::update_gauges(&s);
            vms
        };
        let stopped = vms.len();
        for mut vm in vms {
            vm.stop().await;
        }
        tracing::info!(parent: op.span(), stopped, "pool shut down");
        op.finish();
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
    use std::time::Duration;

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

    /// A launcher that blocks every boot until released.
    struct GatedLauncher {
        entered: Arc<tokio::sync::Notify>,
        proceed: Arc<tokio::sync::Notify>,
    }

    impl VmLauncher for GatedLauncher {
        fn launch<'a>(&'a self, vm: &'a mut Vm) -> BoxFuture<'a, Result<(), VmError>> {
            Box::pin(async move {
                self.entered.notify_one();
                self.proceed.notified().await;
                vm.mark_ready();
                Ok(())
            })
        }
        fn create(&self) -> Vm {
            Vm::in_dir(&std::env::temp_dir())
        }
    }

    fn gated(
        slots: u32,
    ) -> (
        Arc<VmPool>,
        Arc<tokio::sync::Notify>,
        Arc<tokio::sync::Notify>,
    ) {
        let entered = Arc::new(tokio::sync::Notify::new());
        let proceed = Arc::new(tokio::sync::Notify::new());
        let pool = Arc::new(VmPool::new(
            Arc::new(GatedLauncher {
                entered: entered.clone(),
                proceed: proceed.clone(),
            }),
            PoolConfig {
                total_vm_slots: slots,
                warm_pool_target: 0,
            },
        ));
        (pool, entered, proceed)
    }

    // A VM still booting holds its slot.
    #[tokio::test]
    async fn booting_vm_counts_toward_slots() {
        let (p, entered, proceed) = gated(1);
        let booting = {
            let p = p.clone();
            tokio::spawn(async move { p.acquire_or_create().await })
        };
        entered.notified().await;
        let second = tokio::time::timeout(Duration::from_secs(1), p.acquire_or_create())
            .await
            .expect("second acquire must not wait for a boot");
        assert_eq!(second, Err(PoolError::NoSlots(1)));
        proceed.notify_one();
        booting.await.unwrap().unwrap();
        assert_eq!(p.active_count(), 1);
    }

    // C-R1-02: shutdown during a warm boot leaves nothing behind.
    #[tokio::test]
    async fn shutdown_during_warm_boot_keeps_nothing() {
        let (p, entered, proceed) = gated(2);
        let warming = {
            let p = p.clone();
            tokio::spawn(async move { p.warm_pool(2).await })
        };
        entered.notified().await;
        tokio::time::timeout(Duration::from_secs(2), p.shutdown())
            .await
            .expect("shutdown hangs on a boot in flight");
        proceed.notify_waiters();
        tokio::time::timeout(Duration::from_secs(2), warming)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(p.total_count(), 0);
        assert_eq!(p.lock().starting, 0);
        // And nothing new boots afterwards.
        p.warm_pool(2).await;
        assert_eq!(p.total_count(), 0);
        assert_eq!(p.acquire_or_create().await, Err(PoolError::NoSlots(2)));
    }

    // C-R1-02: shutdown during an on-demand boot fails the acquire.
    #[tokio::test]
    async fn shutdown_during_on_demand_boot_fails_acquire() {
        let (p, entered, _proceed) = gated(2);
        let acquiring = {
            let p = p.clone();
            tokio::spawn(async move { p.acquire_or_create().await })
        };
        entered.notified().await;
        tokio::time::timeout(Duration::from_secs(2), p.shutdown())
            .await
            .expect("shutdown hangs on a boot in flight");
        let r = acquiring.await.unwrap();
        assert!(matches!(r, Err(PoolError::LaunchFailed(_))), "{r:?}");
        assert_eq!(p.total_count(), 0);
        assert!(p.is_closing());
    }

    // N01: a boot that completes after closing is not kept.
    #[tokio::test]
    async fn closing_pool_refuses_a_completed_boot() {
        let p = pool(false, 4, 0);
        p.lock().closing = true;
        let refused = p.keep(ready_vm(), Into::Warm);
        assert!(refused.is_some(), "a closing pool kept a VM");
        let refused = p.keep(ready_vm(), Into::Active);
        assert!(refused.is_some(), "a closing pool kept a VM");
        assert_eq!(p.total_count(), 0);
    }

    // N04: shutdown does not return while a slot is still reserved.
    #[tokio::test]
    async fn shutdown_waits_for_reserved_slots() {
        let p = Arc::new(pool(false, 4, 0));
        let slot_released = Arc::new(tokio::sync::Notify::new());
        let reserved = Arc::new(tokio::sync::Notify::new());
        let holder = {
            let p = p.clone();
            let slot_released = slot_released.clone();
            let reserved = reserved.clone();
            tokio::spawn(async move {
                let slot = p.reserve(|_| true).expect("slot");
                reserved.notify_one();
                slot_released.notified().await;
                drop(slot);
            })
        };
        reserved.notified().await;
        let shutting = {
            let p = p.clone();
            tokio::spawn(async move { p.shutdown().await })
        };
        tokio::time::sleep(Duration::from_millis(150)).await;
        assert!(
            !shutting.is_finished(),
            "shutdown returned while a slot was reserved"
        );
        slot_released.notify_one();
        tokio::time::timeout(Duration::from_secs(2), shutting)
            .await
            .expect("shutdown did not finish after the slot was released")
            .unwrap();
        holder.await.unwrap();
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
