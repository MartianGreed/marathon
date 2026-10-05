//! Persistence seam shared by the production and no-database modes.

use crate::{
    db::DbError,
    metering::{Metering, UsageRecord},
};
use common::{
    ClientId, NodeId, TaskId, UserId,
    types::{NodeStatus, Task, TaskState, UsageMetrics},
};
use std::collections::{BTreeMap, HashMap};
use tokio::sync::Mutex;

/// Stored account credentials and metadata; deliberately has no Debug implementation.
#[derive(Clone)]
pub struct User {
    /// Raw account identifier.
    pub id: UserId,
    /// Account email address.
    pub email: String,
    /// Zig-compatible PBKDF2 salt:key hex.
    pub password_hash: String,
    /// Padded base64 API key; never log this value.
    pub api_key: String,
    /// Optional linked GitHub account identifier.
    pub github_id: Option<String>,
    /// Creation time in Unix milliseconds.
    pub created_at: i64,
    /// Last update time in Unix milliseconds.
    pub updated_at: i64,
}

/// Persistence operations implemented by Postgres and the in-memory fallback.
#[tonic::async_trait]
pub trait Store: Send + Sync {
    /// Return whether this store survives process restart.
    fn persistent(&self) -> bool {
        false
    }

    /// Insert a new task without persisting its GitHub token or environment values.
    async fn create_task(&self, task: &Task) -> Result<(), DbError>;

    /// Read a task from memory first, then fall back to persistence.
    async fn get_task(&self, id: TaskId) -> Result<Option<Task>, DbError>;

    /// Persist lifecycle, assignment, completion and usage fields of a task.
    async fn save_task(&self, task: &Task) -> Result<(), DbError>;

    /// List caller-owned tasks with optional state filtering and paging.
    async fn list_tasks(
        &self,
        client: ClientId,
        state: Option<TaskState>,
        limit: u32,
        offset: u32,
    ) -> Result<(Vec<Task>, u32), DbError>;

    /// Insert an account; distinguish an already registered email from other failures.
    async fn create_user(&self, user: &User) -> Result<(), DbError>;

    /// Find an account by its exact email address.
    async fn user_by_email(&self, email: &str) -> Result<Option<User>, DbError>;

    /// Find an account by its complete API key, without prefix matching.
    async fn user_by_api_key(&self, key: &str) -> Result<Option<User>, DbError>;

    /// Find an account by its raw user identifier.
    async fn user_by_id(&self, id: UserId) -> Result<Option<User>, DbError>;

    /// Append one timestamped task usage record.
    async fn record_usage(&self, record: &UsageRecord) -> Result<(), DbError>;

    /// Sum caller-owned usage records over an inclusive timestamp range.
    async fn usage_report(
        &self,
        client: ClientId,
        start: i64,
        end: i64,
    ) -> Result<(UsageMetrics, u32), DbError>;

    /// Check persisted usage when receiving a result after process restart.
    async fn has_task_usage(&self, _id: TaskId) -> Result<bool, DbError> {
        Ok(false)
    }

    /// Commit completion and its usage together where the store supports transactions.
    async fn commit_result(
        &self,
        task: &Task,
        record: &UsageRecord,
        update: bool,
    ) -> Result<(), DbError> {
        if update {
            self.save_task(task).await?;
        }
        self.record_usage(record).await
    }

    /// Insert or refresh a persisted node status.
    async fn upsert_node(&self, status: &NodeStatus) -> Result<(), DbError>;
}

#[derive(Default)]
struct Memory {
    tasks: HashMap<TaskId, Task>,
    users: HashMap<UserId, User>,
    emails: HashMap<String, UserId>,
    keys: HashMap<String, UserId>,
    nodes: BTreeMap<NodeId, NodeStatus>,
    meter: Metering,
}

/// Process-local accounts, tasks, nodes and usage for no-database mode.
#[derive(Default)]
pub struct MemoryStore {
    inner: Mutex<Memory>,
}

#[tonic::async_trait]
impl Store for MemoryStore {
    async fn create_task(&self, task: &Task) -> Result<(), DbError> {
        let mut m = self.inner.lock().await;
        if m.tasks.contains_key(&task.id) {
            return Err(DbError::ConstraintViolation);
        }
        m.tasks.insert(task.id, task.clone());
        Ok(())
    }

    async fn get_task(&self, id: TaskId) -> Result<Option<Task>, DbError> {
        Ok(self.inner.lock().await.tasks.get(&id).cloned())
    }

    async fn save_task(&self, task: &Task) -> Result<(), DbError> {
        self.inner.lock().await.tasks.insert(task.id, task.clone());
        Ok(())
    }

    async fn list_tasks(
        &self,
        client: ClientId,
        state: Option<TaskState>,
        limit: u32,
        offset: u32,
    ) -> Result<(Vec<Task>, u32), DbError> {
        let m = self.inner.lock().await;
        let mut tasks: Vec<_> = m
            .tasks
            .values()
            .filter(|t| t.client_id == client && state.is_none_or(|s| t.state == s))
            .cloned()
            .collect();
        tasks.sort_by(|a, b| b.created_at.cmp(&a.created_at).then(a.id.cmp(&b.id)));
        let total = u32::try_from(tasks.len()).unwrap_or(u32::MAX);
        Ok((
            tasks
                .into_iter()
                .skip(offset as usize)
                .take(page_limit(limit) as usize)
                .collect(),
            total,
        ))
    }

    async fn create_user(&self, user: &User) -> Result<(), DbError> {
        let mut m = self.inner.lock().await;
        if m.emails.contains_key(&user.email) {
            return Err(DbError::EmailTaken);
        }
        if m.keys.contains_key(&user.api_key) || m.users.contains_key(&user.id) {
            return Err(DbError::ConstraintViolation);
        }
        m.emails.insert(user.email.clone(), user.id);
        m.keys.insert(user.api_key.clone(), user.id);
        m.users.insert(user.id, user.clone());
        Ok(())
    }

    async fn user_by_email(&self, email: &str) -> Result<Option<User>, DbError> {
        let m = self.inner.lock().await;
        Ok(m.emails.get(email).and_then(|id| m.users.get(id)).cloned())
    }

    async fn user_by_api_key(&self, key: &str) -> Result<Option<User>, DbError> {
        let m = self.inner.lock().await;
        Ok(m.keys.get(key).and_then(|id| m.users.get(id)).cloned())
    }

    async fn user_by_id(&self, id: UserId) -> Result<Option<User>, DbError> {
        Ok(self.inner.lock().await.users.get(&id).cloned())
    }

    async fn record_usage(&self, record: &UsageRecord) -> Result<(), DbError> {
        self.inner.lock().await.meter.record(record.clone());
        Ok(())
    }

    async fn usage_report(
        &self,
        client: ClientId,
        start: i64,
        end: i64,
    ) -> Result<(UsageMetrics, u32), DbError> {
        Ok(self.inner.lock().await.meter.report(client, start, end))
    }

    async fn has_task_usage(&self, id: TaskId) -> Result<bool, DbError> {
        Ok(self
            .inner
            .lock()
            .await
            .meter
            .records
            .iter()
            .any(|r| r.task_id == id))
    }

    async fn commit_result(
        &self,
        task: &Task,
        record: &UsageRecord,
        update: bool,
    ) -> Result<(), DbError> {
        let mut m = self.inner.lock().await;
        if update {
            m.tasks.insert(task.id, task.clone());
        }
        m.meter.record(record.clone());
        Ok(())
    }

    async fn upsert_node(&self, status: &NodeStatus) -> Result<(), DbError> {
        self.inner
            .lock()
            .await
            .nodes
            .insert(status.node_id, status.clone());
        Ok(())
    }
}

/// Apply the default task page size and the maximum limit.
pub fn page_limit(limit: u32) -> u32 {
    if limit == 0 { 100 } else { limit.min(1000) }
}
