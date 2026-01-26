const std = @import("std");

pub const Oid = u32;

pub const TypeOid = struct {
    pub const bool_oid: Oid = 16;
    pub const bytea: Oid = 17;
    pub const int8: Oid = 20;
    pub const int2: Oid = 21;
    pub const int4: Oid = 23;
    pub const text: Oid = 25;
    pub const float4: Oid = 700;
    pub const float8: Oid = 701;
    pub const varchar: Oid = 1043;
    pub const timestamp: Oid = 1114;
    pub const timestamptz: Oid = 1184;
};

pub const Value = union(enum) {
    null,
    bool: bool,
    i16: i16,
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    text: []const u8,
    bytea: []const u8,

    pub fn isNull(self: Value) bool {
        return self == .null;
    }

    pub fn asI64(self: Value) ?i64 {
        return switch (self) {
            .i16 => |v| @intCast(v),
            .i32 => |v| @intCast(v),
            .i64 => |v| v,
            else => null,
        };
    }

    pub fn asI32(self: Value) ?i32 {
        return switch (self) {
            .i16 => |v| @intCast(v),
            .i32 => |v| v,
            .i64 => |v| if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) @intCast(v) else null,
            else => null,
        };
    }

    pub fn asU32(self: Value) ?u32 {
        return switch (self) {
            .i16 => |v| if (v >= 0) @intCast(v) else null,
            .i32 => |v| if (v >= 0) @intCast(v) else null,
            .i64 => |v| if (v >= 0 and v <= std.math.maxInt(u32)) @intCast(v) else null,
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .bool => |v| v,
            else => null,
        };
    }

    pub fn asF64(self: Value) ?f64 {
        return switch (self) {
            .f32 => |v| @floatCast(v),
            .f64 => |v| v,
            else => null,
        };
    }

    pub fn asText(self: Value) ?[]const u8 {
        return switch (self) {
            .text => |v| v,
            else => null,
        };
    }

    pub fn asBytea(self: Value) ?[]const u8 {
        return switch (self) {
            .bytea => |v| v,
            else => null,
        };
    }
};

pub const FieldDesc = struct {
    name: []const u8,
    table_oid: Oid,
    column_attr: i16,
    type_oid: Oid,
    type_len: i16,
    type_mod: i32,
    format: i16,
};

pub const Row = struct {
    values: []Value,
    fields: []const FieldDesc,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Row) void {
        for (self.values) |val| {
            switch (val) {
                .text => |t| self.allocator.free(t),
                .bytea => |b| self.allocator.free(b),
                else => {},
            }
        }
        self.allocator.free(self.values);
    }

    pub fn get(self: Row, index: usize) ?Value {
        if (index >= self.values.len) return null;
        return self.values[index];
    }

    pub fn getByName(self: Row, name: []const u8) ?Value {
        for (self.fields, 0..) |field, i| {
            if (std.mem.eql(u8, field.name, name)) {
                return self.values[i];
            }
        }
        return null;
    }

    pub fn getI64(self: Row, index: usize) ?i64 {
        return (self.get(index) orelse return null).asI64();
    }

    pub fn getI32(self: Row, index: usize) ?i32 {
        return (self.get(index) orelse return null).asI32();
    }

    pub fn getU32(self: Row, index: usize) ?u32 {
        return (self.get(index) orelse return null).asU32();
    }

    pub fn getBool(self: Row, index: usize) ?bool {
        return (self.get(index) orelse return null).asBool();
    }

    pub fn getF64(self: Row, index: usize) ?f64 {
        return (self.get(index) orelse return null).asF64();
    }

    pub fn getText(self: Row, index: usize) ?[]const u8 {
        return (self.get(index) orelse return null).asText();
    }

    pub fn getBytea(self: Row, index: usize) ?[]const u8 {
        return (self.get(index) orelse return null).asBytea();
    }

    pub fn getOptionalI64(self: Row, index: usize) ??i64 {
        const val = self.get(index) orelse return null;
        if (val.isNull()) return @as(?i64, null);
        return val.asI64();
    }

    pub fn getOptionalText(self: Row, index: usize) ??[]const u8 {
        const val = self.get(index) orelse return null;
        if (val.isNull()) return @as(?[]const u8, null);
        return val.asText();
    }

    pub fn getOptionalBytea(self: Row, index: usize) ??[]const u8 {
        const val = self.get(index) orelse return null;
        if (val.isNull()) return @as(?[]const u8, null);
        return val.asBytea();
    }
};

pub const QueryResult = struct {
    rows: []Row,
    fields: []FieldDesc,
    rows_affected: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *QueryResult) void {
        for (self.fields) |field| {
            self.allocator.free(field.name);
        }
        self.allocator.free(self.fields);
        for (self.rows) |*row| {
            row.deinit();
        }
        self.allocator.free(self.rows);
    }

    pub fn rowCount(self: QueryResult) usize {
        return self.rows.len;
    }

    pub fn isEmpty(self: QueryResult) bool {
        return self.rows.len == 0;
    }

    pub fn first(self: QueryResult) ?Row {
        if (self.rows.len == 0) return null;
        return self.rows[0];
    }
};

pub const Param = union(enum) {
    null,
    bool: bool,
    i16: i16,
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    text: []const u8,
    bytea: []const u8,

    pub fn typeOid(self: Param) Oid {
        return switch (self) {
            .null => 0,
            .bool => TypeOid.bool_oid,
            .i16 => TypeOid.int2,
            .i32 => TypeOid.int4,
            .i64 => TypeOid.int8,
            .f32 => TypeOid.float4,
            .f64 => TypeOid.float8,
            .text => TypeOid.text,
            .bytea => TypeOid.bytea,
        };
    }

    pub fn encode(self: Param, writer: anytype) !void {
        switch (self) {
            .null => {},
            .bool => |v| try writer.writeByte(if (v) 1 else 0),
            .i16 => |v| try writer.writeInt(i16, v, .big),
            .i32 => |v| try writer.writeInt(i32, v, .big),
            .i64 => |v| try writer.writeInt(i64, v, .big),
            .f32 => |v| {
                const bits: u32 = @bitCast(v);
                try writer.writeInt(u32, bits, .big);
            },
            .f64 => |v| {
                const bits: u64 = @bitCast(v);
                try writer.writeInt(u64, bits, .big);
            },
            .text => |v| try writer.writeAll(v),
            .bytea => |v| try writer.writeAll(v),
        }
    }

    pub fn encodedLen(self: Param) ?i32 {
        return switch (self) {
            .null => null,
            .bool => 1,
            .i16 => 2,
            .i32 => 4,
            .i64 => 8,
            .f32 => 4,
            .f64 => 8,
            .text => |v| @intCast(v.len),
            .bytea => |v| @intCast(v.len),
        };
    }
};

pub fn text(s: []const u8) Param {
    return .{ .text = s };
}

pub fn bytea(b: []const u8) Param {
    return .{ .bytea = b };
}

pub fn int(v: anytype) Param {
    const T = @TypeOf(v);
    return switch (@typeInfo(T)) {
        .int => |info| switch (info.bits) {
            0...16 => .{ .i16 = @intCast(v) },
            17...32 => .{ .i32 = @intCast(v) },
            else => .{ .i64 = @intCast(v) },
        },
        .comptime_int => .{ .i64 = v },
        else => @compileError("Expected integer type"),
    };
}

pub fn boolean(v: bool) Param {
    return .{ .bool = v };
}

pub fn float(v: anytype) Param {
    const T = @TypeOf(v);
    return switch (@typeInfo(T)) {
        .float => |info| switch (info.bits) {
            0...32 => .{ .f32 = @floatCast(v) },
            else => .{ .f64 = @floatCast(v) },
        },
        .comptime_float => .{ .f64 = v },
        else => @compileError("Expected float type"),
    };
}

pub fn optional(comptime T: type, v: ?T) Param {
    if (v) |val| {
        return switch (@typeInfo(T)) {
            .int => int(val),
            .float => float(val),
            .bool => boolean(val),
            .pointer => |ptr| if (ptr.size == .slice) blk: {
                if (ptr.child == u8) break :blk text(val);
                @compileError("Unsupported slice type");
            } else @compileError("Unsupported pointer type"),
            else => @compileError("Unsupported optional type"),
        };
    }
    return .null;
}

test "param encoding" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const p = Param{ .i32 = 42 };
    try p.encode(fbs.writer());
    try std.testing.expectEqual(@as(usize, 4), fbs.pos);
    try std.testing.expectEqual(@as(i32, 42), std.mem.readInt(i32, buf[0..4], .big));
}

test "value conversions" {
    const v = Value{ .i32 = 100 };
    try std.testing.expectEqual(@as(?i64, 100), v.asI64());
    try std.testing.expectEqual(@as(?i32, 100), v.asI32());
    try std.testing.expectEqual(@as(?u32, 100), v.asU32());

    const null_val: Value = .null;
    try std.testing.expect(null_val.isNull());
}
