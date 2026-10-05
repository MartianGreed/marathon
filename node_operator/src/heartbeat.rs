//! The node's connection to the orchestrator.
//!
//! The node dials the orchestrator's `NodeService` and opens the
//! bidirectional `Heartbeat` stream. It sends a `NodeHeartbeat` at once
//! (this registers the node), then every heartbeat interval, or every
//! second while VMs are running so task output streams promptly. The
//! orchestrator answers with commands: execute, cancel, drain, warm pool.
//! Finished results and buffered output go out through `ReportTaskResult`
//! and `ReportTaskOutput` before each heartbeat. Every message carries the
//! node's HMAC `NodeAuth`.
//!
//! When the stream ends or fails the node reconnects with exponential
//! backoff, reset once the orchestrator answers again.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use common::NodeId;
use common::config::NodeOperatorConfig;
use common::pb::{self, node_command::Command, node_service_client::NodeServiceClient};
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tokio_util::sync::CancellationToken;
use tonic::transport::{Certificate, Channel, ClientTlsConfig, Endpoint};

use crate::metrics;
use crate::task::executor::TaskExecutor;
use crate::trace::TraceContext;

/// Hint logged when the orchestrator rejects the node token.
pub const AUTH_FAILED_HINT: &str =
    "Authentication failed - check MARATHON_NODE_AUTH_KEY matches orchestrator";

/// Heartbeat timing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HeartbeatSettings {
    /// Interval when idle.
    pub interval: Duration,
    /// Upper bound on the interval while VMs are running.
    pub active_interval_cap: Duration,
    /// First reconnect delay; doubles up to `backoff_max`.
    pub backoff_initial: Duration,
    pub backoff_max: Duration,
    pub connect_timeout: Duration,
    pub rpc_timeout: Duration,
}

impl Default for HeartbeatSettings {
    fn default() -> Self {
        Self {
            interval: Duration::from_millis(5000),
            active_interval_cap: Duration::from_millis(1000),
            backoff_initial: Duration::from_secs(1),
            backoff_max: Duration::from_secs(30),
            connect_timeout: Duration::from_secs(5),
            rpc_timeout: Duration::from_secs(10),
        }
    }
}

impl HeartbeatSettings {
    pub fn from_config(c: &NodeOperatorConfig) -> Self {
        Self {
            interval: Duration::from_millis(c.heartbeat_interval_ms),
            ..Self::default()
        }
    }
}

/// System load figures in the heartbeat. Not measured yet (as in Zig).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct SystemInfo {
    pub cpu_usage: f64,
    pub memory_usage: f64,
    pub disk_available: i64,
    pub uptime: i64,
}

pub fn get_system_info() -> SystemInfo {
    SystemInfo::default()
}

/// The machine's hostname, or `unknown`.
pub fn get_hostname() -> &'static str {
    static HOSTNAME: OnceLock<String> = OnceLock::new();
    HOSTNAME.get_or_init(|| {
        let from_proc = std::fs::read_to_string("/proc/sys/kernel/hostname").ok();
        let from_cmd = || {
            std::process::Command::new("hostname")
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        };
        from_proc
            .or_else(from_cmd)
            .map(|h| h.trim().to_string())
            .filter(|h| !h.is_empty())
            .unwrap_or_else(|| "unknown".to_string())
    })
}

/// Where the orchestrator is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OrchestratorTarget {
    pub address: String,
    pub port: u16,
    pub tls_enabled: bool,
    pub tls_ca_path: Option<String>,
}

impl OrchestratorTarget {
    pub fn uri(&self) -> String {
        let scheme = if self.tls_enabled { "https" } else { "http" };
        format!("{scheme}://{}:{}", self.address, self.port)
    }
}

/// Why one heartbeat stream ended.
#[derive(Debug)]
enum SessionEnd {
    Shutdown,
    StreamEnded,
    Status(tonic::Status),
    Connect(String),
    Timeout,
}

/// Exponential reconnect delay: `initial`, doubling up to `max`, back to
/// `initial` after [`reset`](Self::reset).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Backoff {
    initial: Duration,
    max: Duration,
    current: Duration,
}

impl Backoff {
    pub fn new(initial: Duration, max: Duration) -> Self {
        Self {
            initial,
            max,
            current: initial,
        }
    }

    /// The delay to wait now; the following one doubles.
    pub fn next_delay(&mut self) -> Duration {
        let d = self.current;
        self.current = (self.current * 2).min(self.max);
        d
    }

    pub fn reset(&mut self) {
        self.current = self.initial;
    }
}

/// Metric label for a gRPC status code.
fn code_label(code: tonic::Code) -> &'static str {
    match code {
        tonic::Code::Ok => "ok",
        tonic::Code::Unauthenticated => "unauthenticated",
        tonic::Code::Unavailable => "unavailable",
        tonic::Code::DeadlineExceeded => "deadline_exceeded",
        tonic::Code::PermissionDenied => "permission_denied",
        tonic::Code::InvalidArgument => "invalid_argument",
        tonic::Code::Internal => "internal",
        _ => "other",
    }
}

fn outcome_label<T>(
    outcome: &Result<Result<T, tonic::Status>, tokio::time::error::Elapsed>,
) -> &'static str {
    match outcome {
        Ok(Ok(_)) => "ok",
        Ok(Err(s)) => code_label(s.code()),
        Err(_) => "timeout",
    }
}

fn command_label(cmd: &pb::NodeCommand) -> &'static str {
    match cmd.command {
        Some(Command::ExecuteTask(_)) => "execute_task",
        Some(Command::CancelTask(_)) => "cancel_task",
        Some(Command::Drain(_)) => "drain",
        Some(Command::WarmPool(_)) => "warm_pool",
        None => "empty",
    }
}

/// The node id from `MARATHON_NODE_ID` when it is a valid 32-hex id,
/// otherwise a random one.
pub fn resolve_node_id(config: &NodeOperatorConfig) -> NodeId {
    match config.node_id.as_deref().map(NodeId::parse) {
        Some(Ok(id)) => id,
        Some(Err(e)) => {
            let id = NodeId::random();
            tracing::warn!(node_id = %id, error = %e, "MARATHON_NODE_ID is not a 32-hex node id, using a random id");
            id
        }
        None => NodeId::random(),
    }
}

/// The heartbeat loop.
pub struct HeartbeatClient {
    target: OrchestratorTarget,
    node_id: NodeId,
    hostname: String,
    auth_key: Option<Vec<u8>>,
    executor: Arc<TaskExecutor>,
    settings: HeartbeatSettings,
    running: AtomicBool,
    shutdown: CancellationToken,
    started: Instant,
}

impl HeartbeatClient {
    /// A client with the node id from [`resolve_node_id`].
    pub fn new(
        config: &NodeOperatorConfig,
        executor: Arc<TaskExecutor>,
        settings: HeartbeatSettings,
    ) -> Self {
        Self::with_node_id(config, resolve_node_id(config), executor, settings)
    }

    /// A client for an already chosen node id (the binary resolves it
    /// before warming the pool, so warm-up logs carry it too).
    pub fn with_node_id(
        config: &NodeOperatorConfig,
        node_id: NodeId,
        executor: Arc<TaskExecutor>,
        settings: HeartbeatSettings,
    ) -> Self {
        executor.set_node_id(node_id);
        crate::identity::set(node_id);
        Self {
            target: OrchestratorTarget {
                address: config.orchestrator_address.clone(),
                port: config.orchestrator_port,
                tls_enabled: config.tls_enabled,
                tls_ca_path: config.tls_ca_path.clone(),
            },
            node_id,
            hostname: config
                .hostname
                .clone()
                .unwrap_or_else(|| get_hostname().to_string()),
            auth_key: config.auth_key.as_ref().map(|k| k.as_bytes().to_vec()),
            executor,
            settings,
            running: AtomicBool::new(false),
            shutdown: CancellationToken::new(),
            started: Instant::now(),
        }
    }

    pub fn node_id(&self) -> NodeId {
        self.node_id
    }

    pub fn interval_ms(&self) -> u64 {
        u64::try_from(self.settings.interval.as_millis()).unwrap_or(u64::MAX)
    }

    pub fn target(&self) -> &OrchestratorTarget {
        &self.target
    }

    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Acquire)
    }

    /// Ask the loop to stop; [`run`](Self::run) returns soon after.
    pub fn stop(&self) {
        self.running.store(false, Ordering::Release);
        self.shutdown.cancel();
    }

    fn auth(&self) -> pb::NodeAuth {
        common::node_auth::node_auth(
            self.auth_key.as_deref(),
            &self.node_id,
            common::types::now_ms(),
        )
    }

    /// The status reported in each heartbeat.
    pub fn collect_status(&self) -> pb::NodeStatus {
        let pool = self.executor.pool();
        let info = get_system_info();
        pb::NodeStatus {
            hostname: self.hostname.clone(),
            total_vm_slots: pool.config().total_vm_slots,
            active_vms: u32::try_from(pool.active_count()).unwrap_or(u32::MAX),
            warm_vms: u32::try_from(pool.warm_count()).unwrap_or(u32::MAX),
            cpu_usage: info.cpu_usage,
            memory_usage: info.memory_usage,
            disk_available_bytes: info.disk_available,
            healthy: true,
            draining: self.executor.is_draining(),
            uptime_seconds: i64::try_from(self.started.elapsed().as_secs()).unwrap_or(i64::MAX),
            last_task_at: None,
            active_task_ids: self.executor.active_task_ids(),
        }
    }

    pub fn build_heartbeat(&self) -> pb::NodeHeartbeat {
        pb::NodeHeartbeat {
            auth: Some(self.auth()),
            status: Some(self.collect_status()),
        }
    }

    /// The interval to use now: capped while tasks or VMs are running. A
    /// task counts from the moment its execute command is accepted, before
    /// its VM has booted.
    pub fn current_interval(&self) -> Duration {
        if self.executor.pool().active_count() > 0 || self.executor.active_task_count() > 0 {
            self.settings
                .interval
                .min(self.settings.active_interval_cap)
        } else {
            self.settings.interval
        }
    }

    async fn connect(&self) -> Result<Channel, String> {
        let mut endpoint = Endpoint::from_shared(self.target.uri())
            .map_err(|e| e.to_string())?
            .connect_timeout(self.settings.connect_timeout)
            .tcp_nodelay(true)
            .http2_keep_alive_interval(Duration::from_secs(30))
            .keep_alive_timeout(Duration::from_secs(10))
            .keep_alive_while_idle(true);
        if self.target.tls_enabled {
            let mut tls = ClientTlsConfig::new().domain_name(self.target.address.clone());
            tls = match &self.target.tls_ca_path {
                Some(path) => {
                    let pem = tokio::fs::read(path)
                        .await
                        .map_err(|e| format!("failed to read TLS CA {path}: {e}"))?;
                    tls.ca_certificate(Certificate::from_pem(pem))
                }
                None => tls.with_native_roots(),
            };
            endpoint = endpoint.tls_config(tls).map_err(|e| e.to_string())?;
        }
        endpoint.connect().await.map_err(|e| e.to_string())
    }

    /// Run until [`stop`](Self::stop).
    pub async fn run(&self) {
        self.running.store(true, Ordering::Release);
        let m = metrics::global();
        let mut backoff = Backoff::new(self.settings.backoff_initial, self.settings.backoff_max);
        tracing::info!(operation = "heartbeat", node_id = %self.node_id, orchestrator = %self.target.uri(), "heartbeat loop starting");
        while self.is_running() && !self.shutdown.is_cancelled() {
            let (end, answered) = match self.connect().await {
                Ok(channel) => {
                    m.orchestrator_connected.set(1);
                    let r = self.session(channel).await;
                    m.orchestrator_connected.set(0);
                    r
                }
                Err(e) => {
                    m.rpc_calls.inc("connect", "error");
                    (SessionEnd::Connect(e), false)
                }
            };
            if answered {
                backoff.reset();
            }
            match &end {
                SessionEnd::Shutdown => break,
                SessionEnd::Status(s) if s.code() == tonic::Code::Unauthenticated => {
                    m.heartbeat_auth_failures.inc();
                    tracing::error!(operation = "heartbeat", node_id = %self.node_id, status = %s.message(), "{AUTH_FAILED_HINT}");
                }
                SessionEnd::StreamEnded => {
                    tracing::warn!(operation = "heartbeat", node_id = %self.node_id, "heartbeat stream ended, reconnecting");
                }
                SessionEnd::Status(s) => {
                    m.heartbeat_errors.inc();
                    tracing::warn!(operation = "heartbeat", node_id = %self.node_id, code = ?s.code(), status = %s.message(), "heartbeat failed, reconnecting");
                }
                SessionEnd::Connect(e) => {
                    m.heartbeat_errors.inc();
                    tracing::warn!(operation = "heartbeat", node_id = %self.node_id, error = %e, "cannot reach orchestrator, reconnecting");
                }
                SessionEnd::Timeout => {
                    m.heartbeat_errors.inc();
                    tracing::warn!(operation = "heartbeat", node_id = %self.node_id, "heartbeat stream open timed out, reconnecting");
                }
            }
            m.reconnects.inc();
            let delay = backoff.next_delay();
            tracing::debug!(operation = "heartbeat", node_id = %self.node_id, delay_ms = u64::try_from(delay.as_millis()).unwrap_or(u64::MAX), "reconnect backoff");
            tokio::select! {
                () = self.shutdown.cancelled() => break,
                () = tokio::time::sleep(delay) => {}
            }
        }
        self.running.store(false, Ordering::Release);
        tracing::info!(operation = "heartbeat", node_id = %self.node_id, "heartbeat loop stopped");
    }

    /// One heartbeat stream. Returns why it ended and whether the
    /// orchestrator answered at least once.
    async fn session(&self, channel: Channel) -> (SessionEnd, bool) {
        let m = metrics::global();
        let trace = TraceContext::new_root();
        let mut client = NodeServiceClient::new(channel);
        let (tx, rx) = mpsc::channel(8);
        // Registration: the first heartbeat goes out with the stream.
        if tx.try_send(self.build_heartbeat()).is_err() {
            return (SessionEnd::StreamEnded, false);
        }
        let mut request = tonic::Request::new(ReceiverStream::new(rx));
        trace.inject(&mut request);
        let opened = Instant::now();
        let response = tokio::select! {
            () = self.shutdown.cancelled() => return (SessionEnd::Shutdown, false),
            r = tokio::time::timeout(self.settings.connect_timeout, client.heartbeat(request)) => r,
        };
        let mut inbound = match response {
            Ok(Ok(r)) => {
                m.rpc_calls.inc("heartbeat_open", "ok");
                r.into_inner()
            }
            Ok(Err(status)) => {
                m.rpc_calls.inc("heartbeat_open", code_label(status.code()));
                return (SessionEnd::Status(status), false);
            }
            Err(_) => {
                m.rpc_calls.inc("heartbeat_open", "timeout");
                return (SessionEnd::Timeout, false);
            }
        };
        m.heartbeat_connect_ms.observe(opened.elapsed());
        m.heartbeats_sent.inc();
        tracing::info!(operation = "heartbeat", node_id = %self.node_id, trace_id = %trace.trace_id(), "heartbeat stream open");

        // Reports run beside the heartbeat loop so a slow report RPC never
        // delays a heartbeat or a command. They stop between flushes only,
        // so a drained result is always either reported or re-queued.
        let stop_reports = CancellationToken::new();
        let beats = async {
            let end = self.heartbeat_loop(&mut inbound, &tx, &trace).await;
            stop_reports.cancel();
            end
        };
        let reports = self.report_loop(client, &trace, &stop_reports);
        let (end, ()) = tokio::join!(beats, reports);
        end
    }

    /// Send heartbeats and apply commands until the stream ends. The next
    /// deadline is recomputed on every wake, so starting a task shortens a
    /// pending idle wait at once.
    async fn heartbeat_loop(
        &self,
        inbound: &mut tonic::Streaming<pb::HeartbeatResponse>,
        tx: &mpsc::Sender<pb::NodeHeartbeat>,
        trace: &TraceContext,
    ) -> (SessionEnd, bool) {
        let m = metrics::global();
        let mut answered = false;
        let mut last_sent = tokio::time::Instant::now();
        loop {
            let deadline = last_sent + self.current_interval();
            let wake =
                deadline.min(tokio::time::Instant::now() + self.settings.active_interval_cap);
            tokio::select! {
                () = self.shutdown.cancelled() => return (SessionEnd::Shutdown, answered),
                msg = inbound.message() => match msg {
                    Ok(Some(resp)) => {
                        answered = true;
                        m.heartbeat_responses.inc();
                        if !resp.acknowledged {
                            tracing::warn!(operation = "heartbeat", node_id = %self.node_id, "heartbeat not acknowledged");
                        }
                        for cmd in resp.commands {
                            self.process_command(cmd, trace);
                        }
                    }
                    Ok(None) => return (SessionEnd::StreamEnded, answered),
                    Err(status) => return (SessionEnd::Status(status), answered),
                },
                () = tokio::time::sleep_until(wake) => {
                    let now = tokio::time::Instant::now();
                    if now < last_sent + self.current_interval() {
                        continue;
                    }
                    match tx.try_send(self.build_heartbeat()) {
                        Ok(()) => m.heartbeats_sent.inc(),
                        Err(mpsc::error::TrySendError::Full(_)) => {
                            tracing::warn!(operation = "heartbeat", node_id = %self.node_id, "heartbeat stream backed up, skipping one heartbeat");
                        }
                        Err(mpsc::error::TrySendError::Closed(_)) => return (SessionEnd::StreamEnded, answered),
                    }
                    last_sent = now;
                    m.log();
                }
            }
        }
    }

    /// Flush reports on the heartbeat cadence until `stop`.
    async fn report_loop(
        &self,
        mut client: NodeServiceClient<Channel>,
        trace: &TraceContext,
        stop: &CancellationToken,
    ) {
        let mut last = tokio::time::Instant::now();
        loop {
            let deadline = last + self.current_interval();
            let wake =
                deadline.min(tokio::time::Instant::now() + self.settings.active_interval_cap);
            tokio::select! {
                () = stop.cancelled() => return,
                () = tokio::time::sleep_until(wake) => {}
            }
            let now = tokio::time::Instant::now();
            if now < last + self.current_interval() {
                continue;
            }
            last = now;
            self.flush_reports(&mut client, trace).await;
        }
    }

    /// Send finished results and buffered output. Results whose report
    /// fails are queued again; output is dropped.
    pub async fn flush_reports(
        &self,
        client: &mut NodeServiceClient<Channel>,
        trace: &TraceContext,
    ) {
        let m = metrics::global();
        let results = self.executor.drain_results();
        if !results.is_empty() {
            let count = results.len();
            let span = trace.child();
            let mut req = tonic::Request::new(pb::ReportTaskResultRequest {
                auth: Some(self.auth()),
                results: results.clone(),
            });
            span.inject(&mut req);
            let started = Instant::now();
            let outcome =
                tokio::time::timeout(self.settings.rpc_timeout, client.report_task_result(req))
                    .await;
            m.report_rpc_ms.observe(started.elapsed());
            m.rpc_calls
                .inc("report_task_result", outcome_label(&outcome));
            match outcome {
                Ok(Ok(_)) => {
                    m.result_reports.inc();
                    tracing::info!(operation = "report_task_result", node_id = %self.node_id, trace_id = %span.trace_id(), count, "task results reported");
                }
                Ok(Err(status)) => {
                    m.result_report_errors.inc();
                    tracing::warn!(operation = "report_task_result", node_id = %self.node_id, count, code = ?status.code(), message = %status.message(), "result report failed, will retry");
                    self.executor.requeue_results(results);
                }
                Err(_) => {
                    m.result_report_errors.inc();
                    tracing::warn!(operation = "report_task_result", node_id = %self.node_id, count, "result report timed out, will retry");
                    self.executor.requeue_results(results);
                }
            }
        }

        let events = self.executor.drain_output();
        if !events.is_empty() {
            let count = events.len();
            let span = trace.child();
            let mut req = tonic::Request::new(pb::ReportTaskOutputRequest {
                auth: Some(self.auth()),
                events,
            });
            span.inject(&mut req);
            let started = Instant::now();
            let outcome =
                tokio::time::timeout(self.settings.rpc_timeout, client.report_task_output(req))
                    .await;
            m.report_rpc_ms.observe(started.elapsed());
            m.rpc_calls
                .inc("report_task_output", outcome_label(&outcome));
            match outcome {
                Ok(Ok(_)) => {
                    m.output_reports.inc();
                    tracing::debug!(operation = "report_task_output", node_id = %self.node_id, trace_id = %span.trace_id(), count, "task output reported");
                }
                Ok(Err(status)) => {
                    m.output_report_errors.inc();
                    tracing::warn!(operation = "report_task_output", node_id = %self.node_id, count, code = ?status.code(), message = %status.message(), "output report failed, dropping output");
                }
                Err(_) => {
                    m.output_report_errors.inc();
                    tracing::warn!(operation = "report_task_output", node_id = %self.node_id, count, "output report timed out, dropping output");
                }
            }
        }
    }

    /// Apply one command from the orchestrator. `trace` is the stream's
    /// trace; a task started here runs in a child span of it.
    pub fn process_command(&self, cmd: pb::NodeCommand, trace: &TraceContext) {
        let m = metrics::global();
        m.commands_received.inc();
        m.commands.inc(command_label(&cmd), "received");
        match cmd.command {
            Some(Command::ExecuteTask(task)) => {
                // Rejections are logged and reported by the executor.
                let _ = self.executor.execute_task_traced(task, trace.child());
            }
            Some(Command::CancelTask(c)) => {
                self.executor.cancel_task(&c.task_id);
            }
            Some(Command::Drain(_)) => {
                tracing::info!(operation = "drain", node_id = %self.node_id, "drain command received, rejecting new tasks");
                self.executor.set_draining(true);
            }
            Some(Command::WarmPool(w)) => {
                let pool = self.executor.pool().clone();
                let target = w.target.unwrap_or(pool.config().warm_pool_target);
                tracing::info!(operation = "warm_pool", node_id = %self.node_id, target, "warm_pool command received");
                tokio::spawn(async move { pool.warm_pool(target).await });
            }
            None => {
                tracing::warn!(operation = "heartbeat", node_id = %self.node_id, "empty command ignored");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task::executor::ExecutorSettings;
    use crate::vm::pool::testing::pool;

    fn client(config: &NodeOperatorConfig) -> HeartbeatClient {
        let executor = TaskExecutor::new(Arc::new(pool(true, 10, 0)), ExecutorSettings::default());
        HeartbeatClient::new(config, executor, HeartbeatSettings::from_config(config))
    }

    // Port of Zig `test "heartbeat client init"`.
    #[test]
    fn heartbeat_client_init() {
        let c = client(&NodeOperatorConfig::default());
        assert_eq!(c.interval_ms(), 5000);
        assert_eq!(c.target().uri(), "http://127.0.0.1:8080");
    }

    // Port of Zig `test "stop flag transitions correctly"`.
    #[test]
    fn stop_flag_transitions() {
        let c = client(&NodeOperatorConfig::default());
        assert!(!c.is_running());
        c.running.store(true, Ordering::Release);
        assert!(c.is_running());
        c.stop();
        assert!(!c.is_running());
    }

    // Port of Zig `test "getHostname returns non-empty string"`.
    #[test]
    fn get_hostname_non_empty() {
        assert!(!get_hostname().is_empty());
    }

    // Port of Zig `test "getSystemInfo returns valid defaults"`.
    #[test]
    fn get_system_info_defaults() {
        let info = get_system_info();
        assert_eq!(info.cpu_usage, 0.0);
        assert_eq!(info.memory_usage, 0.0);
        assert_eq!(info.disk_available, 0);
        assert_eq!(info.uptime, 0);
    }

    #[test]
    fn heartbeat_token_verifies_with_shared_key() {
        let c = client(&NodeOperatorConfig {
            auth_key: Some("shared-secret".into()),
            ..NodeOperatorConfig::default()
        });
        let hb = c.build_heartbeat();
        let auth = hb.auth.as_ref().unwrap();
        assert_eq!(auth.token.len(), common::node_auth::TOKEN_LEN);
        let id = common::node_auth::verify_node_auth(
            b"shared-secret",
            hb.auth.as_ref(),
            common::types::now_ms(),
        )
        .unwrap();
        assert_eq!(id, c.node_id());
        assert!(
            common::node_auth::verify_node_auth(
                b"other",
                hb.auth.as_ref(),
                common::types::now_ms()
            )
            .is_err()
        );
        // Independent recomputation of the documented construction.
        let expected = common::node_auth::sign(b"shared-secret", &c.node_id(), auth.timestamp_ms);
        assert_eq!(auth.token, expected);
        assert!((common::types::now_ms() - auth.timestamp_ms).abs() < 5_000);
    }

    #[test]
    fn heartbeat_without_key_sends_empty_token() {
        let c = client(&NodeOperatorConfig::default());
        let auth = c.build_heartbeat().auth.unwrap();
        assert!(auth.token.is_empty());
        assert_eq!(auth.node_id, c.node_id().to_hex());
    }

    #[test]
    fn status_reflects_pool_and_config() {
        let c = client(&NodeOperatorConfig {
            hostname: Some("node-a".into()),
            ..NodeOperatorConfig::default()
        });
        let s = c.build_heartbeat().status.unwrap();
        assert_eq!(s.hostname, "node-a");
        assert_eq!(s.total_vm_slots, 10);
        assert_eq!((s.active_vms, s.warm_vms), (0, 0));
        assert!(s.healthy);
        assert!(!s.draining);
        assert!(s.active_task_ids.is_empty());
    }

    #[test]
    fn node_id_from_config_when_valid() {
        let id = NodeId::random();
        let c = client(&NodeOperatorConfig {
            node_id: Some(id.to_hex().to_uppercase()),
            ..NodeOperatorConfig::default()
        });
        assert_eq!(c.node_id(), id);
        let c = client(&NodeOperatorConfig {
            node_id: Some("node-1".into()),
            ..NodeOperatorConfig::default()
        });
        assert_ne!(c.node_id(), NodeId::default());
    }

    #[test]
    fn tls_target_uses_https() {
        let c = client(&NodeOperatorConfig {
            orchestrator_address: "orch.example.com".into(),
            orchestrator_port: 443,
            tls_enabled: true,
            ..NodeOperatorConfig::default()
        });
        assert_eq!(c.target().uri(), "https://orch.example.com:443");
    }

    #[tokio::test]
    async fn active_vms_shorten_the_interval() {
        let config = NodeOperatorConfig::default();
        let executor = TaskExecutor::new(Arc::new(pool(false, 10, 0)), ExecutorSettings::default());
        let c = HeartbeatClient::new(
            &config,
            executor.clone(),
            HeartbeatSettings::from_config(&config),
        );
        assert_eq!(c.current_interval(), Duration::from_millis(5000));
        executor
            .pool()
            .insert_warm(crate::vm::pool::testing::ready_vm());
        let _lease = executor.pool().acquire().unwrap();
        assert_eq!(c.current_interval(), Duration::from_millis(1000));
    }

    #[tokio::test]
    async fn drain_command_sets_draining() {
        let c = client(&NodeOperatorConfig::default());
        c.process_command(
            pb::NodeCommand {
                command: Some(Command::Drain(pb::Drain {})),
            },
            &TraceContext::new_root(),
        );
        assert!(c.build_heartbeat().status.unwrap().draining);
    }

    #[tokio::test]
    async fn run_returns_after_stop_while_orchestrator_unreachable() {
        let config = NodeOperatorConfig {
            orchestrator_port: 1,
            ..NodeOperatorConfig::default()
        };
        let c = Arc::new(client(&config));
        let runner = c.clone();
        let handle = tokio::spawn(async move { runner.run().await });
        tokio::time::sleep(Duration::from_millis(100)).await;
        c.stop();
        tokio::time::timeout(Duration::from_secs(5), handle)
            .await
            .unwrap()
            .unwrap();
        assert!(!c.is_running());
    }

    #[test]
    fn backoff_doubles_to_max_and_resets() {
        let mut b = Backoff::new(Duration::from_secs(1), Duration::from_secs(30));
        let delays: Vec<u64> = (0..7).map(|_| b.next_delay().as_secs()).collect();
        assert_eq!(delays, [1, 2, 4, 8, 16, 30, 30]);
        b.reset();
        assert_eq!(b.next_delay(), Duration::from_secs(1));
    }

    // C-R1-03: an accepted task shortens the interval before its VM exists.
    #[tokio::test]
    async fn accepted_task_shortens_the_interval() {
        let config = NodeOperatorConfig::default();
        // Launches fail slowly enough that the task is still running.
        let executor = TaskExecutor::new(Arc::new(pool(false, 10, 0)), ExecutorSettings::default());
        let c = HeartbeatClient::new(
            &config,
            executor.clone(),
            HeartbeatSettings::from_config(&config),
        );
        assert_eq!(c.current_interval(), Duration::from_millis(5000));
        executor
            .execute_task(pb::ExecuteTask {
                task_id: common::TaskId::random().to_hex(),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(c.current_interval(), Duration::from_millis(1000));
    }

    #[test]
    fn executor_learns_the_node_id() {
        let c = client(&NodeOperatorConfig::default());
        assert_eq!(c.executor.node_label(), c.node_id().to_hex());
    }
}
