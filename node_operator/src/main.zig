const std = @import("std");
const common = @import("common");

const vm = @import("vm/firecracker.zig");
const snapshot = @import("snapshot/manager.zig");

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

    std.log.info("Node Operator ready", .{});

    while (true) {
        common.compat.sleep(100 * std.time.ns_per_ms);
    }
}

test {
    _ = vm;
    _ = snapshot;
}
