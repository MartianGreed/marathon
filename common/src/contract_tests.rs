//! Wire-contract tests for the generated `marathon.v1` messages.
//!
//! Ports of the Zig `protocol.zig` round-trip tests, plus presence checks:
//! every field that was optional in Zig must keep "absent" distinct from
//! "zero/empty" on the wire. Each check uses `Some(<zero value>)`, which only
//! compiles and round-trips if the field is generated as `Option<_>`.

use prost::Message;

use crate::pb::{self, node_command::Command};

fn round_trip<M: Message + Default>(msg: &M) -> M {
    M::decode(msg.encode_to_vec().as_slice()).expect("decode")
}

fn env_vars() -> Vec<pb::EnvVar> {
    vec![
        pb::EnvVar {
            key: "B".into(),
            value: "2".into(),
        },
        pb::EnvVar {
            key: "A".into(),
            value: "1".into(),
        },
        pb::EnvVar {
            key: "B".into(),
            value: "3".into(),
        },
    ]
}

// Port of protocol.zig "roundtrip encoding" (SubmitTaskRequest).
#[test]
fn submit_task_request_round_trip() {
    let original = pb::SubmitTaskRequest {
        repo_url: "https://github.com/test/repo".into(),
        branch: "main".into(),
        prompt: "Fix the bug".into(),
        github_token: "ghp_xxx".into(),
        create_pr: true,
        pr_title: Some("Fix bug".into()),
        pr_body: None,
        env_vars: env_vars(),
        max_iterations: Some(10),
        completion_promise: Some("TASK_COMPLETE".into()),
    };
    let decoded = round_trip(&original);
    assert_eq!(decoded, original);
    assert_eq!(decoded.repo_url, "https://github.com/test/repo");
    assert_eq!(decoded.branch, "main");
    assert!(decoded.create_pr);
    assert_eq!(decoded.pr_body, None);
    // Order and duplicates of env vars survive.
    let keys: Vec<_> = decoded.env_vars.iter().map(|e| e.key.as_str()).collect();
    assert_eq!(keys, ["B", "A", "B"]);
}

#[test]
fn submit_task_request_optionals_keep_presence() {
    let absent = pb::SubmitTaskRequest::default();
    let decoded = round_trip(&absent);
    assert_eq!(decoded.pr_title, None);
    assert_eq!(decoded.pr_body, None);
    assert_eq!(decoded.max_iterations, None);
    assert_eq!(decoded.completion_promise, None);

    let zero = pb::SubmitTaskRequest {
        pr_title: Some(String::new()),
        pr_body: Some(String::new()),
        max_iterations: Some(0),
        completion_promise: Some(String::new()),
        ..Default::default()
    };
    assert_eq!(round_trip(&zero), zero);
}

fn warm_pool(target: Option<u32>) -> pb::NodeCommand {
    pb::NodeCommand {
        command: Some(Command::WarmPool(pb::WarmPool { target })),
    }
}

// Port of protocol.zig "NodeCommand with warm_pool_target roundtrip".
#[test]
fn node_command_warm_pool_with_target() {
    let decoded = round_trip(&warm_pool(Some(8)));
    assert_eq!(
        decoded.command,
        Some(Command::WarmPool(pb::WarmPool { target: Some(8) }))
    );
}

// Port of protocol.zig "NodeCommand with null warm_pool_target roundtrip".
#[test]
fn node_command_warm_pool_without_target() {
    let decoded = round_trip(&warm_pool(None));
    assert_eq!(
        decoded.command,
        Some(Command::WarmPool(pb::WarmPool { target: None }))
    );
}

#[test]
fn node_command_warm_pool_zero_target_is_not_absent() {
    let zero = round_trip(&warm_pool(Some(0)));
    let none = round_trip(&warm_pool(None));
    assert_eq!(
        zero.command,
        Some(Command::WarmPool(pb::WarmPool { target: Some(0) }))
    );
    assert_ne!(zero, none);
}

// Port of protocol.zig "HeartbeatResponse with warm_pool command roundtrip".
#[test]
fn heartbeat_response_with_commands() {
    let original = pb::HeartbeatResponse {
        timestamp: 1_234_567_890,
        acknowledged: true,
        commands: vec![
            warm_pool(Some(3)),
            pb::NodeCommand {
                command: Some(Command::Drain(pb::Drain {})),
            },
            pb::NodeCommand {
                command: Some(Command::CancelTask(pb::CancelTask {
                    task_id: "ab".repeat(32),
                })),
            },
            pb::NodeCommand {
                command: Some(Command::ExecuteTask(pb::ExecuteTask {
                    task_id: "cd".repeat(32),
                    repo_url: "https://github.com/test/repo".into(),
                    branch: "main".into(),
                    prompt: "p".into(),
                    github_token: "ghp_x".into(),
                    anthropic_api_key: "sk-ant-x".into(),
                    create_pr: true,
                    pr_title: Some("t".into()),
                    pr_body: None,
                    timeout_ms: 600_000,
                    max_tokens: 100_000,
                    env_vars: env_vars(),
                    max_iterations: Some(5),
                    completion_promise: None,
                })),
            },
            warm_pool(None),
        ],
    };
    let decoded = round_trip(&original);
    assert_eq!(decoded, original);
    assert_eq!(decoded.timestamp, 1_234_567_890);
    assert!(decoded.acknowledged);
    assert_eq!(decoded.commands.len(), 5);
    assert_eq!(
        decoded.commands[0].command,
        Some(Command::WarmPool(pb::WarmPool { target: Some(3) }))
    );
    assert_eq!(
        decoded.commands[1].command,
        Some(Command::Drain(pb::Drain {}))
    );
    assert_eq!(
        decoded.commands[4].command,
        Some(Command::WarmPool(pb::WarmPool { target: None }))
    );
}

#[test]
fn execute_task_optionals_keep_presence() {
    let absent = round_trip(&pb::ExecuteTask::default());
    assert_eq!(absent.pr_title, None);
    assert_eq!(absent.pr_body, None);
    assert_eq!(absent.max_iterations, None);
    assert_eq!(absent.completion_promise, None);

    let zero = pb::ExecuteTask {
        pr_title: Some(String::new()),
        pr_body: Some(String::new()),
        max_iterations: Some(0),
        completion_promise: Some(String::new()),
        ..Default::default()
    };
    assert_eq!(round_trip(&zero), zero);
}

#[test]
fn task_optionals_keep_presence() {
    let absent = round_trip(&pb::Task::default());
    assert_eq!(absent.node_id, None);
    assert_eq!(absent.vm_id, None);
    assert_eq!(absent.started_at, None);
    assert_eq!(absent.completed_at, None);
    assert_eq!(absent.error_message, None);
    assert_eq!(absent.pr_url, None);
    assert_eq!(absent.pr_title, None);
    assert_eq!(absent.pr_body, None);
    assert_eq!(absent.max_iterations, None);
    assert_eq!(absent.completion_promise, None);

    let zero = pb::Task {
        node_id: Some(String::new()),
        vm_id: Some(String::new()),
        started_at: Some(0),
        completed_at: Some(0),
        error_message: Some(String::new()),
        pr_url: Some(String::new()),
        pr_title: Some(String::new()),
        pr_body: Some(String::new()),
        max_iterations: Some(0),
        completion_promise: Some(String::new()),
        ..Default::default()
    };
    assert_eq!(round_trip(&zero), zero);
}

#[test]
fn result_event_and_list_optionals_keep_presence() {
    let result = pb::TaskResult {
        error_message: Some(String::new()),
        pr_url: Some(String::new()),
        ..Default::default()
    };
    assert_eq!(round_trip(&result), result);
    let absent = round_trip(&pb::TaskResult::default());
    assert_eq!((absent.error_message, absent.pr_url), (None, None));

    let complete = pb::TaskComplete {
        usage: None,
        pr_url: Some(String::new()),
        error_message: Some(String::new()),
    };
    assert_eq!(round_trip(&complete), complete);
    let absent = round_trip(&pb::TaskComplete::default());
    assert_eq!((absent.pr_url, absent.error_message), (None, None));

    // state_filter Some(UNSPECIFIED) is distinct from "all states".
    let filter = pb::ListTasksRequest {
        state_filter: Some(pb::TaskState::Unspecified as i32),
        limit: 0,
        offset: 0,
    };
    assert_eq!(round_trip(&filter), filter);
    assert_eq!(
        round_trip(&pb::ListTasksRequest::default()).state_filter,
        None
    );

    let summary = pb::TaskSummary {
        completed_at: Some(0),
        ..Default::default()
    };
    assert_eq!(round_trip(&summary), summary);
    assert_eq!(round_trip(&pb::TaskSummary::default()).completed_at, None);

    let status = pb::NodeStatus {
        last_task_at: Some(0),
        ..Default::default()
    };
    assert_eq!(round_trip(&status), status);
    assert_eq!(round_trip(&pb::NodeStatus::default()).last_task_at, None);
}

#[test]
fn auth_response_optionals_keep_presence() {
    let absent = round_trip(&pb::AuthResponse {
        success: false,
        token: None,
        api_key: None,
        message: "Invalid email or password".into(),
    });
    assert_eq!(absent.token, None);
    assert_eq!(absent.api_key, None);
    assert_eq!(absent.message, "Invalid email or password");

    let present = pb::AuthResponse {
        success: true,
        token: Some("a.b.c".into()),
        api_key: Some(String::new()),
        message: "Login successful".into(),
    };
    assert_eq!(round_trip(&present), present);
}

#[test]
fn report_requests_round_trip() {
    let auth = crate::node_auth::node_auth(Some(b"k"), &crate::NodeId::random(), 42);
    let results = pb::ReportTaskResultRequest {
        auth: Some(auth.clone()),
        results: vec![
            pb::TaskResult {
                task_id: "01".repeat(32),
                success: true,
                error_message: None,
                metrics: Some(pb::UsageMetrics {
                    compute_time_ms: 1,
                    input_tokens: 2,
                    output_tokens: 3,
                    cache_read_tokens: 4,
                    cache_write_tokens: 5,
                    tool_calls: 6,
                }),
                pr_url: Some("https://github.com/o/r/pull/1".into()),
            },
            pb::TaskResult {
                task_id: "02".repeat(32),
                success: false,
                error_message: Some("Non-zero exit code".into()),
                metrics: None,
                pr_url: None,
            },
        ],
    };
    assert_eq!(round_trip(&results), results);

    let output = pb::ReportTaskOutputRequest {
        auth: Some(auth),
        events: vec![pb::TaskOutputEvent {
            task_id: "01".repeat(32),
            r#type: pb::OutputType::Claude as i32,
            timestamp: 7,
            data: vec![0, 255, 10],
        }],
    };
    assert_eq!(round_trip(&output), output);

    let heartbeat = pb::NodeHeartbeat {
        auth: output.auth.clone(),
        status: Some(pb::NodeStatus {
            hostname: "h".into(),
            total_vm_slots: 10,
            active_vms: 3,
            warm_vms: 5,
            cpu_usage: 0.5,
            memory_usage: 0.4,
            disk_available_bytes: 1,
            healthy: true,
            draining: false,
            uptime_seconds: 2,
            last_task_at: None,
            active_task_ids: vec!["03".repeat(32)],
        }),
    };
    assert_eq!(round_trip(&heartbeat), heartbeat);
}
