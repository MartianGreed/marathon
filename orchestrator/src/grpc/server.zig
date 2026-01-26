const std = @import("std");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;
const grpc = common.grpc;

const log = std.log.scoped(.grpc);

const scheduler = @import("../scheduler/scheduler.zig");
const registry = @import("../registry/registry.zig");
const metering = @import("../metering/metering.zig");
const auth = @import("../auth/auth.zig");
const db = @import("../db/root.zig");

fn generateClientId(address: std.net.Address) types.ClientId {
    var hasher = std.crypto.hash.Blake3.init(.{});

    switch (address.any.family) {
        std.posix.AF.INET => {
            const bytes = std.mem.asBytes(&address.in.sa.addr);
            hasher.update(bytes);
        },
        std.posix.AF.INET6 => {
            hasher.update(&address.in6.sa.addr);
        },
        else => {
            hasher.update("unknown");
        },
    }

    var full_hash: [32]u8 = undefined;
    hasher.final(&full_hash);

    var client_id: types.ClientId = undefined;
    @memcpy(&client_id, full_hash[0..16]);
    return client_id;
}

pub const Server = struct {
    allocator: std.mem.Allocator,
    scheduler: *scheduler.Scheduler,
    registry: *registry.NodeRegistry,
    metering: *metering.Metering,
    auth: *auth.Authenticator,
    listener: ?std.net.Server,
    running: std.atomic.Value(bool),
    task_repo: ?*db.TaskRepository,
    node_repo: ?*db.NodeRepository,
    usage_repo: ?*db.UsageRepository,

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
            .listener = null,
            .running = std.atomic.Value(bool).init(false),
            .task_repo = null,
            .node_repo = null,
            .usage_repo = null,
        };
    }

    pub fn setRepositories(
        self: *Server,
        task_repo: *db.TaskRepository,
        node_repo: *db.NodeRepository,
        usage_repo: *db.UsageRepository,
    ) void {
        self.task_repo = task_repo;
        self.node_repo = node_repo;
        self.usage_repo = usage_repo;
    }

    pub fn deinit(self: *Server) void {
        self.stop();
    }

    pub fn listen(self: *Server, address: []const u8, port: u16) !void {
        const addr = try std.net.Address.parseIp(address, port);
        self.listener = try addr.listen(.{ .reuse_address = true });
        self.running.store(true, .release);
    }

    pub fn run(self: *Server) !void {
        var listener = self.listener orelse return error.NotListening;

        while (self.running.load(.acquire)) {
            const conn = listener.accept() catch |err| {
                if (err == error.ConnectionAborted) continue;
                return err;
            };

            const thread = try std.Thread.spawn(.{}, handleConnectionWithContext, .{ self, conn });
            thread.detach();
        }
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
    }

    fn handleConnectionWithContext(self: *Server, stream: std.net.Server.Connection) void {
        var conn = grpc.Connection{
            .allocator = self.allocator,
            .stream = stream.stream,
            .address = stream.address,
        };
        defer conn.close();

        log.info("client connected from {any}", .{stream.address});

        while (true) {
            const msg = conn.readMessage(protocol.SubmitTaskRequest) catch |err| {
                if (err == error.ConnectionClosed or err == error.ConnectionResetByPeer) {
                    log.info("client disconnected", .{});
                    return;
                }
                log.err("failed to read message: {}", .{err});
                return;
            };

            if (msg.header.msg_type == .submit_task) {
                var handler = RequestHandler{
                    .allocator = self.allocator,
                    .scheduler = self.scheduler,
                    .registry = self.registry,
                    .metering = self.metering,
                    .auth = self.auth,
                    .task_repo = self.task_repo,
                };

                const client_id = generateClientId(stream.address);
                log.info("generated client_id={s} for address={any}", .{ &types.formatId(&client_id), stream.address });
                handler.handleSubmitTask(&conn, msg.payload, client_id) catch |err| {
                    log.err("failed to handle submit task: {}", .{err});
                };
            } else {
                log.warn("unsupported message type: {}", .{msg.header.msg_type});
            }
        }
    }
};

pub const RequestHandler = struct {
    allocator: std.mem.Allocator,
    scheduler: *scheduler.Scheduler,
    registry: *registry.NodeRegistry,
    metering: *metering.Metering,
    auth: *auth.Authenticator,
    task_repo: ?*db.TaskRepository,

    pub fn handleSubmitTask(
        self: *RequestHandler,
        conn: *grpc.Connection,
        request: protocol.SubmitTaskRequest,
        client_id: types.ClientId,
    ) !void {
        if (!auth.Authenticator.validateGitHubToken(request.github_token)) {
            log.warn("submit rejected: invalid github token", .{});
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

        if (self.task_repo) |repo| {
            repo.create(&task) catch |err| {
                log.err("failed to persist task: {}", .{err});
                try conn.writeMessage(.error_response, 0, ErrorResponse{
                    .code = "DB_ERROR",
                    .message = "Failed to persist task",
                });
                return;
            };
        }

        const task_id = try self.scheduler.submitTask(task);

        log.info("task submit request: task_id={s} repo={s}", .{ &types.formatId(task_id), request.repo_url });

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

            common.compat.sleep(100 * std.time.ns_per_ms);
        }
    }

    pub fn handleGetTask(self: *RequestHandler, task_id: types.TaskId) ?types.Task {
        const ctx = self.scheduler.getTask(task_id) orelse return null;
        return ctx.task;
    }

    pub fn handleCancelTask(self: *RequestHandler, task_id: types.TaskId) CancelResponse {
        const success = self.scheduler.cancelTask(task_id);

        log.info("cancel request: task_id={s} success={}", .{ &types.formatId(task_id), success });

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

test "generateClientId determinism - same IPv4 produces same result" {
    const addr1 = try std.net.Address.parseIp4("192.168.1.100", 8080);
    const addr2 = try std.net.Address.parseIp4("192.168.1.100", 9090);

    const id1 = generateClientId(addr1);
    const id2 = generateClientId(addr2);

    try std.testing.expectEqualSlices(u8, &id1, &id2);
}

test "generateClientId uniqueness - different IPv4 produces different results" {
    const addr1 = try std.net.Address.parseIp4("192.168.1.100", 8080);
    const addr2 = try std.net.Address.parseIp4("192.168.1.101", 8080);

    const id1 = generateClientId(addr1);
    const id2 = generateClientId(addr2);

    try std.testing.expect(!std.mem.eql(u8, &id1, &id2));
}

test "generateClientId determinism - same IPv6 produces same result" {
    const addr1 = try std.net.Address.parseIp6("::1", 8080);
    const addr2 = try std.net.Address.parseIp6("::1", 9090);

    const id1 = generateClientId(addr1);
    const id2 = generateClientId(addr2);

    try std.testing.expectEqualSlices(u8, &id1, &id2);
}

test "generateClientId uniqueness - different IPv6 produces different results" {
    const addr1 = try std.net.Address.parseIp6("::1", 8080);
    const addr2 = try std.net.Address.parseIp6("::2", 8080);

    const id1 = generateClientId(addr1);
    const id2 = generateClientId(addr2);

    try std.testing.expect(!std.mem.eql(u8, &id1, &id2));
}

test "generateClientId - IPv4 and IPv6 produce different results" {
    const ipv4 = try std.net.Address.parseIp4("127.0.0.1", 8080);
    const ipv6 = try std.net.Address.parseIp6("::1", 8080);

    const id_v4 = generateClientId(ipv4);
    const id_v6 = generateClientId(ipv6);

    try std.testing.expect(!std.mem.eql(u8, &id_v4, &id_v6));
}

test "generateClientId - returns valid 16-byte ClientId" {
    const addr = try std.net.Address.parseIp4("10.0.0.1", 443);
    const id = generateClientId(addr);

    try std.testing.expectEqual(@as(usize, 16), id.len);

    var all_zero = true;
    for (id) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

test "generateClientId - consistent across multiple calls" {
    const addr = try std.net.Address.parseIp4("172.16.0.50", 3000);

    const id1 = generateClientId(addr);
    const id2 = generateClientId(addr);
    const id3 = generateClientId(addr);

    try std.testing.expectEqualSlices(u8, &id1, &id2);
    try std.testing.expectEqualSlices(u8, &id2, &id3);
}
