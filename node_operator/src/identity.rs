//! This node's id, for logs and spans in code that has no handle on the
//! heartbeat client (VMs, the pool). Set once at startup.

use std::sync::OnceLock;

use common::NodeId;

static NODE_ID: OnceLock<NodeId> = OnceLock::new();

/// Record the node id. Only the first call counts.
pub fn set(node_id: NodeId) {
    let _ = NODE_ID.set(node_id);
}

pub fn get() -> Option<NodeId> {
    NODE_ID.get().copied()
}

/// The node id in hex, or `unknown` before [`set`].
pub fn label() -> String {
    get().map_or_else(|| "unknown".to_string(), |id| id.to_hex())
}
