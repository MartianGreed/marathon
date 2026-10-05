//! Domain types: the task state machine, usage metrics, node status and the
//! node scoring used by the scheduler.

use std::time::{SystemTime, UNIX_EPOCH};

use crate::ids::{ClientId, NodeId, TaskId, VmId};
use crate::pb;
use crate::redact::{OptSecret, Secret};

/// Current unix time in milliseconds.
pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// Task lifecycle state.
///
/// ```text
/// Unspecified -> Queued -> Starting -> Running -> Completed
///                  |          |  \        |  \--> Failed
///                  |          |   \-> Failed \--> Cancelled
///                  \----------\-----> Cancelled
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum TaskState {
    #[default]
    Unspecified,
    Queued,
    Starting,
    Running,
    Completed,
    Failed,
    Cancelled,
}

/// A state change the state machine does not allow.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("invalid task state transition from {from:?} to {to:?}")]
pub struct InvalidTransition {
    pub from: TaskState,
    pub to: TaskState,
}

impl TaskState {
    /// Completed, failed and cancelled are final.
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }

    /// Whether `self -> to` is an allowed transition.
    pub fn can_transition_to(self, to: TaskState) -> bool {
        match self {
            Self::Unspecified => to == Self::Queued,
            Self::Queued => matches!(to, Self::Starting | Self::Cancelled),
            Self::Starting => matches!(to, Self::Running | Self::Failed | Self::Cancelled),
            Self::Running => matches!(to, Self::Completed | Self::Failed | Self::Cancelled),
            Self::Completed | Self::Failed | Self::Cancelled => false,
        }
    }

    /// Lowercase name as the Zig CLI printed it (`queued`, `running`, ...).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unspecified => "unspecified",
            Self::Queued => "queued",
            Self::Starting => "starting",
            Self::Running => "running",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }
}

impl From<pb::TaskState> for TaskState {
    fn from(state: pb::TaskState) -> Self {
        match state {
            pb::TaskState::Unspecified => Self::Unspecified,
            pb::TaskState::Queued => Self::Queued,
            pb::TaskState::Starting => Self::Starting,
            pb::TaskState::Running => Self::Running,
            pb::TaskState::Completed => Self::Completed,
            pb::TaskState::Failed => Self::Failed,
            pb::TaskState::Cancelled => Self::Cancelled,
        }
    }
}

impl From<TaskState> for pb::TaskState {
    fn from(state: TaskState) -> Self {
        match state {
            TaskState::Unspecified => Self::Unspecified,
            TaskState::Queued => Self::Queued,
            TaskState::Starting => Self::Starting,
            TaskState::Running => Self::Running,
            TaskState::Completed => Self::Completed,
            TaskState::Failed => Self::Failed,
            TaskState::Cancelled => Self::Cancelled,
        }
    }
}

impl TaskState {
    /// Decode the raw `i32` of a protobuf enum field. Unknown values map to
    /// `Unspecified`.
    pub fn from_wire(value: i32) -> Self {
        pb::TaskState::try_from(value)
            .map(Self::from)
            .unwrap_or_default()
    }

    /// The raw `i32` for a protobuf enum field.
    pub fn to_wire(self) -> i32 {
        pb::TaskState::from(self) as i32
    }
}

/// Origin of a chunk of task output.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum OutputType {
    #[default]
    Unspecified,
    Stdout,
    Stderr,
    /// Claude Code structured output.
    Claude,
}

impl From<pb::OutputType> for OutputType {
    fn from(t: pb::OutputType) -> Self {
        match t {
            pb::OutputType::Unspecified => Self::Unspecified,
            pb::OutputType::Stdout => Self::Stdout,
            pb::OutputType::Stderr => Self::Stderr,
            pb::OutputType::Claude => Self::Claude,
        }
    }
}

impl From<OutputType> for pb::OutputType {
    fn from(t: OutputType) -> Self {
        match t {
            OutputType::Unspecified => Self::Unspecified,
            OutputType::Stdout => Self::Stdout,
            OutputType::Stderr => Self::Stderr,
            OutputType::Claude => Self::Claude,
        }
    }
}

impl OutputType {
    /// Decode the raw `i32` of a protobuf enum field. Unknown values map to
    /// `Unspecified`.
    pub fn from_wire(value: i32) -> Self {
        pb::OutputType::try_from(value)
            .map(Self::from)
            .unwrap_or_default()
    }

    /// The raw `i32` for a protobuf enum field.
    pub fn to_wire(self) -> i32 {
        pb::OutputType::from(self) as i32
    }
}

/// Token and compute usage.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct UsageMetrics {
    pub compute_time_ms: i64,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_write_tokens: i64,
    pub tool_calls: i64,
}

impl UsageMetrics {
    /// Add `other` field by field (saturating).
    pub fn add(&mut self, other: &UsageMetrics) {
        self.compute_time_ms = self.compute_time_ms.saturating_add(other.compute_time_ms);
        self.input_tokens = self.input_tokens.saturating_add(other.input_tokens);
        self.output_tokens = self.output_tokens.saturating_add(other.output_tokens);
        self.cache_read_tokens = self
            .cache_read_tokens
            .saturating_add(other.cache_read_tokens);
        self.cache_write_tokens = self
            .cache_write_tokens
            .saturating_add(other.cache_write_tokens);
        self.tool_calls = self.tool_calls.saturating_add(other.tool_calls);
    }
}

impl From<pb::UsageMetrics> for UsageMetrics {
    fn from(m: pb::UsageMetrics) -> Self {
        Self {
            compute_time_ms: m.compute_time_ms,
            input_tokens: m.input_tokens,
            output_tokens: m.output_tokens,
            cache_read_tokens: m.cache_read_tokens,
            cache_write_tokens: m.cache_write_tokens,
            tool_calls: m.tool_calls,
        }
    }
}

impl From<UsageMetrics> for pb::UsageMetrics {
    fn from(m: UsageMetrics) -> Self {
        Self {
            compute_time_ms: m.compute_time_ms,
            input_tokens: m.input_tokens,
            output_tokens: m.output_tokens,
            cache_read_tokens: m.cache_read_tokens,
            cache_write_tokens: m.cache_write_tokens,
            tool_calls: m.tool_calls,
        }
    }
}

/// The vsock metrics carry no compute time; it is left at zero.
impl From<pb::VsockMetrics> for UsageMetrics {
    fn from(m: pb::VsockMetrics) -> Self {
        Self {
            compute_time_ms: 0,
            input_tokens: m.input_tokens,
            output_tokens: m.output_tokens,
            cache_read_tokens: m.cache_read_tokens,
            cache_write_tokens: m.cache_write_tokens,
            tool_calls: m.tool_calls,
        }
    }
}

impl From<UsageMetrics> for pb::VsockMetrics {
    fn from(m: UsageMetrics) -> Self {
        Self {
            input_tokens: m.input_tokens,
            output_tokens: m.output_tokens,
            cache_read_tokens: m.cache_read_tokens,
            cache_write_tokens: m.cache_write_tokens,
            tool_calls: m.tool_calls,
        }
    }
}

/// One environment variable for the agent. Order is significant. `Debug`
/// hides the value.
#[derive(Clone, PartialEq, Eq, Default)]
pub struct EnvVar {
    pub key: String,
    pub value: String,
}

impl std::fmt::Debug for EnvVar {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EnvVar")
            .field("key", &self.key)
            .field("value", &Secret(&self.value))
            .finish()
    }
}

impl From<pb::EnvVar> for EnvVar {
    fn from(v: pb::EnvVar) -> Self {
        Self {
            key: v.key,
            value: v.value,
        }
    }
}

impl From<EnvVar> for pb::EnvVar {
    fn from(v: EnvVar) -> Self {
        Self {
            key: v.key,
            value: v.value,
        }
    }
}

/// A task as the orchestrator tracks it. `Debug` hides the GitHub token and
/// env var values.
#[derive(Clone, PartialEq, Default)]
pub struct Task {
    pub id: TaskId,
    pub client_id: ClientId,
    pub state: TaskState,

    pub repo_url: String,
    pub branch: String,
    pub prompt: String,

    pub node_id: Option<NodeId>,
    pub vm_id: Option<VmId>,

    pub created_at: i64,
    pub started_at: Option<i64>,
    pub completed_at: Option<i64>,

    pub error_message: Option<String>,
    pub pr_url: Option<String>,

    pub usage: UsageMetrics,

    pub create_pr: bool,
    pub pr_title: Option<String>,
    pub pr_body: Option<String>,
    pub github_token: Option<String>,

    pub env_vars: Vec<EnvVar>,
    pub max_iterations: Option<u32>,
    pub completion_promise: Option<String>,
}

impl std::fmt::Debug for Task {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Task")
            .field("id", &self.id)
            .field("client_id", &self.client_id)
            .field("state", &self.state)
            .field("repo_url", &self.repo_url)
            .field("branch", &self.branch)
            .field("prompt", &self.prompt)
            .field("node_id", &self.node_id)
            .field("vm_id", &self.vm_id)
            .field("created_at", &self.created_at)
            .field("started_at", &self.started_at)
            .field("completed_at", &self.completed_at)
            .field("error_message", &self.error_message)
            .field("pr_url", &self.pr_url)
            .field("usage", &self.usage)
            .field("create_pr", &self.create_pr)
            .field("pr_title", &self.pr_title)
            .field("pr_body", &self.pr_body)
            .field("github_token", &OptSecret(self.github_token.as_deref()))
            .field("env_vars", &self.env_vars)
            .field("max_iterations", &self.max_iterations)
            .field("completion_promise", &self.completion_promise)
            .finish()
    }
}

impl Task {
    /// A new queued task with a random id, created now.
    pub fn new(
        client_id: ClientId,
        repo_url: impl Into<String>,
        branch: impl Into<String>,
        prompt: impl Into<String>,
    ) -> Self {
        Self {
            id: TaskId::random(),
            client_id,
            state: TaskState::Queued,
            repo_url: repo_url.into(),
            branch: branch.into(),
            prompt: prompt.into(),
            created_at: now_ms(),
            ..Self::default()
        }
    }

    /// Move to `to` if the state machine allows it.
    pub fn transition_to(&mut self, to: TaskState) -> Result<(), InvalidTransition> {
        if !self.state.can_transition_to(to) {
            return Err(InvalidTransition {
                from: self.state,
                to,
            });
        }
        self.state = to;
        Ok(())
    }

    /// The client-facing protobuf view. Omits the GitHub token and env vars.
    pub fn to_proto(&self) -> pb::Task {
        pb::Task {
            id: self.id.to_hex(),
            client_id: self.client_id.to_hex(),
            state: self.state.to_wire(),
            repo_url: self.repo_url.clone(),
            branch: self.branch.clone(),
            prompt: self.prompt.clone(),
            node_id: self.node_id.map(|id| id.to_hex()),
            vm_id: self.vm_id.map(|id| id.to_hex()),
            created_at: self.created_at,
            started_at: self.started_at,
            completed_at: self.completed_at,
            error_message: self.error_message.clone(),
            pr_url: self.pr_url.clone(),
            usage: Some(self.usage.into()),
            create_pr: self.create_pr,
            pr_title: self.pr_title.clone(),
            pr_body: self.pr_body.clone(),
            max_iterations: self.max_iterations,
            completion_promise: self.completion_promise.clone(),
        }
    }
}

/// Capacity and health of a node, as reported by its heartbeats.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct NodeStatus {
    pub node_id: NodeId,
    pub hostname: String,

    pub total_vm_slots: u32,
    pub active_vms: u32,
    pub warm_vms: u32,

    pub cpu_usage: f64,
    pub memory_usage: f64,
    pub disk_available_bytes: i64,

    pub healthy: bool,
    pub draining: bool,
    pub uptime_seconds: i64,
    pub last_task_at: Option<i64>,

    pub active_task_ids: Vec<TaskId>,
}

impl NodeStatus {
    /// Free VM slots.
    pub fn available_slots(&self) -> u32 {
        self.total_vm_slots.saturating_sub(self.active_vms)
    }

    /// Placement score in `[0, 1]`; higher is better, `0` means the node
    /// cannot take a task (unhealthy, draining or full).
    ///
    /// `0.3 * free slot ratio + 0.4 * warm VM ratio + 0.15 * (1 - cpu) +
    /// 0.15 * (1 - memory)`.
    pub fn score(&self) -> f64 {
        if !self.healthy || self.draining {
            return 0.0;
        }
        let available = self.available_slots();
        if available == 0 {
            return 0.0;
        }
        let total = f64::from(self.total_vm_slots);
        let slot_factor = f64::from(available) / total;
        let warm_factor = f64::from(self.warm_vms) / f64::from(self.total_vm_slots.max(1));
        let cpu_factor = 1.0 - self.cpu_usage;
        let mem_factor = 1.0 - self.memory_usage;
        slot_factor * 0.3 + warm_factor * 0.4 + cpu_factor * 0.15 + mem_factor * 0.15
    }

    /// Build from a heartbeat's node id and protobuf status. Active task ids
    /// that are not valid hex are rejected.
    pub fn from_proto(
        node_id: NodeId,
        status: &pb::NodeStatus,
    ) -> Result<Self, crate::ids::IdParseError> {
        let active_task_ids = status
            .active_task_ids
            .iter()
            .map(|id| TaskId::parse(id))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self {
            node_id,
            hostname: status.hostname.clone(),
            total_vm_slots: status.total_vm_slots,
            active_vms: status.active_vms,
            warm_vms: status.warm_vms,
            cpu_usage: status.cpu_usage,
            memory_usage: status.memory_usage,
            disk_available_bytes: status.disk_available_bytes,
            healthy: status.healthy,
            draining: status.draining,
            uptime_seconds: status.uptime_seconds,
            last_task_at: status.last_task_at,
            active_task_ids,
        })
    }

    /// The protobuf status (the node id travels in `NodeAuth`).
    pub fn to_proto(&self) -> pb::NodeStatus {
        pb::NodeStatus {
            hostname: self.hostname.clone(),
            total_vm_slots: self.total_vm_slots,
            active_vms: self.active_vms,
            warm_vms: self.warm_vms,
            cpu_usage: self.cpu_usage,
            memory_usage: self.memory_usage,
            disk_available_bytes: self.disk_available_bytes,
            healthy: self.healthy,
            draining: self.draining,
            uptime_seconds: self.uptime_seconds,
            last_task_at: self.last_task_at,
            active_task_ids: self.active_task_ids.iter().map(TaskId::to_hex).collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [TaskState; 7] = [
        TaskState::Unspecified,
        TaskState::Queued,
        TaskState::Starting,
        TaskState::Running,
        TaskState::Completed,
        TaskState::Failed,
        TaskState::Cancelled,
    ];

    // Port of types.zig "task state transitions".
    #[test]
    fn queued_transitions() {
        let state = TaskState::Queued;
        assert!(state.can_transition_to(TaskState::Starting));
        assert!(state.can_transition_to(TaskState::Cancelled));
        assert!(!state.can_transition_to(TaskState::Completed));
    }

    #[test]
    fn full_transition_table() {
        use TaskState::*;
        let allowed = [
            (Unspecified, Queued),
            (Queued, Starting),
            (Queued, Cancelled),
            (Starting, Running),
            (Starting, Failed),
            (Starting, Cancelled),
            (Running, Completed),
            (Running, Failed),
            (Running, Cancelled),
        ];
        for from in ALL {
            for to in ALL {
                assert_eq!(
                    from.can_transition_to(to),
                    allowed.contains(&(from, to)),
                    "{from:?} -> {to:?}"
                );
            }
        }
    }

    #[test]
    fn terminal_states() {
        for state in ALL {
            let expected = matches!(
                state,
                TaskState::Completed | TaskState::Failed | TaskState::Cancelled
            );
            assert_eq!(state.is_terminal(), expected, "{state:?}");
        }
    }

    #[test]
    fn task_state_wire_round_trip() {
        for (i, state) in ALL.into_iter().enumerate() {
            assert_eq!(state.to_wire(), i as i32);
            assert_eq!(TaskState::from_wire(state.to_wire()), state);
        }
        assert_eq!(TaskState::from_wire(99), TaskState::Unspecified);
    }

    #[test]
    fn output_type_wire_round_trip() {
        let all = [
            OutputType::Unspecified,
            OutputType::Stdout,
            OutputType::Stderr,
            OutputType::Claude,
        ];
        for (i, t) in all.into_iter().enumerate() {
            assert_eq!(t.to_wire(), i as i32);
            assert_eq!(OutputType::from_wire(t.to_wire()), t);
        }
        assert_eq!(OutputType::from_wire(-1), OutputType::Unspecified);
    }

    #[test]
    fn task_transitions_and_rejects() {
        let mut task = Task::new(ClientId::random(), "https://github.com/a/b", "main", "fix");
        assert_eq!(task.state, TaskState::Queued);
        assert!(task.created_at > 0);
        task.transition_to(TaskState::Starting).unwrap();
        task.transition_to(TaskState::Running).unwrap();
        assert_eq!(
            task.transition_to(TaskState::Queued),
            Err(InvalidTransition {
                from: TaskState::Running,
                to: TaskState::Queued
            })
        );
        task.transition_to(TaskState::Completed).unwrap();
        assert!(task.transition_to(TaskState::Failed).is_err());
        assert_eq!(task.state, TaskState::Completed);
    }

    #[test]
    fn task_proto_omits_secrets() {
        let mut task = Task::new(ClientId::random(), "https://github.com/a/b", "dev", "p");
        task.github_token = Some("ghp_secret".into());
        task.env_vars = vec![EnvVar {
            key: "API_KEY".into(),
            value: "sk-secret".into(),
        }];
        task.max_iterations = Some(4);
        task.pr_title = Some("t".into());
        let proto = task.to_proto();
        assert_eq!(proto.id, task.id.to_hex());
        assert_eq!(proto.state, TaskState::Queued.to_wire());
        assert_eq!(proto.max_iterations, Some(4));
        assert_eq!(proto.pr_title.as_deref(), Some("t"));
        assert_eq!(proto.node_id, None);
        let debug = format!("{proto:?}");
        assert!(!debug.contains("ghp_secret"));
        assert!(!debug.contains("sk-secret"));
    }

    #[test]
    fn task_debug_redacts_secrets() {
        let mut task = Task::new(ClientId::random(), "https://github.com/a/b", "dev", "p");
        task.github_token = Some("ghp_secret".into());
        task.env_vars = vec![EnvVar {
            key: "API_KEY".into(),
            value: "sk-secret".into(),
        }];
        let debug = format!("{task:?}");
        assert!(!debug.contains("ghp_secret"), "{debug}");
        assert!(!debug.contains("sk-secret"), "{debug}");
        assert!(debug.contains("API_KEY"), "{debug}");
        assert!(debug.contains("https://github.com/a/b"), "{debug}");
    }

    #[test]
    fn usage_add() {
        let mut a = UsageMetrics {
            compute_time_ms: 1,
            input_tokens: 2,
            output_tokens: 3,
            cache_read_tokens: 4,
            cache_write_tokens: 5,
            tool_calls: 6,
        };
        a.add(&a.clone());
        assert_eq!(
            a,
            UsageMetrics {
                compute_time_ms: 2,
                input_tokens: 4,
                output_tokens: 6,
                cache_read_tokens: 8,
                cache_write_tokens: 10,
                tool_calls: 12,
            }
        );
    }

    fn sample_status() -> NodeStatus {
        NodeStatus {
            node_id: NodeId([0; 16]),
            hostname: "test-node".into(),
            total_vm_slots: 10,
            active_vms: 3,
            warm_vms: 5,
            cpu_usage: 0.5,
            memory_usage: 0.4,
            disk_available_bytes: 100_000_000_000,
            healthy: true,
            draining: false,
            uptime_seconds: 3600,
            last_task_at: None,
            active_task_ids: vec![],
        }
    }

    // Port of types.zig "node score calculation".
    #[test]
    fn node_score_in_range() {
        let score = sample_status().score();
        assert!(score > 0.0);
        assert!(score <= 1.0);
        // 0.3*0.7 + 0.4*0.5 + 0.15*0.5 + 0.15*0.6
        assert!((score - 0.575).abs() < 1e-12, "{score}");
    }

    #[test]
    fn node_score_zero_when_unavailable() {
        let mut s = sample_status();
        s.healthy = false;
        assert_eq!(s.score(), 0.0);

        let mut s = sample_status();
        s.draining = true;
        assert_eq!(s.score(), 0.0);

        let mut s = sample_status();
        s.active_vms = 10;
        assert_eq!(s.available_slots(), 0);
        assert_eq!(s.score(), 0.0);

        let mut s = sample_status();
        s.active_vms = 12;
        assert_eq!(s.available_slots(), 0);
        assert_eq!(s.score(), 0.0);

        let mut s = sample_status();
        s.total_vm_slots = 0;
        s.active_vms = 0;
        assert_eq!(s.score(), 0.0);
    }

    #[test]
    fn node_score_prefers_warm_and_idle() {
        let base = sample_status();
        let mut warmer = base.clone();
        warmer.warm_vms = 8;
        assert!(warmer.score() > base.score());
        let mut busier = base.clone();
        busier.cpu_usage = 0.9;
        assert!(busier.score() < base.score());
    }

    #[test]
    fn node_status_proto_round_trip() {
        let mut s = sample_status();
        s.node_id = NodeId::random();
        s.last_task_at = Some(42);
        s.active_task_ids = vec![TaskId::random(), TaskId::random()];
        let proto = s.to_proto();
        assert_eq!(NodeStatus::from_proto(s.node_id, &proto).unwrap(), s);

        let mut bad = proto.clone();
        bad.active_task_ids.push("zz".into());
        assert!(NodeStatus::from_proto(s.node_id, &bad).is_err());
    }
}
