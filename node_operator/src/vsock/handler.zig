const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;

const log = std.log.scoped(.vsock_handler);

const vsock = if (builtin.os.tag == .linux) common.vsock else struct {
    pub const Connection = struct {
        fd: i32,
        allocator: std.mem.Allocator,

        pub fn connect(allocator: std.mem.Allocator, cid: u32, port: u32) !Connection {
            _ = cid;
            _ = port;
            return .{ .fd = -1, .allocator = allocator };
        }

        pub fn connectUds(allocator: std.mem.Allocator, uds_path: []const u8, port: u32) !Connection {
            _ = uds_path;
            _ = port;
            return .{ .fd = -1, .allocator = allocator };
        }

        pub fn close(self: *Connection) void {
            _ = self;
        }

        pub fn send(self: *Connection, msg_type: protocol.MessageType, request_id: u32, payload: anytype) !void {
            _ = self;
            _ = msg_type;
            _ = request_id;
            _ = payload;
            return error.NotSupported;
        }
    };
};

pub const VsockHandler = struct {
    allocator: std.mem.Allocator,
    uds_path: []const u8,
    port: u32,
    connection: ?vsock.Connection,
    callback: ?*const fn (VsockEvent) void,

    pub fn init(allocator: std.mem.Allocator, uds_path: []const u8, port: u32) VsockHandler {
        return .{
            .allocator = allocator,
            .uds_path = uds_path,
            .port = port,
            .connection = null,
            .callback = null,
        };
    }

    pub fn deinit(self: *VsockHandler) void {
        self.disconnect();
    }

    pub fn connect(self: *VsockHandler) !void {
        self.connection = try vsock.Connection.connectUds(self.allocator, self.uds_path, self.port);
    }

    pub fn disconnect(self: *VsockHandler) void {
        if (self.connection) |*conn| {
            conn.close();
            self.connection = null;
        }
    }

    pub fn setCallback(self: *VsockHandler, callback: *const fn (VsockEvent) void) void {
        self.callback = callback;
    }

    pub fn sendStart(self: *VsockHandler, request: protocol.VsockStartPayload) !void {
        var conn = self.connection orelse return error.NotConnected;
        try conn.send(.vsock_start, 0, request);
    }

    pub fn sendCancel(self: *VsockHandler) !void {
        var conn = self.connection orelse return error.NotConnected;
        try conn.send(.vsock_cancel, 0, .{});
    }

    pub fn receive(self: *VsockHandler) !VsockEvent {
        const conn = self.connection orelse return error.NotConnected;

        var header_buf: [@sizeOf(protocol.Header)]u8 align(@alignOf(protocol.Header)) = undefined;
        var total: usize = 0;
        while (total < header_buf.len) {
            const n = try std.posix.recv(conn.fd, header_buf[total..], 0);
            if (n == 0) return error.ConnectionClosed;
            total += n;
        }

        const header: *const protocol.Header = @ptrCast(@alignCast(&header_buf));

        const payload_buf = try self.allocator.alloc(u8, header.payload_len);
        defer self.allocator.free(payload_buf);

        total = 0;
        while (total < payload_buf.len) {
            const n = try std.posix.recv(conn.fd, payload_buf[total..], 0);
            if (n == 0) return error.ConnectionClosed;
            total += n;
        }

        return switch (header.msg_type) {
            .vsock_ready => .{ .ready = {} },
            .vsock_output => blk: {
                const payload = try decodeOutput(self.allocator, payload_buf);
                break :blk .{ .output = payload };
            },
            .vsock_metrics => blk: {
                const payload = try decodeMetrics(payload_buf);
                break :blk .{ .metrics = payload };
            },
            .vsock_complete => blk: {
                const payload = try decodeComplete(self.allocator, payload_buf);
                break :blk .{ .complete = payload };
            },
            .vsock_error => blk: {
                const payload = try decodeError(self.allocator, payload_buf);
                break :blk .{ .task_error = payload };
            },
            else => error.UnexpectedMessageType,
        };
    }

    pub fn run(self: *VsockHandler) !void {
        while (true) {
            const event = self.receive() catch |err| {
                if (err == error.ConnectionClosed) break;
                return err;
            };

            if (self.callback) |cb| {
                cb(event);
            }

            if (event == .complete or event == .task_error) break;
        }
    }
};

pub fn decodeOutput(allocator: std.mem.Allocator, data: []const u8) !protocol.VsockOutputPayload {
    if (data.len < 5) return error.InvalidPayload;

    const output_type: types.OutputType = @enumFromInt(data[0]);
    const len = std.mem.readInt(u32, data[1..5], .big);

    if (data.len < 5 + len) return error.InvalidPayload;

    return .{
        .output_type = output_type,
        .data = try allocator.dupe(u8, data[5..][0..len]),
    };
}

pub fn decodeMetrics(data: []const u8) !protocol.VsockMetricsPayload {
    if (data.len < 40) return error.InvalidPayload;

    return .{
        .input_tokens = std.mem.readInt(i64, data[0..8], .big),
        .output_tokens = std.mem.readInt(i64, data[8..16], .big),
        .cache_read_tokens = std.mem.readInt(i64, data[16..24], .big),
        .cache_write_tokens = std.mem.readInt(i64, data[24..32], .big),
        .tool_calls = std.mem.readInt(i64, data[32..40], .big),
    };
}

pub fn decodeComplete(allocator: std.mem.Allocator, data: []const u8) !protocol.VsockCompletePayload {
    if (data.len < 44) return error.InvalidPayload;

    const exit_code = std.mem.readInt(i32, data[0..4], .big);
    const pr_url_present = data[4] != 0;

    var offset: usize = 5;
    var pr_url: ?[]const u8 = null;

    if (pr_url_present) {
        const url_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        pr_url = try allocator.dupe(u8, data[offset..][0..url_len]);
        offset += url_len;
    }

    const metrics = try decodeMetrics(data[offset..]);
    offset += 40; // metrics is 5 * i64 = 40 bytes

    const iteration = if (data.len > offset + 4)
        std.mem.readInt(u32, data[offset..][0..4], .big)
    else
        1;
    offset += 4;

    const promise_found = if (data.len > offset)
        data[offset] != 0
    else
        false;

    return .{
        .exit_code = exit_code,
        .pr_url = pr_url,
        .metrics = metrics,
        .iteration = iteration,
        .promise_found = promise_found,
    };
}

pub fn decodeError(allocator: std.mem.Allocator, data: []const u8) !protocol.VsockErrorPayload {
    if (data.len < 8) return error.InvalidPayload;

    const code_len = std.mem.readInt(u32, data[0..4], .big);
    const code = try allocator.dupe(u8, data[4..][0..code_len]);

    const msg_offset = 4 + code_len;
    const msg_len = std.mem.readInt(u32, data[msg_offset..][0..4], .big);
    const message = try allocator.dupe(u8, data[msg_offset + 4 ..][0..msg_len]);

    return .{
        .code = code,
        .message = message,
    };
}

pub const VsockEvent = union(enum) {
    ready: void,
    output: protocol.VsockOutputPayload,
    metrics: protocol.VsockMetricsPayload,
    complete: protocol.VsockCompletePayload,
    task_error: protocol.VsockErrorPayload,
};

pub const TaskRunner = struct {
    allocator: std.mem.Allocator,
    handler: VsockHandler,
    task_id: types.TaskId,
    metrics: types.UsageMetrics,
    output_callback: ?*const fn (types.OutputType, []const u8) void,

    pub fn init(allocator: std.mem.Allocator, uds_path: []const u8, port: u32, task_id: types.TaskId) TaskRunner {
        return .{
            .allocator = allocator,
            .handler = VsockHandler.init(allocator, uds_path, port),
            .task_id = task_id,
            .metrics = .{},
            .output_callback = null,
        };
    }

    pub fn deinit(self: *TaskRunner) void {
        self.handler.deinit();
    }

    pub fn run(self: *TaskRunner, request: protocol.VsockStartPayload) !TaskResult {
        const max_retries: u32 = 15;
        const retry_delay_ns: u64 = 2 * std.time.ns_per_s;
        var attempt: u32 = 0;
        while (true) {
            self.handler.connect() catch |err| {
                attempt += 1;
                if (attempt >= max_retries) {
                    log.err("vsock connect failed after {d} attempts: task_id={s} err={}", .{
                        max_retries,
                        &types.formatId(self.task_id),
                        err,
                    });
                    return err;
                }
                log.warn("vsock connect attempt {d}/{d} failed, retrying: task_id={s} err={}", .{
                    attempt,
                    max_retries,
                    &types.formatId(self.task_id),
                    err,
                });
                common.compat.sleep(retry_delay_ns);
                continue;
            };
            break;
        }
        defer self.handler.disconnect();

        _ = self.handler.receive() catch |err| {
            return .{ .success = false, .error_message = @errorName(err), .metrics = self.metrics, .pr_url = null };
        };

        try self.handler.sendStart(request);

        while (true) {
            const event = self.handler.receive() catch |err| {
                return .{ .success = false, .error_message = @errorName(err), .metrics = self.metrics, .pr_url = null };
            };

            switch (event) {
                .ready => {},
                .output => |output| {
                    if (self.output_callback) |cb| {
                        cb(output.output_type, output.data);
                    }
                },
                .metrics => |m| {
                    self.metrics.input_tokens = m.input_tokens;
                    self.metrics.output_tokens = m.output_tokens;
                    self.metrics.cache_read_tokens = m.cache_read_tokens;
                    self.metrics.cache_write_tokens = m.cache_write_tokens;
                    self.metrics.tool_calls = m.tool_calls;
                },
                .complete => |c| {
                    self.metrics = .{
                        .input_tokens = c.metrics.input_tokens,
                        .output_tokens = c.metrics.output_tokens,
                        .cache_read_tokens = c.metrics.cache_read_tokens,
                        .cache_write_tokens = c.metrics.cache_write_tokens,
                        .tool_calls = c.metrics.tool_calls,
                        .compute_time_ms = 0,
                    };
                    return .{
                        .success = c.exit_code == 0,
                        .error_message = if (c.exit_code != 0) "Non-zero exit code" else null,
                        .metrics = self.metrics,
                        .pr_url = c.pr_url,
                    };
                },
                .task_error => |e| {
                    return .{
                        .success = false,
                        .error_message = e.message,
                        .metrics = self.metrics,
                        .pr_url = null,
                    };
                },
            }
        }
    }

    pub fn cancel(self: *TaskRunner) !void {
        try self.handler.sendCancel();
    }
};

pub const TaskResult = struct {
    success: bool,
    error_message: ?[]const u8,
    metrics: types.UsageMetrics,
    pr_url: ?[]const u8,
};

test "vsock handler init" {
    const allocator = std.testing.allocator;
    var handler = VsockHandler.init(allocator, "/tmp/test-vsock.sock", 9999);
    defer handler.deinit();
}

test "decodeMetrics valid payload" {
    var data: [40]u8 = undefined;
    std.mem.writeInt(i64, data[0..8], 100, .big); // input_tokens
    std.mem.writeInt(i64, data[8..16], 200, .big); // output_tokens
    std.mem.writeInt(i64, data[16..24], 50, .big); // cache_read_tokens
    std.mem.writeInt(i64, data[24..32], 25, .big); // cache_write_tokens
    std.mem.writeInt(i64, data[32..40], 10, .big); // tool_calls

    const result = try decodeMetrics(&data);

    try std.testing.expectEqual(@as(i64, 100), result.input_tokens);
    try std.testing.expectEqual(@as(i64, 200), result.output_tokens);
    try std.testing.expectEqual(@as(i64, 50), result.cache_read_tokens);
    try std.testing.expectEqual(@as(i64, 25), result.cache_write_tokens);
    try std.testing.expectEqual(@as(i64, 10), result.tool_calls);
}

test "decodeMetrics invalid payload - too short" {
    const data = [_]u8{0} ** 39;
    try std.testing.expectError(error.InvalidPayload, decodeMetrics(&data));
}

test "decodeOutput valid payload" {
    const allocator = std.testing.allocator;

    const content = "Hello, world!";
    var data: [5 + content.len]u8 = undefined;
    data[0] = @intFromEnum(types.OutputType.stdout);
    std.mem.writeInt(u32, data[1..5], @intCast(content.len), .big);
    @memcpy(data[5..], content);

    const result = try decodeOutput(allocator, &data);
    defer allocator.free(result.data);

    try std.testing.expectEqual(types.OutputType.stdout, result.output_type);
    try std.testing.expectEqualStrings(content, result.data);
}

test "decodeOutput invalid payload - too short" {
    const allocator = std.testing.allocator;
    const data = [_]u8{0} ** 4;
    try std.testing.expectError(error.InvalidPayload, decodeOutput(allocator, &data));
}

test "decodeError valid payload" {
    const allocator = std.testing.allocator;

    const code = "ERR001";
    const message = "Something went wrong";
    const total_len = 4 + code.len + 4 + message.len;
    var data: [total_len]u8 = undefined;

    std.mem.writeInt(u32, data[0..4], @intCast(code.len), .big);
    @memcpy(data[4..][0..code.len], code);
    const msg_offset = 4 + code.len;
    std.mem.writeInt(u32, data[msg_offset..][0..4], @intCast(message.len), .big);
    @memcpy(data[msg_offset + 4 ..][0..message.len], message);

    const result = try decodeError(allocator, &data);
    defer {
        allocator.free(result.code);
        allocator.free(result.message);
    }

    try std.testing.expectEqualStrings(code, result.code);
    try std.testing.expectEqualStrings(message, result.message);
}

test "decodeComplete valid payload without pr_url" {
    const allocator = std.testing.allocator;

    var data: [5 + 40 + 5]u8 = undefined; // +5 for iteration(4) + promise_found(1)
    std.mem.writeInt(i32, data[0..4], 0, .big); // exit_code
    data[4] = 0; // pr_url not present

    // metrics at offset 5
    std.mem.writeInt(i64, data[5..13], 100, .big);
    std.mem.writeInt(i64, data[13..21], 200, .big);
    std.mem.writeInt(i64, data[21..29], 50, .big);
    std.mem.writeInt(i64, data[29..37], 25, .big);
    std.mem.writeInt(i64, data[37..45], 10, .big);

    // iteration and promise_found
    std.mem.writeInt(u32, data[45..49], 3, .big);
    data[49] = 1; // promise_found = true

    const result = try decodeComplete(allocator, &data);

    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(result.pr_url == null);
    try std.testing.expectEqual(@as(i64, 100), result.metrics.input_tokens);
    try std.testing.expectEqual(@as(u32, 3), result.iteration);
    try std.testing.expect(result.promise_found);
}

test "decodeComplete valid payload with pr_url" {
    const allocator = std.testing.allocator;

    const pr_url = "https://github.com/test/repo/pull/123";
    const url_len = pr_url.len;
    const total_len = 5 + 4 + url_len + 40 + 5; // exit_code(4) + present(1) + url_len(4) + url + metrics(40) + iteration(4) + promise_found(1)

    var data: [total_len]u8 = undefined;
    std.mem.writeInt(i32, data[0..4], 1, .big); // exit_code = 1
    data[4] = 1; // pr_url present

    // url length and data at offset 5
    std.mem.writeInt(u32, data[5..9], @intCast(url_len), .big);
    @memcpy(data[9..][0..url_len], pr_url);

    // metrics after url
    const metrics_offset = 9 + url_len;
    std.mem.writeInt(i64, data[metrics_offset..][0..8], 500, .big);
    std.mem.writeInt(i64, data[metrics_offset + 8 ..][0..8], 1000, .big);
    std.mem.writeInt(i64, data[metrics_offset + 16 ..][0..8], 100, .big);
    std.mem.writeInt(i64, data[metrics_offset + 24 ..][0..8], 50, .big);
    std.mem.writeInt(i64, data[metrics_offset + 32 ..][0..8], 25, .big);

    // iteration and promise_found after metrics
    const iter_offset = metrics_offset + 40;
    std.mem.writeInt(u32, data[iter_offset..][0..4], 5, .big);
    data[iter_offset + 4] = 0; // promise_found = false

    const result = try decodeComplete(allocator, &data);
    defer if (result.pr_url) |url| allocator.free(url);

    try std.testing.expectEqual(@as(i32, 1), result.exit_code);
    try std.testing.expect(result.pr_url != null);
    try std.testing.expectEqualStrings(pr_url, result.pr_url.?);
    try std.testing.expectEqual(@as(i64, 500), result.metrics.input_tokens);
    try std.testing.expectEqual(@as(u32, 5), result.iteration);
    try std.testing.expect(!result.promise_found);
}

test "vsock stub connection close" {
    const allocator = std.testing.allocator;

    // Test the stub Connection.close directly
    var conn = vsock.Connection{ .fd = -1, .allocator = allocator };
    conn.close();

    // Test VsockHandler with connection set and disconnect
    var handler = VsockHandler.init(allocator, "/tmp/test-vsock.sock", 9999);
    handler.connection = vsock.Connection{ .fd = -1, .allocator = allocator };
    handler.disconnect();

    try std.testing.expect(handler.connection == null);
}
