const std = @import("std");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;
const grpc = common.grpc;
const vm = @import("../vm/firecracker.zig");

pub const HeartbeatClient = struct {
    allocator: std.mem.Allocator,
    orchestrator_address: []const u8,
    orchestrator_port: u16,
    vm_pool: *vm.VmPool,
    node_id: types.NodeId,
    interval_ms: u64,
    running: std.atomic.Value(bool),
    client: grpc.Client,

    pub fn init(
        allocator: std.mem.Allocator,
        orchestrator_address: []const u8,
        orchestrator_port: u16,
        vm_pool: *vm.VmPool,
    ) HeartbeatClient {
        var node_id: types.NodeId = undefined;
        std.crypto.random.bytes(&node_id);

        return .{
            .allocator = allocator,
            .orchestrator_address = orchestrator_address,
            .orchestrator_port = orchestrator_port,
            .vm_pool = vm_pool,
            .node_id = node_id,
            .interval_ms = 5000,
            .running = std.atomic.Value(bool).init(false),
            .client = grpc.Client.init(allocator),
        };
    }

    pub fn deinit(self: *HeartbeatClient) void {
        self.stop();
        self.client.close();
    }

    pub fn run(self: *HeartbeatClient) !void {
        self.running.store(true, .release);

        while (self.running.load(.acquire)) {
            self.sendHeartbeat() catch |err| {
                std.log.warn("Heartbeat failed: {}, reconnecting...", .{err});
                self.reconnect() catch |reconn_err| {
                    std.log.err("Reconnect failed: {}", .{reconn_err});
                };
            };

            std.time.sleep(self.interval_ms * std.time.ns_per_ms);
        }
    }

    pub fn stop(self: *HeartbeatClient) void {
        self.running.store(false, .release);
    }

    fn sendHeartbeat(self: *HeartbeatClient) !void {
        if (self.client.stream == null) {
            try self.client.connect(self.orchestrator_address, self.orchestrator_port);
        }

        const status = self.collectStatus();
        const payload = protocol.HeartbeatPayload{
            .node_id = self.node_id,
            .timestamp = std.time.milliTimestamp(),
            .total_vm_slots = status.total_vm_slots,
            .active_vms = status.active_vms,
            .warm_vms = status.warm_vms,
            .cpu_usage = status.cpu_usage,
            .memory_usage = status.memory_usage,
            .disk_available_bytes = status.disk_available_bytes,
            .healthy = status.healthy,
            .draining = status.draining,
        };

        _ = try self.client.call(.heartbeat_request, payload, HeartbeatResponse);
    }

    fn reconnect(self: *HeartbeatClient) !void {
        self.client.close();
        std.time.sleep(1000 * std.time.ns_per_ms);
        try self.client.connect(self.orchestrator_address, self.orchestrator_port);
    }

    fn collectStatus(self: *HeartbeatClient) types.NodeStatus {
        const sys_info = getSystemInfo();

        return .{
            .node_id = self.node_id,
            .hostname = getHostname() catch "unknown",
            .total_vm_slots = 10,
            .active_vms = @intCast(self.vm_pool.activeCount()),
            .warm_vms = @intCast(self.vm_pool.warmCount()),
            .cpu_usage = sys_info.cpu_usage,
            .memory_usage = sys_info.memory_usage,
            .disk_available_bytes = sys_info.disk_available,
            .healthy = true,
            .draining = false,
            .uptime_seconds = sys_info.uptime,
            .last_task_at = null,
            .active_task_ids = &[_]types.TaskId{},
        };
    }
};

const HeartbeatResponse = struct {
    timestamp: i64,
};

const SystemInfo = struct {
    cpu_usage: f64,
    memory_usage: f64,
    disk_available: i64,
    uptime: i64,
};

fn getSystemInfo() SystemInfo {
    return .{
        .cpu_usage = 0.0,
        .memory_usage = 0.0,
        .disk_available = 0,
        .uptime = 0,
    };
}

fn getHostname() ![]const u8 {
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = try std.posix.gethostname(&buf);
    return hostname;
}

test "heartbeat client init" {
    const allocator = std.testing.allocator;

    var snapshot_mgr = try @import("../snapshot/manager.zig").SnapshotManager.init(allocator, "/tmp");
    defer snapshot_mgr.deinit();

    var pool = vm.VmPool.init(allocator, &snapshot_mgr, .{});
    defer pool.deinit();

    var client = HeartbeatClient.init(allocator, "localhost", 8080, &pool);
    defer client.deinit();

    try std.testing.expectEqual(@as(u64, 5000), client.interval_ms);
}
