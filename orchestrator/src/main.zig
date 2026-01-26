const std = @import("std");
const common = @import("common");

const scheduler = @import("scheduler/scheduler.zig");
const registry = @import("registry/registry.zig");
const metering = @import("metering/metering.zig");
const auth = @import("auth/auth.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try common.config.OrchestratorConfig.fromEnv(allocator);

    std.log.info("Marathon Orchestrator starting...", .{});
    std.log.info("  Listen: {s}:{d}", .{ config.listen_address, config.listen_port });

    var node_registry = registry.NodeRegistry.init(allocator);
    defer node_registry.deinit();

    var task_scheduler = scheduler.Scheduler.init(allocator, &node_registry);
    defer task_scheduler.deinit();

    var meter = metering.Metering.init(allocator);
    defer meter.deinit();

    var authenticator = auth.Authenticator.init(allocator, config.anthropic_api_key);
    defer authenticator.deinit();

    std.log.info("Orchestrator ready", .{});

    while (true) {
        common.compat.sleep(100 * std.time.ns_per_ms);
    }
}

test {
    _ = scheduler;
    _ = registry;
    _ = metering;
    _ = auth;
}
