//! Regression tests for billing, dispatch recovery and report batch isolation.

mod support;

use common::pb::node_service_server::NodeService;
use common::{
    ClientId, NodeId, TaskId, UserId, pb,
    types::{NodeStatus, Task, TaskState, UsageMetrics},
};
use marathon_orchestrator::{
    db::{DbError, PostgresStore, migrate},
    metering::UsageRecord,
    scheduler::Orchestrator,
    service::Service,
    store::{MemoryStore, Store, User},
};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use support::*;
use tonic::{Code, Request};

const COUNT_USAGE_SQL: &str = "
    SELECT COUNT(*)
    FROM usage_records
";

fn app(store: Arc<dyn Store>) -> Arc<Orchestrator> {
    Orchestrator::new(
        common::config::OrchestratorConfig {
            jwt_secret: Some("t".into()),
            ..Default::default()
        },
        store,
    )
}

fn node_status(node: NodeId, slots: u32) -> NodeStatus {
    NodeStatus {
        node_id: node,
        total_vm_slots: slots,
        healthy: true,
        ..Default::default()
    }
}

fn result(id: TaskId, input: i64) -> pb::TaskResult {
    pb::TaskResult {
        task_id: id.to_hex(),
        success: true,
        metrics: Some(pb::UsageMetrics {
            input_tokens: input,
            ..Default::default()
        }),
        ..Default::default()
    }
}

/// MemoryStore whose N-th save_task fails.
struct FailingStore {
    inner: MemoryStore,
    saves: AtomicUsize,
    fail_at: usize,
    commits: AtomicUsize,
    fail_commit_at: usize,
}

#[tonic::async_trait]
impl Store for FailingStore {
    async fn create_task(&self, t: &Task) -> Result<(), DbError> {
        self.inner.create_task(t).await
    }

    async fn get_task(&self, id: TaskId) -> Result<Option<Task>, DbError> {
        self.inner.get_task(id).await
    }

    async fn save_task(&self, t: &Task) -> Result<(), DbError> {
        if self.saves.fetch_add(1, Ordering::SeqCst) + 1 == self.fail_at {
            return Err(DbError::ConnectionFailed);
        }
        self.inner.save_task(t).await
    }

    async fn list_tasks(
        &self,
        c: ClientId,
        s: Option<TaskState>,
        l: u32,
        o: u32,
    ) -> Result<(Vec<Task>, u32), DbError> {
        self.inner.list_tasks(c, s, l, o).await
    }

    async fn create_user(&self, u: &User) -> Result<(), DbError> {
        self.inner.create_user(u).await
    }

    async fn user_by_email(&self, e: &str) -> Result<Option<User>, DbError> {
        self.inner.user_by_email(e).await
    }

    async fn user_by_api_key(&self, k: &str) -> Result<Option<User>, DbError> {
        self.inner.user_by_api_key(k).await
    }

    async fn user_by_id(&self, id: UserId) -> Result<Option<User>, DbError> {
        self.inner.user_by_id(id).await
    }

    async fn record_usage(&self, r: &UsageRecord) -> Result<(), DbError> {
        self.inner.record_usage(r).await
    }

    async fn usage_report(
        &self,
        c: ClientId,
        s: i64,
        e: i64,
    ) -> Result<(UsageMetrics, u32), DbError> {
        self.inner.usage_report(c, s, e).await
    }

    async fn commit_result(
        &self,
        task: &Task,
        record: &UsageRecord,
        update: bool,
    ) -> Result<(), DbError> {
        if self.commits.fetch_add(1, Ordering::SeqCst) + 1 == self.fail_commit_at {
            return Err(DbError::ConnectionFailed);
        }
        self.inner.commit_result(task, record, update).await
    }

    async fn upsert_node(&self, n: &NodeStatus) -> Result<(), DbError> {
        self.inner.upsert_node(n).await
    }
}

fn failing_store(save: usize, commit: usize) -> Arc<FailingStore> {
    Arc::new(FailingStore {
        inner: MemoryStore::default(),
        saves: AtomicUsize::new(0),
        fail_at: save,
        commits: AtomicUsize::new(0),
        fail_commit_at: commit,
    })
}

async fn tasks(a: &Orchestrator, client: ClientId, count: usize) -> Vec<TaskId> {
    let mut ids = Vec::new();
    for _ in 0..count {
        ids.push(
            a.submit(
                Task::new(client, "https://github.com/a/b", "main", "p"),
                "trace".into(),
            )
            .await
            .unwrap(),
        );
    }
    ids
}

async fn billing(store: Arc<dyn Store>) {
    let a = app(store.clone());
    let c = ClientId::random();
    let ids = tasks(&a, c, 3).await;
    let n = NodeId::random();
    assert_eq!(
        a.heartbeat(n, node_status(n, 3), 1)
            .await
            .unwrap()
            .commands
            .len(),
        3
    );
    let (first, second) = tokio::join!(
        a.result(n, result(ids[0], 100), ids[0]),
        a.result(n, result(ids[0], 100), ids[0])
    );
    first.unwrap();
    second.unwrap();
    let seq = a.state.lock().await.tasks[&ids[0]].events.sequence;
    a.result(n, result(ids[0], 999), ids[0]).await.unwrap();
    assert_eq!(a.state.lock().await.tasks[&ids[0]].events.sequence, seq);
    assert_eq!(
        a.get_task(ids[0])
            .await
            .unwrap()
            .unwrap()
            .usage
            .input_tokens,
        100
    );
    let mut failed = result(ids[1], 100);
    failed.success = false;
    failed.error_message = Some("execution failed".into());
    a.result(n, failed.clone(), ids[1]).await.unwrap();
    a.result(n, failed, ids[1]).await.unwrap();
    assert!(a.cancel(ids[2], c).await.unwrap());
    let seq = a.state.lock().await.tasks[&ids[2]].events.sequence;
    a.result(n, result(ids[2], 100), ids[2]).await.unwrap();
    a.result(n, result(ids[2], 100), ids[2]).await.unwrap();
    assert_eq!(
        a.get_task(ids[2]).await.unwrap().unwrap().state,
        TaskState::Cancelled
    );
    assert_eq!(a.state.lock().await.tasks[&ids[2]].events.sequence, seq);
    assert_eq!(store.usage_report(c, 0, i64::MAX).await.unwrap().1, 3);
    assert_eq!(
        store
            .usage_report(c, 0, i64::MAX)
            .await
            .unwrap()
            .0
            .input_tokens,
        300
    );
    assert_eq!(a.state.lock().await.meter.records.len(), 3);
    // A fresh process also ignores previously persisted late cancellation usage.
    let restarted = app(store.clone());
    restarted
        .result(n, result(ids[2], 100), ids[2])
        .await
        .unwrap();
    assert_eq!(store.usage_report(c, 0, i64::MAX).await.unwrap().1, 3);
}

#[tokio::test]
async fn results_bill_once_memory() {
    billing(Arc::new(MemoryStore::default())).await;
}

#[tokio::test]
async fn results_bill_once_postgres() {
    with_db(|pool| async move {
        migrate(&pool).await.unwrap();
        billing(Arc::new(PostgresStore { pool: pool.clone() })).await;
        assert_eq!(
            sqlx::query_scalar::<_, i64>(COUNT_USAGE_SQL)
                .fetch_one(&pool)
                .await
                .unwrap(),
            3
        );
    })
    .await;
}

#[tokio::test]
async fn failed_commit_is_retryable_without_billing() {
    let store = failing_store(0, 1);
    let a = app(store.clone());
    let c = ClientId::random();
    let id = tasks(&a, c, 1).await[0];
    let n = NodeId::random();
    a.heartbeat(n, node_status(n, 1), 1).await.unwrap();
    assert!(a.result(n, result(id, 100), id).await.is_err());
    assert!(!a.state.lock().await.recorded_results.contains(&id));
    assert_eq!(store.usage_report(c, 0, i64::MAX).await.unwrap().1, 0);
    assert!(a.state.lock().await.meter.records.is_empty());
    a.result(n, result(id, 100), id).await.unwrap();
    a.result(n, result(id, 100), id).await.unwrap();
    assert_eq!(store.usage_report(c, 0, i64::MAX).await.unwrap().1, 1);
    assert_eq!(a.state.lock().await.meter.records.len(), 1);
}

#[tokio::test]
async fn partial_dispatch_delivers_success_and_requeues_failure() {
    let store = failing_store(2, 0);
    let a = app(store.clone());
    let c = ClientId::random();
    let ids = tasks(&a, c, 3).await;
    let n = NodeId::random();
    let response = a.heartbeat(n, node_status(n, 2), 1).await.unwrap();
    assert!(response.acknowledged);
    assert_eq!(response.commands.len(), 1);
    assert!(matches!(
        &response.commands[0].command,
        Some(pb::node_command::Command::ExecuteTask(e)) if e.task_id == ids[0].to_hex()
    ));
    for (index, expected) in [TaskState::Starting, TaskState::Queued, TaskState::Queued]
        .into_iter()
        .enumerate()
    {
        assert_eq!(
            a.get_task(ids[index]).await.unwrap().unwrap().state,
            expected
        );
        assert_eq!(
            store.get_task(ids[index]).await.unwrap().unwrap().state,
            expected
        );
    }
    assert_eq!(
        a.state
            .lock()
            .await
            .queue
            .iter()
            .copied()
            .collect::<Vec<_>>(),
        ids[1..]
    );
    assert!(a.state.lock().await.sessions[&n].reservations.is_empty());
    let response = a.heartbeat(n, node_status(n, 2), 1).await.unwrap();
    assert_eq!(response.commands.len(), 1);
    assert!(matches!(
        &response.commands[0].command,
        Some(pb::node_command::Command::ExecuteTask(e)) if e.task_id == ids[1].to_hex()
    ));
    assert_eq!(
        a.get_task(ids[1]).await.unwrap().unwrap().state,
        TaskState::Starting
    );
}

#[tokio::test]
async fn report_batches_continue_after_store_errors_and_retry_safely() {
    let store = failing_store(5, 2);
    let a = app(store.clone());
    let c = ClientId::random();
    let ids = tasks(&a, c, 3).await;
    let n = NodeId::random();
    a.heartbeat(n, node_status(n, 3), 1).await.unwrap();
    let service = Service { app: a.clone() };
    let output = |id: TaskId| pb::TaskOutputEvent {
        task_id: id.to_hex(),
        data: b"output".to_vec(),
        ..Default::default()
    };
    let auth = heartbeat(n, None, 3).auth;
    let response = service
        .report_task_output(Request::new(pb::ReportTaskOutputRequest {
            auth: auth.clone(),
            events: ids.iter().copied().map(output).collect(),
        }))
        .await;
    assert_eq!(response.unwrap_err().code(), Code::Internal);
    assert_eq!(
        a.get_task(ids[0]).await.unwrap().unwrap().state,
        TaskState::Running
    );
    assert_eq!(
        a.get_task(ids[1]).await.unwrap().unwrap().state,
        TaskState::Starting
    );
    assert_eq!(
        a.get_task(ids[2]).await.unwrap().unwrap().state,
        TaskState::Running
    );
    assert_eq!(a.state.lock().await.tasks[&ids[2]].events.outputs.len(), 1);
    let reports = ids.iter().map(|id| result(*id, 100)).collect::<Vec<_>>();
    let response = service
        .report_task_result(Request::new(pb::ReportTaskResultRequest {
            auth: auth.clone(),
            results: reports.clone(),
        }))
        .await;
    assert_eq!(response.unwrap_err().code(), Code::Internal);
    assert_eq!(
        a.get_task(ids[0]).await.unwrap().unwrap().state,
        TaskState::Completed
    );
    assert_ne!(
        a.get_task(ids[1]).await.unwrap().unwrap().state,
        TaskState::Completed
    );
    assert_eq!(
        a.get_task(ids[2]).await.unwrap().unwrap().state,
        TaskState::Completed
    );
    service
        .report_task_result(Request::new(pb::ReportTaskResultRequest {
            auth,
            results: reports,
        }))
        .await
        .unwrap();
    assert_eq!(store.usage_report(c, 0, i64::MAX).await.unwrap().1, 3);
    assert_eq!(
        store
            .usage_report(c, 0, i64::MAX)
            .await
            .unwrap()
            .0
            .input_tokens,
        300
    );
}

#[tokio::test]
async fn malformed_batch_is_rejected_before_any_entry_is_applied() {
    let a = app(Arc::new(MemoryStore::default()));
    let id = tasks(&a, ClientId::random(), 1).await[0];
    let n = NodeId::random();
    a.heartbeat(n, node_status(n, 1), 1).await.unwrap();
    let service = Service { app: a.clone() };
    let mut malformed = result(id, 100);
    malformed.task_id = "bad".into();
    let response = service
        .report_task_result(Request::new(pb::ReportTaskResultRequest {
            auth: heartbeat(n, None, 1).auth,
            results: vec![result(id, 100), malformed, result(id, 100)],
        }))
        .await;
    assert_eq!(response.unwrap_err().code(), Code::InvalidArgument);
    let response = service
        .report_task_output(Request::new(pb::ReportTaskOutputRequest {
            auth: heartbeat(n, None, 1).auth,
            events: vec![
                pb::TaskOutputEvent {
                    task_id: id.to_hex(),
                    ..Default::default()
                },
                pb::TaskOutputEvent {
                    task_id: "bad".into(),
                    ..Default::default()
                },
            ],
        }))
        .await;
    assert_eq!(response.unwrap_err().code(), Code::InvalidArgument);
    assert_eq!(
        a.get_task(id).await.unwrap().unwrap().state,
        TaskState::Starting
    );
    assert!(a.state.lock().await.meter.records.is_empty());
    assert!(a.state.lock().await.tasks[&id].events.outputs.is_empty());
}

#[tokio::test]
async fn unknown_and_foreign_entries_do_not_stop_report_batches() {
    let store = Arc::new(MemoryStore::default());
    let a = app(store.clone());
    let c = ClientId::random();
    let ids = tasks(&a, c, 3).await;
    let n = NodeId::random();
    let other = NodeId::random();
    a.heartbeat(n, node_status(n, 2), 1).await.unwrap();
    a.heartbeat(other, node_status(other, 1), 1).await.unwrap();
    let service = Service { app: a.clone() };
    let batch = [ids[0], ids[2], TaskId::random(), ids[1]];
    service
        .report_task_output(Request::new(pb::ReportTaskOutputRequest {
            auth: heartbeat(n, None, 2).auth,
            events: batch
                .iter()
                .map(|id| pb::TaskOutputEvent {
                    task_id: id.to_hex(),
                    data: b"output".to_vec(),
                    ..Default::default()
                })
                .collect(),
        }))
        .await
        .unwrap();
    for id in &ids[..2] {
        assert_eq!(
            a.get_task(*id).await.unwrap().unwrap().state,
            TaskState::Running
        );
        assert_eq!(a.state.lock().await.tasks[id].events.outputs.len(), 1);
    }
    assert_eq!(
        a.get_task(ids[2]).await.unwrap().unwrap().state,
        TaskState::Starting
    );
    assert!(
        a.state.lock().await.tasks[&ids[2]]
            .events
            .outputs
            .is_empty()
    );
    service
        .report_task_result(Request::new(pb::ReportTaskResultRequest {
            auth: heartbeat(n, None, 2).auth,
            results: batch.iter().map(|id| result(*id, 100)).collect(),
        }))
        .await
        .unwrap();
    for id in &ids[..2] {
        assert_eq!(
            a.get_task(*id).await.unwrap().unwrap().state,
            TaskState::Completed
        );
    }
    assert_eq!(
        a.get_task(ids[2]).await.unwrap().unwrap().state,
        TaskState::Starting
    );
    assert_eq!(store.usage_report(c, 0, i64::MAX).await.unwrap().1, 2);
}

#[tokio::test]
async fn failed_late_usage_commit_remains_retryable() {
    let store = failing_store(0, 1);
    let a = app(store.clone());
    let c = ClientId::random();
    let id = tasks(&a, c, 1).await[0];
    let n = NodeId::random();
    a.heartbeat(n, node_status(n, 1), 1).await.unwrap();
    assert!(a.cancel(id, c).await.unwrap());
    assert!(a.result(n, result(id, 100), id).await.is_err());
    assert!(!a.state.lock().await.recorded_results.contains(&id));
    assert_eq!(store.usage_report(c, 0, i64::MAX).await.unwrap().1, 0);
    a.result(n, result(id, 100), id).await.unwrap();
    a.result(n, result(id, 100), id).await.unwrap();
    assert_eq!(
        a.get_task(id).await.unwrap().unwrap().state,
        TaskState::Cancelled
    );
    assert_eq!(store.usage_report(c, 0, i64::MAX).await.unwrap().1, 1);
    assert_eq!(a.state.lock().await.meter.records.len(), 1);
}
