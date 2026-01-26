const std = @import("std");
const common = @import("common");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try common.config.VmAgentConfig.fromEnv(allocator);

    std.log.info("Marathon VM Agent starting...", .{});
    std.log.info("  Vsock port: {d}", .{config.vsock_port});
    std.log.info("  Work dir: {s}", .{config.work_dir});

    if (!common.compat.VsockSupported) {
        std.log.warn("Vsock not supported on this platform (Linux only)", .{});
    }

    std.log.info("Agent ready, waiting for task...", .{});

    while (true) {
        common.compat.sleep(100 * std.time.ns_per_ms);
    }
}

test "vm agent" {
    _ = common.compat;
}
