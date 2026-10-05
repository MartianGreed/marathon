//! One listener for both services, optional TLS and graceful shutdown.

use crate::{
    config::LocalConfig,
    db::PostgresStore,
    scheduler::Orchestrator,
    service::Service,
    store::{MemoryStore, Store},
};
use common::{config::OrchestratorConfig, pb};
use std::{future::Future, sync::Arc, time::Duration};
use tokio::net::TcpListener;
use tokio_stream::wrappers::TcpListenerStream;
use tonic::transport::{Identity, Server, ServerTlsConfig};

/// Connect and migrate, falling back to memory when the database is unavailable.
pub async fn startup(config: OrchestratorConfig) -> Arc<Orchestrator> {
    let store: Arc<dyn Store> = match PostgresStore::connect(&config.postgres_url).await {
        Ok(store) => Arc::new(store),
        Err(e) => {
            metrics::counter!(
                "marathon_db_errors_total",
                "operation" => "startup"
            )
            .increment(1);
            tracing::warn!(
                operation="startup",
                error = %e,
                postgres_url = ?common::redact::SafeUrl(&config.postgres_url),
                "database unavailable; using memory stores"
            );
            Arc::new(MemoryStore::default())
        }
    };
    Orchestrator::new(config, store)
}

/// Serve both services with optional TLS, metrics and graceful stream shutdown.
pub async fn serve(
    listener: TcpListener,
    app: Arc<Orchestrator>,
    local: LocalConfig,
    shutdown: impl Future<Output = ()> + Send + 'static,
) -> anyhow::Result<()> {
    let mut builder = Server::builder();
    match (local.tls_cert_path, local.tls_key_path) {
        (Some(cert), Some(key)) => {
            let (cert, key) = tokio::try_join!(tokio::fs::read(cert), tokio::fs::read(key))?;
            builder = builder
                .tls_config(ServerTlsConfig::new().identity(Identity::from_pem(cert, key)))?;
        }
        (None, None) => {}
        _ => anyhow::bail!("both TLS certificate and key paths must be set"),
    }
    if let Some(port) = local.metrics_port {
        metrics_exporter_prometheus::PrometheusBuilder::new()
            .with_http_listener(([0, 0, 0, 0], port))
            .install()?;
    }
    let sweeper_app = app.clone();
    let sweeper = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(
            sweeper_app.config.heartbeat_interval_ms.max(1),
        ));
        loop {
            interval.tick().await;
            sweeper_app.sweep().await;
        }
    });

    struct SweepGuard(tokio::task::JoinHandle<()>);

    impl Drop for SweepGuard {
        fn drop(&mut self) {
            self.0.abort();
        }
    }
    let _sweep_guard = SweepGuard(sweeper);
    let shutdown_sender = app.shutdown.clone();
    let shutdown = async move {
        shutdown.await;
        let _ = shutdown_sender.send(true);
    };
    let service = Service { app };

    fn sensitive(mut request: tonic::Request<()>) -> Result<tonic::Request<()>, tonic::Status> {
        common::client_auth::mark_credentials_sensitive(request.metadata_mut());
        Ok(request)
    }
    let result = builder
        .add_service(
            pb::marathon_service_server::MarathonServiceServer::with_interceptor(
                service.clone(),
                sensitive,
            ),
        )
        .add_service(
            pb::node_service_server::NodeServiceServer::with_interceptor(service, sensitive),
        )
        .serve_with_incoming_shutdown(TcpListenerStream::new(listener), shutdown)
        .await;
    result?;
    Ok(())
}

/// Wait for SIGINT or SIGTERM without panicking on signal setup failure.
pub async fn shutdown_signal() {
    #[cfg(unix)]
    {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut term) => {
                tokio::select! {
                    _ = tokio::signal::ctrl_c() => {},
                    _ = term.recv() => {},
                }
            }
            Err(e) => {
                tracing::error!(
                    operation="shutdown",
                    error = %e,
                    "cannot install SIGTERM handler"
                );
                let _ = tokio::signal::ctrl_c().await;
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
