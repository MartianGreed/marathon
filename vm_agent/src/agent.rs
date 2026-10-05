//! One-task agent lifecycle and ordered Ralph loop outcomes.

use crate::{
    claude_wrapper::ClaudeWrapper,
    cleanup::Cleanup,
    memory::MemoryManager,
    metrics::Registry,
    prompt_wrapper::{PromptWrapper, extract_repo_name},
    repo_setup::RepoPreparer,
    signal_parser::parse_signals,
    transport::Listener,
};
use common::{
    config::VmAgentConfig,
    pb::{
        VsockComplete, VsockError, VsockMessage, VsockMetrics, VsockProgress, VsockReady,
        VsockStart, vsock_message::Payload,
    },
    telemetry::Operation,
    types::UsageMetrics,
    vsock::{self, FrameError},
};
use std::{
    io,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Instant,
};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::mpsc,
};
use tracing::Instrument;

/// One-task guest service and its injected dependencies.
pub struct Agent<P> {
    /// Immutable guest execution settings.
    pub config: VmAgentConfig,
    /// Repository preparation used before the first iteration.
    pub preparer: P,
    /// Cleanup policy applied after every handled task outcome.
    pub cleanup: Cleanup,
    /// Run Claude as uid/gid 1000 when enabled.
    pub run_as_marathon: bool,
    /// Shared counters and duration observations.
    pub registry: Arc<Registry>,
}

fn connection_failure(error: &FrameError) -> bool {
    matches!(
        error,
        FrameError::Closed | FrameError::Truncated { .. } | FrameError::Io(_)
    )
}

/// Convert cumulative usage to the frozen wire representation.
pub fn wire_metrics(metrics: UsageMetrics) -> VsockMetrics {
    VsockMetrics {
        input_tokens: metrics.input_tokens,
        output_tokens: metrics.output_tokens,
        cache_read_tokens: metrics.cache_read_tokens,
        cache_write_tokens: metrics.cache_write_tokens,
        tool_calls: metrics.tool_calls,
    }
}

async fn send(tx: &mpsc::Sender<VsockMessage>, payload: Payload) -> bool {
    if tx.send(payload.into()).await.is_err() {
        tracing::warn!(operation = "send_frame", "Host writer closed");
        return false;
    }
    true
}

async fn send_error(
    tx: &mpsc::Sender<VsockMessage>,
    registry: &Registry,
    code: &'static str,
    message: String,
) {
    registry.error(code);
    tracing::error!(operation = "task_error", code, %message, "Task failed");
    send(
        tx,
        Payload::Error(VsockError {
            code: code.into(),
            message,
        }),
    )
    .await;
}

async fn read_frames(
    mut reader: impl AsyncRead + Unpin,
    cancelled: Arc<AtomicBool>,
    disconnected: Arc<AtomicBool>,
) {
    loop {
        match vsock::read_message(&mut reader).await {
            Ok(VsockMessage {
                payload: Some(Payload::Cancel(_)),
            }) => {
                cancelled.store(true, Ordering::Release);
            }
            Ok(frame) => {
                tracing::warn!(
                    operation = "read_frame",
                    kind = vsock::kind(&frame),
                    "Ignoring unexpected host frame"
                );
            }
            Err(error) => {
                disconnected.store(true, Ordering::Release);
                tracing::warn!(operation = "read_frame", %error, "Host reader closed");
                break;
            }
        }
    }
}

async fn write_frames(
    mut writer: impl AsyncWrite + Unpin,
    mut rx: mpsc::Receiver<VsockMessage>,
    registry: Arc<Registry>,
    disconnected: Arc<AtomicBool>,
) {
    while let Some(frame) = rx.recv().await {
        match vsock::write_message(&mut writer, &frame).await {
            Ok(()) => registry.frame_sent(&frame),
            Err(error) => {
                disconnected.store(true, Ordering::Release);
                tracing::warn!(operation = "write_frame", %error, "Host connection lost");
                break;
            }
        }
    }
}

impl<P: RepoPreparer> Agent<P> {
    /// Re-listen after probes, run one task, then clean up and return.
    pub async fn serve<L: Listener>(&self, mut listener: L) -> io::Result<()> {
        loop {
            let (mut stream, cid) = listener.accept().await?;
            self.registry
                .connections_accepted
                .fetch_add(1, Ordering::Relaxed);
            let ready: VsockMessage = Payload::Ready(VsockReady { vm_id: cid }).into();
            let handshake = match vsock::write_message(&mut stream, &ready).await {
                Ok(()) => {
                    self.registry.frame_sent(&ready);
                    tracing::info!(operation = "ready", "Agent ready, waiting for task");
                    vsock::read_message(&mut stream).await
                }
                Err(error) => Err(error),
            };
            let task = match handshake {
                Ok(VsockMessage {
                    payload: Some(Payload::Start(task)),
                }) => task,
                other => {
                    self.registry.probe_resets.fetch_add(1, Ordering::Relaxed);
                    let message = match other {
                        Err(error) if connection_failure(&error) => {
                            tracing::warn!(operation = "probe_reset", %error, "connection closed before task (probe?), re-listening");
                            continue;
                        }
                        Err(error) => error.to_string(),
                        Ok(_) => "Expected Start as first host frame".into(),
                    };
                    self.registry.error("protocol_error");
                    tracing::warn!(operation = "protocol_error", %message, "Invalid task handshake, re-listening");
                    let frame = Payload::Error(VsockError {
                        code: "protocol_error".into(),
                        message,
                    })
                    .into();
                    if vsock::write_message(&mut stream, &frame).await.is_ok() {
                        self.registry.frame_sent(&frame);
                    }
                    continue;
                }
            };
            // The frozen vsock schema has no trace context; every task span correlates by task_id.
            let op = Operation::start("task").task_id(&task.task_id);
            self.registry.active_tasks.store(1, Ordering::Relaxed);
            let (reader, writer) = tokio::io::split(stream);
            let (tx, rx) = mpsc::channel(64);
            let disconnected = Arc::new(AtomicBool::new(false));
            let writer_task = tokio::spawn(
                write_frames(writer, rx, self.registry.clone(), disconnected.clone())
                    .instrument(op.span().clone()),
            );
            let cancelled = Arc::new(AtomicBool::new(false));
            let reader_task = tokio::spawn(
                read_frames(reader, cancelled.clone(), disconnected.clone())
                    .instrument(op.span().clone()),
            );
            self.run_task(&task, &tx, &cancelled, &disconnected)
                .instrument(op.span().clone())
                .await;
            reader_task.abort();
            let _ = reader_task.await;
            // Ignore a normal host close after the task ends, while cleanup runs.
            let task_disconnected = disconnected.load(Ordering::Acquire);
            self.cleanup
                .execute(Path::new(&self.config.work_dir), &task.task_id)
                .await;
            drop(tx);
            if task_disconnected {
                writer_task.abort();
            }
            let _ = writer_task.await;
            if task_disconnected {
                self.registry.error("host_disconnected");
                tracing::warn!(
                    operation = "task",
                    code = "host_disconnected",
                    "Host disconnected, stopping task"
                );
            }
            self.registry.active_tasks.store(0, Ordering::Relaxed);
            self.registry.observe("task", op.finish());
            self.registry.summary(&task.task_id);
            return Ok(());
        }
    }

    async fn run_task(
        &self,
        task: &VsockStart,
        tx: &mpsc::Sender<VsockMessage>,
        cancelled: &AtomicBool,
        disconnected: &AtomicBool,
    ) {
        if let Err(error) = self
            .preparer
            .prepare(task, Path::new(&self.config.work_dir))
            .await
        {
            send_error(tx, &self.registry, "setup_failed", error.to_string()).await;
            return;
        }
        let base = PromptWrapper::new(&self.config.prompt_template).wrap(
            &task.prompt,
            extract_repo_name(&task.repo_url),
            &task.branch,
        );
        let memory = MemoryManager::new(&self.config.work_dir);
        let wrapper = ClaudeWrapper::new(
            &self.config.claude_code_path,
            &self.config.work_dir,
            self.run_as_marathon,
        );
        let max = task.max_iterations.unwrap_or(50);
        let mut cumulative = UsageMetrics::default();
        let mut last_output = Vec::new();
        for iteration in 1..=max {
            if cancelled.load(Ordering::Acquire) {
                send_error(
                    tx,
                    &self.registry,
                    "cancelled",
                    "Task cancelled by user".into(),
                )
                .await;
                return;
            }
            let op = Operation::start("iteration").task_id(&task.task_id);
            let outcome = async {
                self.registry.iterations.fetch_add(1, Ordering::Relaxed);
                tracing::info!(
                    iteration,
                    max_iterations = max,
                    operation = "iteration",
                    "Ralph iteration starting"
                );
                let sent = send(
                    tx,
                    Payload::Progress(VsockProgress {
                        iteration,
                        max_iterations: max,
                        status: "running".into(),
                    }),
                )
                .await;
                if !sent || disconnected.load(Ordering::Acquire) {
                    return true;
                }
                let prompt = if iteration == 1 {
                    base.clone()
                } else {
                    memory.build_context_prefix(iteration, &last_output) + &base
                };
                let start = Instant::now();
                let result = wrapper.run(task, &prompt, tx).await;
                self.registry.observe(
                    "claude_run",
                    u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX),
                );
                let result = match result {
                    Ok(result) => result,
                    Err(error) => {
                        send_error(tx, &self.registry, "execution_failed", error.to_string()).await;
                        return true;
                    }
                };
                cumulative.add(&result.metrics);
                memory.log_iteration(iteration, result.exit_code, &result.stdout);
                last_output = result.stdout;
                if disconnected.load(Ordering::Acquire)
                    || !send(tx, Payload::Metrics(wire_metrics(cumulative))).await
                {
                    return true;
                }
                let signals = parse_signals(
                    &String::from_utf8_lossy(&last_output),
                    task.completion_promise.as_deref(),
                );
                let completion = if signals.pr_created {
                    Some((signals.pr_url, true))
                } else if signals.has_completion_promise {
                    Some((result.pr_url, true))
                } else if signals.needs_clarification {
                    send_error(
                        tx,
                        &self.registry,
                        "needs_clarification",
                        format!(
                            "Clarification needed: {}",
                            signals
                                .clarification_question
                                .as_deref()
                                .unwrap_or("Agent needs more information")
                        ),
                    )
                    .await;
                    return true;
                } else if task.completion_promise.is_none() && (max == 1 || result.exit_code == 0) {
                    Some((result.pr_url, result.output_contains_promise))
                } else {
                    None
                };
                if let Some((pr_url, promise_found)) = completion {
                    send(
                        tx,
                        Payload::Complete(VsockComplete {
                            exit_code: result.exit_code,
                            pr_url,
                            metrics: Some(wire_metrics(cumulative)),
                            iteration,
                            promise_found,
                        }),
                    )
                    .await;
                    return true;
                }
                if result.exit_code != 0 {
                    tracing::warn!(
                        operation = "iteration",
                        iteration,
                        exit_code = result.exit_code,
                        "Claude exited non-zero, continuing"
                    );
                }
                false
            }
            .instrument(op.span().clone())
            .await;
            self.registry.observe("iteration", op.finish());
            if outcome {
                return;
            }
        }
        send_error(
            tx,
            &self.registry,
            "max_iterations",
            "Reached iteration limit without completion".into(),
        )
        .await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_repo_name_handles_https_url() {
        assert_eq!(
            extract_repo_name("https://github.com/owner/repo"),
            "owner/repo"
        );
    }

    #[test]
    fn extract_repo_name_handles_https_url_with_git() {
        assert_eq!(
            extract_repo_name("https://github.com/owner/repo.git"),
            "owner/repo"
        );
    }

    #[test]
    fn extract_repo_name_handles_ssh_url() {
        assert_eq!(
            extract_repo_name("git@github.com:owner/repo.git"),
            "owner/repo"
        );
    }

    #[test]
    fn extract_repo_name_handles_short_form() {
        assert_eq!(extract_repo_name("owner/repo"), "owner/repo");
    }

    #[test]
    fn vm_agent() {
        assert_eq!(
            wire_metrics(UsageMetrics::default()),
            VsockMetrics::default()
        );
    }
}
