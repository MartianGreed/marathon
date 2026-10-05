//! Shared library for the Marathon binaries.
//!
//! - [`pb`]: the `marathon.v1` gRPC contract generated from `proto/marathon/v1`,
//!   with tonic clients and servers for `MarathonService` and `NodeService`.
//! - [`ids`]: fixed-size ids and their lowercase-hex wire form.
//! - [`types`]: task state machine, usage metrics, node status and scoring.
//! - [`config`]: environment configuration for each binary, with the
//!   defaults the Zig implementation used.
//! - [`client_auth`]: gRPC metadata keys for client credentials.
//! - [`node_auth`]: HMAC token proving a node holds the shared node key.
//! - [`redact`]: `Debug` that hides secrets in generated messages.
//! - [`vsock`]: length-prefixed `VsockMessage` framing and the Firecracker
//!   host-side `CONNECT` handshake.
//! - [`telemetry`]: tracing setup and the standard structured field names.
//!
//! This crate is frozen once the service lanes start; changes go through
//! the wave coordinator.

pub mod client_auth;
pub mod config;
pub mod ids;
pub mod node_auth;
pub mod redact;
pub mod telemetry;
pub mod types;
pub mod vsock;

#[cfg(test)]
mod contract_tests;

/// Generated `marathon.v1` protobuf messages and tonic services.
///
/// Clients live in `pb::marathon_service_client` and `pb::node_service_client`,
/// servers in `pb::marathon_service_server` and `pb::node_service_server`.
/// Messages carrying secrets print them redacted in `Debug` (see [`redact`]).
pub mod pb {
    #![allow(missing_docs, clippy::all, clippy::pedantic)]
    tonic::include_proto!("marathon.v1");
}

pub use ids::{ClientId, IdParseError, NodeId, TaskId, UserId, VmId};
pub use types::{EnvVar, InvalidTransition, NodeStatus, OutputType, Task, TaskState, UsageMetrics};
