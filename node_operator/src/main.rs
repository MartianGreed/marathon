//! `marathon-node-operator`: runs Marathon tasks in Firecracker VMs on this
//! node and keeps a heartbeat stream to the orchestrator.

use std::process::ExitCode;
use std::sync::Arc;

use common::config::NodeOperatorConfig;
use node_operator::heartbeat::{HeartbeatClient, HeartbeatSettings};
use node_operator::snapshot::SnapshotManager;
use node_operator::task::executor::{ExecutorSettings, TaskExecutor};
use node_operator::vm::{FirecrackerLauncher, PoolConfig, VmConfig, VmPool};

#[tokio::main]
async fn main() -> ExitCode {
    common::telemetry::init("marathon-node-operator");

    let config = match NodeOperatorConfig::from_env() {
        Ok(c) => c,
        Err(e) => {
            tracing::error!(operation = "startup", error = %e, "invalid configuration");
            return ExitCode::FAILURE;
        }
    };
    tracing::info!(
        operation = "startup",
        version = env!("CARGO_PKG_VERSION"),
        listen = %format!("{}:{}", config.listen_address, config.listen_port),
        orchestrator = %format!("{}:{}", config.orchestrator_address, config.orchestrator_port),
        tls = config.tls_enabled,
        node_auth = config.auth_key.is_some(),
        vm_slots = config.total_vm_slots,
        warm_pool_target = config.warm_pool_target,
        "Marathon node operator starting"
    );

    let snapshots = match SnapshotManager::new(&config.snapshot_path) {
        Ok(s) => Arc::new(s),
        Err(e) => {
            tracing::error!(operation = "startup", path = %config.snapshot_path, error = %e, "failed to open snapshot directory");
            return ExitCode::FAILURE;
        }
    };
    let launcher = Arc::new(FirecrackerLauncher::new(VmConfig::from(&config), snapshots));
    let pool = Arc::new(VmPool::new(launcher, PoolConfig::from(&config)));

    pool.warm_pool(config.warm_pool_target).await;
    tracing::info!(
        operation = "startup",
        warm = pool.warm_count(),
        "warm pool initialized"
    );

    let executor = TaskExecutor::new(
        pool.clone(),
        ExecutorSettings {
            vsock_port: config.vsock_port,
            ..ExecutorSettings::default()
        },
    );
    let heartbeat = Arc::new(HeartbeatClient::new(
        &config,
        executor,
        HeartbeatSettings::from_config(&config),
    ));
    let runner = heartbeat.clone();
    let heartbeat_task = tokio::spawn(async move { runner.run().await });
    tracing::info!(operation = "startup", node_id = %heartbeat.node_id(), "node operator ready");

    shutdown_signal().await;
    tracing::info!(operation = "shutdown", "shutting down");
    heartbeat.stop();
    let _ = heartbeat_task.await;
    pool.shutdown().await;
    tracing::info!(operation = "shutdown", "node operator stopped");
    ExitCode::SUCCESS
}

async fn shutdown_signal() {
    let ctrl_c = async {
        if let Err(e) = tokio::signal::ctrl_c().await {
            tracing::error!(error = %e, "failed to listen for ctrl-c");
            std::future::pending::<()>().await;
        }
    };
    #[cfg(unix)]
    let term = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut s) => {
                s.recv().await;
            }
            Err(e) => {
                tracing::error!(error = %e, "failed to listen for SIGTERM");
                std::future::pending::<()>().await;
            }
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! {
        () = ctrl_c => {}
        () = term => {}
    }
}
