const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");

const DbError = errors.DbError;

pub const MsgType = enum(u8) {
    authentication = 'R',
    backend_key_data = 'K',
    bind_complete = '2',
    close_complete = '3',
    command_complete = 'C',
    data_row = 'D',
    empty_query_response = 'I',
    error_response = 'E',
    notice_response = 'N',
    parameter_description = 't',
    parameter_status = 'S',
    parse_complete = '1',
    portal_suspended = 's',
    ready_for_query = 'Z',
    row_description = 'T',
    no_data = 'n',
    _,
};

pub const AuthType = enum(i32) {
    ok = 0,
    kerberos_v5 = 2,
    cleartext_password = 3,
    md5_password = 5,
    scm_credential = 6,
    gss = 7,
    gss_continue = 8,
    sspi = 9,
    sasl = 10,
    sasl_continue = 11,
    sasl_final = 12,
    _,
};

pub const TransactionStatus = enum(u8) {
    idle = 'I',
    in_transaction = 'T',
    failed = 'E',
    _,
};

pub const Message = struct {
    msg_type: MsgType,
    payload: []const u8,

    pub fn read(stream: std.net.Stream, buf: []u8) !Message {
        var header: [5]u8 = undefined;
        var total: usize = 0;
        while (total < 5) {
            const n = stream.read(header[total..]) catch return DbError.ConnectionClosed;
            if (n == 0) return DbError.ConnectionClosed;
            total += n;
        }

        const type_byte = header[0];
        const len = std.mem.readInt(i32, header[1..5], .big);

        if (len < 4) return DbError.ProtocolError;
        const payload_len: usize = @intCast(len - 4);

        if (payload_len > buf.len) return DbError.ProtocolError;

        total = 0;
        while (total < payload_len) {
            const n = stream.read(buf[total..payload_len]) catch return DbError.ConnectionClosed;
            if (n == 0) return DbError.ConnectionClosed;
            total += n;
        }

        return .{
            .msg_type = @enumFromInt(type_byte),
            .payload = buf[0..payload_len],
        };
    }
};

pub const MessageWriter = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8),

    pub fn init(allocator: std.mem.Allocator) MessageWriter {
        return .{ .allocator = allocator, .buf = .empty };
    }

    pub fn deinit(self: *MessageWriter) void {
        self.buf.deinit(self.allocator);
    }

    pub fn reset(self: *MessageWriter) void {
        self.buf.clearRetainingCapacity();
    }

    pub fn startMessage(self: *MessageWriter, msg_type: ?u8) !void {
        if (msg_type) |t| {
            try self.buf.append(self.allocator, t);
        }
        try self.buf.appendNTimes(self.allocator, 0, 4);
    }

    pub fn finishMessage(self: *MessageWriter) void {
        const has_type = self.buf.items.len > 4 and self.buf.items[0] != 0;
        const len_offset: usize = if (has_type) 1 else 0;
        const len: i32 = @intCast(self.buf.items.len - len_offset);
        std.mem.writeInt(i32, self.buf.items[len_offset..][0..4], len, .big);
    }

    pub fn writeByte(self: *MessageWriter, b: u8) !void {
        try self.buf.append(self.allocator, b);
    }

    pub fn writeBytes(self: *MessageWriter, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    pub fn writeI16(self: *MessageWriter, v: i16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(i16, &bytes, v, .big);
        try self.buf.appendSlice(self.allocator, &bytes);
    }

    pub fn writeI32(self: *MessageWriter, v: i32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, v, .big);
        try self.buf.appendSlice(self.allocator, &bytes);
    }

    pub fn writeString(self: *MessageWriter, s: []const u8) !void {
        try self.buf.appendSlice(self.allocator, s);
        try self.buf.append(self.allocator, 0);
    }

    pub fn data(self: *MessageWriter) []const u8 {
        return self.buf.items;
    }
};

pub fn writeStartupMessage(writer: *MessageWriter, user: []const u8, database: []const u8) !void {
    writer.reset();
    try writer.startMessage(null);
    try writer.writeI32(196608);
    try writer.writeString("user");
    try writer.writeString(user);
    try writer.writeString("database");
    try writer.writeString(database);
    try writer.writeString("client_encoding");
    try writer.writeString("UTF8");
    try writer.writeByte(0);
    writer.finishMessage();
}

pub fn writePasswordMessage(writer: *MessageWriter, password: []const u8) !void {
    writer.reset();
    try writer.startMessage('p');
    try writer.writeString(password);
    writer.finishMessage();
}

fn bytesToHex(bytes: []const u8, out: []u8) void {
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

pub fn writeMd5PasswordMessage(writer: *MessageWriter, user: []const u8, password: []const u8, salt: [4]u8) !void {
    var md5 = std.crypto.hash.Md5.init(.{});

    md5.update(password);
    md5.update(user);
    var inner: [16]u8 = undefined;
    md5.final(&inner);

    var inner_hex: [32]u8 = undefined;
    bytesToHex(&inner, &inner_hex);

    md5 = std.crypto.hash.Md5.init(.{});
    md5.update(&inner_hex);
    md5.update(&salt);
    var outer: [16]u8 = undefined;
    md5.final(&outer);

    var result: [35]u8 = undefined;
    result[0..3].* = "md5".*;
    bytesToHex(&outer, result[3..]);

    writer.reset();
    try writer.startMessage('p');
    try writer.writeString(&result);
    writer.finishMessage();
}

pub fn writeSaslInitialResponse(writer: *MessageWriter, mechanism: []const u8, data: []const u8) !void {
    writer.reset();
    try writer.startMessage('p');
    try writer.writeString(mechanism);
    try writer.writeI32(@intCast(data.len));
    try writer.writeBytes(data);
    writer.finishMessage();
}

pub fn writeSaslResponse(writer: *MessageWriter, data: []const u8) !void {
    writer.reset();
    try writer.startMessage('p');
    try writer.writeBytes(data);
    writer.finishMessage();
}

pub fn writeQuery(writer: *MessageWriter, query: []const u8) !void {
    writer.reset();
    try writer.startMessage('Q');
    try writer.writeString(query);
    writer.finishMessage();
}

pub fn writeParse(writer: *MessageWriter, name: []const u8, query: []const u8, param_types: []const types.Oid) !void {
    writer.reset();
    try writer.startMessage('P');
    try writer.writeString(name);
    try writer.writeString(query);
    try writer.writeI16(@intCast(param_types.len));
    for (param_types) |oid| {
        try writer.writeI32(@intCast(oid));
    }
    writer.finishMessage();
}

pub fn writeBind(writer: *MessageWriter, portal: []const u8, stmt: []const u8, params: []const types.Param) !void {
    writer.reset();
    try writer.startMessage('B');
    try writer.writeString(portal);
    try writer.writeString(stmt);

    try writer.writeI16(1);
    try writer.writeI16(1);

    try writer.writeI16(@intCast(params.len));
    for (params) |param| {
        if (param.encodedLen()) |len| {
            try writer.writeI32(len);
            var param_buf: [1024]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&param_buf);
            try param.encode(fbs.writer());
            try writer.writeBytes(fbs.getWritten());
        } else {
            try writer.writeI32(-1);
        }
    }

    try writer.writeI16(1);
    try writer.writeI16(1);
    writer.finishMessage();
}

pub fn writeDescribe(writer: *MessageWriter, kind: u8, name: []const u8) !void {
    writer.reset();
    try writer.startMessage('D');
    try writer.writeByte(kind);
    try writer.writeString(name);
    writer.finishMessage();
}

pub fn writeExecute(writer: *MessageWriter, portal: []const u8, max_rows: i32) !void {
    writer.reset();
    try writer.startMessage('E');
    try writer.writeString(portal);
    try writer.writeI32(max_rows);
    writer.finishMessage();
}

pub fn writeSync(writer: *MessageWriter) !void {
    writer.reset();
    try writer.startMessage('S');
    writer.finishMessage();
}

pub fn writeClose(writer: *MessageWriter, kind: u8, name: []const u8) !void {
    writer.reset();
    try writer.startMessage('C');
    try writer.writeByte(kind);
    try writer.writeString(name);
    writer.finishMessage();
}

pub fn writeTerminate(writer: *MessageWriter) !void {
    writer.reset();
    try writer.startMessage('X');
    writer.finishMessage();
}

pub fn parseErrorResponse(payload: []const u8, allocator: std.mem.Allocator) !errors.ErrorInfo {
    var info = errors.ErrorInfo{
        .severity = "",
        .code = "",
        .message = "",
        .detail = null,
        .hint = null,
        .position = null,
        .allocator = allocator,
    };
    errdefer info.deinit();

    var pos: usize = 0;
    while (pos < payload.len) {
        const field_type = payload[pos];
        if (field_type == 0) break;
        pos += 1;

        const end = std.mem.indexOfScalarPos(u8, payload, pos, 0) orelse break;
        const value = payload[pos..end];
        pos = end + 1;

        switch (field_type) {
            'S' => info.severity = try allocator.dupe(u8, value),
            'C' => info.code = try allocator.dupe(u8, value),
            'M' => info.message = try allocator.dupe(u8, value),
            'D' => info.detail = try allocator.dupe(u8, value),
            'H' => info.hint = try allocator.dupe(u8, value),
            'P' => info.position = std.fmt.parseInt(u32, value, 10) catch null,
            else => {},
        }
    }

    return info;
}

pub fn parseRowDescription(payload: []const u8, allocator: std.mem.Allocator) ![]types.FieldDesc {
    if (payload.len < 2) return DbError.ProtocolError;

    const field_count = std.mem.readInt(i16, payload[0..2], .big);
    if (field_count < 0) return DbError.ProtocolError;

    var fields = try allocator.alloc(types.FieldDesc, @intCast(field_count));
    errdefer {
        for (fields) |f| {
            if (f.name.len > 0) allocator.free(f.name);
        }
        allocator.free(fields);
    }

    var pos: usize = 2;
    for (0..@intCast(field_count)) |i| {
        const name_end = std.mem.indexOfScalarPos(u8, payload, pos, 0) orelse return DbError.ProtocolError;
        const name = payload[pos..name_end];
        pos = name_end + 1;

        if (pos + 18 > payload.len) return DbError.ProtocolError;

        fields[i] = .{
            .name = try allocator.dupe(u8, name),
            .table_oid = std.mem.readInt(u32, payload[pos..][0..4], .big),
            .column_attr = std.mem.readInt(i16, payload[pos + 4 ..][0..2], .big),
            .type_oid = std.mem.readInt(u32, payload[pos + 6 ..][0..4], .big),
            .type_len = std.mem.readInt(i16, payload[pos + 10 ..][0..2], .big),
            .type_mod = std.mem.readInt(i32, payload[pos + 12 ..][0..4], .big),
            .format = std.mem.readInt(i16, payload[pos + 16 ..][0..2], .big),
        };
        pos += 18;
    }

    return fields;
}

pub fn parseDataRow(payload: []const u8, fields: []const types.FieldDesc, allocator: std.mem.Allocator) !types.Row {
    if (payload.len < 2) return DbError.ProtocolError;

    const col_count = std.mem.readInt(i16, payload[0..2], .big);
    if (col_count < 0 or @as(usize, @intCast(col_count)) != fields.len) return DbError.ProtocolError;

    var values = try allocator.alloc(types.Value, @intCast(col_count));
    errdefer {
        for (values) |v| {
            switch (v) {
                .text => |t| allocator.free(t),
                .bytea => |b| allocator.free(b),
                else => {},
            }
        }
        allocator.free(values);
    }

    var pos: usize = 2;
    for (0..@intCast(col_count)) |i| {
        if (pos + 4 > payload.len) return DbError.ProtocolError;
        const len = std.mem.readInt(i32, payload[pos..][0..4], .big);
        pos += 4;

        if (len == -1) {
            values[i] = .null;
            continue;
        }

        const value_len: usize = @intCast(len);
        if (pos + value_len > payload.len) return DbError.ProtocolError;

        const data = payload[pos .. pos + value_len];
        pos += value_len;

        values[i] = try decodeValue(data, fields[i].type_oid, fields[i].format, allocator);
    }

    return .{
        .values = values,
        .fields = fields,
        .allocator = allocator,
    };
}

fn decodeValue(data: []const u8, type_oid: types.Oid, format: i16, allocator: std.mem.Allocator) !types.Value {
    // format == 0 means text format, format == 1 means binary format
    if (format == 0) {
        return decodeTextValue(data, type_oid, allocator);
    }
    // Binary format
    return switch (type_oid) {
        types.TypeOid.bool_oid => .{ .bool = data.len > 0 and data[0] != 0 },
        types.TypeOid.int2 => .{ .i16 = if (data.len >= 2) std.mem.readInt(i16, data[0..2], .big) else return DbError.ProtocolError },
        types.TypeOid.int4 => .{ .i32 = if (data.len >= 4) std.mem.readInt(i32, data[0..4], .big) else return DbError.ProtocolError },
        types.TypeOid.int8 => .{ .i64 = if (data.len >= 8) std.mem.readInt(i64, data[0..8], .big) else return DbError.ProtocolError },
        types.TypeOid.float4 => {
            if (data.len < 4) return DbError.ProtocolError;
            const bits = std.mem.readInt(u32, data[0..4], .big);
            return .{ .f32 = @bitCast(bits) };
        },
        types.TypeOid.float8 => {
            if (data.len < 8) return DbError.ProtocolError;
            const bits = std.mem.readInt(u64, data[0..8], .big);
            return .{ .f64 = @bitCast(bits) };
        },
        types.TypeOid.bytea => .{ .bytea = try allocator.dupe(u8, data) },
        else => .{ .text = try allocator.dupe(u8, data) },
    };
}

fn decodeTextValue(data: []const u8, type_oid: types.Oid, allocator: std.mem.Allocator) !types.Value {
    return switch (type_oid) {
        types.TypeOid.bool_oid => .{ .bool = data.len > 0 and data[0] == 't' },
        types.TypeOid.int2 => .{ .i16 = std.fmt.parseInt(i16, data, 10) catch return DbError.ProtocolError },
        types.TypeOid.int4 => .{ .i32 = std.fmt.parseInt(i32, data, 10) catch return DbError.ProtocolError },
        types.TypeOid.int8 => .{ .i64 = std.fmt.parseInt(i64, data, 10) catch return DbError.ProtocolError },
        types.TypeOid.float4 => .{ .f32 = std.fmt.parseFloat(f32, data) catch return DbError.ProtocolError },
        types.TypeOid.float8 => .{ .f64 = std.fmt.parseFloat(f64, data) catch return DbError.ProtocolError },
        else => .{ .text = try allocator.dupe(u8, data) },
    };
}

pub fn parseCommandComplete(payload: []const u8) u64 {
    const tag_end = std.mem.indexOfScalar(u8, payload, 0) orelse payload.len;
    const tag = payload[0..tag_end];

    if (std.mem.lastIndexOfScalar(u8, tag, ' ')) |space| {
        return std.fmt.parseInt(u64, tag[space + 1 ..], 10) catch 0;
    }
    return 0;
}

test "startup message format" {
    const allocator = std.testing.allocator;
    var writer = MessageWriter.init(allocator);
    defer writer.deinit();

    try writeStartupMessage(&writer, "testuser", "testdb");
    const msg = writer.data();

    const len = std.mem.readInt(i32, msg[0..4], .big);
    try std.testing.expect(len > 4);

    const version = std.mem.readInt(i32, msg[4..8], .big);
    try std.testing.expectEqual(@as(i32, 196608), version);
}

test "md5 password message" {
    const allocator = std.testing.allocator;
    var writer = MessageWriter.init(allocator);
    defer writer.deinit();

    try writeMd5PasswordMessage(&writer, "user", "password", [4]u8{ 0x01, 0x02, 0x03, 0x04 });
    const msg = writer.data();

    try std.testing.expectEqual(@as(u8, 'p'), msg[0]);
}

test "command complete parsing" {
    try std.testing.expectEqual(@as(u64, 5), parseCommandComplete("INSERT 0 5\x00"));
    try std.testing.expectEqual(@as(u64, 10), parseCommandComplete("UPDATE 10\x00"));
    try std.testing.expectEqual(@as(u64, 3), parseCommandComplete("DELETE 3\x00"));
    try std.testing.expectEqual(@as(u64, 0), parseCommandComplete("SELECT\x00"));
}
