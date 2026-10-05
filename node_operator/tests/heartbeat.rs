//! Drives the real heartbeat client, executor and pool against an
//! in-process fake orchestrator (`NodeService` over gRPC on 127.0.0.1) and
//! fake VM agents behind Firecracker-style vsock Unix sockets.
//!
//! The listener port is `MARATHON_NODE_TEST_PORT` when set (the wave
//! reserves 65442 for the implementer and 65443 for the verifier) and an
//! ephemeral port otherwise.

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::config::NodeOperatorConfig;
use common::pb::{
    self, node_command::Command, node_service_server::NodeService,
    node_service_server::NodeServiceServer, vsock_message::Payload,
};
use common::{NodeId, TaskId};
use futures::future::BoxFuture;
use node_operator::heartbeat::{HeartbeatClient, HeartbeatSettings};
use node_operator::task::executor::{ExecutorSettings, TaskExecutor};
use node_operator::vm::{PoolConfig, Vm, VmError, VmLauncher, VmPool};
use node_operator::vsock::handler::RunnerSettings;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, UnixListener, UnixStream};
use tokio::sync::mpsc;
use tokio_stream::wrappers::{ReceiverStream, TcpListenerStream};
use tonic::{Request, Response, Status, Streaming};

const KEY: &[u8] = b"wave-test-node-key";
const WAIT: Duration = Duration::from_secs(15);

#[derive(Debug, Clone)]
enum Event {
    Heartbeat {
        stream: usize,
        node_id: NodeId,
        status: pb::NodeStatus,
        traceparent: Option<String>,
    },
    Rejected {
        stream: usize,
    },
    Results(Vec<pb::TaskResult>),
    Output(Vec<pb::TaskOutputEvent>),
    ReportRejected,
    AgentStart(pb::VsockStart),
    AgentCancel(String),
}

type Log = Arc<Mutex<Vec<Event>>>;

#[derive(Clone)]
struct FakeOrchestrator {
    key: Option<Vec<u8>>,
    log: Log,
    commands: Arc<Mutex<VecDeque<pb::NodeCommand>>>,
    end_stream: Arc<AtomicBool>,
    streams: Arc<AtomicUsize>,
}

impl FakeOrchestrator {
    fn new(key: Option<&[u8]>, log: Log) -> Self {
        Self {
            key: key.map(<[u8]>::to_vec),
            log,
            commands: Arc::default(),
            end_stream: Arc::default(),
            streams: Arc::default(),
        }
    }

    fn push(&self, command: Command) {
        self.commands.lock().unwrap().push_back(pb::NodeCommand {
            command: Some(command),
        });
    }

    fn verify(&self, auth: Option<&pb::NodeAuth>) -> Result<NodeId, Status> {
        match &self.key {
            Some(key) => common::node_auth::verify_node_auth(key, auth, common::types::now_ms())
                .map_err(|e| Status::unauthenticated(e.to_string())),
            None => NodeId::parse(
                &auth
                    .ok_or_else(|| Status::unauthenticated("no auth"))?
                    .node_id,
            )
            .map_err(|e| Status::invalid_argument(e.to_string())),
        }
    }
}

#[tonic::async_trait]
impl NodeService for FakeOrchestrator {
    type HeartbeatStream = ReceiverStream<Result<pb::HeartbeatResponse, Status>>;

    async fn heartbeat(
        &self,
        request: Request<Streaming<pb::NodeHeartbeat>>,
    ) -> Result<Response<Self::HeartbeatStream>, Status> {
        let traceparent = request
            .metadata()
            .get("traceparent")
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        let stream = self.streams.fetch_add(1, Ordering::SeqCst) + 1;
        let mut inbound = request.into_inner();
        let (tx, rx) = mpsc::channel(16);
        let this = self.clone();
        tokio::spawn(async move {
            while let Ok(Some(hb)) = inbound.message().await {
                let node_id = match this.verify(hb.auth.as_ref()) {
                    Ok(id) => id,
                    Err(status) => {
                        this.log.lock().unwrap().push(Event::Rejected { stream });
                        let _ = tx.send(Err(status)).await;
                        return;
                    }
                };
                this.log.lock().unwrap().push(Event::Heartbeat {
                    stream,
                    node_id,
                    status: hb.status.unwrap_or_default(),
                    traceparent: traceparent.clone(),
                });
                if this.end_stream.swap(false, Ordering::SeqCst) {
                    // Dropping the sender ends the response stream.
                    return;
                }
                let commands = this.commands.lock().unwrap().drain(..).collect();
                let resp = pb::HeartbeatResponse {
                    timestamp: common::types::now_ms(),
                    acknowledged: true,
                    commands,
                };
                if tx.send(Ok(resp)).await.is_err() {
                    return;
                }
            }
        });
        Ok(Response::new(ReceiverStream::new(rx)))
    }

    async fn report_task_result(
        &self,
        request: Request<pb::ReportTaskResultRequest>,
    ) -> Result<Response<pb::ReportTaskResultResponse>, Status> {
        let req = request.into_inner();
        if let Err(s) = self.verify(req.auth.as_ref()) {
            self.log.lock().unwrap().push(Event::ReportRejected);
            return Err(s);
        }
        self.log.lock().unwrap().push(Event::Results(req.results));
        Ok(Response::new(pb::ReportTaskResultResponse {}))
    }

    async fn report_task_output(
        &self,
        request: Request<pb::ReportTaskOutputRequest>,
    ) -> Result<Response<pb::ReportTaskOutputResponse>, Status> {
        let req = request.into_inner();
        if let Err(s) = self.verify(req.auth.as_ref()) {
            self.log.lock().unwrap().push(Event::ReportRejected);
            return Err(s);
        }
        self.log.lock().unwrap().push(Event::Output(req.events));
        Ok(Response::new(pb::ReportTaskOutputResponse {}))
    }
}

fn serve(listener: TcpListener, svc: FakeOrchestrator) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let _ = tonic::transport::Server::builder()
            .add_service(NodeServiceServer::new(svc))
            .serve_with_incoming(TcpListenerStream::new(listener))
            .await;
    })
}

async fn bind(port_env: bool) -> TcpListener {
    let port = if port_env {
        std::env::var("MARATHON_NODE_TEST_PORT")
            .ok()
            .and_then(|p| p.parse::<u16>().ok())
            .unwrap_or(0)
    } else {
        0
    };
    TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], port)))
        .await
        .unwrap()
}

/// Boots "VMs" whose vsock socket is a fake agent.
struct FakeAgentLauncher {
    dir: PathBuf,
    log: Log,
}

impl VmLauncher for FakeAgentLauncher {
    fn launch<'a>(&'a self, vm: &'a mut Vm) -> BoxFuture<'a, Result<(), VmError>> {
        Box::pin(async move {
            let listener = UnixListener::bind(&vm.vsock_uds_path)
                .map_err(|e| VmError::Launch(e.to_string()))?;
            let log = self.log.clone();
            tokio::spawn(async move {
                if let Ok((stream, _)) = listener.accept().await {
                    fake_agent(stream, log).await;
                }
            });
            vm.mark_ready();
            Ok(())
        })
    }

    fn create(&self) -> Vm {
        Vm::in_dir(&self.dir)
    }
}

async fn send(s: &mut UnixStream, payload: Payload) {
    common::vsock::write_message(s, &pb::VsockMessage::from(payload))
        .await
        .unwrap();
}

async fn recv(s: &mut UnixStream) -> Payload {
    common::vsock::read_message(s)
        .await
        .unwrap()
        .payload
        .unwrap()
}

/// The agent: handshake, ready, then complete, or wait for cancel when the
/// prompt is `wait-for-cancel`.
async fn fake_agent(mut s: UnixStream, log: Log) {
    let mut line = Vec::new();
    loop {
        let mut b = [0u8; 1];
        s.read_exact(&mut b).await.unwrap();
        if b[0] == b'\n' {
            break;
        }
        line.push(b[0]);
    }
    assert_eq!(String::from_utf8_lossy(&line), "CONNECT 9999");
    s.write_all(b"OK 1073741824\n").await.unwrap();
    send(&mut s, Payload::Ready(pb::VsockReady { vm_id: 3 })).await;
    let Payload::Start(start) = recv(&mut s).await else {
        panic!("expected start");
    };
    log.lock().unwrap().push(Event::AgentStart(start.clone()));
    send(
        &mut s,
        Payload::Output(pb::VsockOutput {
            r#type: pb::OutputType::Stdout as i32,
            data: format!("hello from {}", start.task_id).into_bytes(),
        }),
    )
    .await;
    if start.prompt == "wait-for-cancel" {
        assert!(matches!(recv(&mut s).await, Payload::Cancel(_)));
        log.lock().unwrap().push(Event::AgentCancel(start.task_id));
        send(
            &mut s,
            Payload::Error(pb::VsockError {
                code: "cancelled".into(),
                message: "Task cancelled by user".into(),
            }),
        )
        .await;
    } else {
        send(
            &mut s,
            Payload::Complete(pb::VsockComplete {
                exit_code: 0,
                pr_url: Some("https://github.com/o/r/pull/1".into()),
                metrics: Some(pb::VsockMetrics {
                    input_tokens: 11,
                    output_tokens: 22,
                    ..Default::default()
                }),
                iteration: 1,
                promise_found: false,
            }),
        )
        .await;
    }
}

struct Node {
    client: Arc<HeartbeatClient>,
    executor: Arc<TaskExecutor>,
    task: tokio::task::JoinHandle<()>,
    _dir: tempfile::TempDir,
}

impl Node {
    async fn stop(self) {
        self.client.stop();
        tokio::time::timeout(WAIT, self.task)
            .await
            .unwrap()
            .unwrap();
    }
}

fn start_node(port: u16, key: Option<&str>, log: &Log) -> Node {
    // Short path: macOS limits Unix socket paths to 104 bytes.
    let dir = tempfile::Builder::new()
        .prefix("mnt")
        .tempdir_in("/tmp")
        .unwrap();
    let launcher = Arc::new(FakeAgentLauncher {
        dir: dir.path().to_path_buf(),
        log: log.clone(),
    });
    let pool = Arc::new(VmPool::new(
        launcher,
        PoolConfig {
            total_vm_slots: 4,
            warm_pool_target: 0,
        },
    ));
    let executor = TaskExecutor::new(
        pool,
        ExecutorSettings {
            vsock_port: 9999,
            runner: RunnerSettings {
                connect_attempts: 5,
                connect_delay: Duration::from_millis(20),
                handshake_timeout: Duration::from_secs(2),
                cancel_grace: Duration::from_secs(5),
            },
        },
    );
    let config = NodeOperatorConfig {
        orchestrator_address: "127.0.0.1".into(),
        orchestrator_port: port,
        auth_key: key.map(str::to_string),
        hostname: Some("test-node".into()),
        ..NodeOperatorConfig::default()
    };
    let settings = HeartbeatSettings {
        interval: Duration::from_millis(50),
        active_interval_cap: Duration::from_millis(50),
        backoff_initial: Duration::from_millis(50),
        backoff_max: Duration::from_millis(200),
        connect_timeout: Duration::from_secs(2),
        rpc_timeout: Duration::from_secs(2),
    };
    let client = Arc::new(HeartbeatClient::new(&config, executor.clone(), settings));
    let runner = client.clone();
    let task = tokio::spawn(async move { runner.run().await });
    Node {
        client,
        executor,
        task,
        _dir: dir,
    }
}

async fn wait_for<T>(log: &Log, what: &str, mut find: impl FnMut(&[Event]) -> Option<T>) -> T {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        if let Some(t) = find(&log.lock().unwrap()) {
            return t;
        }
        if tokio::time::Instant::now() > deadline {
            panic!(
                "timed out waiting for {what}; log: {:#?}",
                log.lock().unwrap()
            );
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

fn result_for(events: &[Event], task: &TaskId) -> Option<pb::TaskResult> {
    events.iter().find_map(|e| match e {
        Event::Results(rs) => rs.iter().find(|r| r.task_id == task.to_hex()).cloned(),
        _ => None,
    })
}

fn execute(task: &TaskId, prompt: &str) -> Command {
    Command::ExecuteTask(pb::ExecuteTask {
        task_id: task.to_hex(),
        repo_url: "https://github.com/o/r".into(),
        branch: "main".into(),
        prompt: prompt.into(),
        github_token: "ghp_test".into(),
        anthropic_api_key: "sk-test".into(),
        env_vars: vec![pb::EnvVar {
            key: "A".into(),
            value: "1".into(),
        }],
        ..Default::default()
    })
}

#[tokio::test]
async fn registers_executes_cancels_and_reconnects() {
    let log: Log = Arc::default();
    let listener = bind(true).await;
    let port = listener.local_addr().unwrap().port();
    let orch = FakeOrchestrator::new(Some(KEY), log.clone());
    let server = serve(listener, orch.clone());
    let node = start_node(port, Some(std::str::from_utf8(KEY).unwrap()), &log);
    let node_id = node.client.node_id();

    // Registration: the first heartbeat arrives on stream 1 with a token
    // the orchestrator verifies, from this node, with trace context.
    let (status, traceparent) = wait_for(&log, "registration", |ev| {
        ev.iter().find_map(|e| match e {
            Event::Heartbeat {
                stream: 1,
                node_id: id,
                status,
                traceparent,
            } if *id == node_id => Some((status.clone(), traceparent.clone())),
            _ => None,
        })
    })
    .await;
    assert_eq!(status.hostname, "test-node");
    assert_eq!(status.total_vm_slots, 4);
    assert!(status.healthy);
    let tp = traceparent.expect("heartbeat stream carries traceparent");
    assert!(
        node_operator::trace::TraceContext::parse(&tp).is_some(),
        "{tp}"
    );

    // Execute reaches the executor and the VM agent, then output and the
    // result are reported.
    let task_a = TaskId::random();
    orch.push(execute(&task_a, "complete"));
    let start = wait_for(&log, "agent start A", |ev| {
        ev.iter().find_map(|e| match e {
            Event::AgentStart(s) if s.task_id == task_a.to_hex() => Some(s.clone()),
            _ => None,
        })
    })
    .await;
    assert_eq!(start.prompt, "complete");
    assert_eq!(start.github_token, "ghp_test");
    assert_eq!(start.anthropic_api_key, "sk-test");
    assert_eq!(start.env_vars.len(), 1);
    let result = wait_for(&log, "result A", |ev| result_for(ev, &task_a)).await;
    assert!(result.success, "{result:?}");
    assert_eq!(
        result.pr_url.as_deref(),
        Some("https://github.com/o/r/pull/1")
    );
    assert_eq!(result.metrics.unwrap().input_tokens, 11);
    let expected_output = format!("hello from {}", task_a.to_hex()).into_bytes();
    wait_for(&log, "output A", |ev| {
        ev.iter()
            .any(|e| matches!(e, Event::Output(o) if o.iter().any(|x| x.data == expected_output && x.task_id == task_a.to_hex())))
            .then_some(())
    })
    .await;

    // Cancel: the agent receives VsockCancel and its error becomes the
    // failed result.
    let task_b = TaskId::random();
    orch.push(execute(&task_b, "wait-for-cancel"));
    wait_for(&log, "agent start B", |ev| {
        ev.iter()
            .any(|e| matches!(e, Event::AgentStart(s) if s.task_id == task_b.to_hex()))
            .then_some(())
    })
    .await;
    // While B runs, heartbeats list it as active.
    wait_for(&log, "B in active_task_ids", |ev| {
        ev.iter()
            .any(|e| matches!(e, Event::Heartbeat { status, .. } if status.active_task_ids.contains(&task_b.to_hex()) && status.active_vms == 1))
            .then_some(())
    })
    .await;
    orch.push(Command::CancelTask(pb::CancelTask {
        task_id: task_b.to_hex(),
    }));
    wait_for(&log, "agent cancel B", |ev| {
        ev.iter()
            .any(|e| matches!(e, Event::AgentCancel(id) if *id == task_b.to_hex()))
            .then_some(())
    })
    .await;
    let result = wait_for(&log, "result B", |ev| result_for(ev, &task_b)).await;
    assert!(!result.success);
    assert_eq!(
        result.error_message.as_deref(),
        Some("Task cancelled by user")
    );
    // Used VMs are destroyed (target 0, so nothing is replenished).
    let pool = node.executor.pool().clone();
    wait_for(&log, "used VMs destroyed", |_| {
        (pool.total_count() == 0).then_some(())
    })
    .await;

    // Reconnect: the orchestrator drops the stream; the node opens a new
    // one and keeps heartbeating.
    orch.end_stream.store(true, Ordering::SeqCst);
    wait_for(&log, "heartbeat on stream 2", |ev| {
        ev.iter()
            .any(|e| matches!(e, Event::Heartbeat { stream: 2, node_id: id, .. } if *id == node_id))
            .then_some(())
    })
    .await;
    // Work still flows on the new stream.
    let task_c = TaskId::random();
    orch.push(execute(&task_c, "complete"));
    let result = wait_for(&log, "result C", |ev| result_for(ev, &task_c)).await;
    assert!(result.success);

    assert!(
        !log.lock()
            .unwrap()
            .iter()
            .any(|e| matches!(e, Event::Rejected { .. } | Event::ReportRejected)),
        "no message was rejected"
    );
    node.stop().await;
    server.abort();
}

#[tokio::test]
async fn wrong_key_is_rejected_and_node_keeps_retrying() {
    let log: Log = Arc::default();
    let listener = bind(false).await;
    let port = listener.local_addr().unwrap().port();
    let orch = FakeOrchestrator::new(Some(KEY), log.clone());
    let server = serve(listener, orch.clone());
    let node = start_node(port, Some("not-the-key"), &log);

    // Rejected on two separate streams: the node reconnected after the
    // first rejection.
    wait_for(&log, "two rejected streams", |ev| {
        let mut streams: Vec<usize> = ev
            .iter()
            .filter_map(|e| match e {
                Event::Rejected { stream } => Some(*stream),
                _ => None,
            })
            .collect();
        streams.dedup();
        (streams.len() >= 2).then_some(())
    })
    .await;
    assert!(
        !log.lock()
            .unwrap()
            .iter()
            .any(|e| matches!(e, Event::Heartbeat { .. })),
        "a heartbeat with a wrong token was accepted"
    );
    assert!(node.client.is_running());
    node.stop().await;
    server.abort();
}

#[tokio::test]
async fn missing_key_sends_empty_token_rejected_by_keyed_orchestrator() {
    let log: Log = Arc::default();
    let listener = bind(false).await;
    let port = listener.local_addr().unwrap().port();
    let server = serve(listener, FakeOrchestrator::new(Some(KEY), log.clone()));
    let node = start_node(port, None, &log);
    wait_for(&log, "rejection", |ev| {
        ev.iter()
            .any(|e| matches!(e, Event::Rejected { .. }))
            .then_some(())
    })
    .await;
    node.stop().await;
    server.abort();
}

#[tokio::test]
async fn unkeyed_orchestrator_accepts_unkeyed_node() {
    let log: Log = Arc::default();
    let listener = bind(false).await;
    let port = listener.local_addr().unwrap().port();
    let server = serve(listener, FakeOrchestrator::new(None, log.clone()));
    let node = start_node(port, None, &log);
    let id = node.client.node_id();
    wait_for(&log, "heartbeat", |ev| {
        ev.iter()
            .any(|e| matches!(e, Event::Heartbeat { node_id, .. } if *node_id == id))
            .then_some(())
    })
    .await;
    node.stop().await;
    server.abort();
}

#[tokio::test]
async fn connects_when_orchestrator_comes_up_late() {
    let log: Log = Arc::default();
    // Learn a free port, release it, start the node against it.
    let port = {
        let l = bind(false).await;
        l.local_addr().unwrap().port()
    };
    let node = start_node(port, Some(std::str::from_utf8(KEY).unwrap()), &log);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(log.lock().unwrap().is_empty());
    let listener = TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], port)))
        .await
        .unwrap();
    let server = serve(listener, FakeOrchestrator::new(Some(KEY), log.clone()));
    wait_for(&log, "late registration", |ev| {
        ev.iter()
            .any(|e| matches!(e, Event::Heartbeat { .. }))
            .then_some(())
    })
    .await;
    node.stop().await;
    server.abort();
}

#[tokio::test]
async fn drain_rejects_new_tasks_and_warm_pool_boots_vms() {
    let log: Log = Arc::default();
    let listener = bind(false).await;
    let port = listener.local_addr().unwrap().port();
    let orch = FakeOrchestrator::new(Some(KEY), log.clone());
    let server = serve(listener, orch.clone());
    let node = start_node(port, Some(std::str::from_utf8(KEY).unwrap()), &log);

    orch.push(Command::WarmPool(pb::WarmPool { target: Some(2) }));
    wait_for(&log, "warm VMs reported", |ev| {
        ev.iter()
            .any(|e| matches!(e, Event::Heartbeat { status, .. } if status.warm_vms == 2))
            .then_some(())
    })
    .await;

    orch.push(Command::Drain(pb::Drain {}));
    wait_for(&log, "draining status", |ev| {
        ev.iter()
            .any(|e| matches!(e, Event::Heartbeat { status, .. } if status.draining))
            .then_some(())
    })
    .await;
    let task = TaskId::random();
    orch.push(execute(&task, "complete"));
    let result = wait_for(&log, "rejected result", |ev| result_for(ev, &task)).await;
    assert!(!result.success);
    assert_eq!(result.error_message.as_deref(), Some("node is draining"));
    assert!(
        !log.lock()
            .unwrap()
            .iter()
            .any(|e| matches!(e, Event::AgentStart(_))),
        "a draining node started a task"
    );
    node.stop().await;
    server.abort();
}
