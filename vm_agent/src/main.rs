//! Guest binary startup, network wait, and platform listener selection.

use common::config::VmAgentConfig;
use marathon_vm_agent::{
    agent::Agent,
    cleanup::{Cleanup, CleanupStrategy},
    metrics::Registry,
    repo_setup::RepoSetup,
};
use std::sync::Arc;

async fn wait_for_network() {
    for attempt in 1..=15 {
        let result = tokio::process::Command::new("ping")
            .args(["-c", "1", "-W", "1", "8.8.8.8"])
            .output()
            .await;
        if result.is_ok_and(|r| r.status.success()) {
            tracing::info!(operation = "network_wait", attempt, "Network ready");
            return;
        }
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
    tracing::warn!(
        operation = "network_wait",
        "Network unavailable, continuing anyway"
    );
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    common::telemetry::init("marathon-vm-agent");
    let config = VmAgentConfig::from_env().inspect_err(|error| {
        tracing::error!(operation = "configuration", %error, "Invalid guest configuration");
    })?;
    tracing::info!(
        operation = "startup",
        vsock_port = config.vsock_port,
        work_dir = %config.work_dir,
        claude_code_path = %config.claude_code_path,
        cleanup_strategy = %config.cleanup_strategy,
        "Guest execution configuration"
    );
    #[cfg(target_os = "linux")]
    let listener = marathon_vm_agent::transport::VsockListener::bind(config.vsock_port)
        .inspect_err(|error| {
            tracing::error!(operation = "bind", %error, "Cannot bind guest vsock listener");
        })?;
    #[cfg(not(target_os = "linux"))]
    let listener = {
        let address = std::env::var("MARATHON_VM_AGENT_TCP_ADDR").ok();
        tracing::info!(
            operation = "startup",
            tcp_address = address.as_deref(),
            "Guest test transport configuration"
        );
        marathon_vm_agent::transport::bind_test_transport(address.as_deref())
            .await
            .map_err(|error| {
                tracing::error!(operation = "bind", %error, "Cannot start guest transport");
                error
            })?
    };
    wait_for_network().await;
    let agent = Agent {
        cleanup: Cleanup::new(CleanupStrategy::from_string(&config.cleanup_strategy)),
        config,
        preparer: RepoSetup,
        run_as_marathon: nix::unistd::geteuid().is_root(),
        registry: Arc::new(Registry::default()),
    };
    agent.serve(listener).await.inspect_err(|error| {
        tracing::error!(operation = "accept", %error, "Guest listener failed");
    })?;
    Ok(())
}
