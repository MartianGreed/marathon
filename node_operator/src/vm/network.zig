const std = @import("std");

const log = std.log.scoped(.vm_network);

/// Create a TAP device for a Firecracker VM
/// Returns the TAP device name (e.g. "tap0")
pub fn createTap(allocator: std.mem.Allocator, vm_index: u32) ![]const u8 {
    const tap_name = try std.fmt.allocPrint(allocator, "tap{d}", .{vm_index});
    errdefer allocator.free(tap_name);

    const ip = try std.fmt.allocPrint(allocator, "172.16.{d}.1/30", .{vm_index});
    defer allocator.free(ip);

    // Create TAP device
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "ip", "tuntap", "add", tap_name, "mode", "tap" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term.Exited != 0) {
            // May already exist, try to continue
            log.warn("tap create returned non-zero (may already exist): {s}", .{result.stderr});
        }
    }

    // Assign IP to TAP
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "ip", "addr", "add", ip, "dev", tap_name },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term.Exited != 0) {
            log.warn("ip addr add returned non-zero: {s}", .{result.stderr});
        }
    }

    // Bring up TAP
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "ip", "link", "set", tap_name, "up" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term.Exited != 0) {
            log.warn("ip link set up returned non-zero: {s}", .{result.stderr});
        }
    }

    log.info("TAP device created: {s} ip={s}", .{ tap_name, ip });
    return tap_name;
}

/// Delete a TAP device
pub fn destroyTap(allocator: std.mem.Allocator, tap_name: []const u8) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "ip", "link", "del", tap_name },
    }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
}

/// Get the guest IP for a given VM index
pub fn guestIp(vm_index: u32, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "172.16.{d}.2", .{vm_index});
}

/// Get the gateway IP for a given VM index (host-side TAP IP)
pub fn gatewayIp(vm_index: u32, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "172.16.{d}.1", .{vm_index});
}

/// Generate a MAC address for a VM based on its index
pub fn macAddress(vm_index: u32, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "AA:FC:00:00:{X:0>2}:{X:0>2}", .{
        @as(u8, @truncate(vm_index >> 8)),
        @as(u8, @truncate(vm_index)),
    });
}

test "mac address generation" {
    var buf: [32]u8 = undefined;
    const mac = try macAddress(0, &buf);
    try std.testing.expectEqualStrings("AA:FC:00:00:00:00", mac);

    const mac2 = try macAddress(42, &buf);
    try std.testing.expectEqualStrings("AA:FC:00:00:00:2A", mac2);
}
