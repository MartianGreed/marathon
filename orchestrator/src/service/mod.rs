//! Client and node gRPC services share one application instance.

pub mod client;

/// Node-facing heartbeat and reporting RPC implementation.
pub mod node;
use crate::scheduler::Orchestrator;
use futures::Stream;
use std::{pin::Pin, sync::Arc};
use tonic::Status;

/// Both tonic services backed by the same orchestrator instance.
#[derive(Clone)]
pub struct Service {
    /// Application instance shared by the services.
    pub app: Arc<Orchestrator>,
}

/// Client task-event response stream.
pub type EventStream = Pin<Box<dyn Stream<Item = Result<common::pb::TaskEvent, Status>> + Send>>;

/// Node heartbeat response stream.
pub type HeartbeatStream =
    Pin<Box<dyn Stream<Item = Result<common::pb::HeartbeatResponse, Status>> + Send>>;
