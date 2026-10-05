//! SQLx repositories and migrations compatible with existing Zig databases.

use crate::{
    metering::UsageRecord,
    store::{Store, User, page_limit},
};
use common::{
    ClientId, NodeId, TaskId, UserId, VmId,
    types::{NodeStatus, Task, TaskState, UsageMetrics, now_ms},
};
use sqlx::{
    PgPool, Row,
    postgres::{PgPoolOptions, PgRow},
};
use std::time::Duration;

const LOCK_MIGRATIONS_SQL: &str = "
    SELECT pg_advisory_xact_lock($1)
";

const CREATE_MIGRATION_TABLE_SQL: &str = "
    CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at BIGINT NOT NULL,
        description TEXT
    )
";

const CURRENT_MIGRATION_VERSION_SQL: &str = "
    SELECT COALESCE(MAX(version),0)
    FROM schema_migrations
";

const RECORD_MIGRATION_SQL: &str = "
    INSERT INTO schema_migrations (
        version, applied_at, description
    ) VALUES (
        $1, $2, $3
    )
";

const UPDATE_TASK_QUERY_SQL: &str = "
    UPDATE tasks
    SET
        state = $2,
        node_id = $3,
        started_at = $4,
        completed_at = $5,
        error_message = $6,
        pr_url = $7,
        compute_time_ms = $8,
        input_tokens = $9,
        output_tokens = $10,
        cache_read_tokens = $11,
        cache_write_tokens = $12,
        tool_calls = $13
    WHERE id = $1
";

const HAS_TASK_USAGE_SQL: &str = "
    SELECT EXISTS (
        SELECT 1
        FROM usage_records
        WHERE task_id = $1
    )
";

const INSERT_USAGE_QUERY_SQL: &str = "
    INSERT INTO usage_records (
        client_id, task_id, timestamp, compute_time_ms, input_tokens, output_tokens,
        cache_read_tokens, cache_write_tokens, tool_calls, user_id
    ) VALUES (
        $1, $2, $3, $4, $5, $6, $7, $8, $9, (SELECT id FROM users WHERE id = $1)
    )
";

const CREATE_TASK_SQL: &str = "
    INSERT INTO tasks (
        id, client_id, state, repo_url, branch, prompt, node_id, vm_id, created_at,
        started_at, completed_at, error_message, pr_url, compute_time_ms, input_tokens,
        output_tokens, cache_read_tokens, cache_write_tokens, tool_calls, create_pr,
        pr_title, pr_body, user_id
    ) VALUES (
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18,
        $19, $20, $21, $22, (SELECT id FROM users WHERE id = $2)
    )
";

const GET_TASK_SQL: &str = "
    SELECT *
    FROM tasks
    WHERE id = $1
";

const COUNT_CLIENT_TASKS_SQL: &str = "
    SELECT COUNT(*)
    FROM tasks
    WHERE client_id = $1 AND ($2::smallint IS NULL OR state = $2)
";

const LIST_TASKS_SQL: &str = "
    SELECT *
    FROM tasks
    WHERE client_id = $1 AND ($2::smallint IS NULL OR state = $2)
    ORDER BY created_at DESC,id ASC
    LIMIT $3
    OFFSET $4
";

const CREATE_USER_SQL: &str = "
    INSERT INTO users (
        id, email, password_hash, api_key, github_id, created_at, updated_at
    ) VALUES (
        $1, $2, $3, $4, $5, $6, $7
    )
";

const USER_BY_EMAIL_SQL: &str = "
    SELECT *
    FROM users
    WHERE email = $1
";

const USER_BY_API_KEY_SQL: &str = "
    SELECT *
    FROM users
    WHERE api_key = $1
";

const USER_BY_ID_SQL: &str = "
    SELECT *
    FROM users
    WHERE id = $1
";

const USAGE_REPORT_SQL: &str = "
    SELECT
        COUNT(*) AS count,
        SUM(compute_time_ms)::bigint AS compute_time_ms,
        SUM(input_tokens)::bigint AS input_tokens,
        SUM(output_tokens)::bigint AS output_tokens,
        SUM(cache_read_tokens)::bigint AS cache_read_tokens,
        SUM(cache_write_tokens)::bigint AS cache_write_tokens,
        SUM(tool_calls)::bigint AS tool_calls
    FROM usage_records
    WHERE client_id = $1 AND timestamp BETWEEN $2 AND $3
";

const UPSERT_NODE_SQL: &str = "
    INSERT INTO nodes (
        node_id, hostname, total_vm_slots, active_vms, warm_vms, cpu_usage, memory_usage,
        disk_available_bytes, healthy, draining, uptime_seconds, last_task_at,
        last_heartbeat_at, registered_at, updated_at
    ) VALUES (
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $13, $13
    )
    ON CONFLICT(node_id) DO UPDATE SET
        hostname = $2,
        total_vm_slots = $3,
        active_vms = $4,
        warm_vms = $5,
        cpu_usage = $6,
        memory_usage = $7,
        disk_available_bytes = $8,
        healthy = $9,
        draining = $10,
        uptime_seconds = $11,
        last_task_at = $12,
        last_heartbeat_at = $13,
        updated_at = $13
";

const LIST_QUEUED_SQL: &str = "
    SELECT *
    FROM tasks
    WHERE state = 1
    ORDER BY created_at ASC,id ASC
    LIMIT $1
";

const COUNT_BY_STATE_SQL: &str = "
    SELECT COUNT(*)
    FROM tasks
    WHERE state = $1
";

const GET_NODE_SQL: &str = "
    SELECT *
    FROM nodes
    WHERE node_id = $1
";

const LIST_NODES_SQL: &str = "
    SELECT *
    FROM nodes
    ORDER BY hostname,node_id
";

const LIST_HEALTHY_SQL: &str = "
    SELECT *
    FROM nodes
    WHERE healthy AND NOT draining AND last_heartbeat_at > $1
    ORDER BY (total_vm_slots-active_vms) DESC,node_id
";

const REMOVE_STALE_SQL: &str = "
    DELETE
    FROM nodes
    WHERE last_heartbeat_at < $1
    RETURNING node_id
";

const SET_DRAINING_SQL: &str = "
    UPDATE nodes
    SET
        draining = $2,
        updated_at = $3
    WHERE node_id = $1
";

const UPDATE_HEARTBEAT_SQL: &str = "
    UPDATE nodes
    SET
        last_heartbeat_at = $2,
        updated_at = $2
    WHERE node_id = $1
";

const PRUNE_OLDER_THAN_SQL: &str = "
    DELETE
    FROM usage_records
    WHERE timestamp<$1
";

const GET_DAILY_TOTALS_SQL: &str = "
    SELECT
        (timestamp/86400000)*86400000 AS day,
        SUM(compute_time_ms)::bigint AS compute_time_ms,
        SUM(input_tokens)::bigint AS input_tokens,
        SUM(output_tokens)::bigint AS output_tokens,
        SUM(cache_read_tokens)::bigint AS cache_read_tokens,
        SUM(cache_write_tokens)::bigint AS cache_write_tokens,
        SUM(tool_calls)::bigint AS tool_calls
    FROM usage_records
    WHERE client_id = $1 AND timestamp >= $2
    GROUP BY day
    ORDER BY day DESC
";

/// Database failures classified without including query values or credentials.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum DbError {
    /// Database connection failed.
    #[error("database connection failed")]
    ConnectionFailed,
    /// Database authentication failed.
    #[error("database authentication failed")]
    AuthenticationFailed,
    /// Database query failed.
    #[error("database query failed")]
    QueryFailed,
    /// Database constraint violation.
    #[error("database constraint violation")]
    ConstraintViolation,
    /// Email already registered.
    #[error("email already registered")]
    EmailTaken,
    /// Database serialization failure.
    #[error("database serialization failure")]
    SerializationFailure,
    /// Database deadlock detected.
    #[error("database deadlock detected")]
    DeadlockDetected,
    /// Database parameter invalid.
    #[error("database parameter invalid")]
    InvalidParameter,
    /// Database resource exhausted.
    #[error("database resource exhausted")]
    OutOfMemory,
    /// Database timeout.
    #[error("database timeout")]
    Timeout,
    /// Database pool closed.
    #[error("database pool closed")]
    PoolClosed,
    /// Invalid pool config.
    #[error("invalid pool config")]
    InvalidConfig,
    /// Invalid database row.
    #[error("invalid database row")]
    InvalidRow,
    /// Unexpected database error.
    #[error("unexpected database error")]
    Unexpected,
}

/// Classify a PostgreSQL SQLSTATE using the Zig error classes.
pub fn map_sql_state(code: &str) -> DbError {
    match code.as_bytes().get(..2) {
        None => DbError::Unexpected,
        Some(b"08") => DbError::ConnectionFailed,
        Some(b"23") => DbError::ConstraintViolation,
        Some(b"28") => DbError::AuthenticationFailed,
        Some(b"40") if code == "40001" => DbError::SerializationFailure,
        Some(b"40") if code == "40P01" => DbError::DeadlockDetected,
        Some(b"42") => DbError::InvalidParameter,
        Some(b"53") => DbError::OutOfMemory,
        Some(b"57") => DbError::Timeout,
        _ => DbError::QueryFailed,
    }
}

impl From<sqlx::Error> for DbError {
    fn from(e: sqlx::Error) -> Self {
        match e {
            sqlx::Error::Database(e) => e
                .code()
                .as_deref()
                .map(map_sql_state)
                .unwrap_or(Self::QueryFailed),
            sqlx::Error::PoolTimedOut => Self::Timeout,
            sqlx::Error::PoolClosed => Self::PoolClosed,
            sqlx::Error::Io(_) | sqlx::Error::Tls(_) => Self::ConnectionFailed,
            sqlx::Error::ColumnDecode { .. } | sqlx::Error::Decode(_) => Self::InvalidRow,
            _ => Self::QueryFailed,
        }
    }
}

/// Connection pool limits and timeouts inherited from the Zig orchestrator.
#[derive(Debug, Clone)]
pub struct PoolConfig {
    /// Minimum number of pooled connections.
    pub min: u32,
    /// Maximum number of pooled connections.
    pub max: u32,
    /// Idle connection timeout in seconds.
    pub idle_seconds: u64,
    /// Maximum connection lifetime in seconds.
    pub lifetime_seconds: u64,
    /// Connection acquisition timeout in seconds.
    pub acquire_seconds: u64,
}

impl Default for PoolConfig {
    fn default() -> Self {
        Self {
            min: 2,
            max: 10,
            idle_seconds: 300,
            lifetime_seconds: 1800,
            acquire_seconds: 30,
        }
    }
}

impl PoolConfig {
    /// Validate pool limits and build the SQLx connection options.
    pub fn options(&self) -> Result<PgPoolOptions, DbError> {
        if self.min > self.max || self.max == 0 {
            return Err(DbError::InvalidConfig);
        }
        Ok(PgPoolOptions::new()
            .min_connections(self.min)
            .max_connections(self.max)
            .idle_timeout(Duration::from_secs(self.idle_seconds))
            .max_lifetime(Duration::from_secs(self.lifetime_seconds))
            .acquire_timeout(Duration::from_secs(self.acquire_seconds)))
    }
}

/// Ordered Zig migration versions, descriptions and unchanged SQL sources.
pub const MIGRATIONS: [(i32, &str, &str); 2] = [
    (
        1,
        "initial schema",
        include_str!("db/migrations/001_initial.sql"),
    ),
    (
        2,
        "users and authentication",
        include_str!("db/migrations/002_users.sql"),
    ),
];

const MIGRATION_LOCK: i64 = 0x4d41524154484f4e;

/// Apply pending migrations under transaction-scoped advisory locks.
pub async fn migrate(pool: &PgPool) -> Result<(), DbError> {
    let op = crate::telemetry::DbOperation::new("migrate", pool.clone());
    let result = async {
        // Lock the initial CREATE as well; concurrent CREATE IF NOT EXISTS can conflict
        // in pg_type before a table exists.
        let mut tx = pool.begin().await?;
        sqlx::query(LOCK_MIGRATIONS_SQL)
            .bind(MIGRATION_LOCK)
            .execute(&mut *tx)
            .await?;
        sqlx::query(CREATE_MIGRATION_TABLE_SQL)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        for (version, description, sql) in MIGRATIONS {
            let mut tx = pool.begin().await?;
            sqlx::query(LOCK_MIGRATIONS_SQL)
                .bind(MIGRATION_LOCK)
                .execute(&mut *tx)
                .await?;
            let current: i32 = sqlx::query_scalar(CURRENT_MIGRATION_VERSION_SQL)
                .fetch_one(&mut *tx)
                .await?;
            if current < version {
                sqlx::raw_sql(sql).execute(&mut *tx).await?;
                sqlx::query(RECORD_MIGRATION_SQL)
                    .bind(version)
                    .bind(now_ms())
                    .bind(description)
                    .execute(&mut *tx)
                    .await?;
            }
            tx.commit().await?;
        }
        Ok(())
    }
    .await;
    op.finish(&result);
    result
}

/// Postgres repositories sharing a SQLx connection pool.
#[derive(Clone)]
pub struct PostgresStore {
    /// SQLx pool shared by the repositories.
    pub pool: PgPool,
}

impl PostgresStore {
    /// Connect with the configured pool defaults and run the migrations.
    pub async fn connect(url: &str) -> Result<Self, DbError> {
        let pool = PoolConfig::default().options()?.connect(url).await?;
        migrate(&pool).await?;
        Ok(Self { pool })
    }

    /// Return the pool size and number of idle connections.
    pub fn pool_stats(&self) -> (u32, usize) {
        (self.pool.size(), self.pool.num_idle())
    }

    fn operation(&self, name: &'static str) -> crate::telemetry::DbOperation {
        crate::telemetry::DbOperation::new(name, self.pool.clone())
    }
}

fn bytes<const N: usize>(value: Vec<u8>) -> Result<[u8; N], DbError> {
    value.try_into().map_err(|_| DbError::InvalidRow)
}

fn optional_id<const N: usize>(r: &PgRow, name: &str) -> Result<Option<[u8; N]>, DbError> {
    r.try_get::<Option<Vec<u8>>, _>(name)?
        .map(bytes)
        .transpose()
}

fn usage(r: &PgRow) -> Result<UsageMetrics, DbError> {
    Ok(UsageMetrics {
        compute_time_ms: r.try_get::<Option<i64>, _>("compute_time_ms")?.unwrap_or(0),
        input_tokens: r.try_get::<Option<i64>, _>("input_tokens")?.unwrap_or(0),
        output_tokens: r.try_get::<Option<i64>, _>("output_tokens")?.unwrap_or(0),
        cache_read_tokens: r
            .try_get::<Option<i64>, _>("cache_read_tokens")?
            .unwrap_or(0),
        cache_write_tokens: r
            .try_get::<Option<i64>, _>("cache_write_tokens")?
            .unwrap_or(0),
        tool_calls: r.try_get::<Option<i64>, _>("tool_calls")?.unwrap_or(0),
    })
}

fn task(r: PgRow) -> Result<Task, DbError> {
    let state: i16 = r.try_get("state")?;
    if !(1..=6).contains(&state) {
        return Err(DbError::InvalidRow);
    }
    Ok(Task {
        id: TaskId(bytes(r.try_get("id")?)?),
        client_id: ClientId(bytes(r.try_get("client_id")?)?),
        state: TaskState::from_wire(i32::from(state)),
        repo_url: r.try_get("repo_url")?,
        branch: r.try_get("branch")?,
        prompt: r.try_get("prompt")?,
        node_id: optional_id(&r, "node_id")?.map(NodeId),
        vm_id: optional_id(&r, "vm_id")?.map(VmId),
        created_at: r.try_get("created_at")?,
        started_at: r.try_get("started_at")?,
        completed_at: r.try_get("completed_at")?,
        error_message: r.try_get("error_message")?,
        pr_url: r.try_get("pr_url")?,
        usage: usage(&r)?,
        create_pr: r.try_get::<Option<bool>, _>("create_pr")?.unwrap_or(false),
        pr_title: r.try_get("pr_title")?,
        pr_body: r.try_get("pr_body")?,
        ..Task::default()
    })
}

fn user(r: PgRow) -> Result<User, DbError> {
    Ok(User {
        id: UserId(bytes(r.try_get("id")?)?),
        email: r.try_get("email")?,
        password_hash: r.try_get("password_hash")?,
        api_key: r.try_get("api_key")?,
        github_id: r.try_get("github_id")?,
        created_at: r.try_get("created_at")?,
        updated_at: r.try_get("updated_at")?,
    })
}

fn node(r: PgRow) -> Result<NodeStatus, DbError> {
    Ok(NodeStatus {
        node_id: NodeId(bytes(r.try_get("node_id")?)?),
        hostname: r.try_get("hostname")?,
        total_vm_slots: u32::try_from(r.try_get::<i32, _>("total_vm_slots")?)
            .map_err(|_| DbError::InvalidRow)?,
        active_vms: u32::try_from(r.try_get::<Option<i32>, _>("active_vms")?.unwrap_or(0))
            .map_err(|_| DbError::InvalidRow)?,
        warm_vms: u32::try_from(r.try_get::<Option<i32>, _>("warm_vms")?.unwrap_or(0))
            .map_err(|_| DbError::InvalidRow)?,
        cpu_usage: r.try_get::<Option<f64>, _>("cpu_usage")?.unwrap_or(0.0),
        memory_usage: r.try_get::<Option<f64>, _>("memory_usage")?.unwrap_or(0.0),
        disk_available_bytes: r
            .try_get::<Option<i64>, _>("disk_available_bytes")?
            .unwrap_or(0),
        healthy: r.try_get::<Option<bool>, _>("healthy")?.unwrap_or(true),
        draining: r.try_get::<Option<bool>, _>("draining")?.unwrap_or(false),
        uptime_seconds: r.try_get::<Option<i64>, _>("uptime_seconds")?.unwrap_or(0),
        last_task_at: r.try_get("last_task_at")?,
        active_task_ids: vec![],
    })
}

fn update_task_query<'a>(
    t: &'a Task,
) -> sqlx::query::Query<'a, sqlx::Postgres, sqlx::postgres::PgArguments> {
    sqlx::query(UPDATE_TASK_QUERY_SQL)
        .bind(t.id.as_bytes().as_slice())
        .bind(t.state.to_wire() as i16)
        .bind(t.node_id.map(|n| n.0.to_vec()))
        .bind(t.started_at)
        .bind(t.completed_at)
        .bind(&t.error_message)
        .bind(&t.pr_url)
        .bind(t.usage.compute_time_ms)
        .bind(t.usage.input_tokens)
        .bind(t.usage.output_tokens)
        .bind(t.usage.cache_read_tokens)
        .bind(t.usage.cache_write_tokens)
        .bind(t.usage.tool_calls)
}

fn insert_usage_query<'a>(
    r: &'a UsageRecord,
) -> sqlx::query::Query<'a, sqlx::Postgres, sqlx::postgres::PgArguments> {
    sqlx::query(INSERT_USAGE_QUERY_SQL)
        .bind(r.client_id.as_bytes().as_slice())
        .bind(r.task_id.as_bytes().as_slice())
        .bind(r.timestamp)
        .bind(r.usage.compute_time_ms)
        .bind(r.usage.input_tokens)
        .bind(r.usage.output_tokens)
        .bind(r.usage.cache_read_tokens)
        .bind(r.usage.cache_write_tokens)
        .bind(r.usage.tool_calls)
}

#[tonic::async_trait]
impl Store for PostgresStore {
    fn persistent(&self) -> bool {
        true
    }

    async fn create_task(&self, t: &Task) -> Result<(), DbError> {
        let op = self.operation("create_task");
        let result = async {
            sqlx::query(CREATE_TASK_SQL)
                .bind(t.id.as_bytes().as_slice())
                .bind(t.client_id.as_bytes().as_slice())
                .bind(t.state.to_wire() as i16)
                .bind(&t.repo_url)
                .bind(&t.branch)
                .bind(&t.prompt)
                .bind(t.node_id.map(|n| n.0.to_vec()))
                .bind(t.vm_id.map(|n| n.0.to_vec()))
                .bind(t.created_at)
                .bind(t.started_at)
                .bind(t.completed_at)
                .bind(&t.error_message)
                .bind(&t.pr_url)
                .bind(t.usage.compute_time_ms)
                .bind(t.usage.input_tokens)
                .bind(t.usage.output_tokens)
                .bind(t.usage.cache_read_tokens)
                .bind(t.usage.cache_write_tokens)
                .bind(t.usage.tool_calls)
                .bind(t.create_pr)
                .bind(&t.pr_title)
                .bind(&t.pr_body)
                .execute(&self.pool)
                .await?;
            Ok(())
        }
        .await;
        op.finish(&result);
        result
    }

    async fn get_task(&self, id: TaskId) -> Result<Option<Task>, DbError> {
        let op = self.operation("get_task");
        let result = async {
            sqlx::query(GET_TASK_SQL)
                .bind(id.as_bytes().as_slice())
                .fetch_optional(&self.pool)
                .await?
                .map(task)
                .transpose()
        }
        .await;
        op.finish(&result);
        result
    }

    async fn save_task(&self, t: &Task) -> Result<(), DbError> {
        let op = self.operation("save_task");
        let result = async {
            update_task_query(t).execute(&self.pool).await?;
            Ok(())
        }
        .await;
        op.finish(&result);
        result
    }

    async fn list_tasks(
        &self,
        client: ClientId,
        state: Option<TaskState>,
        limit: u32,
        offset: u32,
    ) -> Result<(Vec<Task>, u32), DbError> {
        let op = self.operation("list_tasks");
        let result = async {
            let filter = state.map(|s| s.to_wire() as i16);
            let count: i64 = sqlx::query_scalar(COUNT_CLIENT_TASKS_SQL)
                .bind(client.as_bytes().as_slice())
                .bind(filter)
                .fetch_one(&self.pool)
                .await?;
            let rows = sqlx::query(LIST_TASKS_SQL)
                .bind(client.as_bytes().as_slice())
                .bind(filter)
                .bind(i64::from(page_limit(limit)))
                .bind(i64::from(offset))
                .fetch_all(&self.pool)
                .await?;
            Ok((
                rows.into_iter().map(task).collect::<Result<_, _>>()?,
                u32::try_from(count).unwrap_or(u32::MAX),
            ))
        }
        .await;
        op.finish(&result);
        result
    }

    async fn create_user(&self, u: &User) -> Result<(), DbError> {
        let op = self.operation("create_user");
        let result = async {
            let result = sqlx::query(CREATE_USER_SQL)
                .bind(u.id.as_bytes().as_slice())
                .bind(&u.email)
                .bind(&u.password_hash)
                .bind(&u.api_key)
                .bind(&u.github_id)
                .bind(u.created_at)
                .bind(u.updated_at)
                .execute(&self.pool)
                .await;
            if let Err(sqlx::Error::Database(e)) = &result
                && e.code().as_deref() == Some("23505")
                && e.constraint() == Some("users_email_key")
            {
                return Err(DbError::EmailTaken);
            }
            result?;
            Ok(())
        }
        .await;
        op.finish(&result);
        result
    }

    async fn user_by_email(&self, email: &str) -> Result<Option<User>, DbError> {
        let op = self.operation("user_by_email");
        let result = async {
            sqlx::query(USER_BY_EMAIL_SQL)
                .bind(email)
                .fetch_optional(&self.pool)
                .await?
                .map(user)
                .transpose()
        }
        .await;
        op.finish(&result);
        result
    }

    async fn user_by_api_key(&self, key: &str) -> Result<Option<User>, DbError> {
        let op = self.operation("user_by_api_key");
        let result = async {
            sqlx::query(USER_BY_API_KEY_SQL)
                .bind(key)
                .fetch_optional(&self.pool)
                .await?
                .map(user)
                .transpose()
        }
        .await;
        op.finish(&result);
        result
    }

    async fn user_by_id(&self, id: UserId) -> Result<Option<User>, DbError> {
        let op = self.operation("user_by_id");
        let result = async {
            sqlx::query(USER_BY_ID_SQL)
                .bind(id.as_bytes().as_slice())
                .fetch_optional(&self.pool)
                .await?
                .map(user)
                .transpose()
        }
        .await;
        op.finish(&result);
        result
    }

    async fn record_usage(&self, r: &UsageRecord) -> Result<(), DbError> {
        let op = self.operation("record_usage");
        let result = async {
            insert_usage_query(r).execute(&self.pool).await?;
            Ok(())
        }
        .await;
        op.finish(&result);
        result
    }

    async fn usage_report(
        &self,
        client: ClientId,
        start: i64,
        end: i64,
    ) -> Result<(UsageMetrics, u32), DbError> {
        let op = self.operation("usage_report");
        let result = async {
            let r = sqlx::query(USAGE_REPORT_SQL)
                .bind(client.as_bytes().as_slice())
                .bind(start)
                .bind(end)
                .fetch_one(&self.pool)
                .await?;
            Ok((
                usage(&r)?,
                u32::try_from(r.try_get::<i64, _>("count")?).unwrap_or(u32::MAX),
            ))
        }
        .await;
        op.finish(&result);
        result
    }

    async fn has_task_usage(&self, id: TaskId) -> Result<bool, DbError> {
        let op = self.operation("has_task_usage");
        let result = sqlx::query_scalar(HAS_TASK_USAGE_SQL)
            .bind(id.as_bytes().as_slice())
            .fetch_one(&self.pool)
            .await
            .map_err(DbError::from);
        op.finish(&result);
        result
    }

    async fn commit_result(
        &self,
        task: &Task,
        record: &UsageRecord,
        update: bool,
    ) -> Result<(), DbError> {
        let op = self.operation("commit_result");
        let result = async {
            let mut tx = self.pool.begin().await?;
            if update {
                update_task_query(task).execute(&mut *tx).await?;
            }
            insert_usage_query(record).execute(&mut *tx).await?;
            tx.commit().await?;
            Ok(())
        }
        .await;
        op.finish(&result);
        result
    }

    async fn upsert_node(&self, n: &NodeStatus) -> Result<(), DbError> {
        let op = self.operation("upsert_node");
        let result = async {
            let to_int = |v| i32::try_from(v).map_err(|_| DbError::InvalidParameter);
            sqlx::query(UPSERT_NODE_SQL)
                .bind(n.node_id.as_bytes().as_slice())
                .bind(&n.hostname)
                .bind(to_int(n.total_vm_slots)?)
                .bind(to_int(n.active_vms)?)
                .bind(to_int(n.warm_vms)?)
                .bind(n.cpu_usage)
                .bind(n.memory_usage)
                .bind(n.disk_available_bytes)
                .bind(n.healthy)
                .bind(n.draining)
                .bind(n.uptime_seconds)
                .bind(n.last_task_at)
                .bind(now_ms())
                .execute(&self.pool)
                .await?;
            Ok(())
        }
        .await;
        op.finish(&result);
        result
    }
}

impl PostgresStore {
    /// Read queued tasks in creation order without requeueing them.
    pub async fn list_queued(&self, limit: u32) -> Result<Vec<Task>, DbError> {
        let op = self.operation("list_queued");
        let result = async {
            sqlx::query(LIST_QUEUED_SQL)
                .bind(i64::from(limit))
                .fetch_all(&self.pool)
                .await?
                .into_iter()
                .map(task)
                .collect()
        }
        .await;
        op.finish(&result);
        result
    }

    /// Count persisted tasks in the specified lifecycle state.
    pub async fn count_by_state(&self, state: TaskState) -> Result<i64, DbError> {
        let op = self.operation("count_by_state");
        let result = async {
            Ok(sqlx::query_scalar(COUNT_BY_STATE_SQL)
                .bind(state.to_wire() as i16)
                .fetch_one(&self.pool)
                .await?)
        }
        .await;
        op.finish(&result);
        result
    }

    /// Read one persisted node, validating its raw identifier.
    pub async fn get_node(&self, id: NodeId) -> Result<Option<NodeStatus>, DbError> {
        let op = self.operation("get_node");
        let result = async {
            sqlx::query(GET_NODE_SQL)
                .bind(id.as_bytes().as_slice())
                .fetch_optional(&self.pool)
                .await?
                .map(node)
                .transpose()
        }
        .await;
        op.finish(&result);
        result
    }

    /// Read persisted nodes in hostname and identifier order.
    pub async fn list_nodes(&self) -> Result<Vec<NodeStatus>, DbError> {
        let op = self.operation("list_nodes");
        let result = async {
            sqlx::query(LIST_NODES_SQL)
                .fetch_all(&self.pool)
                .await?
                .into_iter()
                .map(node)
                .collect()
        }
        .await;
        op.finish(&result);
        result
    }

    /// Read healthy, non-draining nodes with recent heartbeats.
    pub async fn list_healthy(&self, timeout: i64) -> Result<Vec<NodeStatus>, DbError> {
        let op = self.operation("list_healthy");
        let result = async {
            sqlx::query(LIST_HEALTHY_SQL)
                .bind(now_ms().saturating_sub(timeout))
                .fetch_all(&self.pool)
                .await?
                .into_iter()
                .map(node)
                .collect()
        }
        .await;
        op.finish(&result);
        result
    }

    /// Remove expired nodes and return their identifiers.
    pub async fn remove_stale(&self, timeout: i64) -> Result<Vec<NodeId>, DbError> {
        let op = self.operation("remove_stale");
        let result = async {
            sqlx::query(REMOVE_STALE_SQL)
                .bind(now_ms().saturating_sub(timeout))
                .fetch_all(&self.pool)
                .await?
                .into_iter()
                .map(|r| Ok(NodeId(bytes(r.try_get("node_id")?)?)))
                .collect()
        }
        .await;
        op.finish(&result);
        result
    }

    /// Set a node draining flag and return the affected row count.
    pub async fn set_draining(&self, id: NodeId, draining: bool) -> Result<u64, DbError> {
        let op = self.operation("set_draining");
        let result = async {
            Ok(sqlx::query(SET_DRAINING_SQL)
                .bind(id.as_bytes().as_slice())
                .bind(draining)
                .bind(now_ms())
                .execute(&self.pool)
                .await?
                .rows_affected())
        }
        .await;
        op.finish(&result);
        result
    }

    /// Refresh a persisted node heartbeat and return the affected row count.
    pub async fn update_heartbeat(&self, id: NodeId) -> Result<u64, DbError> {
        let op = self.operation("update_heartbeat");
        let result = async {
            Ok(sqlx::query(UPDATE_HEARTBEAT_SQL)
                .bind(id.as_bytes().as_slice())
                .bind(now_ms())
                .execute(&self.pool)
                .await?
                .rows_affected())
        }
        .await;
        op.finish(&result);
        result
    }

    /// Delete persisted usage older than the cutoff and return the affected row count.
    pub async fn prune_older_than(&self, cutoff: i64) -> Result<u64, DbError> {
        let op = self.operation("prune_older_than");
        let result = async {
            Ok(sqlx::query(PRUNE_OLDER_THAN_SQL)
                .bind(cutoff)
                .execute(&self.pool)
                .await?
                .rows_affected())
        }
        .await;
        op.finish(&result);
        result
    }

    /// Aggregate a client usage into UTC epoch days, newest first.
    pub async fn get_daily_totals(
        &self,
        client: ClientId,
        days: u32,
    ) -> Result<Vec<(i64, UsageMetrics)>, DbError> {
        let op = self.operation("get_daily_totals");
        let result = async {
            sqlx::query(GET_DAILY_TOTALS_SQL)
                .bind(client.as_bytes().as_slice())
                .bind(now_ms().saturating_sub(i64::from(days) * 86400000))
                .fetch_all(&self.pool)
                .await?
                .into_iter()
                .map(|r| Ok((r.try_get("day")?, usage(&r)?)))
                .collect()
        }
        .await;
        op.finish(&result);
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sqlx::{ConnectOptions, postgres::PgConnectOptions};
    use std::str::FromStr;

    // Port of db/errors.zig "map sql state codes"
    #[test]
    fn sql_states() {
        for (s, e) in [
            ("08000", DbError::ConnectionFailed),
            ("23505", DbError::ConstraintViolation),
            ("40001", DbError::SerializationFailure),
            ("40P01", DbError::DeadlockDetected),
            ("28000", DbError::AuthenticationFailed),
        ] {
            assert_eq!(map_sql_state(s), e);
        }
        assert_eq!(map_sql_state(""), DbError::Unexpected);
        assert_eq!(map_sql_state("é000"), DbError::QueryFailed);
    }

    // Port of db/pool.zig "pool config defaults"
    #[test]
    fn pool_defaults() {
        let c = PoolConfig::default();
        assert_eq!(
            (
                c.min,
                c.max,
                c.idle_seconds,
                c.lifetime_seconds,
                c.acquire_seconds
            ),
            (2, 10, 300, 1800, 30)
        );
    }

    // Port of db/pool.zig "pool stats structure"
    #[tokio::test]
    async fn pool_stats() {
        let pool = PgPoolOptions::new()
            .connect_lazy("postgres://localhost/db")
            .unwrap();
        let s = PostgresStore { pool };
        assert_eq!(s.pool_stats(), (0, 0));
        let recorder = metrics_exporter_prometheus::PrometheusBuilder::new().build_recorder();
        let handle = recorder.handle();
        metrics::with_local_recorder(&recorder, || drop(s.operation("pool_stats")));
        let rendered = handle.render();
        assert!(rendered.contains("marathon_db_pool_size"));
        assert!(rendered.contains("marathon_db_pool_idle"));
    }

    // Port of db/pool.zig "pool config validation - min greater than max"
    #[test]
    fn min_greater_than_max() {
        assert!(matches!(
            PoolConfig {
                min: 11,
                ..PoolConfig::default()
            }
            .options(),
            Err(DbError::InvalidConfig)
        ));
    }

    // Port of db/pool.zig "pool config with zero connections allowed"
    #[test]
    fn zero_min() {
        assert!(
            PoolConfig {
                min: 0,
                ..PoolConfig::default()
            }
            .options()
            .is_ok()
        );
    }

    // Port of db/connection.zig "connection config from url"
    #[test]
    fn url_with_port() {
        let o = PgConnectOptions::from_str("postgresql://testuser:testpass@localhost:5433/testdb")
            .unwrap();
        assert_eq!(o.get_host(), "localhost");
        assert_eq!(o.get_port(), 5433);
        assert_eq!(o.get_username(), "testuser");
        assert_eq!(o.to_url_lossy().password(), Some("testpass"));
        assert_eq!(o.get_database(), Some("testdb"));
    }

    // Port of db/connection.zig "connection config from url without port"
    #[test]
    fn url_without_port() {
        let o = PgConnectOptions::from_str("postgresql://user:pass@localhost/db").unwrap();
        assert_eq!(o.get_host(), "localhost");
        assert_eq!(o.get_port(), 5432);
        assert_eq!(o.get_username(), "user");
        assert_eq!(o.to_url_lossy().password(), Some("pass"));
        assert_eq!(o.get_database(), Some("db"));
    }

    // Port of db/migration.zig "migrations array is ordered"
    #[test]
    fn migrations_ordered() {
        assert_eq!(MIGRATIONS.map(|m| m.0), [1, 2]);
    }

    // Port of db/migration.zig "migration has required fields"
    #[test]
    fn migration_fields() {
        for (v, d, s) in MIGRATIONS {
            assert!(v > 0);
            assert!(!d.is_empty());
            assert!(!s.is_empty());
        }
    }

    // Port of db/repository/task.zig "task state enum conversion"
    #[test]
    fn state_conversion() {
        for n in 1..=6 {
            assert_eq!(TaskState::from_wire(n).to_wire() as i16, n as i16);
        }
        assert_eq!(TaskState::Queued.to_wire(), 1);
    }
}
