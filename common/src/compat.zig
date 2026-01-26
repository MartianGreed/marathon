const std = @import("std");
const builtin = @import("builtin");

pub fn sleep(nanoseconds: u64) void {
    std.Thread.sleep(nanoseconds);
}

pub fn fileStat(path: []const u8) !std.fs.File.Stat {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.stat();
}

pub fn fileExists(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

pub const VsockSupported = builtin.os.tag == .linux;

pub const VSOCK_CID_ANY: u32 = 0xFFFFFFFF;
pub const VSOCK_CID_HYPERVISOR: u32 = 0;
pub const VSOCK_CID_LOCAL: u32 = 1;
pub const VSOCK_CID_HOST: u32 = 2;
pub const DEFAULT_VSOCK_PORT: u32 = 9999;

pub const AF_VSOCK: u16 = if (builtin.os.tag == .linux) 40 else 0;

test "sleep" {
    sleep(1);
}
