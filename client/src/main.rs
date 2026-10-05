//! `marathon` entry point. Placeholder until the service lane ports the Zig
//! implementation.

fn main() {
    common::telemetry::init("marathon");
    tracing::info!(
        operation = "startup",
        version = env!("CARGO_PKG_VERSION"),
        "marathon starting"
    );
}
