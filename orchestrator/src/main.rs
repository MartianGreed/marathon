//! `marathon-orchestrator` entry point. Placeholder until the service lane ports the Zig
//! implementation.

fn main() {
    common::telemetry::init("marathon-orchestrator");
    tracing::info!(
        operation = "startup",
        version = env!("CARGO_PKG_VERSION"),
        "marathon-orchestrator starting"
    );
}
