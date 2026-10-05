//! In-process gRPC authentication, dispatch, TLS and shutdown tests.

mod support;
use common::{
    NodeId, TaskId, UserId, pb,
    types::{TaskState, now_ms},
};
use marathon_orchestrator::{
    config::LocalConfig,
    db::{PostgresStore, migrate},
    store::Store,
};
use std::{sync::Arc, time::Duration};
use support::*;
use tokio_stream::wrappers::ReceiverStream;
use tonic::{
    Code,
    transport::{Certificate, Channel, ClientTlsConfig},
};

const COUNT_TASKS_SQL: &str = "
    SELECT COUNT(*)
    FROM tasks
";

const COUNT_USAGE_SQL: &str = "
    SELECT COUNT(*)
    FROM usage_records
";

const COUNT_NODES_SQL: &str = "
    SELECT COUNT(*)
    FROM nodes
";

const COUNT_USER_TASKS_SQL: &str = "
    SELECT COUNT(*)
    FROM tasks
    WHERE user_id IS NOT NULL
";

#[tokio::test]
async fn node_authentication() {
    let s = TestServer::start(None, Some("node-key")).await;
    let id = NodeId::random();
    let (tx, rx) = tokio::sync::mpsc::channel(4);
    let mut node = s.node();
    let mut stream = node
        .heartbeat(ReceiverStream::new(rx))
        .await
        .unwrap()
        .into_inner();
    tx.send(heartbeat(id, Some("node-key"), 1)).await.unwrap();
    assert!(next_heartbeat(&mut stream).await.acknowledged);
    tx.send(heartbeat(NodeId::random(), Some("node-key"), 1))
        .await
        .unwrap();
    assert_eq!(
        stream.message().await.unwrap_err().code(),
        Code::Unauthenticated
    );
    for bad in [
        pb::NodeHeartbeat {
            auth: None,
            status: Some(status(1)),
        },
        heartbeat(id, Some("wrong"), 1),
        pb::NodeHeartbeat {
            auth: Some(common::node_auth::node_auth(
                Some(b"node-key"),
                &id,
                now_ms() - 300_001,
            )),
            status: Some(status(1)),
        },
    ] {
        let mut stream = node
            .heartbeat(tokio_stream::iter([bad.clone()]))
            .await
            .unwrap()
            .into_inner();
        assert_eq!(
            stream.message().await.unwrap_err().code(),
            Code::Unauthenticated
        );
        assert_eq!(
            node.report_task_output(pb::ReportTaskOutputRequest {
                auth: bad.auth.clone(),
                events: vec![]
            })
            .await
            .unwrap_err()
            .code(),
            Code::Unauthenticated
        );
        assert_eq!(
            node.report_task_result(pb::ReportTaskResultRequest {
                auth: bad.auth,
                results: vec![]
            })
            .await
            .unwrap_err()
            .code(),
            Code::Unauthenticated
        );
    }
    let auth = Some(common::node_auth::node_auth(
        Some(b"node-key"),
        &id,
        now_ms(),
    ));
    node.report_task_output(pb::ReportTaskOutputRequest {
        auth: auth.clone(),
        events: vec![],
    })
    .await
    .unwrap();
    node.report_task_result(pb::ReportTaskResultRequest {
        auth: auth.clone(),
        results: vec![],
    })
    .await
    .unwrap();
    let mut invalid = heartbeat(id, Some("node-key"), 1);
    invalid.status.as_mut().unwrap().active_task_ids = vec!["bad".into()];
    let mut stream = node
        .heartbeat(tokio_stream::iter([invalid]))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(
        stream.message().await.unwrap_err().code(),
        Code::InvalidArgument
    );
    let mut invalid = heartbeat(id, Some("node-key"), 1);
    invalid.status.as_mut().unwrap().cpu_usage = 2.0;
    let mut stream = node
        .heartbeat(tokio_stream::iter([invalid]))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(
        stream.message().await.unwrap_err().code(),
        Code::InvalidArgument
    );
    assert_eq!(
        node.report_task_result(pb::ReportTaskResultRequest {
            auth,
            results: vec![pb::TaskResult {
                task_id: "bad".into(),
                ..Default::default()
            }]
        })
        .await
        .unwrap_err()
        .code(),
        Code::InvalidArgument
    );
}

#[tokio::test]
async fn node_without_key() {
    let s = TestServer::start(None, None).await;
    let id = NodeId::random();
    let mut node = s.node();
    let mut stream = node
        .heartbeat(tokio_stream::iter([heartbeat(id, None, 1)]))
        .await
        .unwrap()
        .into_inner();
    assert!(next_heartbeat(&mut stream).await.acknowledged);
    node.report_task_result(pb::ReportTaskResultRequest {
        auth: heartbeat(id, None, 1).auth,
        results: vec![],
    })
    .await
    .unwrap();
    node.report_task_output(pb::ReportTaskOutputRequest {
        auth: heartbeat(id, None, 1).auth,
        events: vec![],
    })
    .await
    .unwrap();
    let mut invalid = heartbeat(id, None, 1);
    invalid.auth.as_mut().unwrap().node_id = "bad".into();
    let mut stream = node
        .heartbeat(tokio_stream::iter([invalid]))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(
        stream.message().await.unwrap_err().code(),
        Code::InvalidArgument
    );
}

fn submission() -> pb::SubmitTaskRequest {
    pb::SubmitTaskRequest {
        repo_url: "https://github.com/test/repo".into(),
        branch: "feature".into(),
        prompt: "implement the change".into(),
        github_token: "ghp_test-github-secret".into(),
        create_pr: true,
        pr_title: Some("title".into()),
        pr_body: Some("body".into()),
        env_vars: vec![
            pb::EnvVar {
                key: "A".into(),
                value: "one".into(),
            },
            pb::EnvVar {
                key: "B".into(),
                value: "two".into(),
            },
            pb::EnvVar {
                key: "A".into(),
                value: "three".into(),
            },
        ],
        max_iterations: Some(8),
        completion_promise: Some("DONE".into()),
    }
}

async fn end_to_end(store: Option<Arc<dyn Store>>) -> TestServer {
    let persistent = store.clone();
    let s = TestServer::start(store, Some("node-key")).await;
    let registered = register(&s, "e2e@example.com").await;
    assert!(registered.success);
    let key = registered.api_key.unwrap();
    let mut client = s.client();
    let mut node = s.node();
    assert_eq!(
        client
            .get_task(pb::GetTaskRequest {
                task_id: TaskId::random().to_hex()
            })
            .await
            .unwrap_err()
            .code(),
        Code::Unauthenticated
    );
    assert_eq!(
        client
            .list_tasks(pb::ListTasksRequest::default())
            .await
            .unwrap_err()
            .code(),
        Code::Unauthenticated
    );
    assert_eq!(
        client
            .cancel_task(pb::CancelTaskRequest {
                task_id: TaskId::random().to_hex()
            })
            .await
            .unwrap_err()
            .code(),
        Code::Unauthenticated
    );
    assert_eq!(
        client
            .get_usage(pb::GetUsageRequest::default())
            .await
            .unwrap_err()
            .code(),
        Code::Unauthenticated
    );
    assert_eq!(
        client
            .get_task_events(pb::GetTaskEventsRequest::default())
            .await
            .unwrap_err()
            .code(),
        Code::Unauthenticated
    );
    assert_eq!(
        client.submit_task(submission()).await.unwrap_err().code(),
        Code::Unauthenticated
    );
    let mut bad = submission();
    bad.repo_url = "http://bad".into();
    assert_eq!(
        client
            .submit_task(authorized(bad, &key))
            .await
            .unwrap_err()
            .code(),
        Code::InvalidArgument
    );
    let mut bad = submission();
    bad.github_token = "bad".into();
    assert_eq!(
        client
            .submit_task(authorized(bad, &key))
            .await
            .unwrap_err()
            .code(),
        Code::InvalidArgument
    );
    let mut traced = authorized(submission(), &key);
    traced.metadata_mut().insert(
        "traceparent",
        "00-00112233445566778899aabbccddeeff-0123456789abcdef-01"
            .parse()
            .unwrap(),
    );
    let mut submit = client.submit_task(traced).await.unwrap().into_inner();
    let first = next_event(&mut submit).await;
    assert_eq!(first.state, 1);
    assert!(matches!(
        first.event,
        Some(pb::task_event::Event::StateChange(_))
    ));
    let id = first.task_id;
    assert_eq!(
        s.app.state.lock().await.tasks[&TaskId::parse(&id).unwrap()].trace_id,
        "00112233445566778899aabbccddeeff"
    );
    let other = register(&s, "other@example.com").await.api_key.unwrap();
    assert_eq!(
        client
            .get_task(authorized(
                pb::GetTaskRequest {
                    task_id: id.clone()
                },
                &other
            ))
            .await
            .unwrap_err()
            .code(),
        Code::NotFound
    );
    assert_eq!(
        client
            .cancel_task(authorized(
                pb::CancelTaskRequest {
                    task_id: id.clone()
                },
                &other
            ))
            .await
            .unwrap_err()
            .code(),
        Code::NotFound
    );
    assert_eq!(
        client
            .get_task_events(authorized(
                pb::GetTaskEventsRequest {
                    task_id: id.clone(),
                    follow: true
                },
                &other
            ))
            .await
            .unwrap_err()
            .code(),
        Code::NotFound
    );
    let other_list = client
        .list_tasks(authorized(pb::ListTasksRequest::default(), &other))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(other_list.total_count, 0);
    let node_id = NodeId::random();
    let (tx, rx) = tokio::sync::mpsc::channel(8);
    let mut heartbeats = node
        .heartbeat(ReceiverStream::new(rx))
        .await
        .unwrap()
        .into_inner();
    tx.send(heartbeat(node_id, Some("node-key"), 1))
        .await
        .unwrap();
    let hb = next_heartbeat(&mut heartbeats).await;
    assert_eq!(hb.commands.len(), 1);
    let pb::node_command::Command::ExecuteTask(execute) = hb.commands[0].command.as_ref().unwrap()
    else {
        panic!("expected execute")
    };
    let request = submission();
    assert_eq!(execute.task_id, id);
    assert_eq!(execute.repo_url, request.repo_url);
    assert_eq!(execute.branch, request.branch);
    assert_eq!(execute.prompt, request.prompt);
    assert_eq!(execute.github_token, request.github_token);
    assert_eq!(execute.env_vars, request.env_vars);
    assert_eq!(execute.anthropic_api_key, "test-anthropic-secret");
    assert_eq!((execute.timeout_ms, execute.max_tokens), (600000, 100000));
    assert_eq!(execute.max_iterations, Some(8));
    assert_eq!(execute.completion_promise.as_deref(), Some("DONE"));
    assert!(execute.create_pr);
    assert_eq!(execute.pr_title, request.pr_title);
    assert_eq!(execute.pr_body, request.pr_body);
    assert_eq!(
        client
            .get_task(authorized(
                pb::GetTaskRequest {
                    task_id: id.clone()
                },
                &key
            ))
            .await
            .unwrap()
            .into_inner()
            .state,
        2
    );
    let mut follower = client
        .get_task_events(authorized(
            pb::GetTaskEventsRequest {
                task_id: id.clone(),
                follow: true,
            },
            &key,
        ))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(next_event(&mut follower).await.state, 2);
    // A node that does not own this task cannot complete it.
    node.report_task_result(pb::ReportTaskResultRequest {
        auth: heartbeat(NodeId::random(), Some("node-key"), 1).auth,
        results: vec![pb::TaskResult {
            task_id: id.clone(),
            success: true,
            ..Default::default()
        }],
    })
    .await
    .unwrap();
    assert_eq!(
        s.app
            .get_task(TaskId::parse(&id).unwrap())
            .await
            .unwrap()
            .unwrap()
            .state,
        TaskState::Starting
    );
    node.report_task_output(pb::ReportTaskOutputRequest {
        auth: heartbeat(node_id, Some("node-key"), 1).auth,
        events: vec![pb::TaskOutputEvent {
            task_id: id.clone(),
            r#type: 1,
            timestamp: now_ms(),
            data: b"output".to_vec(),
        }],
    })
    .await
    .unwrap();
    assert_eq!(next_event(&mut follower).await.state, 3);
    let output = next_event(&mut follower).await;
    assert!(matches!(
        output.event,
        Some(pb::task_event::Event::Output(pb::TaskOutput { ref data, .. }))
            if data == b"output"
    ));
    assert_eq!(
        client
            .get_task(authorized(
                pb::GetTaskRequest {
                    task_id: id.clone()
                },
                &key
            ))
            .await
            .unwrap()
            .into_inner()
            .state,
        3
    );
    let usage = pb::UsageMetrics {
        compute_time_ms: 1234,
        input_tokens: 100,
        output_tokens: 50,
        cache_read_tokens: 7,
        cache_write_tokens: 3,
        tool_calls: 5,
    };
    let result = pb::TaskResult {
        task_id: id.clone(),
        success: true,
        metrics: Some(usage),
        pr_url: Some("https://github.com/test/repo/pull/1".into()),
        error_message: None,
    };
    // Duplicates within a batch and a retried RPC must bill once.
    for _ in 0..2 {
        node.report_task_result(pb::ReportTaskResultRequest {
            auth: heartbeat(node_id, Some("node-key"), 1).auth,
            results: vec![result.clone(), result.clone()],
        })
        .await
        .unwrap();
    }
    let complete = next_event(&mut follower).await;
    assert_eq!(complete.state, 4);
    assert!(matches!(
        complete.event,
        Some(pb::task_event::Event::Complete(_))
    ));
    assert!(follower.message().await.unwrap().is_none());
    loop {
        if matches!(
            next_event(&mut submit).await.event,
            Some(pb::task_event::Event::Complete(_))
        ) {
            break;
        }
    }
    assert!(submit.message().await.unwrap().is_none());
    let got = client
        .get_task(authorized(
            pb::GetTaskRequest {
                task_id: id.clone(),
            },
            &key,
        ))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(got.state, 4);
    assert_eq!(got.usage, Some(usage));
    assert_eq!(
        got.pr_url.as_deref(),
        Some("https://github.com/test/repo/pull/1")
    );
    let report = client
        .get_usage(authorized(
            pb::GetUsageRequest {
                start_time: 0,
                end_time: i64::MAX,
            },
            &key,
        ))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(report.total, Some(usage));
    assert_eq!(report.task_count, 1);
    assert_eq!(report.client_id, got.client_id);
    if let Some(store) = &persistent {
        let saved = store
            .get_task(TaskId::parse(&id).unwrap())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(saved.state, TaskState::Completed);
        assert!(saved.completed_at.is_some());
        assert_eq!(saved.node_id, Some(node_id));
        assert_eq!(saved.usage, usage.into());
        assert_eq!(
            saved.pr_url.as_deref(),
            Some("https://github.com/test/repo/pull/1")
        );
    }

    // Snapshots retain output and are not consumed by reads.
    for _ in 0..2 {
        let mut events = client
            .get_task_events(authorized(
                pb::GetTaskEventsRequest {
                    task_id: id.clone(),
                    follow: false,
                },
                &key,
            ))
            .await
            .unwrap()
            .into_inner();
        assert_eq!(next_event(&mut events).await.state, 4);
        assert!(matches!(
            next_event(&mut events).await.event,
            Some(pb::task_event::Event::Output(_))
        ));
        assert!(events.message().await.unwrap().is_none());
    }
    // Running cancellation delivers a node command and preserves late usage.
    let mut cancelled = client
        .submit_task(authorized(submission(), &key))
        .await
        .unwrap()
        .into_inner();
    let cancel_id = next_event(&mut cancelled).await.task_id;
    tx.send(heartbeat(node_id, Some("node-key"), 1))
        .await
        .unwrap();
    assert_eq!(next_heartbeat(&mut heartbeats).await.commands.len(), 1);
    let mut hb = heartbeat(node_id, Some("node-key"), 1);
    hb.status.as_mut().unwrap().active_vms = 1;
    hb.status.as_mut().unwrap().active_task_ids = vec![cancel_id.clone()];
    tx.send(hb).await.unwrap();
    next_heartbeat(&mut heartbeats).await;
    assert_eq!(
        s.app
            .get_task(TaskId::parse(&cancel_id).unwrap())
            .await
            .unwrap()
            .unwrap()
            .state,
        TaskState::Running
    );
    assert!(
        client
            .cancel_task(authorized(
                pb::CancelTaskRequest {
                    task_id: cancel_id.clone()
                },
                &key
            ))
            .await
            .unwrap()
            .into_inner()
            .success
    );
    tx.send(heartbeat(node_id, Some("node-key"), 1))
        .await
        .unwrap();
    let commands = next_heartbeat(&mut heartbeats).await.commands;
    assert!(commands.iter().any(|c| matches!(
        &c.command,
        Some(pb::node_command::Command::CancelTask(c)) if c.task_id == cancel_id
    )));
    assert!(
        !client
            .cancel_task(authorized(
                pb::CancelTaskRequest {
                    task_id: cancel_id.clone()
                },
                &key
            ))
            .await
            .unwrap()
            .into_inner()
            .success
    );
    if let Some(store) = &persistent {
        let saved = store
            .get_task(TaskId::parse(&cancel_id).unwrap())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(saved.state, TaskState::Cancelled);
        assert!(saved.completed_at.is_some());
        assert_eq!(saved.node_id, Some(node_id));
    }
    let late_result = pb::TaskResult {
        task_id: cancel_id.clone(),
        success: true,
        metrics: Some(usage),
        ..Default::default()
    };
    for _ in 0..2 {
        node.report_task_result(pb::ReportTaskResultRequest {
            auth: heartbeat(node_id, Some("node-key"), 1).auth,
            results: vec![late_result.clone(), late_result.clone()],
        })
        .await
        .unwrap();
    }
    assert_eq!(
        s.app
            .get_task(TaskId::parse(&cancel_id).unwrap())
            .await
            .unwrap()
            .unwrap()
            .state,
        TaskState::Cancelled
    );
    assert_eq!(
        client
            .get_usage(authorized(
                pb::GetUsageRequest {
                    start_time: 0,
                    end_time: i64::MAX
                },
                &key
            ))
            .await
            .unwrap()
            .into_inner()
            .task_count,
        2
    );
    drop(tx);
    drop(heartbeats);
    s
}

#[tokio::test]
async fn dispatch_in_memory() {
    drop(end_to_end(None).await);
}

#[tokio::test]
async fn dispatch_postgres() {
    with_db(|pool| async move {
        migrate(&pool).await.unwrap();
        let store = Arc::new(PostgresStore { pool: pool.clone() });
        let s = end_to_end(Some(store.clone())).await;
        assert_eq!(
            sqlx::query_scalar::<_, i64>(COUNT_TASKS_SQL)
                .fetch_one(&pool)
                .await
                .unwrap(),
            2
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>(COUNT_USAGE_SQL)
                .fetch_one(&pool)
                .await
                .unwrap(),
            2
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>(COUNT_NODES_SQL)
                .fetch_one(&pool)
                .await
                .unwrap(),
            1
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>(COUNT_USER_TASKS_SQL)
                .fetch_one(&pool)
                .await
                .unwrap(),
            2
        );
        // A failed node result must also survive a fresh repository read.
        let completed = s
            .app
            .state
            .lock()
            .await
            .tasks
            .values()
            .find(|task| task.task.state == TaskState::Completed)
            .unwrap()
            .task
            .clone();
        let node = completed.node_id.unwrap();
        let failed_id = s
            .app
            .submit(
                common::types::Task::new(
                    completed.client_id,
                    "https://github.com/test/repo",
                    "main",
                    "fail",
                ),
                "failed-task-trace".into(),
            )
            .await
            .unwrap();
        let status = common::types::NodeStatus {
            node_id: node,
            total_vm_slots: 1,
            healthy: true,
            ..Default::default()
        };
        assert_eq!(
            s.app
                .heartbeat(node, status, 2)
                .await
                .unwrap()
                .commands
                .len(),
            1
        );
        let failed_usage = pb::UsageMetrics {
            input_tokens: 17,
            output_tokens: 9,
            ..Default::default()
        };
        s.node()
            .report_task_result(pb::ReportTaskResultRequest {
                auth: heartbeat(node, Some("node-key"), 1).auth,
                results: vec![pb::TaskResult {
                    task_id: failed_id.to_hex(),
                    success: false,
                    error_message: Some("node execution failed".into()),
                    metrics: Some(failed_usage),
                    ..Default::default()
                }],
            })
            .await
            .unwrap();
        let saved = store.get_task(failed_id).await.unwrap().unwrap();
        assert_eq!(saved.state, TaskState::Failed);
        assert!(saved.completed_at.is_some());
        assert_eq!(saved.node_id, Some(node));
        assert_eq!(saved.usage, failed_usage.into());
        assert_eq!(
            saved.error_message.as_deref(),
            Some("node execution failed")
        );
        assert!(saved.pr_url.is_none());
        drop(s);
    })
    .await;
}

#[tokio::test]
async fn dropped_stream_requeues_reservations() {
    let s = TestServer::start(None, None).await;
    let key = register(&s, "queue@example.com").await.api_key.unwrap();
    let node_id = NodeId::random();
    let (tx, rx) = tokio::sync::mpsc::channel(1);
    let mut node = s.node();
    let mut hb = node
        .heartbeat(ReceiverStream::new(rx))
        .await
        .unwrap()
        .into_inner();
    tx.send(heartbeat(node_id, None, 1)).await.unwrap();
    next_heartbeat(&mut hb).await;
    let mut submit = s
        .client()
        .submit_task(authorized(submission(), &key))
        .await
        .unwrap()
        .into_inner();
    let id = TaskId::parse(&next_event(&mut submit).await.task_id).unwrap();
    assert_eq!(
        s.app.state.lock().await.sessions[&node_id]
            .reservations
            .len(),
        1
    );
    drop(hb);
    drop(tx);
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if s.app.state.lock().await.queue.contains(&id) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(
        s.app.get_task(id).await.unwrap().unwrap().state,
        TaskState::Queued
    );
}

#[tokio::test]
async fn tls_client_and_plaintext_rejection() {
    let rcgen::CertifiedKey { cert, signing_key } =
        rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
    let temp = tempfile::tempdir().unwrap();
    let cert_path = temp.path().join("cert.pem");
    let key_path = temp.path().join("key.pem");
    std::fs::write(&cert_path, cert.pem()).unwrap();
    std::fs::write(&key_path, signing_key.serialize_pem()).unwrap();
    let tls = ClientTlsConfig::new()
        .ca_certificate(Certificate::from_pem(cert.pem()))
        .domain_name("localhost");
    let local = LocalConfig {
        tls_cert_path: Some(cert_path.to_string_lossy().into_owned()),
        tls_key_path: Some(key_path.to_string_lossy().into_owned()),
        metrics_port: None,
    };
    let s = TestServer::configured(None, None, local, Some(tls)).await;
    assert!(register(&s, "tls@example.com").await.success);
    let endpoint = Channel::from_shared(format!("http://{}", s.address))
        .unwrap()
        .connect_timeout(Duration::from_secs(2))
        .timeout(Duration::from_secs(2));
    if let Ok(channel) = endpoint.connect().await {
        let mut client = pb::marathon_service_client::MarathonServiceClient::new(channel);
        assert!(
            client
                .register(pb::RegisterRequest {
                    email: "plain@example.com".into(),
                    password: "password".into()
                })
                .await
                .is_err()
        );
    }
}

#[tokio::test]
async fn registration_and_metadata_errors() {
    let s = TestServer::start(None, None).await;
    let mut c = s.client();
    let first = register(&s, "same@example.com").await;
    assert!(first.success);
    assert_eq!(
        register(&s, "same@example.com").await.message,
        "Email already registered"
    );
    assert!(
        !c.register(pb::RegisterRequest::default())
            .await
            .unwrap()
            .into_inner()
            .success
    );
    let unknown = c
        .login(pb::LoginRequest {
            email: "unknown".into(),
            password: "wrong".into(),
        })
        .await
        .unwrap()
        .into_inner();
    let wrong = c
        .login(pb::LoginRequest {
            email: "same@example.com".into(),
            password: "wrong".into(),
        })
        .await
        .unwrap()
        .into_inner();
    assert_eq!(unknown, wrong);
    assert_eq!(wrong.message, "Invalid email or password");
    let login = c
        .login(pb::LoginRequest {
            email: "same@example.com".into(),
            password: "test-password".into(),
        })
        .await
        .unwrap()
        .into_inner();
    assert!(login.success);
    assert_eq!(login.api_key, first.api_key);
    let mut r = authorized(
        pb::ListTasksRequest::default(),
        first.api_key.as_deref().unwrap(),
    );
    r.metadata_mut()
        .insert("authorization", "Bearer invalid".parse().unwrap());
    assert_eq!(
        c.list_tasks(r).await.unwrap_err().code(),
        Code::Unauthenticated
    );
    assert_eq!(
        c.get_task(authorized(
            pb::GetTaskRequest {
                task_id: "bad".into()
            },
            first.api_key.as_deref().unwrap()
        ))
        .await
        .unwrap_err()
        .code(),
        Code::InvalidArgument
    );
    assert_eq!(
        c.get_task(authorized(
            pb::GetTaskRequest {
                task_id: TaskId::random().to_hex()
            },
            first.api_key.as_deref().unwrap()
        ))
        .await
        .unwrap_err()
        .code(),
        Code::NotFound
    );
    assert_eq!(first.api_key.unwrap().len(), 44);
    assert!(UserId::parse(&common::ClientId::random().to_hex()).is_ok());
}

#[tokio::test]
async fn graceful_shutdown_closes_live_streams() {
    let mut s = TestServer::start(None, None).await;
    let key = register(&s, "shutdown@example.com").await.api_key.unwrap();
    let mut submit = s
        .client()
        .submit_task(authorized(submission(), &key))
        .await
        .unwrap()
        .into_inner();
    next_event(&mut submit).await;
    let (tx, rx) = tokio::sync::mpsc::channel(1);
    let mut heartbeat_stream = s
        .node()
        .heartbeat(ReceiverStream::new(rx))
        .await
        .unwrap()
        .into_inner();
    tx.send(heartbeat(NodeId::random(), None, 0)).await.unwrap();
    next_heartbeat(&mut heartbeat_stream).await;
    s.shutdown().await;
    assert!(
        tokio::time::timeout(Duration::from_secs(2), submit.message())
            .await
            .unwrap()
            .unwrap()
            .is_none()
    );
    assert!(
        tokio::time::timeout(Duration::from_secs(2), heartbeat_stream.message())
            .await
            .unwrap()
            .unwrap()
            .is_none()
    );
}
