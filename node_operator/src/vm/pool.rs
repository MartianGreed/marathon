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
use std::ops::Deref;
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

/// A slot reserved for a VM that is booting; released when dropped. `P`
/// is how the slot refers to its pool: borrowed inside the pool, owned
/// (`Arc`) when a task carries it from accept time to boot.
///
/// Only built after `try_start` admitted it, so every live, armed slot
/// owns exactly one unit of `starting`. When its VM is kept, the count is
/// handed over in the same critical section and the slot is disarmed.
struct StartingSlot<P: Deref<Target = VmPool>> {
    pool: P,
    armed: bool,
}

impl<P: Deref<Target = VmPool>> StartingSlot<P> {
    fn admitted(pool: P) -> Self {
        Self { pool, armed: true }
    }
}

impl<P: Deref<Target = VmPool>> Drop for StartingSlot<P> {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        {
            let mut s = self.pool.lock();
            s.starting = s.starting.saturating_sub(1);
        }
        self.pool.boots_done.notify_waiters();
    }
}

/// Capacity a task claimed when it was accepted: a warm VM, or a slot to
/// boot one in. Claiming at accept time means the node's reported
/// occupancy includes the task before its VM exists, so the orchestrator
/// never sees that capacity as free. Dropping a `Claim::Slot` releases the
/// slot; a `Claim::Warm` lease is returned with [`VmPool::release`].
pub enum Claim {
    Warm(VmLease),
    Slot(BootSlot),
}

/// A booting slot owned by a task until its VM is up.
pub struct BootSlot(StartingSlot<Arc<VmPool>>);

/// A booted VM the closing pool would not keep, with the slot it still
/// holds until the VM is stopped.
struct Refused<P: Deref<Target = VmPool>> {
    vm: Vm,
    /// Held only so it drops after `vm`: field order is drop order.
    _slot: StartingSlot<P>,
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

    /// Keep a VM booted in `slot` unless the pool is shutting down. The
    /// VM and the slot's `starting` count swap in one critical section, so
    /// the VM is never counted twice (or not at all).
    ///
    /// A refused VM comes back together with its still-armed slot: the
    /// caller stops the VM and only then drops the slot, so `shutdown`
    /// (which waits for `starting == 0`) cannot return while that VM is
    /// still being torn down. Use [`VmPool::stop_refused`].
    #[must_use]
    fn keep_from_slot<P: Deref<Target = VmPool>>(
        &self,
        vm: Vm,
        into: Into,
        mut slot: StartingSlot<P>,
    ) -> Option<Refused<P>> {
        let mut s = self.lock();
        if s.closing {
            drop(s);
            return Some(Refused { vm, _slot: slot });
        }
        match into {
            Into::Warm => s.warm.push(vm),
            Into::Active => {
                s.active.insert(vm.id, vm);
            }
        }
        s.starting = s.starting.saturating_sub(1);
        slot.armed = false;
        Self::update_gauges(&s);
        drop(s);
        self.boots_done.notify_waiters();
        None
    }

    /// Stop a VM the closing pool refused, then release its slot.
    ///
    /// `refused` stays whole across the await: if this future is dropped
    /// mid-stop (a cancelled task), its fields drop in declaration order,
    /// VM (and its cleanup) before slot. Destructuring into locals would
    /// reverse that, as locals drop last-declared first.
    async fn stop_refused<P: Deref<Target = VmPool>>(mut refused: Refused<P>) {
        tracing::info!(operation = "pool_shutdown", vm_id = %refused.vm.id, "pool shutting down, stopping freshly booted VM");
        refused.vm.stop().await;
        drop(refused);
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

    /// Count a slot as booting if one is free and `admit` accepts the
    /// current state.
    fn try_start(&self, admit: impl FnOnce(&PoolState) -> bool) -> bool {
        let mut s = self.lock();
        if s.closing || s.occupied() >= self.config.total_vm_slots || !admit(&s) {
            return false;
        }
        s.starting += 1;
        true
    }

    /// Reserve a slot for a VM about to boot, if one is free and `admit`
    /// accepts the current state.
    fn reserve(&self, admit: impl FnOnce(&PoolState) -> bool) -> Option<StartingSlot<&VmPool>> {
        // Built only after admission: a refused reservation must not create
        // (and then drop) a guard that would release someone else's slot.
        if self.try_start(admit) {
            Some(StartingSlot::admitted(self))
        } else {
            None
        }
    }

    /// Slots currently booting (warm-pool boots and claimed task slots).
    pub fn starting_count(&self) -> u32 {
        self.lock().starting
    }

    /// Slots not available to a new task: running VMs plus booting ones.
    /// This is what the node reports as `active_vms`.
    pub fn occupied_count(&self) -> u32 {
        let s = self.lock();
        u32::try_from(s.active.len())
            .unwrap_or(u32::MAX)
            .saturating_add(s.starting)
    }

    /// Claim capacity for a task now: a warm VM if there is one, else a
    /// slot to boot one in.
    pub fn claim(self: &Arc<Self>) -> Result<Claim, PoolError> {
        if let Some(lease) = self.acquire() {
            return Ok(Claim::Warm(lease));
        }
        if self.try_start(|_| true) {
            return Ok(Claim::Slot(BootSlot(StartingSlot::admitted(self.clone()))));
        }
        metrics::global().vm_ops.inc("acquire", "no_slots");
        Err(PoolError::NoSlots(self.config.total_vm_slots))
    }

    /// Turn a claim into a running VM, booting one for a slot claim.
    pub async fn start_claimed(&self, claim: Claim) -> Result<VmLease, PoolError> {
        match claim {
            Claim::Warm(lease) => Ok(lease),
            Claim::Slot(BootSlot(slot)) => self.boot_active(slot).await,
        }
    }

    /// Boot a VM in `slot` and keep it as active (leased).
    async fn boot_active<P: Deref<Target = VmPool>>(
        &self,
        slot: StartingSlot<P>,
    ) -> Result<VmLease, PoolError> {
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
        if let Some(refused) = self.keep_from_slot(vm, Into::Active, slot) {
            Self::stop_refused(refused).await;
            return Err(PoolError::ShuttingDown);
        }
        Ok(lease)
    }

    /// Boot one VM in a reserved slot.
    async fn boot<P: Deref<Target = VmPool>>(
        &self,
        _slot: &StartingSlot<P>,
    ) -> Result<Vm, VmError> {
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
                    if let Some(refused) = self.keep_from_slot(vm, Into::Warm, slot) {
                        Self::stop_refused(refused).await;
                        break;
                    }
                }
                Err(e) => {
                    drop(slot);
                    failures += 1;
                    tracing::error!(parent: op.span(), error = %e, failures, "failed to start warm VM");
                    if failures >= MAX_CONSECUTIVE_FAILURES {
                        tracing::error!(parent: op.span(), failures, "warm pool: consecutive failures, aborting");
                        break;
                    }
                }
            }
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
        self.boot_active(slot).await
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
                if let Some(refused) = self.keep_from_slot(vm, Into::Warm, slot) {
                    Self::stop_refused(refused).await;
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
        let warm_slot = p.reserve(|_| true).unwrap();
        let active_slot = p.reserve(|_| true).unwrap();
        p.lock().closing = true;
        let warm = p.keep_from_slot(ready_vm(), Into::Warm, warm_slot);
        let active = p.keep_from_slot(ready_vm(), Into::Active, active_slot);
        let (Some(warm), Some(active)) = (warm, active) else {
            panic!("a closing pool kept a VM");
        };
        assert_eq!(p.total_count(), 0);
        assert_eq!(
            p.starting_count(),
            2,
            "refused VMs keep their slots until stopped"
        );
        VmPool::stop_refused(warm).await;
        VmPool::stop_refused(active).await;
        assert_eq!(
            p.starting_count(),
            0,
            "stopping a refused VM releases its slot"
        );
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

    #[tokio::test]
    async fn claim_prefers_warm_then_slot_then_fails() {
        let p = Arc::new(pool(false, 2, 0));
        let vm = ready_vm();
        let warm_id = vm.id;
        p.insert_warm(vm);
        let Ok(Claim::Warm(lease)) = p.claim() else {
            panic!("expected the warm VM");
        };
        assert_eq!(lease.vm_id, warm_id);
        assert_eq!(p.occupied_count(), 1);
        let Ok(Claim::Slot(slot)) = p.claim() else {
            panic!("expected a booting slot");
        };
        assert_eq!(p.starting_count(), 1);
        assert_eq!(p.occupied_count(), 2);
        assert!(matches!(p.claim(), Err(PoolError::NoSlots(2))));
        drop(slot);
        assert_eq!(p.starting_count(), 0);
        assert_eq!(p.occupied_count(), 1);
    }

    #[tokio::test]
    async fn start_claimed_boots_a_slot_into_an_active_vm() {
        let p = Arc::new(pool(false, 1, 0));
        let claim = p.claim().unwrap();
        assert!(matches!(claim, Claim::Slot(_)));
        let lease = p.start_claimed(claim).await.unwrap();
        assert_eq!(p.active_count(), 1);
        assert_eq!(p.starting_count(), 0);
        assert_eq!(p.occupied_count(), 1);
        p.release(lease.vm_id).await;
        assert_eq!(p.occupied_count(), 0);
    }

    #[tokio::test]
    async fn failed_claimed_boot_frees_its_slot() {
        let p = Arc::new(pool(true, 1, 0));
        let claim = p.claim().unwrap();
        assert!(matches!(
            p.start_claimed(claim).await,
            Err(PoolError::LaunchFailed(_))
        ));
        assert_eq!(p.occupied_count(), 0);
        assert!(p.claim().is_ok());
    }

    // C-R9-01: a refused warm reservation must not release a claimed slot.
    #[tokio::test]
    async fn refused_reservation_keeps_another_claim() {
        let p = Arc::new(pool(false, 1, 0));
        let held = p.claim().unwrap();
        assert!(matches!(held, Claim::Slot(_)));
        assert_eq!(p.starting_count(), 1);
        p.warm_pool(1).await; // refused: no free slot
        assert_eq!(
            p.starting_count(),
            1,
            "a refused reservation released the claim"
        );
        assert!(matches!(p.claim(), Err(PoolError::NoSlots(1))));
        drop(held);
        assert_eq!(p.starting_count(), 0);
    }

    // C-R9-01, via release: refused replenishment keeps the other claim.
    #[tokio::test]
    async fn release_without_replenishment_keeps_another_claim() {
        let p = Arc::new(pool(false, 2, 0));
        p.insert_warm(ready_vm());
        let Ok(Claim::Warm(lease)) = p.claim() else {
            panic!("expected the warm VM");
        };
        let held = p.claim().unwrap();
        assert!(matches!(held, Claim::Slot(_)));
        p.release(lease.vm_id).await; // target 0: replenishment refused
        assert_eq!(
            p.starting_count(),
            1,
            "refused replenishment released the claim"
        );
        drop(held);
        assert_eq!(p.starting_count(), 0);
    }

    /// Boots a VM with a real child process and, as the boot completes,
    /// starts the pool's shutdown, so the pool refuses the VM it just booted.
    struct ClosingOnLaunch {
        pool: std::sync::OnceLock<std::sync::Weak<VmPool>>,
        socket: Mutex<Option<PathBuf>>,
    }

    impl VmLauncher for ClosingOnLaunch {
        fn launch<'a>(&'a self, vm: &'a mut Vm) -> BoxFuture<'a, Result<(), VmError>> {
            Box::pin(async move {
                // `Vm::stop` removes this file: it marks cleanup done.
                std::fs::write(&vm.socket_path, "").unwrap();
                *self.socket.lock().unwrap() = Some(vm.socket_path.clone());
                let child = tokio::process::Command::new("sleep")
                    .arg("30")
                    .kill_on_drop(true)
                    .spawn()
                    .unwrap();
                vm.attach_process(child);
                vm.mark_ready();
                if let Some(pool) = self.pool.get().and_then(std::sync::Weak::upgrade) {
                    pool.lock().closing = true;
                }
                Ok(())
            })
        }

        fn create(&self) -> Vm {
            Vm::in_dir(&std::env::temp_dir())
        }
    }

    fn closing_pool(
        total_vm_slots: u32,
        warm_pool_target: u32,
    ) -> (Arc<VmPool>, Arc<ClosingOnLaunch>) {
        let launcher = Arc::new(ClosingOnLaunch {
            pool: std::sync::OnceLock::new(),
            socket: Mutex::new(None),
        });
        let p = Arc::new(VmPool::new(
            launcher.clone(),
            PoolConfig {
                total_vm_slots,
                warm_pool_target,
            },
        ));
        launcher.pool.set(Arc::downgrade(&p)).unwrap();
        (p, launcher)
    }

    fn refused_socket(launcher: &ClosingOnLaunch) -> PathBuf {
        launcher.socket.lock().unwrap().clone().unwrap()
    }

    /// The pool path under test, driven until its refused VM is stopping.
    #[derive(Clone, Copy, Debug)]
    enum RefusedPath {
        OnDemand,
        WarmPool,
        Replenish,
    }

    /// A pool, and the future that boots (and has refused) a VM through
    /// `path`. Polling it once reaches the refused VM's stop.
    fn refused_boot(
        path: RefusedPath,
    ) -> (Arc<VmPool>, Arc<ClosingOnLaunch>, BoxFuture<'static, ()>) {
        match path {
            RefusedPath::OnDemand => {
                let (p, l) = closing_pool(1, 0);
                let claim = p.claim().unwrap();
                let q = p.clone();
                let fut = Box::pin(async move {
                    assert!(matches!(
                        q.start_claimed(claim).await,
                        Err(PoolError::ShuttingDown)
                    ));
                });
                (p, l, fut)
            }
            RefusedPath::WarmPool => {
                let (p, l) = closing_pool(1, 0);
                let q = p.clone();
                (p, l, Box::pin(async move { q.warm_pool(1).await }))
            }
            RefusedPath::Replenish => {
                let (p, l) = closing_pool(1, 1);
                p.insert_warm(ready_vm());
                let lease = p.acquire().unwrap();
                let q = p.clone();
                (p, l, Box::pin(async move { q.release(lease.vm_id).await }))
            }
        }
    }

    // C-R10-01 / C-R11-03: on every path, shutdown cannot return while a VM
    // the closing pool refused is still being stopped.
    #[tokio::test]
    async fn shutdown_waits_for_a_refused_vm_to_stop() {
        for path in [
            RefusedPath::OnDemand,
            RefusedPath::WarmPool,
            RefusedPath::Replenish,
        ] {
            let mut windows = 0;
            for _ in 0..20 {
                let (p, launcher, mut boot) = refused_boot(path);
                // One poll boots the VM and reaches the refused VM's stop,
                // which usually waits for the killed child to be reaped.
                if futures::poll!(boot.as_mut()).is_pending() {
                    assert!(
                        refused_socket(&launcher).exists(),
                        "{path:?}: refused VM already cleaned up"
                    );
                    windows += 1;
                    let early =
                        tokio::time::timeout(Duration::from_millis(100), p.shutdown()).await;
                    assert!(
                        early.is_err(),
                        "{path:?}: shutdown returned while the refused VM was still stopping"
                    );
                    boot.await;
                }
                // Ready on the first poll: the stop finished at once, and the
                // completed future is not polled again.
                tokio::time::timeout(Duration::from_secs(2), p.shutdown())
                    .await
                    .expect("shutdown hangs after the refused VM stopped");
                assert!(
                    !refused_socket(&launcher).exists(),
                    "{path:?}: refused VM was not cleaned up"
                );
                assert_eq!(p.starting_count(), 0);
            }
            assert!(
                windows > 0,
                "{path:?}: the stop never yielded; the test proved nothing"
            );
        }
    }

    // C-R11-01: cancelling the task while its refused VM stops must clean
    // the VM up before its slot is released. A shutdown on another worker
    // checks the VM's cleanup marker the moment it returns.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn cancelled_refused_stop_cleans_up_before_releasing_its_slot() {
        let mut windows = 0;
        for _ in 0..200 {
            let (p, launcher, mut boot) = refused_boot(RefusedPath::OnDemand);
            if futures::poll!(boot.as_mut()).is_ready() {
                continue;
            }
            windows += 1;
            let socket = refused_socket(&launcher);
            let shutting = {
                let p = p.clone();
                tokio::spawn(async move {
                    p.shutdown().await;
                    socket.exists()
                })
            };
            // Let the shutdown register its wait, then cancel the boot.
            tokio::time::sleep(Duration::from_millis(1)).await;
            drop(boot);
            let marker_left = tokio::time::timeout(Duration::from_secs(2), shutting)
                .await
                .expect("shutdown hangs after the cancelled stop")
                .unwrap();
            assert!(
                !marker_left,
                "shutdown returned before the cancelled refused VM was cleaned up"
            );
        }
        assert!(
            windows > 0,
            "the stop never yielded; the test proved nothing"
        );
    }

    // C-R9-02: the handoff from booting to kept is atomic.
    #[test]
    fn keep_from_slot_hands_the_count_over() {
        let p = pool(false, 2, 0);
        let slot = p.reserve(|_| true).unwrap();
        // Another boot is outstanding: the handoff must consume exactly
        // one count, never this one too.
        let other = p.reserve(|_| true).unwrap();
        assert_eq!(p.occupied_count(), 2);
        assert!(p.keep_from_slot(ready_vm(), Into::Active, slot).is_none());
        {
            let s = p.lock();
            assert_eq!(
                (s.active.len(), s.starting),
                (1, 1),
                "the handoff released another slot"
            );
        }
        drop(other);
        assert_eq!(p.starting_count(), 0);
        assert_eq!(p.occupied_count(), 1);
    }

    // C-R9-02: an observer never sees more occupied slots than exist.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn occupied_never_exceeds_total_slots() {
        let p = Arc::new(pool(false, 1, 0));
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let observer = {
            let (p, stop) = (p.clone(), stop.clone());
            std::thread::spawn(move || {
                let mut peak = 0;
                while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                    peak = peak.max(p.occupied_count());
                }
                peak
            })
        };
        for _ in 0..20_000 {
            let claim = p.claim().unwrap();
            let lease = p.start_claimed(claim).await.unwrap();
            p.release(lease.vm_id).await;
        }
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        let peak = observer.join().unwrap();
        assert!(peak <= 1, "observed {peak} occupied slots with 1 slot");
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
