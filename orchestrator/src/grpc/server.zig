const std = @import("std");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;
const grpc = common.grpc;

const scheduler = @import("../scheduler/scheduler.zig");
const registry = @import("../registry/registry.zig");
const metering = @import("../metering/metering.zig");
const auth = @import("../auth/auth.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    scheduler: *scheduler.Scheduler,
    registry: *registry.NodeRegistry,
    metering: *metering.Metering,
    auth: *auth.Authenticator,
    inner: grpc.Server,

    pub fn init(
        allocator: std.mem.Allocator,
        sched: *scheduler.Scheduler,
        reg: *registry.NodeRegistry,
        meter: *metering.Metering,
        authenticator: *auth.Authenticator,
    ) Server {
        return .{
            .allocator = allocator,
            .scheduler = sched,
            .registry = reg,
            .metering = meter,
            .auth = authenticator,
            .inner = grpc.Server.init(allocator, handleConnection),
        };
    }

    pub fn deinit(self: *Server) void {
        self.inner.stop();
    }

    pub fn listen(self: *Server, address: []const u8, port: u16) !void {
        try self.inner.listen(address, port);
    }

    pub fn run(self: *Server) !void {
        _ = self;

        while (true) {
            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }

    fn handleConnection(conn: *grpc.Connection) void {
        _ = conn;
    }
};

pub const RequestHandler = struct {
    allocator: std.mem.Allocator,
    scheduler: *scheduler.Scheduler,
    registry: *registry.NodeRegistry,
    metering: *metering.Metering,
    auth: *auth.Authenticator,

    pub fn handleSubmitTask(
        self: *RequestHandler,
        conn: *grpc.Connection,
        request: protocol.SubmitTaskRequest,
        client_id: types.ClientId,
    ) !void {
        if (!auth.Authenticator.validateGitHubToken(request.github_token)) {
            try conn.writeMessage(.error_response, 0, ErrorResponse{
                .code = "INVALID_GITHUB_TOKEN",
                .message = "Invalid GitHub token format",
            });
            return;
        }

        var task = try types.Task.init(
            self.allocator,
            client_id,
            request.repo_url,
            request.branch,
            request.prompt,
        );
        task.create_pr = request.create_pr;
        task.pr_title = request.pr_title;
        task.pr_body = request.pr_body;

        const task_id = try self.scheduler.submitTask(task);

        const event = protocol.TaskEvent{
            .task_id = task_id,
            .state = .queued,
            .timestamp = std.time.milliTimestamp(),
            .event_type = .state_change,
            .data = &[_]u8{},
        };

        try conn.writeMessage(.task_event, 0, event);

        self.streamTaskEvents(conn, task_id) catch |err| {
            std.log.err("Error streaming task events: {}", .{err});
        };
    }

    fn streamTaskEvents(self: *RequestHandler, conn: *grpc.Connection, task_id: types.TaskId) !void {
        while (true) {
            const ctx = self.scheduler.getTask(task_id) orelse break;
            const task = ctx.task;

            if (task.state.isTerminal()) {
                const complete_event = protocol.TaskEvent{
                    .task_id = task_id,
                    .state = task.state,
                    .timestamp = std.time.milliTimestamp(),
                    .event_type = .complete,
                    .data = &[_]u8{},
                };
                try conn.writeMessage(.task_event, 0, complete_event);
                break;
            }

            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }

    pub fn handleGetTask(self: *RequestHandler, task_id: types.TaskId) ?types.Task {
        const ctx = self.scheduler.getTask(task_id) orelse return null;
        return ctx.task;
    }

    pub fn handleCancelTask(self: *RequestHandler, task_id: types.TaskId) CancelResponse {
        const success = self.scheduler.cancelTask(task_id);
        return .{
            .success = success,
            .message = if (success) "Task cancelled" else "Failed to cancel task",
        };
    }

    pub fn handleGetUsage(
        self: *RequestHandler,
        client_id: types.ClientId,
        start_time: i64,
        end_time: i64,
    ) !metering.UsageReport {
        return self.metering.getUsageReport(client_id, start_time, end_time);
    }
};

const ErrorResponse = struct {
    code: []const u8,
    message: []const u8,
};

const CancelResponse = struct {
    success: bool,
    message: []const u8,
};

test "request handler" {
    _ = RequestHandler;
}
