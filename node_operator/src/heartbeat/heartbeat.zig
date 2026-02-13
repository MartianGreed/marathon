const std = @import("std");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;
const grpc = common.grpc;
const vm = @import("../vm/firecracker.zig");
const task_executor = @import("../task/executor.zig");

pub const HeartbeatClient = struct {
    allocator: std.mem.Allocator,
    orchestrator_address: []const u8,
    orchestrator_port: u16,
    vm_pool: *vm.VmPool,
    executor: *task_executor.TaskExecutor,
    node_id: types.NodeId,
    interval_ms: u64,
    running: std.atomic.Value(bool),
    client: grpc.Client,
    auth_key: ?[]const u8,
    tls_enabled: bool,
    tls_ca_path: ?[]const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        orchestrator_address: []const u8,
        orchestrator_port: u16,
        vm_pool: *vm.VmPool,
        executor: *task_executor.TaskExecutor,
        auth_key: ?[]const u8,
        tls_enabled: bool,
        tls_ca_path: ?[]const u8,
    ) HeartbeatClient {
        var node_id: types.NodeId = undefined;
        std.crypto.random.bytes(&node_id);

        return .{
            .allocator = allocator,
            .orchestrator_address = orchestrator_address,
            .orchestrator_port = orchestrator_port,
            .vm_pool = vm_pool,
            .executor = executor,
            .node_id = node_id,
            .interval_ms = 5000,
            .running = std.atomic.Value(bool).init(false),
            .client = grpc.Client.init(allocator),
            .auth_key = auth_key,
            .tls_enabled = tls_enabled,
            .tls_ca_path = tls_ca_path,
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
                switch (err) {
                    error.AuthFailed => {
                        std.log.err("Authentication failed - check MARATHON_NODE_AUTH_KEY matches orchestrator", .{});
                    },
                    error.UnexpectedResponse => {
                        std.log.warn("Unexpected response from orchestrator", .{});
                    },
                    error.InvalidMagic => {
                        std.log.err("Protocol mismatch - check TLS settings match orchestrator", .{});
                        self.safeReconnect();
                    },
                    else => {
                        std.log.warn("Heartbeat failed: {}, reconnecting...", .{err});
                        self.safeReconnect();
                    },
                }
            };

            // Use faster heartbeat (1s) when there are active tasks for real-time output streaming.
            // Fall back to normal interval (5s) when idle.
            const has_active_tasks = self.vm_pool.activeCount() > 0;
            const sleep_ms = if (has_active_tasks) @min(self.interval_ms, 1000) else self.interval_ms;
            common.compat.sleep(sleep_ms * std.time.ns_per_ms);
        }
    }

    pub fn stop(self: *HeartbeatClient) void {
        self.running.store(false, .release);
    }

    fn sendHeartbeat(self: *HeartbeatClient) !void {
        if (self.client.stream == null) {
            try self.client.connect(self.orchestrator_address, self.orchestrator_port, self.tls_enabled, self.tls_ca_path);
        }

        const status = self.collectStatus();
        const timestamp = std.time.milliTimestamp();

        const auth_token: [32]u8 = if (self.auth_key) |key| blk: {
            var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(key);
            hmac.update(&self.node_id);
            hmac.update(std.mem.asBytes(&timestamp));
            var out: [32]u8 = undefined;
            hmac.final(&out);
            break :blk out;
        } else [_]u8{0} ** 32;

        const completed_tasks = self.executor.drainResults();
        defer self.allocator.free(completed_tasks);

        const pending_output = self.executor.drainOutput();
        defer self.allocator.free(pending_output);

        const payload = protocol.HeartbeatPayload{
            .node_id = self.node_id,
            .timestamp = timestamp,
            .auth_token = auth_token,
            .hostname = status.hostname,
            .total_vm_slots = status.total_vm_slots,
            .active_vms = status.active_vms,
            .warm_vms = status.warm_vms,
            .cpu_usage = status.cpu_usage,
            .memory_usage = status.memory_usage,
            .disk_available_bytes = status.disk_available_bytes,
            .healthy = status.healthy,
            .draining = status.draining,
            .completed_tasks = completed_tasks,
            .pending_output = pending_output,
        };

        var raw = try self.client.callWithHeader(.heartbeat_request, payload);
        defer raw.deinit();

        if (raw.header.msg_type == .error_response) {
            const err_resp = raw.decodeAs(protocol.ErrorResponse) catch {
                std.log.err("heartbeat rejected with unparseable error", .{});
                return error.AuthFailed;
            };
            std.log.err("heartbeat rejected: code={s} message={s}", .{ err_resp.code, err_resp.message });
            return error.AuthFailed;
        }

        if (raw.header.msg_type != .heartbeat_response) {
            std.log.warn("unexpected response type: {s}", .{@tagName(raw.header.msg_type)});
            return error.UnexpectedResponse;
        }

        const response = try raw.decodeAs(protocol.HeartbeatResponse);

        for (response.commands) |cmd| {
            self.processCommand(cmd) catch |err| {
                std.log.err("command processing failed: {}", .{err});
            };
        }
    }

    fn processCommand(self: *HeartbeatClient, cmd: protocol.NodeCommand) !void {
        switch (cmd.command_type) {
            .execute_task => {
                const req = cmd.execute_request orelse return error.MissingExecuteRequest;
                std.log.info("received task: task_id={s}", .{&types.formatId(req.task_id)});
                try self.executor.executeTask(req);
            },
            .cancel_task => {
                std.log.info("cancel_task command received (not yet implemented)", .{});
            },
            .drain => {
                std.log.info("drain command received (not yet implemented)", .{});
            },
            .warm_pool => {
                const target = cmd.warm_pool_target orelse self.vm_pool.config.warm_pool_target;
                std.log.info("warm_pool command received, target={d}", .{target});
                self.vm_pool.warmPool(target) catch |err| {
                    std.log.err("Failed to warm pool: {}", .{err});
                };
            },
        }
    }

    fn safeReconnect(self: *HeartbeatClient) void {
        // Close connection safely, ignoring any errors
        self.client.close();
        common.compat.sleep(1000 * std.time.ns_per_ms);
        self.client.connect(self.orchestrator_address, self.orchestrator_port, self.tls_enabled, self.tls_ca_path) catch |err| {
            std.log.err("Reconnect failed: {}", .{err});
        };
    }

    fn collectStatus(self: *HeartbeatClient) types.NodeStatus {
        const sys_info = getSystemInfo();

        return .{
            .node_id = self.node_id,
            .hostname = getHostname(),
            .total_vm_slots = self.vm_pool.config.total_vm_slots,
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

fn getHostname() []const u8 {
    const S = struct {
        var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        var len: usize = 0;
        var initialized: bool = false;
    };

    if (!S.initialized) {
        const hostname = std.posix.gethostname(&S.buf) catch return "unknown";
        S.len = hostname.len;
        S.initialized = true;
    }

    return S.buf[0..S.len];
}

test "heartbeat client init" {
    const allocator = std.testing.allocator;

    var snapshot_mgr = try @import("../snapshot/manager.zig").SnapshotManager.init(allocator, "/tmp/marathon-heartbeat-test-init");
    defer snapshot_mgr.deinit();

    var pool = vm.VmPool.init(allocator, &snapshot_mgr, .{});
    defer pool.deinit();

    var executor = task_executor.TaskExecutor.init(allocator, &pool);
    defer executor.deinit();

    var client = HeartbeatClient.init(allocator, "localhost", 8080, &pool, &executor, null, false, null);
    defer client.deinit();

    try std.testing.expectEqual(@as(u64, 5000), client.interval_ms);
}

test "stop flag transitions correctly" {
    const allocator = std.testing.allocator;

    var snapshot_mgr = try @import("../snapshot/manager.zig").SnapshotManager.init(allocator, "/tmp/marathon-heartbeat-test-stop");
    defer snapshot_mgr.deinit();

    var pool = vm.VmPool.init(allocator, &snapshot_mgr, .{});
    defer pool.deinit();

    var executor = task_executor.TaskExecutor.init(allocator, &pool);
    defer executor.deinit();

    var client = HeartbeatClient.init(allocator, "localhost", 8080, &pool, &executor, null, false, null);
    defer client.deinit();

    try std.testing.expect(!client.running.load(.acquire));

    client.running.store(true, .release);
    try std.testing.expect(client.running.load(.acquire));

    client.stop();
    try std.testing.expect(!client.running.load(.acquire));
}

test "getHostname returns non-empty string" {
    const hostname = getHostname();
    try std.testing.expect(hostname.len > 0);
}

test "getSystemInfo returns valid defaults" {
    const info = getSystemInfo();

    try std.testing.expectEqual(@as(f64, 0.0), info.cpu_usage);
    try std.testing.expectEqual(@as(f64, 0.0), info.memory_usage);
    try std.testing.expectEqual(@as(i64, 0), info.disk_available);
    try std.testing.expectEqual(@as(i64, 0), info.uptime);
}
