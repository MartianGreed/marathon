//! Load configuration, initialise telemetry and run both gRPC services.

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    common::telemetry::init("marathon-orchestrator");
    let config = common::config::OrchestratorConfig::from_env()?;
    let local = marathon_orchestrator::config::LocalConfig::from_env()?;
    let listener =
        tokio::net::TcpListener::bind((config.listen_address.as_str(), config.listen_port)).await?;
    tracing::info!(
        operation="startup",
        address = %listener.local_addr()?,
        "orchestrator listening"
    );
    let app = marathon_orchestrator::server::startup(config).await;
    marathon_orchestrator::server::serve(
        listener,
        app,
        local,
        marathon_orchestrator::server::shutdown_signal(),
    )
    .await
}
