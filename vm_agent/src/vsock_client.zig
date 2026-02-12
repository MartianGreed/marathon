const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;
const claude_wrapper = @import("claude_wrapper.zig");

pub const VsockClient = if (builtin.os.tag == .linux) LinuxVsockClient else StubVsockClient;

const LinuxVsockClient = struct {
    const vsock = common.vsock;

    allocator: std.mem.Allocator,
    port: u32,
    listener: ?vsock.Listener,
    connection: ?vsock.Connection,

    pub fn init(allocator: std.mem.Allocator, port: u32) !LinuxVsockClient {
        var client = LinuxVsockClient{
            .allocator = allocator,
            .port = port,
            .listener = null,
            .connection = null,
        };

        client.listener = try vsock.Listener.bind(allocator, port);

        return client;
    }

    pub fn deinit(self: *LinuxVsockClient) void {
        if (self.connection) |*conn| {
            conn.close();
        }
        if (self.listener) |*listener| {
            listener.close();
        }
    }

    pub fn waitForConnection(self: *LinuxVsockClient) !void {
        var listener = self.listener orelse return error.NotListening;
        self.connection = try listener.accept();
    }

    pub fn resetConnection(self: *LinuxVsockClient) void {
        if (self.connection) |*conn| {
            conn.close();
            self.connection = null;
        }
    }

    pub fn sendReady(self: *LinuxVsockClient) !void {
        if (self.connection == null) {
            try self.waitForConnection();
        }

        var conn = self.connection orelse return error.NotConnected;

        const vm_id = try vsock.getCid();
        try conn.send(.vsock_ready, 0, VsockReadyPayload{ .vm_id = vm_id });
    }

    pub fn receiveTask(self: *LinuxVsockClient) !claude_wrapper.TaskInfo {
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
            .max_iterations = msg.payload.max_iterations,
            .completion_promise = msg.payload.completion_promise,
            .env_vars = msg.payload.env_vars,
        };
    }

    pub fn sendOutput(self: *LinuxVsockClient, output_type: types.OutputType, data: []const u8) !void {
        var conn = self.connection orelse return error.NotConnected;

        const payload = protocol.VsockOutputPayload{
            .output_type = output_type,
            .data = data,
        };

        try conn.send(.vsock_output, 0, payload);
    }

    pub fn sendMetrics(self: *LinuxVsockClient, metrics: types.UsageMetrics) !void {
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

    pub fn sendComplete(self: *LinuxVsockClient, result: claude_wrapper.RunResult, iteration: u32) !void {
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
            .iteration = iteration,
            .promise_found = result.output_contains_promise,
        };

        try conn.send(.vsock_complete, 0, payload);
    }

    pub fn sendProgress(self: *LinuxVsockClient, iteration: u32, max_iterations: u32, status: []const u8) !void {
        var conn = self.connection orelse return error.NotConnected;

        const payload = protocol.VsockProgressPayload{
            .iteration = iteration,
            .max_iterations = max_iterations,
            .status = status,
        };

        try conn.send(.vsock_progress, 0, payload);
    }

    pub fn sendError(self: *LinuxVsockClient, code: []const u8, message: []const u8) !void {
        var conn = self.connection orelse return error.NotConnected;

        const payload = protocol.VsockErrorPayload{
            .code = code,
            .message = message,
        };

        try conn.send(.vsock_error, 0, payload);
    }

    pub fn checkCancel(self: *LinuxVsockClient) !bool {
        const conn = self.connection orelse return error.NotConnected;

        var fds = [_]std.posix.pollfd{.{
            .fd = conn.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const ready = try std.posix.poll(&fds, 0);
        if (ready == 0) return false;

        if (fds[0].revents & std.posix.POLL.IN != 0) {
            var header_buf: [@sizeOf(protocol.Header)]u8 align(@alignOf(protocol.Header)) = undefined;
            const n = try std.posix.recv(conn.fd, &header_buf, std.posix.MSG.PEEK);
            if (n < @sizeOf(protocol.Header)) return false;

            const header: *const protocol.Header = @ptrCast(@alignCast(&header_buf));
            return header.msg_type == .vsock_cancel;
        }

        return false;
    }
};

const StubVsockClient = struct {
    allocator: std.mem.Allocator,
    port: u32,

    pub fn init(allocator: std.mem.Allocator, port: u32) !StubVsockClient {
        return .{
            .allocator = allocator,
            .port = port,
        };
    }

    pub fn deinit(self: *StubVsockClient) void {
        _ = self;
    }

    pub fn sendReady(self: *StubVsockClient) !void {
        _ = self;
        return error.VsockNotSupported;
    }

    pub fn receiveTask(self: *StubVsockClient) !claude_wrapper.TaskInfo {
        _ = self;
        return error.VsockNotSupported;
    }

    pub fn sendOutput(self: *StubVsockClient, output_type: types.OutputType, data: []const u8) !void {
        _ = self;
        _ = output_type;
        _ = data;
        return error.VsockNotSupported;
    }

    pub fn sendMetrics(self: *StubVsockClient, metrics: types.UsageMetrics) !void {
        _ = self;
        _ = metrics;
        return error.VsockNotSupported;
    }

    pub fn sendComplete(self: *StubVsockClient, result: claude_wrapper.RunResult, iteration: u32) !void {
        _ = self;
        _ = result;
        _ = iteration;
        return error.VsockNotSupported;
    }

    pub fn sendProgress(self: *StubVsockClient, iteration: u32, max_iterations: u32, status: []const u8) !void {
        _ = self;
        _ = iteration;
        _ = max_iterations;
        _ = status;
        return error.VsockNotSupported;
    }

    pub fn sendError(self: *StubVsockClient, code: []const u8, message: []const u8) !void {
        _ = self;
        _ = code;
        _ = message;
        return error.VsockNotSupported;
    }

    pub fn checkCancel(self: *StubVsockClient) !bool {
        _ = self;
        return error.VsockNotSupported;
    }
};

const VsockReadyPayload = struct {
    vm_id: u32,
};

test "vsock client type selection" {
    _ = VsockClient;
}

test "StubVsockClient init succeeds" {
    const allocator = std.testing.allocator;
    var client = try StubVsockClient.init(allocator, 5000);
    defer client.deinit();

    try std.testing.expectEqual(@as(u32, 5000), client.port);
}

test "StubVsockClient sendReady returns VsockNotSupported" {
    const allocator = std.testing.allocator;
    var client = try StubVsockClient.init(allocator, 5000);
    defer client.deinit();

    const result = client.sendReady();
    try std.testing.expectError(error.VsockNotSupported, result);
}

test "StubVsockClient receiveTask returns VsockNotSupported" {
    const allocator = std.testing.allocator;
    var client = try StubVsockClient.init(allocator, 5000);
    defer client.deinit();

    const result = client.receiveTask();
    try std.testing.expectError(error.VsockNotSupported, result);
}

test "StubVsockClient sendComplete returns VsockNotSupported" {
    const allocator = std.testing.allocator;
    var client = try StubVsockClient.init(allocator, 5000);
    defer client.deinit();

    const result = client.sendComplete(.{
        .exit_code = 0,
        .pr_url = null,
        .metrics = .{},
        .output_contains_promise = false,
        .stdout = "",
        .stderr = "",
    }, 1);
    try std.testing.expectError(error.VsockNotSupported, result);
}

test "StubVsockClient checkCancel returns VsockNotSupported" {
    const allocator = std.testing.allocator;
    var client = try StubVsockClient.init(allocator, 5000);
    defer client.deinit();

    const result = client.checkCancel();
    try std.testing.expectError(error.VsockNotSupported, result);
}

test "StubVsockClient sendOutput returns VsockNotSupported" {
    const allocator = std.testing.allocator;
    var client = try StubVsockClient.init(allocator, 5000);
    defer client.deinit();

    const result = client.sendOutput(.stdout, "test output");
    try std.testing.expectError(error.VsockNotSupported, result);
}

test "StubVsockClient sendMetrics returns VsockNotSupported" {
    const allocator = std.testing.allocator;
    var client = try StubVsockClient.init(allocator, 5000);
    defer client.deinit();

    const result = client.sendMetrics(.{
        .input_tokens = 100,
        .output_tokens = 50,
    });
    try std.testing.expectError(error.VsockNotSupported, result);
}

test "StubVsockClient sendProgress returns VsockNotSupported" {
    const allocator = std.testing.allocator;
    var client = try StubVsockClient.init(allocator, 5000);
    defer client.deinit();

    const result = client.sendProgress(1, 5, "running");
    try std.testing.expectError(error.VsockNotSupported, result);
}

test "StubVsockClient sendError returns VsockNotSupported" {
    const allocator = std.testing.allocator;
    var client = try StubVsockClient.init(allocator, 5000);
    defer client.deinit();

    const result = client.sendError("ERR001", "Something went wrong");
    try std.testing.expectError(error.VsockNotSupported, result);
}
