//! Host side of the node ↔ VM agent conversation.
//!
//! The node connects to the VM's Firecracker vsock Unix socket and runs the
//! `CONNECT <port>` handshake (`common::vsock::connect_firecracker`), then
//! exchanges length-prefixed `VsockMessage` frames: the agent sends `ready`,
//! the node sends `start`, the agent streams `output`, `metrics` and
//! `progress`, then one `complete` or `error`. The node may send `cancel`
//! at any time after `start`.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use common::pb::{self, VsockMessage, vsock_message::Payload};
use common::vsock::{FrameError, HandshakeError};
use common::{OutputType, TaskId, UsageMetrics};
use tokio::net::UnixStream;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::metrics;
use crate::task::output_buffer::OutputBuffer;
use crate::trace::TraceContext;

/// Default time limit for one connect + handshake attempt.
pub const DEFAULT_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);

/// One message from the agent.
#[derive(Debug, Clone, PartialEq)]
pub enum VsockEvent {
    Ready {
        vm_id: u32,
    },
    Output {
        output_type: OutputType,
        data: Vec<u8>,
    },
    Metrics(UsageMetrics),
    Complete(pb::VsockComplete),
    Error(pb::VsockError),
}

/// The vsock conversation failed.
#[derive(Debug, thiserror::Error)]
pub enum HandlerError {
    #[error("vsock not connected")]
    NotConnected,
    #[error("vsock connect timed out")]
    ConnectTimeout,
    #[error(transparent)]
    Handshake(#[from] HandshakeError),
    #[error(transparent)]
    Frame(#[from] FrameError),
    #[error("unexpected vsock message from agent: {0}")]
    UnexpectedMessage(&'static str),
}

/// Map a message from the agent to an event. Progress becomes a line of
/// stdout, `Progress: <iteration>/<max> - <status>`.
pub fn event_from_message(msg: VsockMessage) -> Result<VsockEvent, HandlerError> {
    let kind = common::vsock::kind(&msg);
    match msg.payload {
        Some(Payload::Ready(r)) => Ok(VsockEvent::Ready { vm_id: r.vm_id }),
        Some(Payload::Output(o)) => Ok(VsockEvent::Output {
            output_type: OutputType::from_wire(o.r#type),
            data: o.data,
        }),
        Some(Payload::Metrics(m)) => Ok(VsockEvent::Metrics(m.into())),
        Some(Payload::Progress(p)) => Ok(VsockEvent::Output {
            output_type: OutputType::Stdout,
            data: format!(
                "Progress: {}/{} - {}",
                p.iteration, p.max_iterations, p.status
            )
            .into_bytes(),
        }),
        Some(Payload::Complete(c)) => Ok(VsockEvent::Complete(c)),
        Some(Payload::Error(e)) => Ok(VsockEvent::Error(e)),
        Some(Payload::Start(_) | Payload::Cancel(_)) | None => {
            Err(HandlerError::UnexpectedMessage(kind))
        }
    }
}

/// Short name of an event, for logs (never its content).
pub fn event_kind(event: &VsockEvent) -> &'static str {
    match event {
        VsockEvent::Ready { .. } => "ready",
        VsockEvent::Output { .. } => "output",
        VsockEvent::Metrics(_) => "metrics",
        VsockEvent::Complete(_) => "complete",
        VsockEvent::Error(_) => "error",
    }
}

/// A connection to one VM's agent.
#[derive(Debug)]
pub struct VsockHandler {
    uds_path: PathBuf,
    port: u32,
    handshake_timeout: Duration,
    connection: Option<UnixStream>,
}

impl VsockHandler {
    pub fn new(uds_path: impl AsRef<Path>, port: u32) -> Self {
        Self {
            uds_path: uds_path.as_ref().to_path_buf(),
            port,
            handshake_timeout: DEFAULT_HANDSHAKE_TIMEOUT,
            connection: None,
        }
    }

    pub fn with_handshake_timeout(mut self, timeout: Duration) -> Self {
        self.handshake_timeout = timeout;
        self
    }

    pub fn uds_path(&self) -> &Path {
        &self.uds_path
    }

    pub fn port(&self) -> u32 {
        self.port
    }

    pub fn is_connected(&self) -> bool {
        self.connection.is_some()
    }

    /// Connect and complete the Firecracker handshake.
    pub async fn connect(&mut self) -> Result<(), HandlerError> {
        let stream = tokio::time::timeout(
            self.handshake_timeout,
            common::vsock::connect_firecracker(&self.uds_path, self.port),
        )
        .await
        .map_err(|_| HandlerError::ConnectTimeout)??;
        self.connection = Some(stream);
        Ok(())
    }

    pub fn disconnect(&mut self) {
        self.connection = None;
    }

    /// Use an already connected stream (tests).
    pub fn attach(&mut self, stream: UnixStream) {
        self.connection = Some(stream);
    }

    fn conn(&mut self) -> Result<&mut UnixStream, HandlerError> {
        self.connection.as_mut().ok_or(HandlerError::NotConnected)
    }

    async fn send(&mut self, payload: Payload) -> Result<(), HandlerError> {
        let msg = VsockMessage::from(payload);
        common::vsock::write_message(self.conn()?, &msg).await?;
        Ok(())
    }

    pub async fn send_start(&mut self, start: pb::VsockStart) -> Result<(), HandlerError> {
        self.send(Payload::Start(start)).await
    }

    pub async fn send_cancel(&mut self) -> Result<(), HandlerError> {
        self.send(Payload::Cancel(pb::VsockCancel {})).await
    }

    /// Read the next event.
    pub async fn receive(&mut self) -> Result<VsockEvent, HandlerError> {
        let msg = common::vsock::read_message(self.conn()?).await?;
        event_from_message(msg)
    }

    /// Feed events to `callback` until `complete`, `error` or a clean close.
    pub async fn run(&mut self, mut callback: impl FnMut(&VsockEvent)) -> Result<(), HandlerError> {
        loop {
            let event = match self.receive().await {
                Ok(e) => e,
                Err(HandlerError::Frame(FrameError::Closed)) => return Ok(()),
                Err(e) => return Err(e),
            };
            callback(&event);
            if matches!(event, VsockEvent::Complete(_) | VsockEvent::Error(_)) {
                return Ok(());
            }
        }
    }

    fn take_stream(&mut self) -> Option<UnixStream> {
        self.connection.take()
    }
}

/// Outcome of one task on its VM.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskResult {
    pub success: bool,
    pub error_message: Option<String>,
    pub metrics: UsageMetrics,
    pub pr_url: Option<String>,
}

impl TaskResult {
    fn failed(message: impl Into<String>, metrics: UsageMetrics) -> Self {
        Self {
            success: false,
            error_message: Some(message.into()),
            metrics,
            pr_url: None,
        }
    }
}

/// Retry and cancel timing for a task run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RunnerSettings {
    /// Connect attempts before giving up (the agent may still be booting).
    pub connect_attempts: u32,
    pub connect_delay: Duration,
    pub handshake_timeout: Duration,
    /// How long to wait for the agent's `ready` after the handshake.
    pub ready_timeout: Duration,
    /// How long to wait for the agent to answer a cancel.
    pub cancel_grace: Duration,
}

impl Default for RunnerSettings {
    fn default() -> Self {
        Self {
            connect_attempts: 15,
            connect_delay: Duration::from_secs(2),
            handshake_timeout: DEFAULT_HANDSHAKE_TIMEOUT,
            ready_timeout: Duration::from_secs(30),
            cancel_grace: Duration::from_secs(30),
        }
    }
}

/// Error text when the agent does not answer a cancel in time.
pub const CANCEL_UNACKNOWLEDGED: &str = "Task cancelled; agent did not acknowledge";
/// Error text when the agent never sends `ready`.
pub const READY_TIMEOUT: &str = "VM agent did not send ready";
/// Error text when a task is cancelled before it reached the agent.
pub const CANCELLED_BEFORE_START: &str = "Task cancelled before start";
/// Error text for a non-zero agent exit code.
pub const NON_ZERO_EXIT: &str = "Non-zero exit code";

/// Runs one task on one VM.
pub struct TaskRunner {
    handler: VsockHandler,
    task_id: TaskId,
    metrics: UsageMetrics,
    output_buffer: Option<Arc<OutputBuffer>>,
    settings: RunnerSettings,
    trace: TraceContext,
}

impl TaskRunner {
    pub fn new(uds_path: impl AsRef<Path>, port: u32, task_id: TaskId) -> Self {
        Self {
            handler: VsockHandler::new(uds_path, port),
            task_id,
            metrics: UsageMetrics::default(),
            output_buffer: None,
            settings: RunnerSettings::default(),
            trace: TraceContext::new_root(),
        }
    }

    pub fn with_settings(mut self, settings: RunnerSettings) -> Self {
        self.handler = self
            .handler
            .with_handshake_timeout(settings.handshake_timeout);
        self.settings = settings;
        self
    }

    pub fn with_output_buffer(mut self, buffer: Arc<OutputBuffer>) -> Self {
        self.output_buffer = Some(buffer);
        self
    }

    pub fn with_trace(mut self, trace: TraceContext) -> Self {
        self.trace = trace;
        self
    }

    /// Connect, retrying while the agent boots. Returns `Ok(false)` when
    /// cancelled first.
    async fn connect(&mut self, cancel: &CancellationToken) -> Result<bool, HandlerError> {
        let attempts = self.settings.connect_attempts.max(1);
        let mut attempt = 0;
        loop {
            let attempt_result = tokio::select! {
                () = cancel.cancelled() => return Ok(false),
                r = self.handler.connect() => r,
            };
            match attempt_result {
                Ok(()) => return Ok(true),
                Err(e) => {
                    attempt += 1;
                    if attempt >= attempts {
                        tracing::error!(task_id = %self.task_id, attempts, error = %e, "vsock connect failed");
                        return Err(e);
                    }
                    metrics::global().vsock_connect_retries.inc();
                    tracing::warn!(task_id = %self.task_id, attempt, attempts, error = %e, "vsock connect failed, retrying");
                    tokio::select! {
                        () = cancel.cancelled() => return Ok(false),
                        () = tokio::time::sleep(self.settings.connect_delay) => {}
                    }
                }
            }
        }
    }

    /// Run the task: connect, wait for `ready`, send `start`, then follow
    /// the agent until `complete` or `error`. `cancel` sends `VsockCancel`.
    ///
    /// Errors after connecting become a failed [`TaskResult`]; only a
    /// connect that never succeeds is an `Err`.
    pub async fn run(
        &mut self,
        start: pb::VsockStart,
        cancel: CancellationToken,
    ) -> Result<TaskResult, HandlerError> {
        tracing::debug!(task_id = %self.task_id, trace_id = %self.trace.trace_id(), uds = %self.handler.uds_path.display(), "connecting to VM agent");
        if !self.connect(&cancel).await? {
            return Ok(TaskResult::failed(CANCELLED_BEFORE_START, self.metrics));
        }
        let result = self.converse(start, &cancel).await;
        self.handler.disconnect();
        Ok(result)
    }

    async fn converse(&mut self, start: pb::VsockStart, cancel: &CancellationToken) -> TaskResult {
        let Some(stream) = self.handler.take_stream() else {
            return TaskResult::failed(HandlerError::NotConnected.to_string(), self.metrics);
        };
        let (mut reader, mut writer) = stream.into_split();
        // Read frames in their own task: a frame read is not cancel-safe,
        // the channel receive is.
        let (tx, mut rx) = mpsc::channel(64);
        let reader_task = tokio::spawn(async move {
            loop {
                let item = common::vsock::read_message(&mut reader)
                    .await
                    .map_err(HandlerError::from)
                    .and_then(event_from_message);
                let stop = item.is_err();
                if tx.send(item).await.is_err() || stop {
                    return;
                }
            }
        });
        let _abort = AbortOnDrop(reader_task);

        // Wait for `ready`, bounded and cancellable: before `start` the
        // agent has nothing to cancel, so cancelling just stops here.
        let first = tokio::select! {
            biased;
            item = rx.recv() => item,
            () = cancel.cancelled() => {
                tracing::info!(task_id = %self.task_id, "task cancelled before start");
                return TaskResult::failed(CANCELLED_BEFORE_START, self.metrics);
            }
            () = tokio::time::sleep(self.settings.ready_timeout) => {
                tracing::error!(task_id = %self.task_id, "VM agent did not send ready");
                return TaskResult::failed(READY_TIMEOUT, self.metrics);
            }
        };
        match first {
            Some(Ok(VsockEvent::Ready { vm_id })) => {
                tracing::debug!(task_id = %self.task_id, guest_cid = vm_id, "agent ready");
            }
            Some(Ok(other)) => {
                tracing::warn!(task_id = %self.task_id, event = %event_kind(&other), "expected ready from agent");
            }
            Some(Err(e)) => return TaskResult::failed(e.to_string(), self.metrics),
            None => return TaskResult::failed(FrameError::Closed.to_string(), self.metrics),
        }
        if cancel.is_cancelled() {
            return TaskResult::failed(CANCELLED_BEFORE_START, self.metrics);
        }
        let msg = VsockMessage::from(Payload::Start(start));
        if let Err(e) = common::vsock::write_message(&mut writer, &msg).await {
            return TaskResult::failed(e.to_string(), self.metrics);
        }
        tracing::info!(task_id = %self.task_id, trace_id = %self.trace.trace_id(), "task started on VM");

        let mut cancel_deadline: Option<tokio::time::Instant> = None;
        loop {
            tokio::select! {
                biased;
                item = rx.recv() => {
                    let event = match item {
                        Some(Ok(event)) => event,
                        Some(Err(e)) => return TaskResult::failed(e.to_string(), self.metrics),
                        None => return TaskResult::failed(FrameError::Closed.to_string(), self.metrics),
                    };
                    if let Some(result) = self.handle(event) {
                        return result;
                    }
                }
                () = cancel.cancelled(), if cancel_deadline.is_none() => {
                    tracing::info!(task_id = %self.task_id, "cancelling task on VM");
                    let msg = VsockMessage::from(Payload::Cancel(pb::VsockCancel {}));
                    if let Err(e) = common::vsock::write_message(&mut writer, &msg).await {
                        tracing::warn!(task_id = %self.task_id, error = %e, "failed to send cancel to agent");
                    }
                    cancel_deadline = Some(tokio::time::Instant::now() + self.settings.cancel_grace);
                }
                () = sleep_until_opt(cancel_deadline) => {
                    tracing::warn!(task_id = %self.task_id, "agent did not acknowledge cancel");
                    return TaskResult::failed(CANCEL_UNACKNOWLEDGED, self.metrics);
                }
            }
        }
    }

    /// Apply one event; `Some` when the task is finished.
    fn handle(&mut self, event: VsockEvent) -> Option<TaskResult> {
        match event {
            VsockEvent::Ready { .. } => None,
            VsockEvent::Output { output_type, data } => {
                tracing::debug!(task_id = %self.task_id, output_type = ?output_type, bytes = data.len(), "vm output");
                if let Some(buf) = &self.output_buffer {
                    buf.push(&self.task_id, output_type, &data);
                }
                None
            }
            VsockEvent::Metrics(m) => {
                self.metrics.input_tokens = m.input_tokens;
                self.metrics.output_tokens = m.output_tokens;
                self.metrics.cache_read_tokens = m.cache_read_tokens;
                self.metrics.cache_write_tokens = m.cache_write_tokens;
                self.metrics.tool_calls = m.tool_calls;
                None
            }
            VsockEvent::Complete(c) => {
                self.metrics = c.metrics.map(UsageMetrics::from).unwrap_or_default();
                Some(TaskResult {
                    success: c.exit_code == 0,
                    error_message: (c.exit_code != 0).then(|| NON_ZERO_EXIT.to_string()),
                    metrics: self.metrics,
                    pr_url: c.pr_url,
                })
            }
            VsockEvent::Error(e) => {
                // The message goes to the orchestrator in the result; the
                // log keeps only its code and size, as it can echo secrets.
                tracing::warn!(task_id = %self.task_id, code = %e.code, message_bytes = e.message.len(), "agent reported an error");
                Some(TaskResult::failed(e.message, self.metrics))
            }
        }
    }
}

struct AbortOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

async fn sleep_until_opt(deadline: Option<tokio::time::Instant>) {
    match deadline {
        Some(d) => tokio::time::sleep_until(d).await,
        None => std::future::pending().await,
    }
}

#[cfg(test)]
pub(crate) mod fake_agent {
    //! A fake VM agent behind a Firecracker-style vsock Unix socket.

    use std::path::Path;

    use common::pb::{self, VsockMessage, vsock_message::Payload};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{UnixListener, UnixStream};

    /// Accept one connection, answer the `CONNECT` handshake and return the
    /// stream positioned at the first frame.
    pub async fn accept(listener: &UnixListener) -> UnixStream {
        let (mut s, _) = listener.accept().await.unwrap();
        let mut line = Vec::new();
        loop {
            let mut b = [0u8; 1];
            s.read_exact(&mut b).await.unwrap();
            if b[0] == b'\n' {
                break;
            }
            line.push(b[0]);
        }
        assert!(String::from_utf8_lossy(&line).starts_with("CONNECT "));
        s.write_all(b"OK 1073741824\n").await.unwrap();
        s
    }

    pub async fn send(s: &mut UnixStream, payload: Payload) {
        common::vsock::write_message(s, &VsockMessage::from(payload))
            .await
            .unwrap();
    }

    pub async fn recv(s: &mut UnixStream) -> Payload {
        common::vsock::read_message(s)
            .await
            .unwrap()
            .payload
            .unwrap()
    }

    pub fn bind(path: &Path) -> UnixListener {
        UnixListener::bind(path).unwrap()
    }

    pub fn ready() -> Payload {
        Payload::Ready(pb::VsockReady { vm_id: 42 })
    }
}

#[cfg(test)]
mod tests {
    use super::fake_agent::{accept, bind, ready, recv, send};
    use super::*;

    fn fast() -> RunnerSettings {
        RunnerSettings {
            connect_attempts: 3,
            connect_delay: Duration::from_millis(10),
            handshake_timeout: Duration::from_secs(2),
            ready_timeout: Duration::from_secs(2),
            cancel_grace: Duration::from_millis(200),
        }
    }

    fn start_for(task: &TaskId) -> pb::VsockStart {
        pb::VsockStart {
            task_id: task.to_hex(),
            repo_url: "https://github.com/o/r".into(),
            branch: "main".into(),
            prompt: "do it".into(),
            ..Default::default()
        }
    }

    // Port of Zig `test "vsock handler init"`.
    #[test]
    fn vsock_handler_init() {
        let h = VsockHandler::new("/tmp/test-vsock.sock", 9999);
        assert_eq!(h.uds_path(), Path::new("/tmp/test-vsock.sock"));
        assert_eq!(h.port(), 9999);
        assert!(!h.is_connected());
    }

    // Port of Zig `test "vsock stub connection close"`: disconnect drops the
    // connection.
    #[tokio::test]
    async fn disconnect_clears_connection() {
        let (a, _b) = UnixStream::pair().unwrap();
        let mut h = VsockHandler::new("/tmp/test-vsock.sock", 9999);
        h.attach(a);
        assert!(h.is_connected());
        h.disconnect();
        assert!(!h.is_connected());
        h.disconnect();
        assert!(matches!(h.receive().await, Err(HandlerError::NotConnected)));
        assert!(matches!(
            h.send_cancel().await,
            Err(HandlerError::NotConnected)
        ));
    }

    #[test]
    fn progress_becomes_stdout_line() {
        let msg = VsockMessage::from(Payload::Progress(pb::VsockProgress {
            iteration: 2,
            max_iterations: 5,
            status: "running tests".into(),
        }));
        assert_eq!(
            event_from_message(msg).unwrap(),
            VsockEvent::Output {
                output_type: OutputType::Stdout,
                data: b"Progress: 2/5 - running tests".to_vec(),
            }
        );
    }

    #[test]
    fn host_bound_messages_are_unexpected_from_agent() {
        let start = VsockMessage::from(Payload::Start(pb::VsockStart::default()));
        assert!(matches!(
            event_from_message(start),
            Err(HandlerError::UnexpectedMessage("start"))
        ));
        let cancel = VsockMessage::from(Payload::Cancel(pb::VsockCancel {}));
        assert!(matches!(
            event_from_message(cancel),
            Err(HandlerError::UnexpectedMessage("cancel"))
        ));
    }

    #[tokio::test]
    async fn handler_connects_and_runs_until_complete() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.sock");
        let listener = bind(&path);
        let agent = tokio::spawn(async move {
            let mut s = accept(&listener).await;
            send(&mut s, ready()).await;
            send(
                &mut s,
                Payload::Output(pb::VsockOutput {
                    r#type: pb::OutputType::Stderr as i32,
                    data: b"e".to_vec(),
                }),
            )
            .await;
            send(
                &mut s,
                Payload::Complete(pb::VsockComplete {
                    exit_code: 0,
                    ..Default::default()
                }),
            )
            .await;
            // Not read by the handler: it stops at complete.
            send(&mut s, ready()).await;
        });
        let mut h = VsockHandler::new(&path, 9999);
        h.connect().await.unwrap();
        let mut seen = Vec::new();
        h.run(|e| seen.push(e.clone())).await.unwrap();
        agent.await.unwrap();
        assert_eq!(seen.len(), 3);
        assert!(matches!(seen[0], VsockEvent::Ready { vm_id: 42 }));
        assert!(matches!(seen[2], VsockEvent::Complete(_)));
    }

    #[tokio::test]
    async fn runner_full_conversation() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.sock");
        let listener = bind(&path);
        let task = TaskId::random();
        let expected_task = task.to_hex();
        let agent = tokio::spawn(async move {
            let mut s = accept(&listener).await;
            send(&mut s, ready()).await;
            let Payload::Start(start) = recv(&mut s).await else {
                panic!("expected start")
            };
            assert_eq!(start.task_id, expected_task);
            assert_eq!(start.prompt, "do it");
            send(
                &mut s,
                Payload::Output(pb::VsockOutput {
                    r#type: pb::OutputType::Stdout as i32,
                    data: b"hello".to_vec(),
                }),
            )
            .await;
            send(
                &mut s,
                Payload::Progress(pb::VsockProgress {
                    iteration: 1,
                    max_iterations: 3,
                    status: "go".into(),
                }),
            )
            .await;
            send(
                &mut s,
                Payload::Metrics(pb::VsockMetrics {
                    input_tokens: 1,
                    output_tokens: 2,
                    cache_read_tokens: 3,
                    cache_write_tokens: 4,
                    tool_calls: 5,
                }),
            )
            .await;
            send(
                &mut s,
                Payload::Complete(pb::VsockComplete {
                    exit_code: 0,
                    pr_url: Some("https://github.com/o/r/pull/7".into()),
                    metrics: Some(pb::VsockMetrics {
                        input_tokens: 10,
                        output_tokens: 20,
                        cache_read_tokens: 30,
                        cache_write_tokens: 40,
                        tool_calls: 50,
                    }),
                    iteration: 1,
                    promise_found: true,
                }),
            )
            .await;
        });
        let buffer = Arc::new(OutputBuffer::new());
        let mut runner = TaskRunner::new(&path, 9999, task)
            .with_settings(fast())
            .with_output_buffer(buffer.clone());
        let result = runner
            .run(start_for(&task), CancellationToken::new())
            .await
            .unwrap();
        agent.await.unwrap();
        assert_eq!(
            result,
            TaskResult {
                success: true,
                error_message: None,
                metrics: UsageMetrics {
                    compute_time_ms: 0,
                    input_tokens: 10,
                    output_tokens: 20,
                    cache_read_tokens: 30,
                    cache_write_tokens: 40,
                    tool_calls: 50
                },
                pr_url: Some("https://github.com/o/r/pull/7".into()),
            }
        );
        let out = buffer.drain();
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].data, b"hello");
        assert_eq!(out[1].data, b"Progress: 1/3 - go");
        assert!(out.iter().all(|e| e.task_id == task.to_hex()));
    }

    #[tokio::test]
    async fn runner_non_zero_exit_fails() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.sock");
        let listener = bind(&path);
        tokio::spawn(async move {
            let mut s = accept(&listener).await;
            send(&mut s, ready()).await;
            let _ = recv(&mut s).await;
            send(
                &mut s,
                Payload::Metrics(pb::VsockMetrics {
                    input_tokens: 9,
                    ..Default::default()
                }),
            )
            .await;
            send(
                &mut s,
                Payload::Complete(pb::VsockComplete {
                    exit_code: 3,
                    ..Default::default()
                }),
            )
            .await;
        });
        let task = TaskId::random();
        let r = TaskRunner::new(&path, 9999, task)
            .with_settings(fast())
            .run(start_for(&task), CancellationToken::new())
            .await
            .unwrap();
        assert!(!r.success);
        assert_eq!(r.error_message.as_deref(), Some(NON_ZERO_EXIT));
        // Complete without metrics resets them, as in Zig.
        assert_eq!(r.metrics, UsageMetrics::default());
    }

    #[tokio::test]
    async fn runner_agent_error_fails_with_message_and_last_metrics() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.sock");
        let listener = bind(&path);
        tokio::spawn(async move {
            let mut s = accept(&listener).await;
            send(&mut s, ready()).await;
            let _ = recv(&mut s).await;
            send(
                &mut s,
                Payload::Metrics(pb::VsockMetrics {
                    input_tokens: 9,
                    tool_calls: 1,
                    ..Default::default()
                }),
            )
            .await;
            send(
                &mut s,
                Payload::Error(pb::VsockError {
                    code: "clone_failed".into(),
                    message: "git clone failed".into(),
                }),
            )
            .await;
        });
        let task = TaskId::random();
        let r = TaskRunner::new(&path, 9999, task)
            .with_settings(fast())
            .run(start_for(&task), CancellationToken::new())
            .await
            .unwrap();
        assert!(!r.success);
        assert_eq!(r.error_message.as_deref(), Some("git clone failed"));
        assert_eq!(r.metrics.input_tokens, 9);
        assert_eq!(r.metrics.tool_calls, 1);
        assert!(r.pr_url.is_none());
    }

    #[tokio::test]
    async fn runner_agent_closing_early_fails() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.sock");
        let listener = bind(&path);
        tokio::spawn(async move {
            let mut s = accept(&listener).await;
            send(&mut s, ready()).await;
            let _ = recv(&mut s).await;
        });
        let task = TaskId::random();
        let r = TaskRunner::new(&path, 9999, task)
            .with_settings(fast())
            .run(start_for(&task), CancellationToken::new())
            .await
            .unwrap();
        assert!(!r.success);
        assert_eq!(r.error_message.as_deref(), Some("vsock stream closed"));
    }

    #[tokio::test]
    async fn runner_cancel_sends_vsock_cancel() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.sock");
        let listener = bind(&path);
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let mut s = accept(&listener).await;
            send(&mut s, ready()).await;
            let _ = recv(&mut s).await;
            started_tx.send(()).unwrap();
            assert!(matches!(recv(&mut s).await, Payload::Cancel(_)));
            send(
                &mut s,
                Payload::Error(pb::VsockError {
                    code: "cancelled".into(),
                    message: "Task cancelled by user".into(),
                }),
            )
            .await;
        });
        let task = TaskId::random();
        let cancel = CancellationToken::new();
        let c = cancel.clone();
        tokio::spawn(async move {
            started_rx.await.unwrap();
            c.cancel();
        });
        let r = TaskRunner::new(&path, 9999, task)
            .with_settings(fast())
            .run(start_for(&task), cancel)
            .await
            .unwrap();
        assert!(!r.success);
        assert_eq!(r.error_message.as_deref(), Some("Task cancelled by user"));
    }

    #[tokio::test]
    async fn runner_cancel_without_ack_gives_up_after_grace() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.sock");
        let listener = bind(&path);
        tokio::spawn(async move {
            let mut s = accept(&listener).await;
            send(&mut s, ready()).await;
            let _ = recv(&mut s).await;
            let _ = recv(&mut s).await;
            tokio::time::sleep(Duration::from_secs(5)).await;
        });
        let task = TaskId::random();
        let cancel = CancellationToken::new();
        let c = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            c.cancel();
        });
        let r = TaskRunner::new(&path, 9999, task)
            .with_settings(fast())
            .run(start_for(&task), cancel)
            .await
            .unwrap();
        assert_eq!(r.error_message.as_deref(), Some(CANCEL_UNACKNOWLEDGED));
    }

    #[tokio::test]
    async fn runner_retries_connect_until_agent_listens() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.sock");
        let p = path.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(15)).await;
            let listener = bind(&p);
            let mut s = accept(&listener).await;
            send(&mut s, ready()).await;
            let _ = recv(&mut s).await;
            send(&mut s, Payload::Complete(pb::VsockComplete::default())).await;
        });
        let task = TaskId::random();
        let mut settings = fast();
        settings.connect_attempts = 20;
        let r = TaskRunner::new(&path, 9999, task)
            .with_settings(settings)
            .run(start_for(&task), CancellationToken::new())
            .await
            .unwrap();
        assert!(r.success);
    }

    #[tokio::test]
    async fn runner_connect_gives_up_after_attempts() {
        let dir = tempfile::tempdir().unwrap();
        let task = TaskId::random();
        let err = TaskRunner::new(dir.path().join("none.sock"), 9999, task)
            .with_settings(fast())
            .run(start_for(&task), CancellationToken::new())
            .await
            .unwrap_err();
        assert!(
            matches!(err, HandlerError::Handshake(HandshakeError::Io(_))),
            "{err:?}"
        );
    }

    #[tokio::test]
    async fn runner_cancelled_while_connecting() {
        let dir = tempfile::tempdir().unwrap();
        let task = TaskId::random();
        let cancel = CancellationToken::new();
        cancel.cancel();
        let mut settings = fast();
        settings.connect_attempts = 100;
        settings.connect_delay = Duration::from_secs(10);
        let r = TaskRunner::new(dir.path().join("none.sock"), 9999, task)
            .with_settings(settings)
            .run(start_for(&task), cancel)
            .await
            .unwrap();
        assert_eq!(r.error_message.as_deref(), Some(CANCELLED_BEFORE_START));
    }

    #[tokio::test]
    async fn runner_rejected_handshake_is_retried_then_fails() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.sock");
        let listener = bind(&path);
        tokio::spawn(async move {
            loop {
                let (mut s, _) = listener.accept().await.unwrap();
                use tokio::io::AsyncWriteExt;
                let _ = s.write_all(b"FAILURE\n").await;
            }
        });
        let task = TaskId::random();
        let err = TaskRunner::new(&path, 9999, task)
            .with_settings(fast())
            .run(start_for(&task), CancellationToken::new())
            .await
            .unwrap_err();
        assert!(
            matches!(err, HandlerError::Handshake(HandshakeError::Rejected(_))),
            "{err:?}"
        );
    }

    /// An agent that completes the handshake and then stays silent.
    fn silent_after_handshake(path: &Path) -> tokio::sync::oneshot::Receiver<()> {
        let listener = bind(path);
        let (tx, rx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let _s = accept(&listener).await;
            let _ = tx.send(());
            tokio::time::sleep(Duration::from_secs(30)).await;
        });
        rx
    }

    // C-R1-01: cancelling while waiting for `ready` must return promptly.
    #[tokio::test]
    async fn runner_cancel_while_waiting_for_ready() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.sock");
        let handshaken = silent_after_handshake(&path);
        let cancel = CancellationToken::new();
        let c = cancel.clone();
        let task = TaskId::random();
        let mut settings = fast();
        settings.ready_timeout = Duration::from_secs(30);
        let run = tokio::spawn(async move {
            TaskRunner::new(&path, 9999, task)
                .with_settings(settings)
                .run(start_for(&task), c)
                .await
        });
        handshaken.await.unwrap();
        cancel.cancel();
        let r = tokio::time::timeout(Duration::from_millis(500), run)
            .await
            .expect("cancel before ready hangs")
            .unwrap()
            .unwrap();
        assert_eq!(r.error_message.as_deref(), Some(CANCELLED_BEFORE_START));
    }

    #[tokio::test]
    async fn runner_ready_timeout_fails_the_task() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.sock");
        let _handshaken = silent_after_handshake(&path);
        let task = TaskId::random();
        let mut settings = fast();
        settings.ready_timeout = Duration::from_millis(100);
        let r = tokio::time::timeout(
            Duration::from_secs(2),
            TaskRunner::new(&path, 9999, task)
                .with_settings(settings)
                .run(start_for(&task), CancellationToken::new()),
        )
        .await
        .expect("ready wait is unbounded")
        .unwrap();
        assert_eq!(r.error_message.as_deref(), Some(READY_TIMEOUT));
    }

    // Cancel during a handshake the agent never answers.
    #[tokio::test]
    async fn runner_cancel_during_stalled_handshake() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v.sock");
        let listener = bind(&path);
        tokio::spawn(async move {
            let (_s, _) = listener.accept().await.unwrap();
            tokio::time::sleep(Duration::from_secs(30)).await;
        });
        let cancel = CancellationToken::new();
        let c = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            c.cancel();
        });
        let task = TaskId::random();
        let mut settings = fast();
        settings.handshake_timeout = Duration::from_secs(30);
        let r = tokio::time::timeout(
            Duration::from_secs(2),
            TaskRunner::new(&path, 9999, task)
                .with_settings(settings)
                .run(start_for(&task), cancel),
        )
        .await
        .expect("cancel during handshake hangs")
        .unwrap();
        assert_eq!(r.error_message.as_deref(), Some(CANCELLED_BEFORE_START));
    }
}
