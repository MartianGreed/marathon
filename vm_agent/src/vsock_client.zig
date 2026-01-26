const std = @import("std");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;
const vsock = common.vsock;
const claude_wrapper = @import("claude_wrapper.zig");

pub const VsockClient = struct {
    allocator: std.mem.Allocator,
    port: u32,
    listener: ?vsock.Listener,
    connection: ?vsock.Connection,

    pub fn init(allocator: std.mem.Allocator, port: u32) !VsockClient {
        var client = VsockClient{
            .allocator = allocator,
            .port = port,
            .listener = null,
            .connection = null,
        };

        client.listener = try vsock.Listener.bind(allocator, port);

        return client;
    }

    pub fn deinit(self: *VsockClient) void {
        if (self.connection) |*conn| {
            conn.close();
        }
        if (self.listener) |*listener| {
            listener.close();
        }
    }

    pub fn waitForConnection(self: *VsockClient) !void {
        var listener = self.listener orelse return error.NotListening;
        self.connection = try listener.accept();
    }

    pub fn sendReady(self: *VsockClient) !void {
        if (self.connection == null) {
            try self.waitForConnection();
        }

        var conn = self.connection orelse return error.NotConnected;

        const vm_id = try vsock.getCid();
        try conn.send(.vsock_ready, 0, VsockReadyPayload{ .vm_id = vm_id });
    }

    pub fn receiveTask(self: *VsockClient) !claude_wrapper.TaskInfo {
        var conn = self.connection orelse return error.NotConnected;

        const msg = try conn.receive(protocol.VsockStartPayload);

        return .{
            .task_id = msg.payload.task_id,
            .repo_url = msg.payload.repo_url,
            .branch = msg.payload.branch,
            .prompt = msg.payload.prompt,
            .github_token = msg.payload.github_token,
            .anthropic_api_key = msg.payload.anthropic_api_key,
            .create_pr = msg.payload.create_pr,
            .pr_title = msg.payload.pr_title,
            .pr_body = msg.payload.pr_body,
        };
    }

    pub fn sendOutput(self: *VsockClient, output_type: types.OutputType, data: []const u8) !void {
        var conn = self.connection orelse return error.NotConnected;

        const payload = protocol.VsockOutputPayload{
            .output_type = output_type,
            .data = data,
        };

        try conn.send(.vsock_output, 0, payload);
    }

    pub fn sendMetrics(self: *VsockClient, metrics: types.UsageMetrics) !void {
        var conn = self.connection orelse return error.NotConnected;

        const payload = protocol.VsockMetricsPayload{
            .input_tokens = metrics.input_tokens,
            .output_tokens = metrics.output_tokens,
            .cache_read_tokens = metrics.cache_read_tokens,
            .cache_write_tokens = metrics.cache_write_tokens,
            .tool_calls = metrics.tool_calls,
        };

        try conn.send(.vsock_metrics, 0, payload);
    }

    pub fn sendComplete(self: *VsockClient, result: claude_wrapper.RunResult) !void {
        var conn = self.connection orelse return error.NotConnected;

        const payload = protocol.VsockCompletePayload{
            .exit_code = result.exit_code,
            .pr_url = result.pr_url,
            .metrics = .{
                .input_tokens = result.metrics.input_tokens,
                .output_tokens = result.metrics.output_tokens,
                .cache_read_tokens = result.metrics.cache_read_tokens,
                .cache_write_tokens = result.metrics.cache_write_tokens,
                .tool_calls = result.metrics.tool_calls,
            },
        };

        try conn.send(.vsock_complete, 0, payload);
    }

    pub fn sendError(self: *VsockClient, code: []const u8, message: []const u8) !void {
        var conn = self.connection orelse return error.NotConnected;

        const payload = protocol.VsockErrorPayload{
            .code = code,
            .message = message,
        };

        try conn.send(.vsock_error, 0, payload);
    }

    pub fn checkCancel(self: *VsockClient) !bool {
        const conn = self.connection orelse return error.NotConnected;

        var fds = [_]std.posix.pollfd{.{
            .fd = conn.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const ready = try std.posix.poll(&fds, 0);
        if (ready == 0) return false;

        if (fds[0].revents & std.posix.POLL.IN != 0) {
            var header_buf: [@sizeOf(protocol.Header)]u8 = undefined;
            const n = try std.posix.recv(conn.fd, &header_buf, std.posix.MSG.PEEK);
            if (n < @sizeOf(protocol.Header)) return false;

            const header: *const protocol.Header = @ptrCast(@alignCast(&header_buf));
            return header.msg_type == .vsock_cancel;
        }

        return false;
    }
};

const VsockReadyPayload = struct {
    vm_id: u32,
};

test "vsock client" {
    _ = VsockClient;
}
