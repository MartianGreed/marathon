//! Runs `ExecuteTask` commands on pooled VMs.
//!
//! Each task gets a VM from the pool, runs to completion on it in its own
//! tokio task, and leaves a `TaskResult` for the heartbeat loop to report.
//! The VM is destroyed afterwards. Running tasks can be cancelled; a
//! draining node rejects new tasks.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::Instant;

use common::pb;
use common::{NodeId, TaskId, UsageMetrics};
use tokio_util::sync::CancellationToken;

use crate::metrics;
use crate::task::output_buffer::OutputBuffer;
use crate::trace::TraceContext;
use crate::vm::VmPool;
use crate::vsock::handler::{CANCELLED_BEFORE_START, RunnerSettings, TaskRunner};

/// Error text for a task rejected because the node is draining.
pub const DRAINING: &str = "node is draining";
/// Error text for a task id that does not parse.
pub const INVALID_TASK_ID: &str = "invalid task id";

/// Executor settings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExecutorSettings {
    pub vsock_port: u32,
    pub runner: RunnerSettings,
}

impl Default for ExecutorSettings {
    fn default() -> Self {
        Self {
            vsock_port: common::vsock::DEFAULT_PORT,
            runner: RunnerSettings::default(),
        }
    }
}

/// Why an execute command was not started.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ExecuteError {
    #[error("invalid task id {0:?}")]
    InvalidTaskId(String),
    #[error("task {0} is already running")]
    AlreadyRunning(TaskId),
    #[error("node is draining")]
    Draining,
}

/// The node's task runner.
pub struct TaskExecutor {
    pool: Arc<VmPool>,
    settings: ExecutorSettings,
    results: Mutex<Vec<pb::TaskResult>>,
    output: Arc<OutputBuffer>,
    running: Mutex<HashMap<TaskId, CancellationToken>>,
    draining: AtomicBool,
    node_id: OnceLock<NodeId>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Build the agent's start message from the orchestrator's command.
pub fn vsock_start(req: &pb::ExecuteTask) -> pb::VsockStart {
    pb::VsockStart {
        task_id: req.task_id.clone(),
        repo_url: req.repo_url.clone(),
        branch: req.branch.clone(),
        prompt: req.prompt.clone(),
        github_token: req.github_token.clone(),
        anthropic_api_key: req.anthropic_api_key.clone(),
        create_pr: req.create_pr,
        pr_title: req.pr_title.clone(),
        pr_body: req.pr_body.clone(),
        max_iterations: req.max_iterations,
        completion_promise: req.completion_promise.clone(),
        env_vars: req.env_vars.clone(),
    }
}

fn failed_result(task_id: String, message: impl Into<String>) -> pb::TaskResult {
    pb::TaskResult {
        task_id,
        success: false,
        error_message: Some(message.into()),
        metrics: Some(UsageMetrics::default().into()),
        pr_url: None,
    }
}

impl TaskExecutor {
    pub fn new(pool: Arc<VmPool>, settings: ExecutorSettings) -> Arc<Self> {
        Arc::new(Self {
            pool,
            settings,
            results: Mutex::new(Vec::new()),
            output: Arc::new(OutputBuffer::new()),
            running: Mutex::new(HashMap::new()),
            draining: AtomicBool::new(false),
            node_id: OnceLock::new(),
        })
    }

    /// Record this node's id for logs and spans. Only the first call counts.
    pub fn set_node_id(&self, node_id: NodeId) {
        let _ = self.node_id.set(node_id);
    }

    /// This node's id in logs, `unknown` before it is set.
    pub(crate) fn node_label(&self) -> String {
        self.node_id
            .get()
            .map_or_else(|| "unknown".to_string(), NodeId::to_hex)
    }

    fn update_queue_gauge(queued: usize) {
        metrics::global()
            .result_queue_depth
            .set(i64::try_from(queued).unwrap_or(i64::MAX));
    }

    pub fn pool(&self) -> &Arc<VmPool> {
        &self.pool
    }

    pub fn output_buffer(&self) -> &Arc<OutputBuffer> {
        &self.output
    }

    /// Take the finished results, oldest first.
    pub fn drain_results(&self) -> Vec<pb::TaskResult> {
        let taken = std::mem::take(&mut *lock(&self.results));
        Self::update_queue_gauge(0);
        taken
    }

    /// Put back results whose report failed, ahead of newer ones.
    pub fn requeue_results(&self, mut results: Vec<pb::TaskResult>) {
        let mut queued = lock(&self.results);
        results.append(&mut queued);
        *queued = results;
        Self::update_queue_gauge(queued.len());
    }

    /// Take the buffered output.
    pub fn drain_output(&self) -> Vec<pb::TaskOutputEvent> {
        self.output.drain()
    }

    pub fn set_draining(&self, draining: bool) {
        self.draining.store(draining, Ordering::SeqCst);
    }

    pub fn is_draining(&self) -> bool {
        self.draining.load(Ordering::SeqCst)
    }

    /// Ids of the tasks currently running, lowercase hex.
    pub fn active_task_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = lock(&self.running).keys().map(TaskId::to_hex).collect();
        ids.sort();
        ids
    }

    pub fn active_task_count(&self) -> usize {
        lock(&self.running).len()
    }

    fn push_result(&self, result: pb::TaskResult) {
        let mut queued = lock(&self.results);
        queued.push(result);
        Self::update_queue_gauge(queued.len());
    }

    /// Start a task in the background. A rejected task also leaves a
    /// failed result so the orchestrator does not wait for it forever.
    pub fn execute_task(self: &Arc<Self>, req: pb::ExecuteTask) -> Result<(), ExecuteError> {
        self.execute_task_traced(req, TraceContext::new_root())
    }

    /// [`execute_task`](Self::execute_task) inside an existing trace (the
    /// heartbeat stream's), so the task's logs join the command that
    /// started it.
    pub fn execute_task_traced(
        self: &Arc<Self>,
        req: pb::ExecuteTask,
        trace: TraceContext,
    ) -> Result<(), ExecuteError> {
        let m = metrics::global();
        let node_id = self.node_label();
        let Ok(task_id) = TaskId::parse(&req.task_id) else {
            tracing::error!(operation = "execute_task", node_id = %node_id, task_id = %req.task_id, "invalid task id");
            m.tasks_rejected.inc();
            m.tasks.inc("execute_task", "invalid_task_id");
            self.push_result(failed_result(req.task_id.clone(), INVALID_TASK_ID));
            return Err(ExecuteError::InvalidTaskId(req.task_id));
        };
        if self.is_draining() {
            tracing::warn!(operation = "execute_task", node_id = %node_id, task_id = %task_id, "rejecting task: node is draining");
            m.tasks_rejected.inc();
            m.tasks.inc("execute_task", "draining");
            self.push_result(failed_result(task_id.to_hex(), DRAINING));
            return Err(ExecuteError::Draining);
        }
        let token = CancellationToken::new();
        {
            let mut running = lock(&self.running);
            if running.contains_key(&task_id) {
                tracing::warn!(operation = "execute_task", node_id = %node_id, task_id = %task_id, "duplicate execute ignored: task already running");
                m.tasks.inc("execute_task", "duplicate");
                return Err(ExecuteError::AlreadyRunning(task_id));
            }
            running.insert(task_id, token.clone());
        }
        tracing::info!(operation = "execute_task", node_id = %node_id, task_id = %task_id, trace_id = %trace.trace_id(), "received task");
        m.tasks_started.inc();
        m.tasks.inc("execute_task", "accepted");
        let this = self.clone();
        tokio::spawn(async move { this.run_task(task_id, req, token, trace).await });
        Ok(())
    }

    /// Cancel a running task. Returns whether it was running.
    pub fn cancel_task(&self, task_id: &str) -> bool {
        let Ok(id) = TaskId::parse(task_id) else {
            tracing::warn!(
                operation = "cancel_task",
                task_id,
                "cancel for invalid task id ignored"
            );
            return false;
        };
        match lock(&self.running).get(&id) {
            Some(token) => {
                tracing::info!(operation = "cancel_task", node_id = %self.node_label(), task_id = %id, "cancelling task");
                token.cancel();
                true
            }
            None => {
                tracing::warn!(operation = "cancel_task", node_id = %self.node_label(), task_id = %id, "cancel for unknown task ignored");
                false
            }
        }
    }

    async fn run_task(
        self: Arc<Self>,
        task_id: TaskId,
        req: pb::ExecuteTask,
        token: CancellationToken,
        trace: TraceContext,
    ) {
        let op = common::telemetry::Operation::start("run_task")
            .task_id(&task_id)
            .node_id(&self.node_label());
        let started = Instant::now();
        tracing::info!(parent: op.span(), trace_id = %trace.trace_id(), span_id = %trace.span_id(), "task starting");

        // A cancel while the VM boots drops the boot (the VM is torn down).
        let acquired = tokio::select! {
            r = self.pool.acquire_or_create() => Some(r),
            () = token.cancelled() => None,
        };
        let (report, used_vm) = match acquired {
            None => {
                tracing::info!(parent: op.span(), "task cancelled while acquiring a VM");
                (
                    failed_result(task_id.to_hex(), CANCELLED_BEFORE_START),
                    None,
                )
            }
            Some(Err(e)) => {
                tracing::error!(parent: op.span(), error = %e, "failed to acquire VM");
                (failed_result(task_id.to_hex(), e.to_string()), None)
            }
            Some(Ok(lease)) => {
                tracing::info!(parent: op.span(), vm_id = %lease.vm_id, "task assigned to VM");
                self.pool.assign_task(lease.vm_id, task_id);
                let mut runner =
                    TaskRunner::new(&lease.vsock_uds_path, self.settings.vsock_port, task_id)
                        .with_settings(self.settings.runner)
                        .with_output_buffer(self.output.clone())
                        .with_trace(trace);
                let report = match runner.run(vsock_start(&req), token.clone()).await {
                    Ok(r) => pb::TaskResult {
                        task_id: task_id.to_hex(),
                        success: r.success,
                        error_message: r.error_message,
                        metrics: Some(r.metrics.into()),
                        pr_url: r.pr_url,
                    },
                    Err(e) => {
                        tracing::error!(parent: op.span(), error = %e, "task execution failed");
                        failed_result(task_id.to_hex(), e.to_string())
                    }
                };
                (report, Some(lease.vm_id))
            }
        };

        let m = metrics::global();
        m.task_duration_ms.observe(started.elapsed());
        if report.success {
            m.tasks_succeeded.inc();
            m.tasks.inc("run_task", "succeeded");
        } else if token.is_cancelled() {
            m.tasks_cancelled.inc();
            m.tasks.inc("run_task", "cancelled");
        } else {
            m.tasks_failed.inc();
            m.tasks.inc("run_task", "failed");
        }
        tracing::info!(
            parent: op.span(),
            success = report.success,
            pr_url = ?common::redact::OptSafeUrl(report.pr_url.as_deref()),
            // The error text can come from the agent and echo secrets: it
            // goes to the orchestrator in the result, the log keeps its size.
            error_bytes = report.error_message.as_deref().map_or(0, str::len),
            "task completed"
        );
        lock(&self.running).remove(&task_id);
        self.push_result(report);
        // Queue the result first: releasing may boot a replacement VM.
        if let Some(vm_id) = used_vm {
            self.pool.release(vm_id).await;
        }
        op.finish();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vm::pool::testing::pool;

    fn executor(fail_launch: bool) -> Arc<TaskExecutor> {
        TaskExecutor::new(
            Arc::new(pool(fail_launch, 2, 0)),
            ExecutorSettings::default(),
        )
    }

    // Port of Zig `test "task executor init"`.
    #[test]
    fn task_executor_init() {
        let e = executor(true);
        assert!(e.drain_results().is_empty());
        assert!(e.drain_output().is_empty());
        assert!(!e.is_draining());
        assert!(e.active_task_ids().is_empty());
    }

    #[test]
    fn vsock_start_copies_every_field() {
        let req = pb::ExecuteTask {
            task_id: "ab".repeat(32),
            repo_url: "https://github.com/o/r".into(),
            branch: "dev".into(),
            prompt: "p".into(),
            github_token: "ghp".into(),
            anthropic_api_key: "sk".into(),
            create_pr: true,
            pr_title: Some("t".into()),
            pr_body: Some("b".into()),
            timeout_ms: 1,
            max_tokens: 2,
            env_vars: vec![
                pb::EnvVar {
                    key: "A".into(),
                    value: "1".into(),
                },
                pb::EnvVar {
                    key: "A".into(),
                    value: "2".into(),
                },
            ],
            max_iterations: Some(4),
            completion_promise: Some("DONE".into()),
        };
        let s = vsock_start(&req);
        assert_eq!(s.task_id, req.task_id);
        assert_eq!(s.repo_url, req.repo_url);
        assert_eq!(s.branch, req.branch);
        assert_eq!(s.prompt, req.prompt);
        assert_eq!(s.github_token, req.github_token);
        assert_eq!(s.anthropic_api_key, req.anthropic_api_key);
        assert!(s.create_pr);
        assert_eq!(s.pr_title, req.pr_title);
        assert_eq!(s.pr_body, req.pr_body);
        assert_eq!(s.env_vars, req.env_vars);
        assert_eq!(s.max_iterations, Some(4));
        assert_eq!(s.completion_promise.as_deref(), Some("DONE"));
    }

    #[tokio::test]
    async fn invalid_task_id_is_reported_failed() {
        let e = executor(false);
        let err = e
            .execute_task(pb::ExecuteTask {
                task_id: "nope".into(),
                ..Default::default()
            })
            .unwrap_err();
        assert_eq!(err, ExecuteError::InvalidTaskId("nope".into()));
        let r = e.drain_results();
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].task_id, "nope");
        assert_eq!(r[0].error_message.as_deref(), Some(INVALID_TASK_ID));
    }

    #[tokio::test]
    async fn draining_rejects_with_failed_result() {
        let e = executor(false);
        e.set_draining(true);
        let id = TaskId::random();
        assert_eq!(
            e.execute_task(pb::ExecuteTask {
                task_id: id.to_hex(),
                ..Default::default()
            }),
            Err(ExecuteError::Draining)
        );
        let r = e.drain_results();
        assert_eq!(r[0].task_id, id.to_hex());
        assert!(!r[0].success);
        assert_eq!(r[0].error_message.as_deref(), Some(DRAINING));
    }

    async fn wait_result(e: &TaskExecutor) -> pb::TaskResult {
        for _ in 0..500 {
            if let Some(r) = e.drain_results().pop() {
                return r;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        panic!("no result");
    }

    #[tokio::test]
    async fn no_available_vm_is_reported_failed() {
        let e = executor(true);
        let id = TaskId::random();
        e.execute_task(pb::ExecuteTask {
            task_id: id.to_hex(),
            ..Default::default()
        })
        .unwrap();
        let r = wait_result(&e).await;
        assert_eq!(r.task_id, id.to_hex());
        assert!(!r.success);
        assert!(r.error_message.unwrap().starts_with("no available VM"));
        assert!(e.active_task_ids().is_empty());
        assert_eq!(e.pool().total_count(), 0);
    }

    #[tokio::test]
    async fn requeued_results_come_first() {
        let e = executor(false);
        e.push_result(failed_result("new".into(), "x"));
        e.requeue_results(vec![failed_result("old".into(), "x")]);
        let ids: Vec<_> = e.drain_results().into_iter().map(|r| r.task_id).collect();
        assert_eq!(ids, ["old", "new"]);
    }

    #[tokio::test]
    async fn cancel_unknown_task_is_false() {
        let e = executor(false);
        assert!(!e.cancel_task(&TaskId::random().to_hex()));
        assert!(!e.cancel_task("zz"));
    }

    /// Captures everything logged on this thread.
    #[derive(Clone, Default)]
    struct LogBuf(Arc<Mutex<Vec<u8>>>);

    impl std::io::Write for LogBuf {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            lock(&self.0).extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// A process-wide subscriber writing into a buffer. A thread-local
    /// one can miss events whose callsite interest another test thread
    /// already cached, so this test installs a global one, once.
    fn captured_logs() -> LogBuf {
        static LOGS: std::sync::OnceLock<LogBuf> = std::sync::OnceLock::new();
        LOGS.get_or_init(|| {
            let logs = LogBuf::default();
            let sink = logs.clone();
            let subscriber = tracing_subscriber::fmt()
                .with_max_level(tracing::Level::TRACE)
                .with_writer(move || sink.clone())
                .finish();
            tracing::subscriber::set_global_default(subscriber)
                .expect("no other test installs a global subscriber");
            logs
        })
        .clone()
    }

    /// Boots "VMs" whose agent answers `start` with an error carrying a
    /// secret.
    struct ErrorAgentLauncher {
        dir: std::path::PathBuf,
        message: String,
    }

    impl crate::vm::VmLauncher for ErrorAgentLauncher {
        fn launch<'a>(
            &'a self,
            vm: &'a mut crate::vm::Vm,
        ) -> futures::future::BoxFuture<'a, Result<(), crate::vm::VmError>> {
            use crate::vsock::handler::fake_agent::{accept, bind, ready, recv, send};
            Box::pin(async move {
                let listener = bind(&vm.vsock_uds_path);
                let message = self.message.clone();
                tokio::spawn(async move {
                    let mut s = accept(&listener).await;
                    send(&mut s, ready()).await;
                    let _ = recv(&mut s).await;
                    send(
                        &mut s,
                        common::pb::vsock_message::Payload::Error(pb::VsockError {
                            code: "clone_failed".into(),
                            message,
                        }),
                    )
                    .await;
                });
                vm.mark_ready();
                Ok(())
            })
        }

        fn create(&self) -> crate::vm::Vm {
            crate::vm::Vm::in_dir(&self.dir)
        }
    }

    // R06: agent error text reaches the orchestrator, never the logs.
    #[tokio::test]
    async fn agent_error_text_is_not_logged() {
        const SECRET: &str = "https://user:SYNTHETIC_TEST_SECRET@host/r";
        let logs = captured_logs();

        let dir = tempfile::Builder::new()
            .prefix("mne")
            .tempdir_in("/tmp")
            .unwrap();
        let pool = Arc::new(crate::vm::VmPool::new(
            Arc::new(ErrorAgentLauncher {
                dir: dir.path().to_path_buf(),
                message: format!("git clone {SECRET} failed"),
            }),
            crate::vm::PoolConfig {
                total_vm_slots: 2,
                warm_pool_target: 0,
            },
        ));
        let e = TaskExecutor::new(pool, ExecutorSettings::default());
        let id = TaskId::random();
        e.execute_task(pb::ExecuteTask {
            task_id: id.to_hex(),
            ..Default::default()
        })
        .unwrap();
        let r = wait_result(&e).await;
        assert!(!r.success);
        assert!(
            r.error_message.as_deref().unwrap_or("").contains(SECRET),
            "the orchestrator still gets the agent's message"
        );
        let logged = String::from_utf8_lossy(&lock(&logs.0)).into_owned();
        assert!(
            logged.contains("task completed") && logged.contains(&id.to_hex()),
            "logs were not captured"
        );
        assert!(
            !logged.contains("SYNTHETIC_TEST_SECRET"),
            "agent error text reached the logs"
        );
    }
}
