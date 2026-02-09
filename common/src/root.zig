const builtin = @import("builtin");

pub const protocol = @import("protocol.zig");
pub const types = @import("types.zig");
pub const config = @import("config.zig");
pub const compat = @import("compat.zig");
pub const grpc = @import("grpc.zig");

pub const vsock = if (builtin.os.tag == .linux) @import("vsock.zig") else struct {};

test {
    _ = protocol;
    _ = types;
    _ = config;
    _ = compat;
    _ = grpc;
    if (builtin.os.tag == .linux) {
        _ = @import("vsock.zig");
        _ = @import("integration_test.zig");
    }
}
