//! FIFO placement, live stream reservations and task state ownership.

use crate::{
    auth::Jwt,
    events::{Events, complete_event, state_event},
    metering::{Metering, UsageRecord},
    registry::Registry,
    store::Store,
    telemetry::db_error,
};
use common::{
    ClientId, NodeId, TaskId,
    config::OrchestratorConfig,
    pb,
    types::{NodeStatus, Task, TaskState, UsageMetrics, now_ms},
};
use std::{
    collections::{BTreeMap, HashMap, HashSet, VecDeque},
    sync::Arc,
};
use tokio::sync::Mutex;
use tonic::Status;

/// A task with its submit trace, events and FIFO submission order.
pub struct TrackedTask {
    /// Current task snapshot, including process-local execution secrets.
    pub task: Task,
    /// Trace identifier retained from the submit request.
    pub trace_id: String,
    /// Retained output and live task-event broadcast.
    pub events: Events,
    /// FIFO submission sequence.
    pub order: u64,
}

/// Reservations owned by one live heartbeat stream.
#[derive(Default)]
pub struct NodeSession {
    /// Identity of the heartbeat stream owning these reservations.
    pub generation: u64,
    /// Queued tasks reserved but not yet delivered to the node.
    pub reservations: VecDeque<TaskId>,
    /// Delivered tasks not yet reflected in node VM or task reports.
    pub pending_visible: VecDeque<TaskId>,
}

/// Scheduling and event state protected by the application mutex.
#[derive(Default)]
pub struct State {
    /// Process-local tasks with their traces and event buffers.
    pub tasks: HashMap<TaskId, TrackedTask>,
    /// Unreserved task identifiers in FIFO order.
    pub queue: VecDeque<TaskId>,
    /// Node health snapshots used during placement.
    pub registry: Registry,
    /// Heartbeat streams eligible for scheduling.
    pub sessions: BTreeMap<NodeId, NodeSession>,
    /// In-memory task usage and lifetime totals.
    pub meter: Metering,
    /// Cancellation commands awaiting a node heartbeat.
    pub cancels: BTreeMap<NodeId, VecDeque<TaskId>>,
    /// Unobserved delivered tasks retained across stream disconnects.
    pub disconnected_pending: BTreeMap<NodeId, VecDeque<TaskId>>,
    /// Sequence assigned to the next submitted task.
    pub next_order: u64,
    /// Successfully committed results, checked and marked under the task-state lock.
    pub recorded_results: HashSet<TaskId>,
}

/// Application services sharing configuration, persistence and scheduling state.
pub struct Orchestrator {
    /// Immutable orchestrator configuration.
    pub config: OrchestratorConfig,
    /// Persistence implementation selected at startup.
    pub store: Arc<dyn Store>,
    /// JWT signer and validator for client credentials.
    pub jwt: Jwt,
    /// Mutex protecting scheduling and task-event mutations.
    pub state: Mutex<State>,
    /// PBKDF2 hash used for unknown-account login timing.
    pub dummy_password_hash: String,
    /// Signals live streams to finish during graceful shutdown.
    pub shutdown: tokio::sync::watch::Sender<bool>,
}

impl Orchestrator {
    /// Create the application with its configured persistence implementation.
    pub fn new(config: OrchestratorConfig, store: Arc<dyn Store>) -> Arc<Self> {
        if config.node_auth_key.is_none() {
            tracing::warn!(operation = "startup", "node authentication disabled");
        }
        let jwt = Jwt::new(config.jwt_secret.as_deref());
        let (shutdown, _) = tokio::sync::watch::channel(false);
        Arc::new(Self {
            config,
            store,
            jwt,
            shutdown,
            state: Mutex::new(State::default()),
            dummy_password_hash: crate::auth::hash_password("unknown-user-dummy-password"),
        })
    }

    /// Read a task from memory first, then fall back to persistence.
    pub async fn get_task(&self, id: TaskId) -> Result<Option<Task>, Status> {
        if let Some(t) = self.state.lock().await.tasks.get(&id) {
            return Ok(Some(t.task.clone()));
        }
        self.store
            .get_task(id)
            .await
            .map_err(|e| db_error("get_task", &e))
    }

    /// Read a task only when it belongs to the caller, otherwise return NOT_FOUND.
    pub async fn owned_task(&self, id: TaskId, client: ClientId) -> Result<Task, Status> {
        self.get_task(id)
            .await?
            .filter(|t| t.client_id == client)
            .ok_or_else(|| Status::not_found("Task not found"))
    }

    /// Persist a submitted task, retain its trace and queue it for placement.
    pub async fn submit(&self, task: Task, trace_id: String) -> Result<TaskId, Status> {
        let _op = crate::telemetry::task_operation("submit", task.id, None, &trace_id);
        self.store
            .create_task(&task)
            .await
            .map_err(|e| db_error("create_task", &e))?;
        let mut state = self.state.lock().await;
        let id = task.id;
        let order = state.next_order;
        state.next_order = state.next_order.saturating_add(1);
        state.tasks.insert(
            id,
            TrackedTask {
                task,
                trace_id,
                events: Events::default(),
                order,
            },
        );
        state.queue.push_back(id);
        self.schedule(&mut state);
        Ok(id)
    }

    /// Reserve queued tasks on eligible live nodes in FIFO order.
    pub fn schedule(&self, s: &mut State) {
        let now = now_ms();
        let timeout = i64::try_from(self.config.node_timeout_ms).unwrap_or(i64::MAX);
        while let Some(id) = s.queue.front().copied() {
            let best = s
                .sessions
                .iter()
                .filter_map(|(id, session)| {
                    let (status, last) = s.registry.nodes.get(id)?;
                    if now.saturating_sub(*last) >= timeout || !status.healthy || status.draining {
                        return None;
                    }
                    let held = session
                        .reservations
                        .len()
                        .saturating_add(session.pending_visible.len());
                    let free = status
                        .available_slots()
                        .saturating_sub(u32::try_from(held).unwrap_or(u32::MAX));
                    if free == 0 {
                        return None;
                    }
                    let mut effective = status.clone();
                    effective.active_vms = effective.total_vm_slots.saturating_sub(free);
                    Some((*id, effective.score()))
                })
                .max_by(|(aid, a), (bid, b)| a.total_cmp(b).then_with(|| bid.cmp(aid)))
                .map(|(id, _)| id);
            let Some(node) = best else {
                break;
            };
            s.queue.pop_front();
            if let Some(session) = s.sessions.get_mut(&node) {
                session.reservations.push_back(id);
            }
        }
        self.gauges(s);
    }

    /// Release the stream reservations while retaining undelivered task order.
    pub fn release(&self, s: &mut State, node: NodeId, generation: u64) {
        if s.sessions
            .get(&node)
            .is_none_or(|n| n.generation != generation)
        {
            return;
        }
        if let Some(session) = s.sessions.remove(&node) {
            s.disconnected_pending
                .entry(node)
                .or_default()
                .extend(session.pending_visible);
            let mut released: Vec<_> = session.reservations.into_iter().collect();
            metrics::counter!("marathon_requeues_total").increment(released.len() as u64);
            released.extend(s.queue.drain(..));
            released.sort_by_key(|id| s.tasks.get(id).map(|t| t.order).unwrap_or(u64::MAX));
            s.queue = released.into();
        }
        self.schedule(s);
    }

    /// Expire stale nodes and release their undelivered reservations.
    pub async fn sweep(&self) {
        let mut s = self.state.lock().await;
        let stale = s.registry.remove_stale(
            now_ms(),
            i64::try_from(self.config.node_timeout_ms).unwrap_or(i64::MAX),
        );
        for id in stale {
            tracing::warn!(
                operation="expire_node",
                node_id = %id,
                "node heartbeat expired"
            );
            if let Some(generation) = s.sessions.get(&id).map(|n| n.generation) {
                self.release(&mut s, id, generation);
            }
        }
        self.gauges(&s);
    }

    fn gauges(&self, s: &State) {
        metrics::gauge!("marathon_queue_depth").set(
            (s.queue.len()
                + s.sessions
                    .values()
                    .map(|n| n.reservations.len())
                    .sum::<usize>()) as f64,
        );
        metrics::gauge!("marathon_registered_nodes").set(s.registry.node_count() as f64);
        metrics::gauge!("marathon_live_heartbeat_streams").set(s.sessions.len() as f64);
    }

    async fn transition(&self, t: &mut TrackedTask, to: TaskState) -> Result<(), Status> {
        let previous = t.task.state.to_wire();
        let mut task = t.task.clone();
        task.transition_to(to)
            .map_err(|_| Status::failed_precondition("Invalid task transition"))?;
        self.store
            .save_task(&task)
            .await
            .map_err(|e| db_error("save_task", &e))?;
        t.task = task;
        let op = common::telemetry::Operation::start("task_transition").task_id(&t.task.id);
        op.span().in_scope(|| {
            tracing::info!(
                task_id = %t.task.id,
                node_id = ?t.task.node_id,
                trace_id = %t.trace_id,
                state = t.task.state.as_str(),
                operation="task_transition",
                "task state changed"
            )
        });
        t.events.publish(state_event(&t.task, previous));
        Ok(())
    }

    /// Refresh node status and deliver commands, persisting STARTING on dispatch.
    pub async fn heartbeat(
        &self,
        node: NodeId,
        status: NodeStatus,
        generation: u64,
    ) -> Result<pb::HeartbeatResponse, Status> {
        let _op = common::telemetry::Operation::start("node_heartbeat").node_id(&node);
        let mut s = self.state.lock().await;
        if let Some(old) = s.sessions.get(&node).map(|n| n.generation)
            && old != generation
        {
            self.release(&mut s, node, old);
        }
        let previous_active = s.registry.get(node).map(|n| n.active_vms).unwrap_or(0);
        s.registry.register(status.clone(), now_ms());
        let restored = s.disconnected_pending.remove(&node).unwrap_or_default();
        let session = s.sessions.entry(node).or_insert_with(|| NodeSession {
            generation,
            ..NodeSession::default()
        });
        session.pending_visible.extend(restored);
        let held = session.pending_visible.len();
        session
            .pending_visible
            .retain(|id| !status.active_task_ids.contains(id));
        let newly_visible = held - session.pending_visible.len();
        // Nodes may report only the VM count. Credit increases not already covered
        // by task ids, retaining reservations while a VM is being started.
        let increase = status.active_vms.saturating_sub(previous_active) as usize;
        let credit = increase.saturating_sub(newly_visible);
        for _ in 0..credit {
            session.pending_visible.pop_front();
        }
        for id in &status.active_task_ids {
            if let Some(t) = s.tasks.get_mut(id)
                && t.task.node_id == Some(node)
                && t.task.state == TaskState::Starting
            {
                self.transition(t, TaskState::Running).await?;
            }
        }
        if let Err(e) = self.store.upsert_node(&status).await {
            db_error("upsert_node", &e);
            tracing::warn!(
                operation="upsert_node",
                node_id = %node,
                "node persistence degraded"
            );
        }
        self.schedule(&mut s);
        let ids: Vec<_> = s
            .sessions
            .get(&node)
            .map(|n| n.reservations.iter().copied().collect())
            .unwrap_or_default();
        let mut commands = vec![];
        let mut failed = Vec::new();
        for id in ids {
            if let Some(t) = s.tasks.get_mut(&id) {
                if t.task.state != TaskState::Queued {
                    continue;
                }
                let _op = crate::telemetry::task_operation("dispatch", id, Some(node), &t.trace_id);
                let mut task = t.task.clone();
                task.node_id = Some(node);
                task.started_at = Some(now_ms());
                task.transition_to(TaskState::Starting)
                    .map_err(|_| Status::internal("Invalid queued task"))?;
                if let Err(error) = self.store.save_task(&task).await {
                    db_error("update_started", &error);
                    tracing::error!(
                        operation = "dispatch",
                        task_id = %id,
                        node_id = %node,
                        error = %error,
                        "starting persistence failed; task requeued"
                    );
                    // The queued snapshot is unchanged until persistence succeeds.
                    failed.push(id);
                    if let Some(session) = s.sessions.get_mut(&node) {
                        session.reservations.retain(|reserved| *reserved != id);
                    }
                    continue;
                }
                t.task = task;
                commands.push(pb::NodeCommand {
                    command: Some(pb::node_command::Command::ExecuteTask(
                        self.execute(&t.task),
                    )),
                });
                t.events
                    .publish(state_event(&t.task, TaskState::Queued.to_wire()));
                tracing::info!(
                    operation="dispatch",
                    task_id = %id,
                    node_id = %node,
                    trace_id = %t.trace_id,
                    "task starting"
                );
                if let Some(session) = s.sessions.get_mut(&node) {
                    session.reservations.retain(|r| *r != id);
                    session.pending_visible.push_back(id);
                }
            }
        }
        let cancelled_ids: Vec<_> = s
            .cancels
            .remove(&node)
            .map(|ids| ids.into_iter().collect())
            .unwrap_or_default();
        if let Some(session) = s.sessions.get_mut(&node) {
            session
                .pending_visible
                .retain(|id| !cancelled_ids.contains(id));
        }
        {
            commands.extend(cancelled_ids.into_iter().map(|id| pb::NodeCommand {
                command: Some(pb::node_command::Command::CancelTask(pb::CancelTask {
                    task_id: id.to_hex(),
                })),
            }));
        }
        if failed.is_empty() {
            self.schedule(&mut s);
        } else {
            metrics::counter!("marathon_requeues_total").increment(failed.len() as u64);
            // Keep failed reservations at the front, in their original FIFO order.
            for id in failed.into_iter().rev() {
                s.queue.push_front(id);
            }
            self.gauges(&s);
        }
        Ok(pb::HeartbeatResponse {
            timestamp: now_ms(),
            acknowledged: true,
            commands,
        })
    }

    /// Build the node execution command with the task fields and configured secrets.
    pub fn execute(&self, t: &Task) -> pb::ExecuteTask {
        pb::ExecuteTask {
            task_id: t.id.to_hex(),
            repo_url: t.repo_url.clone(),
            branch: t.branch.clone(),
            prompt: t.prompt.clone(),
            github_token: t.github_token.clone().unwrap_or_default(),
            anthropic_api_key: self.config.anthropic_api_key.clone(),
            create_pr: t.create_pr,
            pr_title: t.pr_title.clone(),
            pr_body: t.pr_body.clone(),
            timeout_ms: 600_000,
            max_tokens: 100_000,
            env_vars: t.env_vars.iter().cloned().map(Into::into).collect(),
            max_iterations: t.max_iterations,
            completion_promise: t.completion_promise.clone(),
        }
    }

    /// Persist cancellation and arrange a node command for an active task.
    pub async fn cancel(&self, id: TaskId, client: ClientId) -> Result<bool, Status> {
        let mut s = self.state.lock().await;
        let task = match s.tasks.get(&id) {
            Some(t) => t.task.clone(),
            None => self
                .store
                .get_task(id)
                .await
                .map_err(|e| db_error("get_task", &e))?
                .ok_or_else(|| Status::not_found("Task not found"))?,
        };
        let trace = s.tasks.get(&id).map(|t| t.trace_id.as_str()).unwrap_or("");
        let _op = crate::telemetry::task_operation("cancel", id, task.node_id, trace);
        if task.client_id != client {
            return Err(Status::not_found("Task not found"));
        }
        if task.state.is_terminal() {
            return Ok(false);
        }
        let mut cancelled = task.clone();
        cancelled
            .transition_to(TaskState::Cancelled)
            .map_err(|_| Status::failed_precondition("Task cannot be cancelled"))?;
        cancelled.completed_at = Some(now_ms());
        self.store
            .save_task(&cancelled)
            .await
            .map_err(|e| db_error("cancel_task", &e))?;
        if let Some(t) = s.tasks.get_mut(&id) {
            t.task = cancelled;
            t.events.publish(complete_event(&t.task));
            tracing::info!(
                operation="cancel",
                task_id = %id,
                trace_id = %t.trace_id,
                "task cancelled"
            );
        }
        s.queue.retain(|i| *i != id);
        for session in s.sessions.values_mut() {
            session.reservations.retain(|i| *i != id);
        }
        if matches!(task.state, TaskState::Starting | TaskState::Running)
            && let Some(node) = task.node_id
        {
            // Keep pending cancellation across heartbeat stream reconnects.
            s.cancels.entry(node).or_default().push_back(id);
        }
        self.schedule(&mut s);
        Ok(true)
    }

    /// Publish assigned-node output, retrying RUNNING persistence without dropping output.
    pub async fn output(
        &self,
        node: NodeId,
        event: pb::TaskOutputEvent,
        id: TaskId,
    ) -> Result<(), Status> {
        let mut s = self.state.lock().await;
        if let Some(t) = s.tasks.get_mut(&id) {
            let _op = crate::telemetry::task_operation("output", id, Some(node), &t.trace_id);
            if t.task.node_id != Some(node) || t.task.state.is_terminal() {
                tracing::warn!(
                    operation="output",
                    task_id = %id,
                    node_id = %node,
                    "output ignored"
                );
                return Ok(());
            }
            if t.task.state == TaskState::Starting
                && let Err(error) = self.transition(t, TaskState::Running).await
            {
                metrics::counter!("marathon_db_errors_total", "operation" => "output_running")
                    .increment(1);
                // transition keeps the STARTING snapshot when its store write fails.
                // Output is process-local; publish it so the node need not resend it.
                tracing::error!(
                    operation = "output",
                    task_id = %id,
                    node_id = %node,
                    error = %error,
                    "running persistence failed; output retained"
                );
            }
            t.events.publish(pb::TaskEvent {
                task_id: id.to_hex(),
                state: t.task.state.to_wire(),
                timestamp: event.timestamp,
                event: Some(pb::task_event::Event::Output(pb::TaskOutput {
                    r#type: event.r#type,
                    data: event.data,
                })),
            });
            tracing::debug!(
                operation="output",
                task_id = %id,
                node_id = %node,
                trace_id = %t.trace_id,
                "task output received"
            );
        }
        Ok(())
    }

    /// Commit an assigned-node result once, including the first late cancelled result.
    pub async fn result(
        &self,
        node: NodeId,
        result: pb::TaskResult,
        id: TaskId,
    ) -> Result<(), Status> {
        let mut s = self.state.lock().await;
        let current = match s.tasks.get(&id) {
            Some(t) => Some(t.task.clone()),
            None => self
                .store
                .get_task(id)
                .await
                .map_err(|e| db_error("get_task", &e))?,
        };
        let Some(mut task) = current.filter(|t| t.node_id == Some(node)) else {
            tracing::warn!(
                operation="result",
                task_id = %id,
                node_id = %node,
                "unassigned task result ignored"
            );
            return Ok(());
        };
        let trace = s.tasks.get(&id).map(|t| t.trace_id.as_str()).unwrap_or("");
        let _op = crate::telemetry::task_operation("result", id, Some(node), trace);
        if s.recorded_results.contains(&id)
            || matches!(task.state, TaskState::Completed | TaskState::Failed)
            || self
                .store
                .has_task_usage(id)
                .await
                .map_err(|error| db_error("has_task_usage", &error))?
        {
            tracing::warn!(
                operation = "result",
                task_id = %id,
                node_id = %node,
                "duplicate task result ignored"
            );
            metrics::counter!("marathon_duplicate_results_total").increment(1);
            return Ok(());
        }
        let usage: UsageMetrics = result.metrics.unwrap_or_default().into();
        let completed = now_ms();
        let terminal = task.state.is_terminal();
        if !terminal {
            if task.state == TaskState::Starting {
                if let Some(t) = s.tasks.get_mut(&id) {
                    self.transition(t, TaskState::Running).await?;
                    task = t.task.clone();
                } else {
                    task.transition_to(TaskState::Running)
                        .map_err(|_| Status::failed_precondition("Invalid result state"))?;
                }
            }
            task.transition_to(if result.success {
                TaskState::Completed
            } else {
                TaskState::Failed
            })
            .map_err(|_| Status::failed_precondition("Invalid result state"))?;
            task.completed_at = Some(completed);
            task.usage = usage;
            task.error_message = result.error_message;
            task.pr_url = result.pr_url;
        }
        let record = UsageRecord {
            client_id: task.client_id,
            task_id: id,
            timestamp: completed,
            usage,
        };
        self.store
            .commit_result(&task, &record, !terminal)
            .await
            .map_err(|e| db_error("commit_result", &e))?;
        // The store commit succeeded. A failed write leaves this task retryable.
        s.recorded_results.insert(id);
        s.meter.record(record);
        if let Some(t) = s.tasks.get_mut(&id) {
            t.task = task.clone();
            if !terminal {
                t.events.publish(complete_event(&task));
            }
            tracing::info!(
                operation="result",
                task_id = %id,
                node_id = %node,
                trace_id = %t.trace_id,
                state = task.state.as_str(),
                "task result recorded"
            );
        }
        if let Some(session) = s.sessions.get_mut(&node) {
            session.pending_visible.retain(|i| *i != id);
        }
        if let Some(pending) = s.disconnected_pending.get_mut(&node) {
            pending.retain(|i| *i != id);
        }
        metrics::histogram!("marathon_task_execution_ms").record(usage.compute_time_ms as f64);
        self.schedule(&mut s);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::MemoryStore;

    fn app() -> Arc<Orchestrator> {
        Orchestrator::new(
            OrchestratorConfig {
                jwt_secret: Some("test".into()),
                ..OrchestratorConfig::default()
            },
            Arc::new(MemoryStore::default()),
        )
    }

    async fn submit(a: &Orchestrator, c: ClientId) -> TaskId {
        a.submit(
            Task::new(c, "https://github.com/test/repo", "main", "prompt"),
            "trace".into(),
        )
        .await
        .unwrap()
    }

    // Port of scheduler/scheduler.zig "scheduler basic operations"
    #[tokio::test]
    async fn basic_operations() {
        let a = app();
        let id = submit(&a, ClientId::random()).await;
        assert_eq!(
            a.get_task(id).await.unwrap().unwrap().state,
            TaskState::Queued
        );
        assert_eq!(a.state.lock().await.queue.len(), 1);
    }

    // Port of scheduler/scheduler.zig "scheduler getTask returns copy not pointer"
    #[tokio::test]
    async fn task_copy() {
        let a = app();
        let id = submit(&a, ClientId::random()).await;
        let mut t = a.get_task(id).await.unwrap().unwrap();
        t.prompt = "changed".into();
        assert_eq!(a.get_task(id).await.unwrap().unwrap().prompt, "prompt");
    }

    // Port of scheduler/scheduler.zig "scheduler getTaskState returns state only"
    #[tokio::test]
    async fn task_state() {
        let a = app();
        let id = submit(&a, ClientId::random()).await;
        assert_eq!(
            a.get_task(id).await.unwrap().map(|t| t.state),
            Some(TaskState::Queued)
        );
        assert!(a.get_task(TaskId::random()).await.unwrap().is_none());
    }

    // Port of scheduler/scheduler.zig "scheduler cancelTask"
    #[tokio::test]
    async fn cancel_twice() {
        let a = app();
        let c = ClientId::random();
        let id = submit(&a, c).await;
        assert!(a.cancel(id, c).await.unwrap());
        assert!(!a.cancel(id, c).await.unwrap());
        let t = a.get_task(id).await.unwrap().unwrap();
        assert_eq!(t.state, TaskState::Cancelled);
        assert!(t.completed_at.is_some());
        assert!(a.state.lock().await.queue.is_empty());
    }

    // Port of scheduler/scheduler.zig "scheduler listTasks filters by client"
    #[tokio::test]
    async fn lists_client() {
        let a = app();
        let c = ClientId::random();
        submit(&a, c).await;
        submit(&a, c).await;
        submit(&a, ClientId::random()).await;
        assert_eq!(a.store.list_tasks(c, None, 0, 0).await.unwrap().1, 2);
    }

    // Port of scheduler/scheduler.zig "scheduler listTasks respects limit"
    #[tokio::test]
    async fn lists_limit() {
        let a = app();
        let c = ClientId::random();
        for _ in 0..5 {
            submit(&a, c).await;
        }
        let (tasks, total) = a.store.list_tasks(c, None, 2, 1).await.unwrap();
        assert_eq!(tasks.len(), 2);
        assert_eq!(total, 5);
    }

    // Port of scheduler/scheduler.zig "scheduler listTasks filters by state"
    #[tokio::test]
    async fn lists_state() {
        let a = app();
        let c = ClientId::random();
        let id = submit(&a, c).await;
        submit(&a, c).await;
        a.cancel(id, c).await.unwrap();
        assert_eq!(
            a.store
                .list_tasks(c, Some(TaskState::Queued), 0, 0)
                .await
                .unwrap()
                .1,
            1
        );
        assert_eq!(
            a.store
                .list_tasks(c, Some(TaskState::Cancelled), 0, 0)
                .await
                .unwrap()
                .1,
            1
        );
    }

    // Port of scheduler/scheduler.zig "scheduler completeTask updates state and metrics"
    #[tokio::test]
    async fn complete_metrics() {
        let a = app();
        let id = submit(&a, ClientId::random()).await;
        let node = NodeId::random();
        a.heartbeat(
            node,
            NodeStatus {
                node_id: node,
                total_vm_slots: 1,
                healthy: true,
                ..NodeStatus::default()
            },
            1,
        )
        .await
        .unwrap();
        a.result(
            node,
            pb::TaskResult {
                task_id: id.to_hex(),
                success: true,
                metrics: Some(pb::UsageMetrics {
                    input_tokens: 100,
                    output_tokens: 50,
                    ..pb::UsageMetrics::default()
                }),
                pr_url: Some("https://github.com/test/repo/pull/1".into()),
                ..pb::TaskResult::default()
            },
            id,
        )
        .await
        .unwrap();
        let t = a.get_task(id).await.unwrap().unwrap();
        assert_eq!(t.state, TaskState::Completed);
        assert_eq!(t.usage.input_tokens, 100);
        assert_eq!(t.usage.output_tokens, 50);
    }

    #[tokio::test]
    async fn reservations_release_and_capacity() {
        let a = app();
        let node = NodeId::random();
        let status = NodeStatus {
            node_id: node,
            total_vm_slots: 1,
            healthy: true,
            ..NodeStatus::default()
        };
        a.heartbeat(node, status.clone(), 1).await.unwrap();
        let first = submit(&a, ClientId::random()).await;
        let second = submit(&a, ClientId::random()).await;
        {
            let mut s = a.state.lock().await;
            assert_eq!(s.sessions[&node].reservations.len(), 1);
            assert_eq!(s.queue, VecDeque::from([second]));
            a.release(&mut s, node, 1);
            assert_eq!(s.queue, VecDeque::from([first, second]));
        }
        let response = a.heartbeat(node, status.clone(), 2).await.unwrap();
        assert_eq!(response.commands.len(), 1);
        let response = a.heartbeat(node, status, 2).await.unwrap();
        assert!(response.commands.is_empty());
        assert_eq!(
            a.get_task(second).await.unwrap().unwrap().state,
            TaskState::Queued
        );
    }

    // Port of auth/auth.zig "authenticator getAnthropicKey"
    #[test]
    fn anthropic_key() {
        let a = Orchestrator::new(
            OrchestratorConfig {
                anthropic_api_key: "test-secret".into(),
                jwt_secret: Some("test".into()),
                ..OrchestratorConfig::default()
            },
            Arc::new(MemoryStore::default()),
        );
        let e = a.execute(&Task::default());
        assert_eq!(e.anthropic_api_key, "test-secret");
        assert_eq!(e.timeout_ms, 600000);
        assert_eq!(e.max_tokens, 100000);
    }

    #[tokio::test]
    async fn expiry_releases_only_undelivered_tasks() {
        let a = app();
        let c = ClientId::random();
        let node = NodeId::random();
        let status = NodeStatus {
            node_id: node,
            total_vm_slots: 2,
            healthy: true,
            ..Default::default()
        };
        let started = submit(&a, c).await;
        a.heartbeat(node, status.clone(), 1).await.unwrap();
        let reserved = submit(&a, c).await;
        {
            let mut s = a.state.lock().await;
            s.registry.nodes.get_mut(&node).unwrap().1 = now_ms() - 30001;
        }
        a.sweep().await;
        {
            let s = a.state.lock().await;
            assert_eq!(s.queue, VecDeque::from([reserved]));
            assert!(!s.sessions.contains_key(&node));
        }
        assert_eq!(
            a.get_task(started).await.unwrap().unwrap().state,
            TaskState::Starting
        );
        // The returning stream counts the delivered, unobserved task against capacity.
        let hb = a.heartbeat(node, status, 2).await.unwrap();
        assert_eq!(hb.commands.len(), 1);
        let queued = submit(&a, c).await;
        assert!(a.state.lock().await.queue.contains(&queued));
    }

    #[tokio::test]
    async fn deterministic_scoring_and_offline_cancel() {
        let a = app();
        let c = ClientId::random();
        let low = NodeId([1; 16]);
        let high = NodeId([2; 16]);
        for node in [high, low] {
            a.heartbeat(
                node,
                NodeStatus {
                    node_id: node,
                    total_vm_slots: 1,
                    healthy: true,
                    ..Default::default()
                },
                1,
            )
            .await
            .unwrap();
        }
        let id = submit(&a, c).await;
        assert_eq!(
            a.state.lock().await.sessions[&low].reservations,
            VecDeque::from([id])
        );
        assert!(a.cancel(id, c).await.unwrap());
        assert!(a.state.lock().await.sessions[&low].reservations.is_empty());
        let running = submit(&a, c).await;
        a.heartbeat(
            low,
            NodeStatus {
                node_id: low,
                total_vm_slots: 1,
                healthy: true,
                ..Default::default()
            },
            1,
        )
        .await
        .unwrap();
        {
            let mut s = a.state.lock().await;
            a.release(&mut s, low, 1);
        }
        a.cancel(running, c).await.unwrap();
        assert!(!a.state.lock().await.sessions.contains_key(&low));
        let hb = a
            .heartbeat(
                low,
                NodeStatus {
                    node_id: low,
                    total_vm_slots: 1,
                    healthy: true,
                    ..Default::default()
                },
                2,
            )
            .await
            .unwrap();
        assert!(matches!(
            hb.commands[0].command,
            Some(pb::node_command::Command::CancelTask(_))
        ));
    }
}
