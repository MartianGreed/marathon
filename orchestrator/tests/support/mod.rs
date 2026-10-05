//! Shared helpers for isolated Postgres and in-process gRPC tests.

#![allow(dead_code)]

use common::{config::OrchestratorConfig, pb};
use futures::FutureExt;
use marathon_orchestrator::{
    config::LocalConfig,
    scheduler::Orchestrator,
    server,
    store::{MemoryStore, Store},
};
use sqlx::{
    PgPool,
    postgres::{PgConnectOptions, PgPoolOptions},
};
use std::{future::Future, panic::AssertUnwindSafe, sync::Arc, time::Duration};
use tonic::{Request, transport::Channel};

const CREATE_DATABASE_SQL: &str = "
    CREATE DATABASE {name}
";

const DROP_DATABASE_SQL: &str = "
    DROP DATABASE {name} WITH (FORCE)
";

/// Run a test in a private database and clean it up, including after a caught panic.
pub async fn with_db<F, Fut>(test: F)
where
    F: FnOnce(PgPool) -> Fut,
    Fut: Future<Output = ()>,
{
    let url = match std::env::var("MARATHON_TEST_POSTGRES_URL") {
        Ok(url) => url,
        Err(_) => {
            assert_ne!(
                std::env::var("MARATHON_TEST_REQUIRE_POSTGRES").as_deref(),
                Ok("1"),
                "MARATHON_TEST_POSTGRES_URL required"
            );
            eprintln!("SKIPPED (MARATHON_TEST_POSTGRES_URL not set)");
            return;
        }
    };
    let options: PgConnectOptions = url.parse().unwrap();
    let admin = PgPoolOptions::new()
        .max_connections(2)
        .connect_with(options.clone())
        .await
        .unwrap();
    // Generated name contains only a fixed ASCII prefix and lowercase hex.
    let name = format!("marathon_b_{}", hex::encode(rand::random::<[u8; 12]>()));
    sqlx::query(sqlx::AssertSqlSafe(
        CREATE_DATABASE_SQL.replace("{name}", &name),
    ))
    .execute(&admin)
    .await
    .unwrap();
    let pool = PgPoolOptions::new()
        .max_connections(10)
        .connect_with(options.database(&name))
        .await
        .unwrap();
    let result = AssertUnwindSafe(test(pool.clone())).catch_unwind().await;
    pool.close().await;
    sqlx::query(sqlx::AssertSqlSafe(
        DROP_DATABASE_SQL.replace("{name}", &name),
    ))
    .execute(&admin)
    .await
    .unwrap();
    admin.close().await;
    if let Err(panic) = result {
        std::panic::resume_unwind(panic);
    }
}

/// An in-process gRPC server with clients and an explicit shutdown handle.
pub struct TestServer {
    /// Application instance shared by the services.
    pub app: Arc<Orchestrator>,
    /// Client transport connected to the test listener.
    pub channel: Channel,
    /// Ephemeral loopback address bound by the test server.
    pub address: std::net::SocketAddr,
    job: tokio::task::JoinHandle<anyhow::Result<()>>,
    stop: Option<tokio::sync::oneshot::Sender<()>>,
}

impl TestServer {
    /// Start a loopback test server with optional persistence and node authentication.
    pub async fn start(store: Option<Arc<dyn Store>>, key: Option<&str>) -> Self {
        Self::configured(store, key, LocalConfig::default(), None).await
    }

    /// Start an in-process server with the requested persistence, node auth and TLS.
    pub async fn configured(
        store: Option<Arc<dyn Store>>,
        key: Option<&str>,
        local: LocalConfig,
        tls: Option<tonic::transport::ClientTlsConfig>,
    ) -> Self {
        let app = Orchestrator::new(
            OrchestratorConfig {
                node_auth_key: key.map(str::to_owned),
                jwt_secret: Some("test-jwt-secret".into()),
                anthropic_api_key: "test-anthropic-secret".into(),
                ..Default::default()
            },
            store.unwrap_or_else(|| Arc::new(MemoryStore::default())),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (stop, rx) = tokio::sync::oneshot::channel();
        let server_app = app.clone();
        let job = tokio::spawn(server::serve(listener, server_app, local, async {
            let _ = rx.await;
        }));
        let mut endpoint = Channel::from_shared(format!(
            "{}://{address}",
            if tls.is_some() { "https" } else { "http" }
        ))
        .unwrap()
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(10));
        if let Some(tls) = tls {
            endpoint = endpoint.tls_config(tls).unwrap();
        }
        let channel = endpoint.connect().await.unwrap();
        Self {
            app,
            channel,
            address,
            job,
            stop: Some(stop),
        }
    }

    /// Signal graceful shutdown and wait for the test server to finish.
    pub async fn shutdown(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        tokio::time::timeout(Duration::from_secs(5), &mut self.job)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
    }

    /// Create a client-facing stub on the test server channel.
    pub fn client(&self) -> pb::marathon_service_client::MarathonServiceClient<Channel> {
        pb::marathon_service_client::MarathonServiceClient::new(self.channel.clone())
    }

    /// Create a node-facing stub on the test server channel.
    pub fn node(&self) -> pb::node_service_client::NodeServiceClient<Channel> {
        pb::node_service_client::NodeServiceClient::new(self.channel.clone())
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        self.job.abort();
    }
}

/// Add a sensitive API-key credential to a test request.
pub fn authorized<T>(message: T, key: &str) -> Request<T> {
    let mut r = Request::new(message);
    common::client_auth::ClientCredential::ApiKey(key.into())
        .apply(r.metadata_mut())
        .unwrap();
    r
}

/// Register an account on the test server and return its credentials.
pub async fn register(s: &TestServer, email: &str) -> pb::AuthResponse {
    s.client()
        .register(pb::RegisterRequest {
            email: email.into(),
            password: "test-password".into(),
        })
        .await
        .unwrap()
        .into_inner()
}

/// Build a healthy test node status with the requested capacity.
pub fn status(slots: u32) -> pb::NodeStatus {
    pb::NodeStatus {
        hostname: "fake-node".into(),
        total_vm_slots: slots,
        healthy: true,
        ..Default::default()
    }
}

/// Build a signed test heartbeat with current time and the requested capacity.
pub fn heartbeat(id: common::NodeId, key: Option<&str>, slots: u32) -> pb::NodeHeartbeat {
    pb::NodeHeartbeat {
        auth: Some(common::node_auth::node_auth(
            key.map(str::as_bytes),
            &id,
            common::types::now_ms(),
        )),
        status: Some(status(slots)),
    }
}

/// Read the next task event with a bounded test timeout.
pub async fn next_event(stream: &mut tonic::Streaming<pb::TaskEvent>) -> pb::TaskEvent {
    tokio::time::timeout(Duration::from_secs(10), stream.message())
        .await
        .unwrap()
        .unwrap()
        .unwrap()
}

/// Read the next heartbeat response with a bounded test timeout.
pub async fn next_heartbeat(
    stream: &mut tonic::Streaming<pb::HeartbeatResponse>,
) -> pb::HeartbeatResponse {
    tokio::time::timeout(Duration::from_secs(10), stream.message())
        .await
        .unwrap()
        .unwrap()
        .unwrap()
}
