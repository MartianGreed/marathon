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

test "node registry nodeCount" {
    const allocator = std.testing.allocator;

    var reg = NodeRegistry.init(allocator);
    defer reg.deinit();

    try std.testing.expectEqual(@as(usize, 0), reg.nodeCount());

    var node_id: types.NodeId = undefined;
    @memset(&node_id, 1);

    const status = types.NodeStatus{
        .node_id = node_id,
        .hostname = "test-node",
        .total_vm_slots = 10,
        .active_vms = 0,
        .warm_vms = 0,
        .cpu_usage = 0.0,
        .memory_usage = 0.0,
        .disk_available_bytes = 100_000_000_000,
        .healthy = true,
        .draining = false,
        .uptime_seconds = 3600,
        .last_task_at = null,
        .active_task_ids = &[_]types.TaskId{},
    };

    try reg.register(status);
    try std.testing.expectEqual(@as(usize, 1), reg.nodeCount());
}

test "node registry update existing" {
    const allocator = std.testing.allocator;

    var reg = NodeRegistry.init(allocator);
    defer reg.deinit();

    var node_id: types.NodeId = undefined;
    @memset(&node_id, 1);

    const status1 = types.NodeStatus{
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

    try reg.register(status1);

    const status2 = types.NodeStatus{
        .node_id = node_id,
        .hostname = "test-node",
        .total_vm_slots = 10,
        .active_vms = 5,
        .warm_vms = 3,
        .cpu_usage = 0.8,
        .memory_usage = 0.7,
        .disk_available_bytes = 50_000_000_000,
        .healthy = true,
        .draining = false,
        .uptime_seconds = 7200,
        .last_task_at = null,
        .active_task_ids = &[_]types.TaskId{},
    };

    try reg.register(status2);

    try std.testing.expectEqual(@as(usize, 1), reg.nodeCount());

    const retrieved = reg.getNode(node_id).?;
    try std.testing.expectEqual(@as(u32, 5), retrieved.active_vms);
    try std.testing.expect(retrieved.cpu_usage > 0.7);
}

test "node registry totalCapacity" {
    const allocator = std.testing.allocator;

    var reg = NodeRegistry.init(allocator);
    defer reg.deinit();

    var node1: types.NodeId = undefined;
    @memset(&node1, 1);

    var node2: types.NodeId = undefined;
    @memset(&node2, 2);

    try reg.register(.{
        .node_id = node1,
        .hostname = "node1",
        .total_vm_slots = 10,
        .active_vms = 3,
        .warm_vms = 2,
        .cpu_usage = 0.3,
        .memory_usage = 0.4,
        .disk_available_bytes = 100_000_000_000,
        .healthy = true,
        .draining = false,
        .uptime_seconds = 3600,
        .last_task_at = null,
        .active_task_ids = &[_]types.TaskId{},
    });

    try reg.register(.{
        .node_id = node2,
        .hostname = "node2",
        .total_vm_slots = 8,
        .active_vms = 2,
        .warm_vms = 1,
        .cpu_usage = 0.2,
        .memory_usage = 0.3,
        .disk_available_bytes = 100_000_000_000,
        .healthy = true,
        .draining = false,
        .uptime_seconds = 3600,
        .last_task_at = null,
        .active_task_ids = &[_]types.TaskId{},
    });

    const total = reg.totalCapacity();
    try std.testing.expectEqual(@as(u32, 13), total);
}

test "node registry excludes unhealthy and draining from capacity" {
    const allocator = std.testing.allocator;

    var reg = NodeRegistry.init(allocator);
    defer reg.deinit();

    var healthy_id: types.NodeId = undefined;
    @memset(&healthy_id, 1);

    var unhealthy_id: types.NodeId = undefined;
    @memset(&unhealthy_id, 2);

    var draining_id: types.NodeId = undefined;
    @memset(&draining_id, 3);

    try reg.register(.{
        .node_id = healthy_id,
        .hostname = "healthy",
        .total_vm_slots = 10,
        .active_vms = 2,
        .warm_vms = 0,
        .cpu_usage = 0.3,
        .memory_usage = 0.4,
        .disk_available_bytes = 100_000_000_000,
        .healthy = true,
        .draining = false,
        .uptime_seconds = 3600,
        .last_task_at = null,
        .active_task_ids = &[_]types.TaskId{},
    });

    try reg.register(.{
        .node_id = unhealthy_id,
        .hostname = "unhealthy",
        .total_vm_slots = 10,
        .active_vms = 0,
        .warm_vms = 0,
        .cpu_usage = 0.0,
        .memory_usage = 0.0,
        .disk_available_bytes = 100_000_000_000,
        .healthy = false,
        .draining = false,
        .uptime_seconds = 3600,
        .last_task_at = null,
        .active_task_ids = &[_]types.TaskId{},
    });

    try reg.register(.{
        .node_id = draining_id,
        .hostname = "draining",
        .total_vm_slots = 10,
        .active_vms = 1,
        .warm_vms = 0,
        .cpu_usage = 0.3,
        .memory_usage = 0.4,
        .disk_available_bytes = 100_000_000_000,
        .healthy = true,
        .draining = true,
        .uptime_seconds = 3600,
        .last_task_at = null,
        .active_task_ids = &[_]types.TaskId{},
    });

    try std.testing.expectEqual(@as(usize, 3), reg.nodeCount());
    try std.testing.expectEqual(@as(u32, 8), reg.totalCapacity());
}

test "node registry getNode returns null for unknown" {
    const allocator = std.testing.allocator;

    var reg = NodeRegistry.init(allocator);
    defer reg.deinit();

    var unknown_id: types.NodeId = undefined;
    @memset(&unknown_id, 0xFF);

    try std.testing.expect(reg.getNode(unknown_id) == null);
}
