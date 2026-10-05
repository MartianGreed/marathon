//! Heartbeat health and expiry. Live stream ownership is tracked by the scheduler.

use common::{NodeId, types::NodeStatus};
use std::collections::BTreeMap;

/// Node status snapshots and the time of each last heartbeat.
#[derive(Default)]
pub struct Registry {
    /// Status and last heartbeat time, keyed by node identifier.
    pub nodes: BTreeMap<NodeId, (NodeStatus, i64)>,
}

impl Registry {
    /// Insert or refresh node status and heartbeat time.
    pub fn register(&mut self, status: NodeStatus, now: i64) {
        self.nodes.insert(status.node_id, (status, now));
    }

    /// Return a copy of the node status, or None for an unknown node.
    pub fn get(&self, id: NodeId) -> Option<NodeStatus> {
        self.nodes.get(&id).map(|(s, _)| s.clone())
    }

    /// Return healthy node snapshots with heartbeats inside the timeout.
    pub fn healthy_nodes(&self, now: i64, timeout: i64) -> Vec<NodeStatus> {
        self.nodes
            .values()
            .filter(|(s, t)| s.healthy && now.saturating_sub(*t) < timeout)
            .map(|(s, _)| s.clone())
            .collect()
    }

    /// Remove expired nodes and return their identifiers.
    pub fn remove_stale(&mut self, now: i64, timeout: i64) -> Vec<NodeId> {
        let ids: Vec<_> = self
            .nodes
            .iter()
            .filter(|(_, (_, t))| now.saturating_sub(*t) > timeout)
            .map(|(id, _)| *id)
            .collect();
        for id in &ids {
            self.nodes.remove(id);
        }
        ids
    }

    /// Return the number of nodes currently registered.
    pub fn node_count(&self) -> usize {
        self.nodes.len()
    }

    /// Sum free slots of recent, healthy, non-draining nodes.
    pub fn total_capacity(&self, now: i64, timeout: i64) -> u32 {
        self.healthy_nodes(now, timeout)
            .iter()
            .filter(|n| !n.draining)
            .fold(0u32, |a, n| a.saturating_add(n.available_slots()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(id: NodeId) -> NodeStatus {
        NodeStatus {
            node_id: id,
            total_vm_slots: 10,
            active_vms: 3,
            warm_vms: 5,
            cpu_usage: 0.5,
            memory_usage: 0.4,
            healthy: true,
            ..NodeStatus::default()
        }
    }

    // Port of registry/registry.zig "node registry operations"
    #[test]
    fn operations() {
        let mut r = Registry::default();
        let id = NodeId::random();
        r.register(status(id), 0);
        assert_eq!(r.get(id).unwrap().total_vm_slots, 10);
        assert_eq!(r.healthy_nodes(29999, 30000).len(), 1);
        assert!(r.healthy_nodes(30000, 30000).is_empty());
        assert_eq!(r.remove_stale(30001, 30000), vec![id]);
        assert!(r.get(id).is_none());
    }

    // Port of registry/registry.zig "node registry nodeCount"
    #[test]
    fn node_count() {
        let mut r = Registry::default();
        assert_eq!(r.node_count(), 0);
        r.register(status(NodeId::random()), 0);
        r.register(status(NodeId::random()), 0);
        assert_eq!(r.node_count(), 2);
    }

    // Port of registry/registry.zig "node registry update existing"
    #[test]
    fn update_existing() {
        let mut r = Registry::default();
        let id = NodeId::random();
        r.register(status(id), 0);
        let mut s = status(id);
        s.active_vms = 6;
        r.register(s, 100);
        assert_eq!(r.node_count(), 1);
        assert_eq!(r.get(id).unwrap().active_vms, 6);
        assert_eq!(r.nodes[&id].1, 100);
    }

    // Port of registry/registry.zig "node registry totalCapacity"
    #[test]
    fn total_capacity() {
        let mut r = Registry::default();
        r.register(status(NodeId::random()), 0);
        r.register(status(NodeId::random()), 0);
        assert_eq!(r.total_capacity(0, 30000), 14);
        assert_eq!(r.total_capacity(30001, 30000), 0);
    }

    // Port of registry/registry.zig "node registry excludes unhealthy and draining from capacity"
    #[test]
    fn excludes_unavailable() {
        let mut r = Registry::default();
        let mut a = status(NodeId::random());
        a.healthy = false;
        r.register(a, 0);
        let mut b = status(NodeId::random());
        b.draining = true;
        r.register(b, 0);
        assert_eq!(r.total_capacity(0, 30000), 0);
    }

    // Port of registry/registry.zig "node registry getNode returns null for unknown"
    #[test]
    fn unknown_node() {
        assert!(Registry::default().get(NodeId::random()).is_none());
    }

    // Port of db/repository/node.zig "node status conversion"
    #[test]
    fn node_status_conversion() {
        let n = status(NodeId::random());
        assert_eq!(n.available_slots(), 7);
        assert!(n.score() > 0.0);
        assert_eq!(NodeStatus::from_proto(n.node_id, &n.to_proto()).unwrap(), n);
    }
}
