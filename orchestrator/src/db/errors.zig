const std = @import("std");

pub const DbError = error{
    ConnectionFailed,
    AuthenticationFailed,
    ConnectionClosed,
    ProtocolError,
    InvalidMessage,
    QueryFailed,
    ConstraintViolation,
    SerializationFailure,
    DeadlockDetected,
    Timeout,
    PoolExhausted,
    PoolClosed,
    InvalidState,
    InvalidParameter,
    InvalidConfig,
    MigrationFailed,
    SchemaVersionMismatch,
    OutOfMemory,
    Unexpected,
};

pub const ErrorInfo = struct {
    severity: []const u8,
    code: []const u8,
    message: []const u8,
    detail: ?[]const u8,
    hint: ?[]const u8,
    position: ?u32,
    allocator: ?std.mem.Allocator,

    pub fn deinit(self: *ErrorInfo) void {
        if (self.allocator) |alloc| {
            alloc.free(self.severity);
            alloc.free(self.code);
            alloc.free(self.message);
            if (self.detail) |d| alloc.free(d);
            if (self.hint) |h| alloc.free(h);
        }
    }

    pub fn format(
        self: ErrorInfo,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{s}: {s} ({s})", .{ self.severity, self.message, self.code });
        if (self.detail) |d| {
            try writer.print("\nDetail: {s}", .{d});
        }
        if (self.hint) |h| {
            try writer.print("\nHint: {s}", .{h});
        }
    }
};

pub fn mapSqlState(code: []const u8) DbError {
    if (code.len < 2) return DbError.Unexpected;

    const class = code[0..2];
    return switch (class[0]) {
        '0' => switch (class[1]) {
            '8' => DbError.ConnectionFailed,
            else => DbError.QueryFailed,
        },
        '2' => switch (class[1]) {
            '3' => DbError.ConstraintViolation,
            '8' => DbError.AuthenticationFailed,
            else => DbError.QueryFailed,
        },
        '4' => switch (class[1]) {
            '0' => if (std.mem.eql(u8, code, "40001"))
                DbError.SerializationFailure
            else if (std.mem.eql(u8, code, "40P01"))
                DbError.DeadlockDetected
            else
                DbError.QueryFailed,
            '2' => DbError.InvalidParameter,
            else => DbError.QueryFailed,
        },
        '5' => switch (class[1]) {
            '3' => DbError.OutOfMemory,
            '7' => DbError.Timeout,
            else => DbError.QueryFailed,
        },
        else => DbError.QueryFailed,
    };
}

test "map sql state codes" {
    try std.testing.expectEqual(DbError.ConnectionFailed, mapSqlState("08000"));
    try std.testing.expectEqual(DbError.ConstraintViolation, mapSqlState("23505"));
    try std.testing.expectEqual(DbError.SerializationFailure, mapSqlState("40001"));
    try std.testing.expectEqual(DbError.DeadlockDetected, mapSqlState("40P01"));
    try std.testing.expectEqual(DbError.AuthenticationFailed, mapSqlState("28000"));
}
