const std = @import("std");
const common = @import("common");

const vm = @import("vm/firecracker.zig");
const snapshot = @import("snapshot/manager.zig");
const heartbeat = @import("heartbeat/heartbeat.zig");
const vsock = @import("vsock/handler.zig");
const task_executor = @import("task/executor.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try common.config.NodeOperatorConfig.fromEnv(allocator);

    std.log.info("Marathon Node Operator starting...", .{});
    std.log.info("  Listen: {s}:{d}", .{ config.listen_address, config.listen_port });
    std.log.info("  Orchestrator: {s}:{d}", .{ config.orchestrator_address, config.orchestrator_port });
    std.log.info("  VM slots: {d}, Warm pool target: {d}", .{ config.total_vm_slots, config.warm_pool_target });

    var snapshot_mgr = try snapshot.SnapshotManager.init(allocator, config.snapshot_path);
    defer snapshot_mgr.deinit();

    var vm_pool = vm.VmPool.init(allocator, &snapshot_mgr, config);
    defer vm_pool.deinit();

    vm_pool.warmPool(config.warm_pool_target) catch |err| {
        std.log.err("Failed to warm VM pool: {}", .{err});
    };
    std.log.info("Warm pool initialized: {d} VMs ready", .{vm_pool.warmCount()});

    var executor = task_executor.TaskExecutor.init(allocator, &vm_pool);
    defer executor.deinit();

    var heartbeat_client = heartbeat.HeartbeatClient.init(
        allocator,
        config.orchestrator_address,
        config.orchestrator_port,
        &vm_pool,
        &executor,
        config.auth_key,
        config.tls_enabled,
        config.tls_ca_path,
    );
    defer heartbeat_client.deinit();

    const heartbeat_thread = try std.Thread.spawn(.{}, runHeartbeat, .{&heartbeat_client});

    std.log.info("Node Operator ready", .{});

    while (true) {
        common.compat.sleep(100 * std.time.ns_per_ms);
    }

    heartbeat_client.stop();
    heartbeat_thread.join();
}

fn runHeartbeat(client: *heartbeat.HeartbeatClient) void {
    client.run() catch |err| {
        std.log.err("Heartbeat thread error: {}", .{err});
    };
}

test {
    _ = vm;
    _ = snapshot;
    _ = heartbeat;
    _ = vsock;
    _ = task_executor;
}
