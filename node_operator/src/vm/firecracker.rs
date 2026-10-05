//! One Firecracker microVM: process lifecycle, boot through the API socket,
//! per-VM rootfs copy, TAP networking and the VM state machine.

use std::os::unix::fs::FileTypeExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use common::config::NodeOperatorConfig;
use common::{TaskId, VmId};
use tokio::io::AsyncReadExt;
use tokio::process::{Child, Command};

use super::{api, network};
use crate::metrics;
use crate::snapshot::SnapshotManager;

/// VM lifecycle state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VmState {
    Creating,
    Ready,
    Running,
    Stopping,
    Stopped,
    Failed,
}

/// Snapshot restore is disabled: a restored VM cannot get its own network
/// interface, so every VM cold boots (the Zig code hard-wired the same
/// choice). The restore path is kept for when that changes.
pub const SNAPSHOT_RESTORE_ENABLED: bool = false;

/// Where a base snapshot's vsock socket reappears after restore.
pub const SNAPSHOT_VSOCK_PATH: &str = "/run/marathon/snapshot-base-vsock.sock";

/// How long to wait for Firecracker's API socket after spawning it.
pub const API_SOCKET_TIMEOUT: Duration = Duration::from_millis(5000);
const API_SOCKET_POLL: Duration = Duration::from_millis(50);

/// Keep at most this much of Firecracker's stderr for error reports.
const STDERR_TAIL_LEN: usize = 4096;

/// Polling schedule for the vsock socket to appear.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReadyWait {
    pub attempts: u32,
    pub interval: Duration,
}

impl ReadyWait {
    /// After a cold boot: 30 checks, 500 ms apart.
    pub const COLD_BOOT: Self = Self {
        attempts: 30,
        interval: Duration::from_millis(500),
    };
    /// After a snapshot restore: 10 checks, 500 ms apart.
    pub const RESTORE: Self = Self {
        attempts: 10,
        interval: Duration::from_millis(500),
    };
}

/// What a VM boots with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VmConfig {
    pub firecracker_bin: String,
    pub kernel_path: String,
    pub rootfs_path: String,
    pub snapshot_path: String,
    pub vcpu_count: u32,
    pub mem_size_mib: u32,
    pub vsock_port: u32,
}

impl Default for VmConfig {
    fn default() -> Self {
        Self {
            firecracker_bin: "/usr/bin/firecracker".into(),
            kernel_path: "/tmp/marathon/kernel/vmlinux".into(),
            rootfs_path: "/tmp/marathon/rootfs/rootfs.ext4".into(),
            snapshot_path: "/tmp/marathon/snapshots/base".into(),
            vcpu_count: 2,
            mem_size_mib: 512,
            vsock_port: common::vsock::DEFAULT_PORT,
        }
    }
}

impl From<&NodeOperatorConfig> for VmConfig {
    fn from(c: &NodeOperatorConfig) -> Self {
        Self {
            firecracker_bin: c.firecracker_bin.clone(),
            kernel_path: c.kernel_path.clone(),
            rootfs_path: c.rootfs_path.clone(),
            snapshot_path: c.snapshot_path.clone(),
            vsock_port: c.vsock_port,
            ..Self::default()
        }
    }
}

/// Starting a VM failed.
#[derive(Debug, thiserror::Error)]
pub enum VmError {
    #[error("Firecracker binary not found at {0}")]
    FirecrackerNotFound(String),
    #[error("kernel image not found at {0}")]
    KernelNotFound(String),
    #[error("rootfs not found at {0}")]
    RootfsNotFound(String),
    #[error("failed to copy rootfs to {dest}: {source}")]
    RootfsCopyFailed {
        dest: String,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to spawn Firecracker: {0}")]
    Spawn(#[source] std::io::Error),
    #[error("Firecracker API socket did not appear")]
    FirecrackerStartFailed,
    #[error(transparent)]
    Api(#[from] api::ApiError),
    #[error("vsock socket not ready")]
    VsockNotReady,
    #[error("VM launch failed: {0}")]
    Launch(String),
}

/// The socket wait timed out.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("timed out waiting for socket")]
pub struct SocketTimeout;

/// One microVM.
pub struct Vm {
    pub id: VmId,
    pub state: VmState,
    process: Option<Child>,
    stderr_tail: Arc<Mutex<Vec<u8>>>,
    /// Firecracker API socket.
    pub socket_path: PathBuf,
    /// Host side of the guest's vsock.
    pub vsock_uds_path: PathBuf,
    pub vsock_cid: u32,
    pub task_id: Option<TaskId>,
    start_time: Option<Instant>,
    pub tap_name: Option<String>,
    pub vm_index: u32,
    pub rootfs_copy_path: Option<PathBuf>,
}

impl std::fmt::Debug for Vm {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Vm")
            .field("id", &self.id)
            .field("state", &self.state)
            .field("pid", &self.process.as_ref().and_then(Child::id))
            .field("socket_path", &self.socket_path)
            .field("vsock_uds_path", &self.vsock_uds_path)
            .field("vsock_cid", &self.vsock_cid)
            .field("task_id", &self.task_id)
            .field("tap_name", &self.tap_name)
            .field("vm_index", &self.vm_index)
            .finish()
    }
}

static VM_INDEX: AtomicU32 = AtomicU32::new(0);

fn next_vm_index() -> u32 {
    VM_INDEX.fetch_add(1, Ordering::SeqCst)
}

/// A random guest CID in `[3, 0xFFFF_FFFE]` (0–2 are reserved).
pub fn generate_cid() -> u32 {
    let r: u32 = rand::random();
    (r % 0xFFFF_FFFC) + 3
}

/// The first writable directory of `/run/marathon`, `/var/run/marathon`,
/// `/tmp/marathon`, else `/tmp`. Chosen once per process.
pub fn socket_dir() -> &'static Path {
    static DIR: OnceLock<PathBuf> = OnceLock::new();
    DIR.get_or_init(|| {
        for dir in ["/run/marathon", "/var/run/marathon", "/tmp/marathon"] {
            if std::fs::create_dir_all(dir).is_err() {
                continue;
            }
            let probe = Path::new(dir).join(".test");
            if std::fs::File::create(&probe).is_ok() {
                let _ = std::fs::remove_file(&probe);
                tracing::info!(operation = "socket_dir", dir, "using socket directory");
                return PathBuf::from(dir);
            }
        }
        tracing::warn!(
            operation = "socket_dir",
            dir = "/tmp",
            "using fallback socket directory"
        );
        PathBuf::from("/tmp")
    })
}

impl Default for Vm {
    fn default() -> Self {
        Self::new()
    }
}

impl Vm {
    /// A new VM with sockets in [`socket_dir`].
    pub fn new() -> Self {
        Self::in_dir(socket_dir())
    }

    /// A new VM with its sockets in `dir`.
    pub fn in_dir(dir: &Path) -> Self {
        let id = VmId::random();
        Self {
            socket_path: dir.join(format!("firecracker-{id}.sock")),
            vsock_uds_path: dir.join(format!("firecracker-{id}-vsock.sock")),
            id,
            state: VmState::Creating,
            process: None,
            stderr_tail: Arc::new(Mutex::new(Vec::new())),
            vsock_cid: generate_cid(),
            task_id: None,
            start_time: None,
            tap_name: None,
            vm_index: next_vm_index(),
            rootfs_copy_path: None,
        }
    }

    pub fn has_process(&self) -> bool {
        self.process.is_some()
    }

    /// Take ownership of an already spawned process as this VM's
    /// Firecracker.
    pub fn attach_process(&mut self, child: Child) {
        self.process = Some(child);
    }

    /// Per-VM copy of the base rootfs at `<base>.<vm id>`, reflinked when
    /// the filesystem supports it.
    async fn copy_rootfs(&mut self, base: &str) -> Result<PathBuf, VmError> {
        let dest = PathBuf::from(format!("{base}.{}", self.id));
        let reflinked = Command::new("cp")
            .arg("--reflink=auto")
            .arg(base)
            .arg(&dest)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .is_ok_and(|s| s.success());
        if !reflinked {
            tokio::fs::copy(base, &dest).await.map_err(|source| {
                tracing::error!(operation = "copy_rootfs", vm_id = %self.id, dest = %dest.display(), error = %source, "failed to copy rootfs");
                VmError::RootfsCopyFailed {
                    dest: dest.display().to_string(),
                    source,
                }
            })?;
        }
        tracing::info!(operation = "copy_rootfs", vm_id = %self.id, dest = %dest.display(), reflinked, "created per-VM rootfs copy");
        self.rootfs_copy_path = Some(dest.clone());
        Ok(dest)
    }

    fn check_artifacts(config: &VmConfig) -> Result<(), VmError> {
        if !Path::new(&config.firecracker_bin).exists() {
            return Err(VmError::FirecrackerNotFound(config.firecracker_bin.clone()));
        }
        if !Path::new(&config.kernel_path).exists() {
            return Err(VmError::KernelNotFound(config.kernel_path.clone()));
        }
        if !Path::new(&config.rootfs_path).exists() {
            return Err(VmError::RootfsNotFound(config.rootfs_path.clone()));
        }
        Ok(())
    }

    fn spawn_firecracker(&mut self, bin: &str) -> Result<(), VmError> {
        let mut child = Command::new(bin)
            .arg("--api-sock")
            .arg(&self.socket_path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(VmError::Spawn)?;
        // Drain stderr so Firecracker never blocks on a full pipe; keep the
        // tail for error reports.
        if let Some(mut stderr) = child.stderr.take() {
            let tail = self.stderr_tail.clone();
            let vm_id = self.id;
            tokio::spawn(async move {
                let mut buf = [0u8; 1024];
                loop {
                    match stderr.read(&mut buf).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            tracing::debug!(vm_id = %vm_id, stderr = %String::from_utf8_lossy(&buf[..n]).trim_end(), "firecracker stderr");
                            let mut t = tail
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner);
                            t.extend_from_slice(&buf[..n]);
                            let excess = t.len().saturating_sub(STDERR_TAIL_LEN);
                            t.drain(..excess);
                        }
                    }
                }
            });
        }
        tracing::debug!(operation = "spawn_firecracker", vm_id = %self.id, pid = child.id(), "Firecracker spawned");
        self.process = Some(child);
        Ok(())
    }

    /// Log Firecracker's stderr tail and exit status after a failed start.
    async fn log_firecracker_error(&mut self) {
        // Give the stderr reader a moment to catch up.
        tokio::time::sleep(Duration::from_millis(50)).await;
        let tail = String::from_utf8_lossy(
            &self
                .stderr_tail
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        )
        .into_owned();
        if !tail.is_empty() {
            tracing::error!(vm_id = %self.id, stderr = %tail.trim_end(), "Firecracker stderr");
        }
        if let Some(child) = self.process.as_mut()
            && let Ok(Some(status)) = child.try_wait()
            && !status.success()
        {
            tracing::error!(vm_id = %self.id, status = %status, "Firecracker exited");
        }
    }

    /// Wait for Firecracker's API socket, giving up early if Firecracker
    /// has already exited.
    async fn wait_for_api_socket(&mut self) -> Result<(), SocketTimeout> {
        let deadline = Instant::now() + API_SOCKET_TIMEOUT;
        while Instant::now() < deadline {
            if is_socket(&self.socket_path) {
                return Ok(());
            }
            if let Some(child) = self.process.as_mut()
                && matches!(child.try_wait(), Ok(Some(_)))
            {
                return Err(SocketTimeout);
            }
            tokio::time::sleep(API_SOCKET_POLL).await;
        }
        Err(SocketTimeout)
    }

    async fn kill_process(&mut self) {
        if let Some(mut child) = self.process.take() {
            let _ = child.start_kill();
            let _ = tokio::time::timeout(Duration::from_secs(5), child.wait()).await;
        }
    }

    /// Cold boot: copy the rootfs, spawn Firecracker, configure it through
    /// its API and wait for the guest's vsock socket.
    pub async fn start(&mut self, config: &VmConfig) -> Result<(), VmError> {
        let op = common::telemetry::Operation::start("vm_start");
        tracing::info!(parent: op.span(), vm_id = %self.id, vm_index = self.vm_index, "starting VM (cold start)");
        let m = metrics::global();
        match self.start_inner(config).await {
            Ok(()) => {
                self.state = VmState::Ready;
                self.start_time = Some(Instant::now());
                tracing::info!(parent: op.span(), vm_id = %self.id, cid = self.vsock_cid, "VM started");
                m.vm_boots.inc();
                m.vm_boot_ms.observe_ms(op.finish());
                Ok(())
            }
            Err(e) => {
                self.kill_process().await;
                self.state = VmState::Failed;
                m.vm_boot_failures.inc();
                op.fail(&e);
                Err(e)
            }
        }
    }

    async fn start_inner(&mut self, config: &VmConfig) -> Result<(), VmError> {
        Self::check_artifacts(config).inspect_err(
            |e| tracing::error!(vm_id = %self.id, error = %e, "VM artifacts missing"),
        )?;
        let rootfs = self.copy_rootfs(&config.rootfs_path).await?;
        let _ = std::fs::remove_file(&self.socket_path);
        let _ = std::fs::remove_file(&self.vsock_uds_path);
        self.spawn_firecracker(&config.firecracker_bin)?;
        if self.wait_for_api_socket().await.is_err() {
            tracing::error!(vm_id = %self.id, socket = %self.socket_path.display(), "Firecracker API socket not ready");
            self.log_firecracker_error().await;
            return Err(VmError::FirecrackerStartFailed);
        }
        self.tap_name = match network::create_tap(self.vm_index).await {
            Ok(tap) => Some(tap),
            Err(e) => {
                tracing::warn!(vm_id = %self.id, error = %e, "failed to create TAP device, VM will have no network");
                None
            }
        };
        let tap = self.tap_name.clone();
        self.configure(config, &rootfs.display().to_string(), tap.as_deref())
            .await?;
        wait_for_vsock_ready(&self.vsock_uds_path, ReadyWait::COLD_BOOT)
            .await
            .map_err(|_| {
                tracing::error!(vm_id = %self.id, path = %self.vsock_uds_path.display(), "vsock not ready after VM start");
                VmError::VsockNotReady
            })
    }

    /// The cold-boot API sequence, in the Zig order: boot source, rootfs
    /// drive, vsock, network interface (when there is a TAP device),
    /// machine config, instance start.
    pub async fn configure(
        &self,
        config: &VmConfig,
        rootfs: &str,
        tap: Option<&str>,
    ) -> Result<(), VmError> {
        let sock = &self.socket_path;
        api::call(
            sock,
            "PUT",
            "/boot-source",
            &api::boot_source_body(&config.kernel_path, self.vm_index),
        )
        .await?;
        api::call(
            sock,
            "PUT",
            "/drives/rootfs",
            &api::rootfs_drive_body(rootfs),
        )
        .await?;
        api::call(
            sock,
            "PUT",
            "/vsock",
            &api::vsock_body(self.vsock_cid, &self.vsock_uds_path.display().to_string()),
        )
        .await?;
        if let Some(tap) = tap {
            let mac = network::mac_address(self.vm_index);
            api::call(
                sock,
                "PUT",
                "/network-interfaces/eth0",
                &api::network_interface_body(&mac, tap),
            )
            .await?;
        }
        api::call(
            sock,
            "PUT",
            "/machine-config",
            &api::machine_config_body(config.vcpu_count, config.mem_size_mib),
        )
        .await?;
        api::call(sock, "PUT", "/actions", api::INSTANCE_START_BODY).await?;
        Ok(())
    }

    /// Start from the base snapshot when restore is enabled, else cold boot.
    pub async fn start_from_snapshot(
        &mut self,
        snapshots: &SnapshotManager,
        config: &VmConfig,
    ) -> Result<(), VmError> {
        if !SNAPSHOT_RESTORE_ENABLED {
            return self.start(config).await;
        }
        self.restore_from_snapshot(snapshots, config).await
    }

    /// Restore the `base` snapshot, falling back to a cold boot when there
    /// is none, its vsock directory is not writable, or the load fails.
    pub async fn restore_from_snapshot(
        &mut self,
        snapshots: &SnapshotManager,
        config: &VmConfig,
    ) -> Result<(), VmError> {
        let Some(base) = snapshots.get_default_snapshot() else {
            tracing::warn!(vm_id = %self.id, "no base snapshot available, falling back to cold start");
            return self.start(config).await;
        };
        let snapshot_vsock = Path::new(SNAPSHOT_VSOCK_PATH);
        let vsock_dir = snapshot_vsock
            .parent()
            .unwrap_or(Path::new("/run/marathon"));
        let probe = vsock_dir.join(".writable_test");
        if std::fs::File::create(&probe).is_err() {
            tracing::warn!(vm_id = %self.id, dir = %vsock_dir.display(), "snapshot vsock dir not writable, skipping restore");
            return self.start(config).await;
        }
        let _ = std::fs::remove_file(&probe);

        let op = common::telemetry::Operation::start("vm_restore");
        tracing::info!(parent: op.span(), vm_id = %self.id, snapshot = %base.path.display(), "starting VM from snapshot");
        let _ = std::fs::remove_file(&self.socket_path);
        let _ = std::fs::remove_file(&self.vsock_uds_path);
        let _ = std::fs::remove_file(snapshot_vsock);
        if let Err(e) = self.spawn_firecracker(&config.firecracker_bin) {
            op.fail(&e);
            return Err(e);
        }
        if self.wait_for_api_socket().await.is_err() {
            self.log_firecracker_error().await;
            self.kill_process().await;
            self.state = VmState::Failed;
            op.fail(&VmError::FirecrackerStartFailed);
            return Err(VmError::FirecrackerStartFailed);
        }
        if let Err(e) = self.load_snapshot(&base.path.display().to_string()).await {
            tracing::warn!(vm_id = %self.id, error = %e, "snapshot load failed, falling back to cold start");
            self.kill_process().await;
            let _ = std::fs::remove_file(&self.socket_path);
            let _ = std::fs::remove_file(snapshot_vsock);
            op.fail(&e);
            return self.start(config).await;
        }
        if let Err(e) = std::fs::rename(snapshot_vsock, &self.vsock_uds_path) {
            tracing::error!(vm_id = %self.id, from = SNAPSHOT_VSOCK_PATH, to = %self.vsock_uds_path.display(), error = %e, "failed to rename vsock socket");
            self.kill_process().await;
            self.state = VmState::Failed;
            op.fail(&e);
            return Err(VmError::VsockNotReady);
        }
        if wait_for_vsock_ready(&self.vsock_uds_path, ReadyWait::RESTORE)
            .await
            .is_err()
        {
            self.kill_process().await;
            self.state = VmState::Failed;
            op.fail(&VmError::VsockNotReady);
            return Err(VmError::VsockNotReady);
        }
        self.state = VmState::Ready;
        self.start_time = Some(Instant::now());
        tracing::info!(parent: op.span(), vm_id = %self.id, "VM restored from snapshot");
        op.finish();
        Ok(())
    }

    /// `PUT /snapshot/load` for the snapshot directory `dir`.
    pub async fn load_snapshot(&self, dir: &str) -> Result<(), VmError> {
        api::call(
            &self.socket_path,
            "PUT",
            "/snapshot/load",
            &api::snapshot_load_body(dir),
        )
        .await?;
        Ok(())
    }

    /// Kill Firecracker, remove the sockets and the TAP device.
    pub async fn stop(&mut self) {
        if self.state != VmState::Stopped {
            self.state = VmState::Stopping;
        }
        self.kill_process().await;
        let _ = std::fs::remove_file(&self.socket_path);
        let _ = std::fs::remove_file(&self.vsock_uds_path);
        if let Some(tap) = self.tap_name.take() {
            network::destroy_tap(&tap);
        }
        self.state = VmState::Stopped;
        tracing::debug!(operation = "vm_stop", vm_id = %self.id, "VM stopped");
    }

    pub fn assign_task(&mut self, task_id: TaskId) {
        self.task_id = Some(task_id);
        self.state = VmState::Running;
    }

    pub fn release_task(&mut self) {
        self.task_id = None;
        self.state = VmState::Ready;
    }

    /// Milliseconds since the VM became ready.
    pub fn uptime_ms(&self) -> Option<i64> {
        self.start_time
            .map(|t| i64::try_from(t.elapsed().as_millis()).unwrap_or(i64::MAX))
    }

    /// Mark the VM ready without booting it (tests and custom launchers).
    pub fn mark_ready(&mut self) {
        self.state = VmState::Ready;
        self.start_time = Some(Instant::now());
    }
}

impl Drop for Vm {
    fn drop(&mut self) {
        if let Some(child) = self.process.as_mut() {
            let _ = child.start_kill();
        }
        let _ = std::fs::remove_file(&self.socket_path);
        let _ = std::fs::remove_file(&self.vsock_uds_path);
        if let Some(tap) = self.tap_name.take() {
            network::destroy_tap(&tap);
        }
        if let Some(path) = self.rootfs_copy_path.take()
            && let Err(e) = std::fs::remove_file(&path)
            && e.kind() != std::io::ErrorKind::NotFound
        {
            tracing::warn!(vm_id = %self.id, path = %path.display(), error = %e, "failed to delete VM rootfs copy");
        }
    }
}

fn is_socket(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|m| m.file_type().is_socket())
}

/// Wait until `path` is a Unix socket, polling every 50 ms.
pub async fn wait_for_socket(path: &Path, timeout: Duration) -> Result<(), SocketTimeout> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if is_socket(path) {
            return Ok(());
        }
        tokio::time::sleep(API_SOCKET_POLL).await;
    }
    Err(SocketTimeout)
}

/// Wait for the guest's vsock Unix socket to exist.
///
/// This only checks the file (#37). It must not connect or send `CONNECT`:
/// a probe connection reaches the agent of a snapshot-restored VM and
/// breaks it. Whether the agent listens is found out by the task runner's
/// own handshake, which retries.
pub async fn wait_for_vsock_ready(path: &Path, wait: ReadyWait) -> Result<(), SocketTimeout> {
    for _ in 0..wait.attempts {
        if is_socket(path) {
            tracing::debug!(path = %path.display(), "vsock socket ready");
            return Ok(());
        }
        tokio::time::sleep(wait.interval).await;
    }
    Err(SocketTimeout)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vm::api::fake::FakeApi;
    use std::sync::atomic::AtomicUsize;

    /// A temp dir under `/tmp`: VM socket names are long, and macOS temp
    /// dirs would push them past the 104-byte Unix socket path limit.
    fn short_dir() -> tempfile::TempDir {
        tempfile::Builder::new()
            .prefix("mno")
            .tempdir_in("/tmp")
            .unwrap()
    }

    // Port of Zig `test "vm state transitions"`.
    #[test]
    fn vm_state_transitions() {
        assert_eq!(VmState::Creating, VmState::Creating);
        assert_ne!(VmState::Creating, VmState::Ready);
    }

    // Port of Zig `test "cid generation"`.
    #[test]
    fn cid_generation() {
        for _ in 0..1000 {
            let cid = generate_cid();
            assert!(cid >= 3);
            assert!(cid < 0xFFFF_FFFF);
        }
    }

    // Port of Zig `test "vm init creates valid state"`.
    #[test]
    fn vm_init_creates_valid_state() {
        let vm = Vm::new();
        assert_eq!(vm.state, VmState::Creating);
        assert!(vm.task_id.is_none());
        assert!(!vm.has_process());
        assert!(vm.uptime_ms().is_none());
        assert!(vm.vsock_cid >= 3);
        let id = vm.id.to_hex();
        assert!(vm.socket_path.ends_with(format!("firecracker-{id}.sock")));
        assert!(
            vm.vsock_uds_path
                .ends_with(format!("firecracker-{id}-vsock.sock"))
        );
        assert_eq!(vm.socket_path.parent(), Some(socket_dir()));
    }

    #[test]
    fn vm_indexes_are_unique() {
        let a = Vm::in_dir(Path::new("/tmp"));
        let b = Vm::in_dir(Path::new("/tmp"));
        assert_ne!(a.vm_index, b.vm_index);
        assert_ne!(a.id, b.id);
    }

    // Port of Zig `test "vm stop transitions to stopped"`.
    #[tokio::test]
    async fn vm_stop_transitions_to_stopped() {
        let dir = short_dir();
        let mut vm = Vm::in_dir(dir.path());
        vm.mark_ready();
        vm.stop().await;
        assert_eq!(vm.state, VmState::Stopped);
    }

    // Port of Zig `test "vm assign and release task"`.
    #[test]
    fn vm_assign_and_release_task() {
        let mut vm = Vm::in_dir(Path::new("/tmp"));
        vm.mark_ready();
        assert!(vm.task_id.is_none());
        let task_id = TaskId::from_bytes([0xAB; 32]);
        vm.assign_task(task_id);
        assert_eq!(vm.state, VmState::Running);
        assert_eq!(vm.task_id, Some(task_id));
        vm.release_task();
        assert_eq!(vm.state, VmState::Ready);
        assert!(vm.task_id.is_none());
    }

    // Port of Zig `test "vm uptime tracking"`.
    #[test]
    fn vm_uptime_tracking() {
        let mut vm = Vm::in_dir(Path::new("/tmp"));
        assert!(vm.uptime_ms().is_none());
        vm.mark_ready();
        assert!(vm.uptime_ms().unwrap() >= 0);
    }

    // Port of Zig `test "vm stop with running process"`.
    #[tokio::test]
    async fn vm_stop_with_running_process() {
        let dir = short_dir();
        let mut vm = Vm::in_dir(dir.path());
        let child = Command::new("sleep").arg("10").spawn().unwrap();
        let pid = child.id().unwrap();
        vm.attach_process(child);
        vm.state = VmState::Running;
        let started = Instant::now();
        vm.stop().await;
        assert!(started.elapsed() < Duration::from_secs(5));
        assert_eq!(vm.state, VmState::Stopped);
        assert!(!vm.has_process());
        // The process is gone (reaped): signalling it fails.
        let alive = std::process::Command::new("kill")
            .args(["-0", &pid.to_string()])
            .status()
            .unwrap()
            .success();
        assert!(!alive, "sleep process still alive after stop");
    }

    #[tokio::test]
    async fn stop_removes_sockets() {
        let dir = short_dir();
        let mut vm = Vm::in_dir(dir.path());
        std::fs::write(&vm.socket_path, "").unwrap();
        std::fs::write(&vm.vsock_uds_path, "").unwrap();
        vm.stop().await;
        assert!(!vm.socket_path.exists());
        assert!(!vm.vsock_uds_path.exists());
    }

    #[test]
    fn drop_deletes_rootfs_copy() {
        let dir = short_dir();
        let copy = dir.path().join("rootfs.ext4.copy");
        std::fs::write(&copy, "x").unwrap();
        let mut vm = Vm::in_dir(dir.path());
        vm.rootfs_copy_path = Some(copy.clone());
        drop(vm);
        assert!(!copy.exists());
    }

    #[tokio::test]
    async fn rootfs_copy_is_per_vm() {
        let dir = short_dir();
        let base = dir.path().join("rootfs.ext4");
        std::fs::write(&base, "root filesystem").unwrap();
        let mut vm = Vm::in_dir(dir.path());
        let copy = vm.copy_rootfs(&base.display().to_string()).await.unwrap();
        assert_eq!(copy, PathBuf::from(format!("{}.{}", base.display(), vm.id)));
        assert_eq!(std::fs::read_to_string(&copy).unwrap(), "root filesystem");
        assert_eq!(vm.rootfs_copy_path.as_deref(), Some(copy.as_path()));
    }

    #[tokio::test]
    async fn start_checks_artifacts_in_order() {
        let dir = short_dir();
        let present = dir.path().join("present");
        std::fs::write(&present, "").unwrap();
        let p = present.display().to_string();
        let missing = dir.path().join("missing").display().to_string();

        let cases = [
            (missing.clone(), p.clone(), p.clone(), "FirecrackerNotFound"),
            (p.clone(), missing.clone(), p.clone(), "KernelNotFound"),
            (p.clone(), p.clone(), missing.clone(), "RootfsNotFound"),
        ];
        for (bin, kernel, rootfs, want) in cases {
            let mut vm = Vm::in_dir(dir.path());
            let config = VmConfig {
                firecracker_bin: bin,
                kernel_path: kernel,
                rootfs_path: rootfs,
                ..VmConfig::default()
            };
            let err = vm.start(&config).await.unwrap_err();
            assert!(format!("{err:?}").starts_with(want), "{err:?}");
            assert_eq!(vm.state, VmState::Failed);
        }
    }

    #[tokio::test]
    async fn start_fails_when_api_socket_never_appears() {
        let dir = short_dir();
        let file = dir.path().join("f");
        std::fs::write(&file, "").unwrap();
        // `true` exits at once and never creates the API socket.
        let config = VmConfig {
            firecracker_bin: which("true"),
            kernel_path: file.display().to_string(),
            rootfs_path: file.display().to_string(),
            ..VmConfig::default()
        };
        let mut vm = Vm::in_dir(dir.path());
        let err = vm.start(&config).await.unwrap_err();
        assert!(matches!(err, VmError::FirecrackerStartFailed), "{err:?}");
        assert!(!vm.has_process());
        assert_eq!(vm.state, VmState::Failed);
    }

    fn which(cmd: &str) -> String {
        for dir in ["/usr/bin", "/bin"] {
            let p = Path::new(dir).join(cmd);
            if p.exists() {
                return p.display().to_string();
            }
        }
        panic!("{cmd} not found");
    }

    fn sequence(fake: &FakeApi) -> Vec<(String, String, String)> {
        fake.recorded()
            .into_iter()
            .map(|r| (r.method, r.path, r.body))
            .collect()
    }

    #[tokio::test]
    async fn cold_boot_api_sequence_with_network() {
        let dir = short_dir();
        let mut vm = Vm::in_dir(dir.path());
        vm.vm_index = 42;
        vm.vsock_cid = 1234;
        let fake = FakeApi::ok(&vm.socket_path);
        let config = VmConfig::default();
        let rootfs = "/tmp/marathon/rootfs/rootfs.ext4.vm";
        vm.configure(&config, rootfs, Some("tap42")).await.unwrap();
        let uds = vm.vsock_uds_path.display().to_string();
        assert_eq!(
            sequence(&fake),
            vec![
                ("PUT".into(), "/boot-source".into(), r#"{"kernel_image_path":"/tmp/marathon/kernel/vmlinux","boot_args":"console=ttyS0 reboot=k panic=1 pci=off marathon.vm_index=42"}"#.into()),
                ("PUT".into(), "/drives/rootfs".into(), r#"{"drive_id":"rootfs","path_on_host":"/tmp/marathon/rootfs/rootfs.ext4.vm","is_root_device":true,"is_read_only":false}"#.into()),
                ("PUT".into(), "/vsock".into(), format!(r#"{{"vsock_id":"vsock0","guest_cid":1234,"uds_path":"{uds}"}}"#)),
                ("PUT".into(), "/network-interfaces/eth0".into(), r#"{"iface_id":"eth0","guest_mac":"AA:FC:00:00:00:2A","host_dev_name":"tap42"}"#.into()),
                ("PUT".into(), "/machine-config".into(), r#"{"vcpu_count":2,"mem_size_mib":512}"#.into()),
                ("PUT".into(), "/actions".into(), r#"{"action_type":"InstanceStart"}"#.into()),
            ]
        );
        for r in fake.recorded() {
            assert!(r.headers.contains(&("Host".into(), "localhost".into())));
            assert!(
                r.headers
                    .contains(&("Content-Type".into(), "application/json".into()))
            );
            assert!(r.headers.contains(&("Connection".into(), "close".into())));
            assert!(
                r.headers
                    .contains(&("Content-Length".into(), r.body.len().to_string()))
            );
        }
    }

    #[tokio::test]
    async fn cold_boot_api_sequence_without_network() {
        let dir = short_dir();
        let vm = Vm::in_dir(dir.path());
        let fake = FakeApi::ok(&vm.socket_path);
        vm.configure(&VmConfig::default(), "/r", None)
            .await
            .unwrap();
        let paths: Vec<_> = fake.recorded().into_iter().map(|r| r.path).collect();
        assert_eq!(
            paths,
            [
                "/boot-source",
                "/drives/rootfs",
                "/vsock",
                "/machine-config",
                "/actions"
            ]
        );
    }

    #[tokio::test]
    async fn api_failure_stops_the_sequence() {
        let dir = short_dir();
        let vm = Vm::in_dir(dir.path());
        let fake = FakeApi::start(&vm.socket_path, |path| {
            if path == "/vsock" {
                "HTTP/1.1 400 Bad Request\r\nContent-Length: 2\r\n\r\n{}".into()
            } else {
                "HTTP/1.1 204 No Content\r\n\r\n".into()
            }
        });
        let err = vm
            .configure(&VmConfig::default(), "/r", None)
            .await
            .unwrap_err();
        assert!(matches!(err, VmError::Api(api::ApiError::Failed { .. })));
        let paths: Vec<_> = fake.recorded().into_iter().map(|r| r.path).collect();
        assert_eq!(paths, ["/boot-source", "/drives/rootfs", "/vsock"]);
    }

    #[tokio::test]
    async fn snapshot_load_request() {
        let dir = short_dir();
        let vm = Vm::in_dir(dir.path());
        let fake = FakeApi::ok(&vm.socket_path);
        vm.load_snapshot("/tmp/marathon/snapshots/base")
            .await
            .unwrap();
        assert_eq!(
            sequence(&fake),
            vec![(
                "PUT".into(),
                "/snapshot/load".into(),
                r#"{"snapshot_path":"/tmp/marathon/snapshots/base/snapshot","mem_file_path":"/tmp/marathon/snapshots/base/mem","resume_vm":true}"#.into()
            )]
        );
    }

    #[test]
    fn snapshot_restore_is_disabled_like_zig() {
        const { assert!(!SNAPSHOT_RESTORE_ENABLED) };
    }

    #[test]
    fn ready_wait_schedules_match_zig() {
        assert_eq!(ReadyWait::COLD_BOOT.attempts, 30);
        assert_eq!(ReadyWait::RESTORE.attempts, 10);
        assert_eq!(ReadyWait::COLD_BOOT.interval, Duration::from_millis(500));
        assert_eq!(ReadyWait::RESTORE.interval, Duration::from_millis(500));
        assert_eq!(API_SOCKET_TIMEOUT, Duration::from_millis(5000));
    }

    /// A vsock UDS that counts connections and fails the test on any byte.
    fn counting_listener(path: &Path) -> (Arc<AtomicUsize>, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::UnixListener::bind(path).unwrap();
        let count = Arc::new(AtomicUsize::new(0));
        let c = count.clone();
        let task = tokio::spawn(async move {
            while let Ok((mut s, _)) = listener.accept().await {
                c.fetch_add(1, Ordering::SeqCst);
                let mut b = [0u8; 64];
                if let Ok(n) = s.read(&mut b).await {
                    assert_eq!(
                        n,
                        0,
                        "readiness wait sent {:?}",
                        String::from_utf8_lossy(&b[..n])
                    );
                }
            }
        });
        (count, task)
    }

    #[tokio::test]
    async fn vsock_ready_wait_never_connects() {
        let dir = short_dir();
        let path = dir.path().join("vsock.sock");
        let (count, task) = counting_listener(&path);
        let wait = ReadyWait {
            attempts: 3,
            interval: Duration::from_millis(10),
        };
        wait_for_vsock_ready(&path, wait).await.unwrap();
        // Give a stray connection time to be accepted.
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(
            count.load(Ordering::SeqCst),
            0,
            "readiness wait connected to the vsock socket"
        );
        task.abort();
    }

    #[tokio::test]
    async fn vsock_ready_wait_waits_for_socket_to_appear() {
        let dir = short_dir();
        let path = dir.path().join("vsock.sock");
        let p = path.clone();
        let late = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(60)).await;
            counting_listener(&p)
        });
        let wait = ReadyWait {
            attempts: 50,
            interval: Duration::from_millis(10),
        };
        wait_for_vsock_ready(&path, wait).await.unwrap();
        let (count, task) = late.await.unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(count.load(Ordering::SeqCst), 0);
        task.abort();
    }

    #[tokio::test]
    async fn vsock_ready_wait_times_out() {
        let dir = short_dir();
        let path = dir.path().join("vsock.sock");
        let wait = ReadyWait {
            attempts: 3,
            interval: Duration::from_millis(5),
        };
        assert_eq!(wait_for_vsock_ready(&path, wait).await, Err(SocketTimeout));
        // A regular file is not a socket.
        std::fs::write(&path, "").unwrap();
        assert_eq!(wait_for_vsock_ready(&path, wait).await, Err(SocketTimeout));
    }

    #[tokio::test]
    async fn wait_for_socket_detects_unix_socket() {
        let dir = short_dir();
        let path = dir.path().join("api.sock");
        assert!(
            wait_for_socket(&path, Duration::from_millis(60))
                .await
                .is_err()
        );
        let _l = tokio::net::UnixListener::bind(&path).unwrap();
        wait_for_socket(&path, Duration::from_millis(60))
            .await
            .unwrap();
    }

    #[test]
    fn vm_config_from_node_config() {
        let node = NodeOperatorConfig {
            firecracker_bin: "/fc".into(),
            kernel_path: "/k".into(),
            rootfs_path: "/r".into(),
            snapshot_path: "/s".into(),
            vsock_port: 1234,
            ..NodeOperatorConfig::default()
        };
        let c = VmConfig::from(&node);
        assert_eq!(c.firecracker_bin, "/fc");
        assert_eq!(c.kernel_path, "/k");
        assert_eq!(c.rootfs_path, "/r");
        assert_eq!(c.snapshot_path, "/s");
        assert_eq!(c.vsock_port, 1234);
        assert_eq!((c.vcpu_count, c.mem_size_mib), (2, 512));
    }
}
