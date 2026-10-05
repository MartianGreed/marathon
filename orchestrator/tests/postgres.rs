//! Postgres compatibility and repository integration tests.

mod support;
use common::{
    ClientId, NodeId, TaskId, UserId, pb,
    types::{NodeStatus, Task, TaskState, UsageMetrics, now_ms},
};
use marathon_orchestrator::{
    db::{DbError, MIGRATIONS, PostgresStore, migrate},
    metering::UsageRecord,
    store::{Store, User},
};
use sqlx::Row;
use std::sync::Arc;
use support::*;

const MIGRATION_HISTORY_SQL: &str = "
    SELECT version,applied_at,description
    FROM schema_migrations
    ORDER BY version
";

const INITIAL_MIGRATION_TIME_SQL: &str = "
    SELECT applied_at
    FROM schema_migrations
    WHERE version = 1
";

const LIST_USERS_SQL: &str = "
    SELECT *
    FROM users
";

const SQLX_MIGRATION_TABLE_SQL: &str = "
    SELECT *
    FROM _sqlx_migrations
";

const COUNT_MIGRATIONS_SQL: &str = "
    SELECT COUNT(*)
    FROM schema_migrations
";

const FIRST_CONNECTION_QUERY_SQL: &str = "
    SELECT 1
";

const REACQUIRED_CONNECTION_QUERY_SQL: &str = "
    SELECT 2
";

const SERVER_VERSION_SQL: &str = "
    SHOW server_version
";

const CURRENT_USER_SQL: &str = "
    SELECT current_user
";

const DRIVER_SCRAM_AUTHENTICATION_SQL: &str = "
    SELECT rolpassword
    FROM pg_authid
    WHERE rolname = current_user
";

const CREATE_COUNTS_SQL: &str = "
    CREATE TABLE counts (
        id INTEGER
    )
";

const INSERT_COUNTS_SQL: &str = "
    INSERT INTO counts SELECT generate_series(1,5)
";

const UPDATE_COUNTS_SQL: &str = "
    UPDATE counts
    SET
        id = id+10
";

const DELETE_COUNTS_SQL: &str = "
    DELETE
    FROM counts
    WHERE id<14
";

const TASK_USER_ID_SQL: &str = "
    SELECT user_id
    FROM tasks
    WHERE id = $1
";

const EXPIRE_NODES_SQL: &str = "
    UPDATE nodes
    SET
        last_heartbeat_at = 0
";

const USAGE_USER_ID_SQL: &str = "
    SELECT user_id
    FROM usage_records
";

const INVALID_TASK_STATE_SQL: &str = "
    UPDATE tasks
    SET
        state = 99
    WHERE id = $1
";

const INVALID_TASK_NODE_SQL: &str = "
    UPDATE tasks
    SET
        state = 4,
        node_id = $2
    WHERE id = $1
";

const REPOSITORY_VALUE_CONVERSIONS_SQL: &str = "
    SELECT
        $1::smallint AS a,
        $2::integer AS b,
        $3::bigint AS c,
        $4::double precision AS d,
        $5::boolean AS e,
        $6::text AS f,
        $7::bytea AS g,
        $8::text AS h
";

#[tokio::test]
async fn zig_v2_compatibility() {
    with_db(|pool| async move {
        sqlx::raw_sql(include_str!("fixtures/zig_created_db.sql"))
            .execute(&pool)
            .await
            .unwrap();
        let before: Vec<(i32, i64, Option<String>)> = sqlx::query_as(MIGRATION_HISTORY_SQL)
            .fetch_all(&pool)
            .await
            .unwrap();
        migrate(&pool).await.unwrap();
        migrate(&pool).await.unwrap();
        let after: Vec<(i32, i64, Option<String>)> = sqlx::query_as(MIGRATION_HISTORY_SQL)
            .fetch_all(&pool)
            .await
            .unwrap();
        assert_eq!(before, after);
        let store = Arc::new(PostgresStore { pool: pool.clone() });
        let s = TestServer::start(Some(store.clone()), None).await;
        let mut client = s.client();
        let login = client
            .login(pb::LoginRequest {
                email: "zig@example.com".into(),
                password: "zig-compat-password".into(),
            })
            .await
            .unwrap()
            .into_inner();
        assert!(login.success);
        let key = login.api_key.unwrap();
        assert_eq!(key, "zig-api-key-0123456789abcdefghijklmnopqrstuv");
        assert!(
            !client
                .login(pb::LoginRequest {
                    email: "zig@example.com".into(),
                    password: "wrong".into()
                })
                .await
                .unwrap()
                .into_inner()
                .success
        );
        let id = "e1c01a45331f99b9d64c8f8a4221746cb4d128fce9f47e93bc58e357a275807c";
        let task = client
            .get_task(authorized(pb::GetTaskRequest { task_id: id.into() }, &key))
            .await
            .unwrap()
            .into_inner();
        assert_eq!(task.state, 4);
        assert_eq!(task.client_id, "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf");
        assert_eq!(
            task.node_id.as_deref(),
            Some("101112131415161718191a1b1c1d1e1f")
        );
        assert_eq!(task.started_at, Some(1791192199696));
        assert_eq!(task.completed_at, Some(1791192200018));
        assert_eq!(
            task.pr_url.as_deref(),
            Some("https://github.com/zig/compat/pull/1")
        );
        assert!(task.create_pr);
        assert_eq!(task.pr_title.as_deref(), Some("Zig PR title"));
        assert_eq!(task.usage.as_ref().unwrap().input_tokens, 100);
        let mut jwt = tonic::Request::new(pb::GetTaskRequest { task_id: id.into() });
        common::client_auth::ClientCredential::Bearer(login.token.unwrap())
            .apply(jwt.metadata_mut())
            .unwrap();
        assert_eq!(client.get_task(jwt).await.unwrap().into_inner(), task);
        let list = client
            .list_tasks(authorized(pb::ListTasksRequest::default(), &key))
            .await
            .unwrap()
            .into_inner();
        assert_eq!(list.total_count, 2);
        assert_eq!(
            list.tasks[0].task_id,
            "8fcdfd97d5d3cbdbbf6650158494a97530062cc9fbb0e893607b03e638b91cc8"
        );
        assert_eq!(list.tasks[1].task_id, id);
        let report = client
            .get_usage(authorized(
                pb::GetUsageRequest {
                    start_time: 1791190001000,
                    end_time: 1791190001000,
                },
                &key,
            ))
            .await
            .unwrap()
            .into_inner();
        assert_eq!(report.task_count, 1);
        assert_eq!(report.total.unwrap(), task.usage.unwrap());
        let mut events = client
            .get_task_events(authorized(
                pb::GetTaskEventsRequest {
                    task_id: list.tasks[0].task_id.clone(),
                    follow: true,
                },
                &key,
            ))
            .await
            .unwrap()
            .into_inner();
        assert_eq!(next_event(&mut events).await.state, 1);
        assert!(events.message().await.unwrap().is_none());
        assert!(s.app.state.lock().await.queue.is_empty());
        assert_eq!(
            store
                .get_node(NodeId::parse("101112131415161718191a1b1c1d1e1f").unwrap())
                .await
                .unwrap()
                .unwrap()
                .hostname,
            "zig-node"
        );
        drop(s);
    })
    .await;
}

#[tokio::test]
async fn zig_v1_upgrade() {
    with_db(|pool| async move {
        sqlx::raw_sql(include_str!("fixtures/zig_created_db_v1_first_boot.sql"))
            .execute(&pool)
            .await
            .unwrap();
        let before: (i64,) = sqlx::query_as(INITIAL_MIGRATION_TIME_SQL)
            .fetch_one(&pool)
            .await
            .unwrap();
        migrate(&pool).await.unwrap();
        let rows: Vec<(i32, i64, String)> = sqlx::query_as(MIGRATION_HISTORY_SQL)
            .fetch_all(&pool)
            .await
            .unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].1, before.0);
        assert_eq!(rows[1].2, "users and authentication");
        assert!(
            sqlx::query(LIST_USERS_SQL)
                .fetch_all(&pool)
                .await
                .unwrap()
                .is_empty()
        );
    })
    .await;
}

#[tokio::test]
async fn fresh_idempotent_and_racing_migrations() {
    with_db(|pool| async move {
        let (a, b) = tokio::join!(migrate(&pool), migrate(&pool));
        a.unwrap();
        b.unwrap();
        let before: Vec<(i32, i64, String)> = sqlx::query_as(MIGRATION_HISTORY_SQL)
            .fetch_all(&pool)
            .await
            .unwrap();
        assert_eq!(before.len(), 2);
        assert_eq!(before.iter().map(|r| r.0).collect::<Vec<_>>(), vec![1, 2]);
        migrate(&pool).await.unwrap();
        let after: Vec<(i32, i64, String)> = sqlx::query_as(MIGRATION_HISTORY_SQL)
            .fetch_all(&pool)
            .await
            .unwrap();
        assert_eq!(before, after);
        assert!(
            sqlx::query(SQLX_MIGRATION_TABLE_SQL)
                .execute(&pool)
                .await
                .is_err()
        );
    })
    .await;
}

#[tokio::test]
async fn schema_without_bookkeeping_converges() {
    with_db(|pool| async move {
        for (_, _, sql) in MIGRATIONS {
            sqlx::raw_sql(sql).execute(&pool).await.unwrap();
        }
        migrate(&pool).await.unwrap();
        assert_eq!(
            sqlx::query_scalar::<_, i64>(COUNT_MIGRATIONS_SQL)
                .fetch_one(&pool)
                .await
                .unwrap(),
            2
        );
    })
    .await;
}

// Port of db/pool.zig "pooled conn structure"
// SQLx owns connection checkout and release.
#[tokio::test]
async fn pooled_connection() {
    with_db(|pool| async move {
        let mut conn = pool.acquire().await.unwrap();
        assert_eq!(
            sqlx::query_scalar::<_, i32>(FIRST_CONNECTION_QUERY_SQL)
                .fetch_one(&mut *conn)
                .await
                .unwrap(),
            1
        );
        drop(conn);
        let mut again = pool.acquire().await.unwrap();
        assert_eq!(
            sqlx::query_scalar::<_, i32>(REACQUIRED_CONNECTION_QUERY_SQL)
                .fetch_one(&mut *again)
                .await
                .unwrap(),
            2
        );
    })
    .await;
}

// Port of db/protocol.zig "startup message format"
// The driver now negotiates startup and authenticates rather than exposing wire bytes.
#[tokio::test]
async fn driver_startup() {
    with_db(|pool| async move {
        let v: String = sqlx::query_scalar(SERVER_VERSION_SQL)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert!(v.starts_with("16."), "test server must be postgres:16");
        assert_eq!(
            sqlx::query_scalar::<_, String>(CURRENT_USER_SQL)
                .fetch_one(&pool)
                .await
                .unwrap(),
            "postgres"
        );
    })
    .await;
}

// Port of db/protocol.zig "md5 password message"
// SQLx replaces the old MD5 builder with real SCRAM authentication.
#[tokio::test]
async fn driver_scram_authentication() {
    with_db(|pool| async move {
        let hash: String = sqlx::query_scalar(DRIVER_SCRAM_AUTHENTICATION_SQL)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert!(hash.starts_with("SCRAM-SHA-256$"));
    })
    .await;
}

// Port of db/protocol.zig "command complete parsing"
// Affected-row counts replace handwritten command tags.
#[tokio::test]
async fn affected_rows() {
    with_db(|pool| async move {
        sqlx::query(CREATE_COUNTS_SQL).execute(&pool).await.unwrap();
        assert_eq!(
            sqlx::query(INSERT_COUNTS_SQL)
                .execute(&pool)
                .await
                .unwrap()
                .rows_affected(),
            5
        );
        assert_eq!(
            sqlx::query(UPDATE_COUNTS_SQL)
                .execute(&pool)
                .await
                .unwrap()
                .rows_affected(),
            5
        );
        assert_eq!(
            sqlx::query(DELETE_COUNTS_SQL)
                .execute(&pool)
                .await
                .unwrap()
                .rows_affected(),
            3
        );
    })
    .await;
}

async fn repositories(pool: sqlx::PgPool) {
    migrate(&pool).await.unwrap();
    let s = PostgresStore { pool: pool.clone() };
    let now = now_ms();
    let user = User {
        id: UserId::random(),
        email: "crud@example.com".into(),
        password_hash: "fixture-hash".into(),
        api_key: "crud-key".into(),
        github_id: Some("42".into()),
        created_at: now,
        updated_at: now,
    };
    s.create_user(&user).await.unwrap();
    assert_eq!(
        s.create_user(&User {
            id: UserId::random(),
            api_key: "other".into(),
            github_id: None,
            ..user.clone()
        })
        .await,
        Err(DbError::EmailTaken)
    );
    assert_eq!(
        s.user_by_email(&user.email).await.unwrap().unwrap().id,
        user.id
    );
    assert_eq!(
        s.user_by_api_key(&user.api_key).await.unwrap().unwrap().id,
        user.id
    );
    assert_eq!(
        s.user_by_id(user.id).await.unwrap().unwrap().github_id,
        user.github_id
    );
    assert!(s.user_by_email("unknown").await.unwrap().is_none());
    assert!(s.user_by_api_key("unknown").await.unwrap().is_none());
    assert!(s.user_by_id(UserId::random()).await.unwrap().is_none());
    let c = ClientId(user.id.0);
    let mut t = Task::new(c, "https://example.com/repo", "main", "text 🦀");
    t.github_token = Some("secret-never-store".into());
    t.env_vars = vec![common::types::EnvVar {
        key: "SECRET".into(),
        value: "secret".into(),
    }];
    t.create_pr = true;
    t.pr_title = Some("title".into());
    t.vm_id = Some(common::VmId::random());
    s.create_task(&t).await.unwrap();
    let got = s.get_task(t.id).await.unwrap().unwrap();
    assert_eq!(got.repo_url, t.repo_url);
    assert_eq!(got.prompt, t.prompt);
    assert_eq!(got.vm_id, t.vm_id);
    assert!(got.github_token.is_none());
    assert!(got.env_vars.is_empty());
    assert!(got.completed_at.is_none());
    assert!(s.get_task(TaskId::random()).await.unwrap().is_none());
    assert_eq!(
        sqlx::query_scalar::<_, Vec<u8>>(TASK_USER_ID_SQL)
            .bind(t.id.0.as_slice())
            .fetch_one(&pool)
            .await
            .unwrap(),
        user.id.0
    );
    let mut newer = Task::new(c, "git@example:repo", "b", "newer");
    newer.created_at = t.created_at + 1;
    s.create_task(&newer).await.unwrap();
    assert_eq!(s.list_tasks(c, None, 1, 0).await.unwrap().0[0].id, newer.id);
    assert_eq!(s.list_tasks(c, None, 1, 1).await.unwrap().1, 2);
    assert_eq!(s.list_queued(100).await.unwrap().len(), 2);
    assert_eq!(s.count_by_state(TaskState::Queued).await.unwrap(), 2);
    let n = NodeStatus {
        node_id: NodeId::random(),
        hostname: "roundtrip".into(),
        total_vm_slots: 10,
        active_vms: 3,
        warm_vms: 5,
        cpu_usage: 0.25,
        memory_usage: 0.5,
        disk_available_bytes: i64::MAX,
        healthy: true,
        draining: false,
        uptime_seconds: 3600,
        last_task_at: None,
        active_task_ids: vec![],
    };
    s.upsert_node(&n).await.unwrap();
    assert_eq!(s.get_node(n.node_id).await.unwrap(), Some(n.clone()));
    assert!(s.get_node(NodeId::random()).await.unwrap().is_none());
    assert_eq!(s.list_nodes().await.unwrap(), vec![n.clone()]);
    assert_eq!(s.list_healthy(30000).await.unwrap().len(), 1);
    assert_eq!(s.set_draining(n.node_id, true).await.unwrap(), 1);
    assert!(s.list_healthy(30000).await.unwrap().is_empty());
    assert_eq!(s.update_heartbeat(n.node_id).await.unwrap(), 1);
    assert_eq!(s.update_heartbeat(NodeId::random()).await.unwrap(), 0);
    sqlx::query(EXPIRE_NODES_SQL).execute(&pool).await.unwrap();
    assert_eq!(s.remove_stale(30000).await.unwrap(), vec![n.node_id]);
    assert!(s.list_nodes().await.unwrap().is_empty());
    t.state = TaskState::Starting;
    t.node_id = Some(n.node_id);
    t.started_at = Some(now);
    s.save_task(&t).await.unwrap();
    assert_eq!(
        s.get_task(t.id).await.unwrap().unwrap().state,
        TaskState::Starting
    );
    let mut failed_completion = t.clone();
    failed_completion.state = TaskState::Completed;
    let invalid_usage = UsageRecord {
        client_id: c,
        task_id: TaskId::random(),
        timestamp: now,
        usage: UsageMetrics::default(),
    };
    assert_eq!(
        s.commit_result(&failed_completion, &invalid_usage, true)
            .await,
        Err(DbError::ConstraintViolation)
    );
    assert_eq!(
        s.get_task(t.id).await.unwrap().unwrap().state,
        TaskState::Starting
    );
    t.state = TaskState::Completed;
    t.completed_at = Some(now + 20);
    t.pr_url = Some("https://example.com/pr/1".into());
    t.usage = UsageMetrics {
        compute_time_ms: 1000,
        input_tokens: 100,
        output_tokens: 50,
        cache_read_tokens: 7,
        cache_write_tokens: 3,
        tool_calls: 5,
    };
    s.save_task(&t).await.unwrap();
    assert_eq!(s.get_task(t.id).await.unwrap().unwrap().usage, t.usage);
    assert_eq!(
        s.list_tasks(c, Some(TaskState::Completed), 0, 0)
            .await
            .unwrap()
            .1,
        1
    );
    s.record_usage(&UsageRecord {
        client_id: c,
        task_id: t.id,
        timestamp: now,
        usage: t.usage,
    })
    .await
    .unwrap();
    s.record_usage(&UsageRecord {
        client_id: c,
        task_id: t.id,
        timestamp: now + 10,
        usage: t.usage,
    })
    .await
    .unwrap();
    assert_eq!(s.usage_report(c, now, now).await.unwrap(), (t.usage, 1));
    assert_eq!(s.usage_report(c, now, now + 10).await.unwrap().1, 2);
    assert_eq!(
        s.usage_report(ClientId::random(), 0, i64::MAX)
            .await
            .unwrap()
            .1,
        0
    );
    assert_eq!(
        s.get_daily_totals(c, 1).await.unwrap()[0].1.input_tokens,
        200
    );
    assert_eq!(s.prune_older_than(now + 10).await.unwrap(), 1);
    assert_eq!(
        sqlx::query_scalar::<_, Vec<u8>>(USAGE_USER_ID_SQL)
            .fetch_one(&pool)
            .await
            .unwrap(),
        user.id.0
    );
    newer.state = TaskState::Cancelled;
    newer.completed_at = Some(now);
    s.save_task(&newer).await.unwrap();
    assert_eq!(
        s.get_task(newer.id).await.unwrap().unwrap().state,
        TaskState::Cancelled
    );
    // Corrupt rows return typed errors instead of panicking.
    sqlx::query(INVALID_TASK_STATE_SQL)
        .bind(t.id.0.as_slice())
        .execute(&pool)
        .await
        .unwrap();
    assert!(matches!(s.get_task(t.id).await, Err(DbError::InvalidRow)));
    sqlx::query(INVALID_TASK_NODE_SQL)
        .bind(t.id.0.as_slice())
        .bind(vec![1u8])
        .execute(&pool)
        .await
        .unwrap();
    assert!(matches!(s.get_task(t.id).await, Err(DbError::InvalidRow)));
}

// Port of db/types.zig "param encoding"
// Repository bindings replace handwritten encoders for SMALLINT/INTEGER/BIGINT,
// floating point, bool, text, bytea and nullable columns.
#[tokio::test]
async fn repository_parameter_roundtrips() {
    with_db(repositories).await;
}

// Port of db/types.zig "value conversions"
// Driver decoding and repository validation replace Value conversion helpers.
#[tokio::test]
async fn repository_value_conversions() {
    with_db(|pool| async move {
        migrate(&pool).await.unwrap();
        let row = sqlx::query(REPOSITORY_VALUE_CONVERSIONS_SQL)
            .bind(42i16)
            .bind(100i32)
            .bind(i64::MAX)
            .bind(0.5f64)
            .bind(true)
            .bind("text")
            .bind(vec![0u8, 255])
            .bind(None::<String>)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(row.get::<i16, _>("a"), 42);
        assert_eq!(row.get::<i32, _>("b"), 100);
        assert_eq!(row.get::<i64, _>("c"), i64::MAX);
        assert_eq!(row.get::<f64, _>("d"), 0.5);
        assert!(row.get::<bool, _>("e"));
        assert_eq!(row.get::<String, _>("f"), "text");
        assert_eq!(row.get::<Vec<u8>, _>("g"), vec![0, 255]);
        assert!(row.get::<Option<String>, _>("h").is_none());
    })
    .await;
}
