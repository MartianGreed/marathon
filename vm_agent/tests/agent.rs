//! Host-side framed conversations with real subprocesses and local repo stubs.

use common::{
    config::VmAgentConfig,
    pb::{EnvVar, VsockCancel, VsockMetrics, VsockStart, vsock_message::Payload},
    vsock::{read_message, write_message},
};
use marathon_vm_agent::{
    agent::Agent,
    cleanup::{Cleanup, CleanupStrategy},
    metrics::Registry,
    repo_setup::{RepoPreparer, SetupError},
};
use std::{
    net::SocketAddr,
    os::unix::fs::PermissionsExt,
    path::Path,
    sync::{Arc, atomic::Ordering},
    time::Duration,
};
use tempfile::TempDir;
use tokio::{
    net::{TcpListener, TcpStream},
    task::JoinHandle,
};

struct StubRepo {
    fail: bool,
}

impl RepoPreparer for StubRepo {
    async fn prepare(&self, _: &VsockStart, path: &Path) -> Result<(), SetupError> {
        if self.fail {
            Err(SetupError::GitCloneFailed)
        } else {
            tokio::fs::create_dir_all(path).await?;
            Ok(())
        }
    }
}

struct Running {
    tmp: TempDir,
    address: SocketAddr,
    handle: JoinHandle<std::io::Result<()>>,
    registry: Arc<Registry>,
}

impl Drop for Running {
    fn drop(&mut self) {
        self.handle.abort();
    }
}

async fn launch(script: &str, fail_setup: bool) -> Running {
    launch_with_cleanup(script, fail_setup, CleanupStrategy::None).await
}

async fn launch_with_cleanup(script: &str, fail_setup: bool, strategy: CleanupStrategy) -> Running {
    let tmp = tempfile::tempdir().unwrap();
    let executable = tmp.path().join("claude");
    std::fs::write(&executable, format!("#!/bin/sh\n{script}\n")).unwrap();
    std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::create_dir_all(tmp.path().join("work")).unwrap();
    std::fs::create_dir_all(tmp.path().join("cache")).unwrap();
    std::fs::write(tmp.path().join("credentials"), "fake credential").unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let registry = Arc::new(Registry::default());
    let agent = Agent {
        config: VmAgentConfig {
            claude_code_path: executable.to_string_lossy().into(),
            work_dir: tmp.path().join("work").to_string_lossy().into(),
            cleanup_strategy: "none".into(),
            ..Default::default()
        },
        preparer: StubRepo { fail: fail_setup },
        cleanup: Cleanup {
            strategy,
            cache_path: tmp.path().join("cache"),
            credentials_path: tmp.path().join("credentials"),
        },
        run_as_marathon: false,
        registry: registry.clone(),
    };
    let handle = tokio::spawn(async move { agent.serve(listener).await });
    Running {
        tmp,
        address,
        handle,
        registry,
    }
}

fn start(promise: Option<&str>, max: u32) -> VsockStart {
    VsockStart {
        task_id: "test-task".into(),
        repo_url: "owner/repo".into(),
        branch: "main".into(),
        prompt: "Do the task".into(),
        max_iterations: Some(max),
        completion_promise: promise.map(str::to_owned),
        env_vars: vec![
            EnvVar {
                key: "CUSTOM".into(),
                value: "first".into(),
            },
            EnvVar {
                key: "CUSTOM".into(),
                value: "arrived".into(),
            },
        ],
        ..Default::default()
    }
}

async fn receive(stream: &mut TcpStream) -> Payload {
    tokio::time::timeout(Duration::from_secs(10), read_message(stream))
        .await
        .unwrap()
        .unwrap()
        .payload
        .unwrap()
}

async fn connect(running: &Running) -> TcpStream {
    let mut stream = TcpStream::connect(running.address).await.unwrap();
    assert!(matches!(receive(&mut stream).await, Payload::Ready(r) if r.vm_id == 0));
    stream
}

async fn send_start(stream: &mut TcpStream, task: VsockStart) {
    write_message(stream, &Payload::Start(task).into())
        .await
        .unwrap();
}

async fn terminal(stream: &mut TcpStream) -> (Vec<Payload>, Payload) {
    let mut frames = Vec::new();
    loop {
        let frame = receive(stream).await;
        if matches!(frame, Payload::Complete(_) | Payload::Error(_)) {
            return (frames, frame);
        }
        frames.push(frame);
    }
}

async fn finish(r: &mut Running) {
    tokio::time::timeout(Duration::from_secs(10), &mut r.handle)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(r.registry.active_tasks.load(Ordering::Relaxed), 0);
}

fn totals(input: i64, output: i64, read: i64, write: i64) -> VsockMetrics {
    VsockMetrics {
        input_tokens: input,
        output_tokens: output,
        cache_read_tokens: read,
        cache_write_tokens: write,
        tool_calls: 0,
    }
}

const TWO_ITERATIONS: &str = r#"
n=0
test ! -f counter || n=$(cat counter)
n=$((n+1))
printf '%s' "$n" > counter
printf '%s' "$5" > "prompt-$n"
printf '%s' "$CUSTOM" > "env-$n"
if test "$n" = 1; then
    printf '%s' '{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":10,"cache_creation_input_tokens":5},"result":"working"}'
    printf '%s' 'persistent note' > MEMORY.md
    exit 1
fi
printf '%s' '{"usage":{"input_tokens":200,"output_tokens":80,"cache_read_input_tokens":20,"cache_creation_input_tokens":7},"result":"<promise>DONE</promise>"}'
"#;

#[tokio::test]
async fn probes_ready_start_output_metrics_progress_complete() {
    let mut r = launch(TWO_ITERATIONS, false).await;
    drop(TcpStream::connect(r.address).await.unwrap());
    drop(connect(&r).await);
    let mut stream = connect(&r).await;
    send_start(&mut stream, start(Some("DONE"), 3)).await;
    let (frames, done) = terminal(&mut stream).await;
    let mut pos = 0;
    for (n, expected, text) in [
        (1, totals(100, 50, 10, 5), "working"),
        (2, totals(300, 130, 30, 12), "<promise>DONE</promise>"),
    ] {
        assert!(
            matches!(&frames[pos], Payload::Progress(p) if p.iteration == n && p.max_iterations == 3 && p.status == "running")
        );
        pos += 1;
        let mut output = Vec::new();
        while let Some(Payload::Output(o)) = frames.get(pos) {
            assert!(o.data.len() <= 4096);
            output.extend_from_slice(&o.data);
            pos += 1;
        }
        assert!(String::from_utf8_lossy(&output).contains(text));
        assert!(matches!(&frames[pos], Payload::Metrics(m) if *m == expected));
        pos += 1;
    }
    assert_eq!(pos, frames.len());
    match done {
        Payload::Complete(c) => {
            assert_eq!(c.iteration, 2);
            assert!(c.promise_found);
            assert_eq!(c.metrics, Some(totals(300, 130, 30, 12)));
        }
        other => panic!("Unexpected terminal frame {other:?}"),
    }
    finish(&mut r).await;
    assert_eq!(r.registry.probe_resets.load(Ordering::Relaxed), 2);
    assert_eq!(r.registry.connections_accepted.load(Ordering::Relaxed), 3);
    let work = r.tmp.path().join("work");
    let prompt = std::fs::read_to_string(work.join("prompt-2")).unwrap();
    assert!(prompt.contains("This is iteration 2"));
    assert!(prompt.contains("persistent note"));
    assert!(prompt.ends_with("Do the task"));
    assert_eq!(
        std::fs::read_to_string(work.join("env-1")).unwrap(),
        "arrived"
    );
    assert_eq!(
        std::fs::read_to_string(work.join("env-2")).unwrap(),
        "arrived"
    );
}

async fn run_terminal(script: &str, task: VsockStart, fail: bool) -> (Vec<Payload>, Payload) {
    let mut r = launch(script, fail).await;
    let mut stream = connect(&r).await;
    send_start(&mut stream, task).await;
    let result = terminal(&mut stream).await;
    finish(&mut r).await;
    result
}

fn assert_error(frame: Payload, code: &str, message: &str) {
    assert!(matches!(frame, Payload::Error(e) if e.code == code && e.message == message));
}

#[tokio::test]
async fn clarification() {
    let (_, frame) = run_terminal(
        r#"printf '%s' '<clarification>Which database?</clarification>'"#,
        start(Some("DONE"), 3),
        false,
    )
    .await;
    assert_error(
        frame,
        "needs_clarification",
        "Clarification needed: Which database?",
    );
}

#[tokio::test]
async fn pr_url_completes() {
    let (_, frame) = run_terminal(
        r#"printf '%s' 'Created PR: https://github.com/o/r/pull/42'"#,
        start(Some("DONE"), 3),
        false,
    )
    .await;
    assert!(
        matches!(frame, Payload::Complete(c) if c.pr_url.as_deref() == Some("https://github.com/o/r/pull/42") && c.promise_found && c.iteration == 1)
    );
}

#[tokio::test]
async fn max_iterations_exhausted() {
    let (frames, frame) = run_terminal(
        r#"printf '%s' '{"usage":{"input_tokens":3}}'; exit 1"#,
        start(Some("DONE"), 2),
        false,
    )
    .await;
    assert_error(
        frame,
        "max_iterations",
        "Reached iteration limit without completion",
    );
    assert_eq!(
        frames
            .iter()
            .filter(|f| matches!(f, Payload::Progress(_)))
            .count(),
        2
    );
    assert!(matches!(frames.last(), Some(Payload::Metrics(m)) if m.input_tokens == 6));
}

#[tokio::test]
async fn setup_failure() {
    let (frames, frame) = run_terminal("exit 0", start(None, 1), true).await;
    assert!(frames.is_empty());
    assert_error(frame, "setup_failed", "GitCloneFailed");
}

#[tokio::test]
async fn single_iteration_completes_even_nonzero() {
    let (_, frame) = run_terminal(
        r#"printf '%s' '{"usage":{"input_tokens":9}}'; exit 7"#,
        start(None, 1),
        false,
    )
    .await;
    assert!(
        matches!(frame, Payload::Complete(c) if c.iteration == 1 && !c.promise_found && c.exit_code == 7 && c.metrics.unwrap().input_tokens == 9)
    );
}

#[tokio::test]
async fn exit_zero_iteration_two_has_cumulative_metrics() {
    let script = TWO_ITERATIONS.replace("<promise>DONE</promise>", "finished");
    let (frames, frame) = run_terminal(&script, start(None, 3), false).await;
    assert!(matches!(frames.last(), Some(Payload::Metrics(m)) if *m == totals(300,130,30,12)));
    assert!(
        matches!(frame, Payload::Complete(c) if c.iteration == 2 && !c.promise_found && c.metrics == Some(totals(300,130,30,12)))
    );
}

#[tokio::test]
async fn cancel_before_iteration_two() {
    // Claude waits for a host-created file, making cancellation delivery deterministic.
    let mut r = launch(
        r#"printf '%s' 'iteration started'; while test ! -f release; do sleep 0.01; done; exit 1"#,
        false,
    )
    .await;
    let mut stream = connect(&r).await;
    send_start(&mut stream, start(Some("DONE"), 3)).await;
    assert!(matches!(receive(&mut stream).await, Payload::Progress(p) if p.iteration == 1));
    assert!(matches!(receive(&mut stream).await, Payload::Output(_)));
    write_message(&mut stream, &Payload::Cancel(VsockCancel {}).into())
        .await
        .unwrap();
    // Reader processes Cancel while the child is still in its first iteration.
    tokio::time::sleep(Duration::from_millis(50)).await;
    std::fs::write(r.tmp.path().join("work/release"), "").unwrap();
    let (frames, frame) = terminal(&mut stream).await;
    assert_error(frame, "cancelled", "Task cancelled by user");
    assert!(!frames.iter().any(|f| matches!(f, Payload::Progress(_))));
    assert!(frames.iter().any(|f| matches!(f, Payload::Metrics(_))));
    finish(&mut r).await;
}

#[tokio::test]
async fn protocol_error_before_start_relistens() {
    use tokio::io::AsyncWriteExt;
    let mut r = launch("exit 0", false).await;
    let mut stream = connect(&r).await;
    write_message(&mut stream, &Payload::Cancel(VsockCancel {}).into())
        .await
        .unwrap();
    assert!(matches!(receive(&mut stream).await, Payload::Error(e) if e.code == "protocol_error"));
    drop(stream);
    for bytes in [
        vec![0, 0, 0, 0],
        vec![0, 0, 0, 1, 0xff],
        (common::vsock::MAX_FRAME_LEN as u32 + 1)
            .to_be_bytes()
            .to_vec(),
    ] {
        let mut s = connect(&r).await;
        s.write_all(&bytes).await.unwrap();
        assert!(matches!(receive(&mut s).await, Payload::Error(e) if e.code == "protocol_error"));
    }
    let mut stream = connect(&r).await;
    send_start(&mut stream, start(None, 1)).await;
    assert!(matches!(
        terminal(&mut stream).await.1,
        Payload::Complete(_)
    ));
    finish(&mut r).await;
    assert_eq!(r.registry.probe_resets.load(Ordering::Relaxed), 4);
}

#[tokio::test]
async fn truncated_probe_relistens() {
    use tokio::io::AsyncWriteExt;
    let mut r = launch("exit 0", false).await;
    for bytes in [vec![0, 0], vec![0, 0, 0, 5, 1]] {
        let mut s = connect(&r).await;
        s.write_all(&bytes).await.unwrap();
        s.shutdown().await.unwrap();
        drop(s);
    }
    let mut s = connect(&r).await;
    send_start(&mut s, start(None, 1)).await;
    assert!(matches!(terminal(&mut s).await.1, Payload::Complete(_)));
    finish(&mut r).await;
    assert_eq!(r.registry.probe_resets.load(Ordering::Relaxed), 2);
}

#[tokio::test]
async fn execution_failure_and_cleanup() {
    let mut r = launch("exit 0", false).await;
    std::fs::remove_file(r.tmp.path().join("claude")).unwrap();
    let mut s = connect(&r).await;
    send_start(&mut s, start(None, 1)).await;
    assert!(matches!(terminal(&mut s).await.1,Payload::Error(e) if e.code == "execution_failed"));
    finish(&mut r).await;
}

#[tokio::test]
async fn cleanup_runs_on_setup_failure_and_success() {
    for fail in [false, true] {
        let mut r = launch_with_cleanup("exit 0", fail, CleanupStrategy::Full).await;
        let mut stream = connect(&r).await;
        send_start(&mut stream, start(None, 1)).await;
        let _ = terminal(&mut stream).await;
        finish(&mut r).await;
        for path in ["work", "cache", "credentials"] {
            assert!(!r.tmp.path().join(path).exists());
        }
    }
}

#[tokio::test]
async fn stderr_is_streamed_and_ignored_in_metrics() {
    let script = r#"printf '%s' '{"usage":{"input_tokens":5}}'; printf '%s' 'stderr output' >&2"#;
    let (frames, frame) = run_terminal(script, start(None, 1), false).await;
    assert!(frames.iter().any(|f| matches!(f, Payload::Output(o) if o.r#type == common::pb::OutputType::Stderr as i32 && o.data == b"stderr output")));
    assert!(matches!(frame, Payload::Complete(c) if c.metrics == Some(totals(5,0,0,0))));
}

#[tokio::test]
async fn ready_broken_pipe_and_start_connection_reset_relisten() {
    use marathon_vm_agent::transport::Listener;
    use std::{
        collections::VecDeque,
        io,
        pin::Pin,
        task::{Context, Poll},
    };
    use tokio::io::{AsyncRead, AsyncWrite, DuplexStream, ReadBuf};

    enum TestStream {
        Fault { write_fails: bool },
        Duplex(DuplexStream),
    }

    impl AsyncRead for TestStream {
        fn poll_read(
            self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            match self.get_mut() {
                Self::Fault { .. } => Poll::Ready(Err(io::ErrorKind::ConnectionReset.into())),
                Self::Duplex(s) => Pin::new(s).poll_read(cx, buf),
            }
        }
    }

    impl AsyncWrite for TestStream {
        fn poll_write(
            self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &[u8],
        ) -> Poll<io::Result<usize>> {
            match self.get_mut() {
                Self::Fault { write_fails: true } => {
                    Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()))
                }
                Self::Fault { write_fails: false } => Poll::Ready(Ok(buf.len())),
                Self::Duplex(s) => Pin::new(s).poll_write(cx, buf),
            }
        }

        fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            match self.get_mut() {
                Self::Duplex(s) => Pin::new(s).poll_flush(cx),
                _ => Poll::Ready(Ok(())),
            }
        }

        fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            match self.get_mut() {
                Self::Duplex(s) => Pin::new(s).poll_shutdown(cx),
                _ => Poll::Ready(Ok(())),
            }
        }
    }

    struct QueueListener(VecDeque<TestStream>);

    impl Listener for QueueListener {
        type Stream = TestStream;

        async fn accept(&mut self) -> io::Result<(TestStream, u32)> {
            self.0
                .pop_front()
                .map(|s| (s, 123))
                .ok_or_else(|| io::Error::other("No more connections"))
        }
    }
    let tmp = tempfile::tempdir().unwrap();
    let registry = Arc::new(Registry::default());
    let agent = Agent {
        config: VmAgentConfig {
            claude_code_path: "/usr/bin/env".into(),
            work_dir: tmp.path().to_string_lossy().into(),
            ..Default::default()
        },
        preparer: StubRepo { fail: false },
        cleanup: Cleanup::new(CleanupStrategy::None),
        run_as_marathon: false,
        registry: registry.clone(),
    };
    let (guest, mut host) = tokio::io::duplex(16384);
    let listener = QueueListener(VecDeque::from([
        TestStream::Fault { write_fails: true },
        TestStream::Fault { write_fails: false },
        TestStream::Duplex(guest),
    ]));
    let handle = tokio::spawn(async move { agent.serve(listener).await });
    let ready = read_message(&mut host).await.unwrap();
    assert!(matches!(ready.payload, Some(Payload::Ready(r)) if r.vm_id == 123));
    write_message(&mut host, &Payload::Start(start(None, 1)).into())
        .await
        .unwrap();
    loop {
        let frame = read_message(&mut host).await.unwrap();
        if matches!(frame.payload, Some(Payload::Complete(_))) {
            break;
        }
    }
    handle.await.unwrap().unwrap();
    assert_eq!(registry.probe_resets.load(Ordering::Relaxed), 2);
    assert_eq!(registry.connections_accepted.load(Ordering::Relaxed), 3);
}
