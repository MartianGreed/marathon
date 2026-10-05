//! `marathon-vm-agent` entry point. Placeholder until the service lane ports the Zig
//! implementation.

fn main() {
    common::telemetry::init("marathon-vm-agent");
    tracing::info!(
        operation = "startup",
        version = env!("CARGO_PKG_VERSION"),
        "marathon-vm-agent starting"
    );
}
