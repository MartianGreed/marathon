const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;
const OutputBuffer = @import("../task/output_buffer.zig").OutputBuffer;

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
        var conn = self.connection orelse return error.NotConnected;

        // Peek at the header to determine message type without consuming data
        var header_buf: [@sizeOf(protocol.Header)]u8 align(@alignOf(protocol.Header)) = undefined;
        var total: usize = 0;
        while (total < header_buf.len) {
            const n = try std.posix.recv(conn.fd, header_buf[total..], std.posix.MSG.PEEK);
            if (n == 0) return error.ConnectionClosed;
            total += n;
        }

        const header: *const protocol.Header = @ptrCast(@alignCast(&header_buf));

        return switch (header.msg_type) {
            .vsock_ready => {
                _ = try conn.receive(VsockReadyPayload);
                return .{ .ready = {} };
            },
            .vsock_output => {
                const msg = try conn.receive(protocol.VsockOutputPayload);
                return .{ .output = msg.payload };
            },
            .vsock_metrics => {
                const msg = try conn.receive(protocol.VsockMetricsPayload);
                return .{ .metrics = msg.payload };
            },
            .vsock_complete => {
                const msg = try conn.receive(protocol.VsockCompletePayload);
                return .{ .complete = msg.payload };
            },
            .vsock_error => {
                const msg = try conn.receive(protocol.VsockErrorPayload);
                return .{ .task_error = msg.payload };
            },
            .vsock_progress => {
                const msg = try conn.receive(protocol.VsockProgressPayload);
                const progress_text = try std.fmt.allocPrint(self.allocator, "Progress: {d}/{d} - {s}", .{
                    msg.payload.iteration, msg.payload.max_iterations, msg.payload.status,
                });
                return .{ .output = .{ .output_type = .stdout, .data = progress_text } };
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

// Removed manual decode functions - now using proper protocol decoding from common/src/protocol.zig

const VsockReadyPayload = struct {
    vm_id: u32,
};

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
    output_buffer: ?*OutputBuffer = null,

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
                    log.info("vm output [{s}]: {s}", .{ @tagName(output.output_type), output.data });
                    if (self.output_callback) |cb| {
                        cb(output.output_type, output.data);
                    }
                    if (self.output_buffer) |buf| {
                        buf.push(self.task_id, output.output_type, output.data);
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

// Manual decode tests removed - now using proper protocol decoding from common/src/protocol.zig
// The protocol.zig file has comprehensive tests for message encoding/decoding

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
