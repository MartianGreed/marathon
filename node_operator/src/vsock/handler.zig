const std = @import("std");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;
const vsock = common.vsock;

pub const VsockHandler = struct {
    allocator: std.mem.Allocator,
    cid: u32,
    port: u32,
    connection: ?vsock.Connection,
    callback: ?*const fn (VsockEvent) void,

    pub fn init(allocator: std.mem.Allocator, cid: u32, port: u32) VsockHandler {
        return .{
            .allocator = allocator,
            .cid = cid,
            .port = port,
            .connection = null,
            .callback = null,
        };
    }

    pub fn deinit(self: *VsockHandler) void {
        self.disconnect();
    }

    pub fn connect(self: *VsockHandler) !void {
        self.connection = try vsock.Connection.connect(self.allocator, self.cid, self.port);
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

        var header_buf: [@sizeOf(protocol.Header)]u8 = undefined;
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

fn decodeOutput(allocator: std.mem.Allocator, data: []const u8) !protocol.VsockOutputPayload {
    if (data.len < 5) return error.InvalidPayload;

    const output_type: types.OutputType = @enumFromInt(data[0]);
    const len = std.mem.readInt(u32, data[1..5], .big);

    if (data.len < 5 + len) return error.InvalidPayload;

    return .{
        .output_type = output_type,
        .data = try allocator.dupe(u8, data[5..][0..len]),
    };
}

fn decodeMetrics(data: []const u8) !protocol.VsockMetricsPayload {
    if (data.len < 40) return error.InvalidPayload;

    return .{
        .input_tokens = std.mem.readInt(i64, data[0..8], .big),
        .output_tokens = std.mem.readInt(i64, data[8..16], .big),
        .cache_read_tokens = std.mem.readInt(i64, data[16..24], .big),
        .cache_write_tokens = std.mem.readInt(i64, data[24..32], .big),
        .tool_calls = std.mem.readInt(i64, data[32..40], .big),
    };
}

fn decodeComplete(allocator: std.mem.Allocator, data: []const u8) !protocol.VsockCompletePayload {
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

    return .{
        .exit_code = exit_code,
        .pr_url = pr_url,
        .metrics = metrics,
    };
}

fn decodeError(allocator: std.mem.Allocator, data: []const u8) !protocol.VsockErrorPayload {
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

    pub fn init(allocator: std.mem.Allocator, cid: u32, port: u32, task_id: types.TaskId) TaskRunner {
        return .{
            .allocator = allocator,
            .handler = VsockHandler.init(allocator, cid, port),
            .task_id = task_id,
            .metrics = .{},
            .output_callback = null,
        };
    }

    pub fn deinit(self: *TaskRunner) void {
        self.handler.deinit();
    }

    pub fn run(self: *TaskRunner, request: protocol.VsockStartPayload) !TaskResult {
        try self.handler.connect();
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
    var handler = VsockHandler.init(allocator, 3, 9999);
    defer handler.deinit();
}
