const std = @import("std");
const common = @import("common");
const types = common.types;

const log = std.log.scoped(.registry);

pub const NodeRegistry = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(types.NodeId, types.NodeStatus),
    last_heartbeat: std.AutoHashMap(types.NodeId, i64),
    mutex: std.Thread.Mutex,
    timeout_ms: u64,

    pub fn init(allocator: std.mem.Allocator) NodeRegistry {
        return .{
            .allocator = allocator,
            .nodes = std.AutoHashMap(types.NodeId, types.NodeStatus).init(allocator),
            .last_heartbeat = std.AutoHashMap(types.NodeId, i64).init(allocator),
            .mutex = .{},
            .timeout_ms = 30_000,
        };
    }

    pub fn deinit(self: *NodeRegistry) void {
        self.nodes.deinit();
        self.last_heartbeat.deinit();
    }

    pub fn register(self: *NodeRegistry, status: types.NodeStatus) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.nodes.put(status.node_id, status);
        try self.last_heartbeat.put(status.node_id, std.time.milliTimestamp());

        log.info("node registered: node_id={s} hostname={s} slots={d}", .{
            &types.formatId(status.node_id),
            status.hostname,
            status.total_vm_slots,
        });
    }

    pub fn updateHeartbeat(self: *NodeRegistry, node_id: types.NodeId, status: types.NodeStatus) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.nodes.put(node_id, status);
        try self.last_heartbeat.put(node_id, std.time.milliTimestamp());
    }

    pub fn getNode(self: *NodeRegistry, node_id: types.NodeId) ?types.NodeStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.nodes.get(node_id);
    }

    pub fn getHealthyNodes(self: *NodeRegistry) ![]types.NodeStatus {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(types.NodeStatus).init(self.allocator);
        errdefer result.deinit();

        const now = std.time.milliTimestamp();

        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            const last = self.last_heartbeat.get(entry.key_ptr.*) orelse continue;
            if (now - last < @as(i64, @intCast(self.timeout_ms)) and entry.value_ptr.healthy) {
                try result.append(entry.value_ptr.*);
            }
        }

        return result.toOwnedSlice();
    }

    pub fn removeStale(self: *NodeRegistry) ![]types.NodeId {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stale = std.ArrayList(types.NodeId).init(self.allocator);
        errdefer stale.deinit();

        const now = std.time.milliTimestamp();

        var it = self.last_heartbeat.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.* > @as(i64, @intCast(self.timeout_ms))) {
                try stale.append(entry.key_ptr.*);
            }
        }

        for (stale.items) |node_id| {
            log.warn("removing stale node: node_id={s}", .{&types.formatId(node_id)});
            _ = self.nodes.remove(node_id);
            _ = self.last_heartbeat.remove(node_id);
        }

        return stale.toOwnedSlice();
    }

    pub fn nodeCount(self: *NodeRegistry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.nodes.count();
    }

    pub fn totalCapacity(self: *NodeRegistry) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var total: u32 = 0;
        var it = self.nodes.valueIterator();
        while (it.next()) |status| {
            if (status.healthy and !status.draining) {
                total += status.availableSlots();
            }
        }
        return total;
    }
};

test "node registry operations" {
    const allocator = std.testing.allocator;

    var reg = NodeRegistry.init(allocator);
    defer reg.deinit();

    var node_id: types.NodeId = undefined;
    @memset(&node_id, 1);

    const status = types.NodeStatus{
        .node_id = node_id,
        .hostname = "test-node",
        .total_vm_slots = 10,
        .active_vms = 2,
        .warm_vms = 5,
        .cpu_usage = 0.3,
        .memory_usage = 0.4,
        .disk_available_bytes = 100_000_000_000,
        .healthy = true,
        .draining = false,
        .uptime_seconds = 3600,
        .last_task_at = null,
        .active_task_ids = &[_]types.TaskId{},
    };

    try reg.register(status);
    try std.testing.expectEqual(@as(usize, 1), reg.nodeCount());

    const retrieved = reg.getNode(node_id);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u32, 10), retrieved.?.total_vm_slots);
}
