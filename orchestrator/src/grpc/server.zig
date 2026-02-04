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

fn validateRepoUrl(url: []const u8) bool {
    if (url.len < 10 or url.len > 2048) return false;

    const valid_prefixes = [_][]const u8{
        "https://github.com/",
        "https://gitlab.com/",
        "https://bitbucket.org/",
        "git@github.com:",
        "git@gitlab.com:",
        "git@bitbucket.org:",
    };

    for (valid_prefixes) |prefix| {
        if (std.mem.startsWith(u8, url, prefix)) return true;
    }

    if (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "git@")) {
        return true;
    }

    return false;
}

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
    node_auth_key: ?[]const u8,
    pending_tasks: std.AutoHashMap(types.NodeId, std.ArrayListUnmanaged(*types.Task)),
    anthropic_api_key: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        sched: *scheduler.Scheduler,
        reg: *registry.NodeRegistry,
        meter: *metering.Metering,
        authenticator: *auth.Authenticator,
        node_auth_key: ?[]const u8,
        anthropic_api_key: []const u8,
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
            .node_auth_key = node_auth_key,
            .pending_tasks = std.AutoHashMap(types.NodeId, std.ArrayListUnmanaged(*types.Task)).init(allocator),
            .anthropic_api_key = anthropic_api_key,
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

        var it = self.pending_tasks.valueIterator();
        while (it.next()) |list| {
            list.deinit(self.allocator);
        }
        self.pending_tasks.deinit();
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

        const client_id = generateClientId(stream.address);
        log.info("client connected from {any} client_id={s}", .{ stream.address, &types.formatId(&client_id) });

        var handler = RequestHandler{
            .allocator = self.allocator,
            .scheduler = self.scheduler,
            .registry = self.registry,
            .metering = self.metering,
            .auth = self.auth,
            .task_repo = self.task_repo,
        };

        while (true) {
            log.info("waiting for next message from client_id={s}", .{&types.formatId(&client_id)});
            const header = conn.readHeader() catch |err| {
                if (err == error.ConnectionClosed or err == error.ConnectionResetByPeer) {
                    log.info("client disconnected: client_id={s}", .{&types.formatId(&client_id)});
                    return;
                }
                log.err("failed to read header: client_id={s} err={}", .{ &types.formatId(&client_id), err });
                return;
            };

            log.info("received message: client_id={s} msg_type={s} request_id={d} payload_len={d}", .{
                &types.formatId(&client_id),
                @tagName(header.msg_type),
                header.request_id,
                header.payload_len,
            });

            self.dispatchMessage(&conn, &handler, header, client_id) catch |err| {
                log.err("failed to handle message type={s} request_id={d}: {}", .{ @tagName(header.msg_type), header.request_id, err });
                conn.writeMessage(.error_response, header.request_id, protocol.ErrorResponse{
                    .code = "INTERNAL_ERROR",
                    .message = "Failed to process request",
                }) catch |write_err| {
                    log.err("failed to send error response: {}", .{write_err});
                    return;
                };
            };
        }
    }

    fn dispatchMessage(
        self: *Server,
        conn: *grpc.Connection,
        handler: *RequestHandler,
        header: protocol.Header,
        client_id: types.ClientId,
    ) !void {
        log.info("dispatching msg_type={s} request_id={d}", .{ @tagName(header.msg_type), header.request_id });
        switch (header.msg_type) {
            .heartbeat_request => {
                const payload = try conn.readPayload(protocol.HeartbeatPayload, header);
                try self.handleHeartbeat(conn, payload, header.request_id);
            },
            .submit_task => {
                log.info("reading submit_task payload ({d} bytes)", .{header.payload_len});
                const request = try conn.readPayload(protocol.SubmitTaskRequest, header);
                log.info("submit_task payload decoded: repo={s} branch={s} prompt_len={d}", .{ request.repo_url, request.branch, request.prompt.len });
                try handler.handleSubmitTask(conn, request, client_id, header.request_id);
            },
            .get_task => {
                const request = try conn.readPayload(protocol.GetTaskRequest, header);
                try handler.handleGetTask(conn, request.task_id, header.request_id);
            },
            .cancel_task => {
                const request = try conn.readPayload(protocol.CancelTaskRequest, header);
                try handler.handleCancelTask(conn, request.task_id, header.request_id);
            },
            .get_usage => {
                const request = try conn.readPayload(protocol.GetUsageRequest, header);
                try handler.handleGetUsage(conn, request, client_id, header.request_id);
            },
            .list_tasks => {
                const request = try conn.readPayload(protocol.ListTasksRequest, header);
                try handler.handleListTasks(conn, request, client_id, header.request_id);
            },
            else => {
                log.warn("unsupported message type: {}", .{header.msg_type});
                try conn.writeMessage(.error_response, header.request_id, protocol.ErrorResponse{
                    .code = "UNSUPPORTED_MESSAGE",
                    .message = "Message type not supported",
                });
            },
        }
    }

    fn handleHeartbeat(
        self: *Server,
        conn: *grpc.Connection,
        payload: protocol.HeartbeatPayload,
        request_id: u32,
    ) !void {
        if (!self.validateNodeAuth(payload)) {
            log.warn("node auth failed: node_id={s}", .{&types.formatId(payload.node_id)});
            try conn.writeMessage(.error_response, request_id, protocol.ErrorResponse{
                .code = "AUTH_FAILED",
                .message = "Node authentication failed",
            });
            return;
        }

        const status = types.NodeStatus{
            .node_id = payload.node_id,
            .hostname = payload.hostname,
            .total_vm_slots = payload.total_vm_slots,
            .active_vms = payload.active_vms,
            .warm_vms = payload.warm_vms,
            .cpu_usage = payload.cpu_usage,
            .memory_usage = payload.memory_usage,
            .disk_available_bytes = payload.disk_available_bytes,
            .healthy = payload.healthy,
            .draining = payload.draining,
            .uptime_seconds = 0,
            .last_task_at = null,
            .active_task_ids = &[_]types.TaskId{},
        };

        if (self.registry.getNode(payload.node_id)) |_| {
            try self.registry.updateHeartbeat(payload.node_id, status);
        } else {
            try self.registry.register(status);
            log.info("node registered: node_id={s} hostname={s}", .{
                &types.formatId(payload.node_id),
                payload.hostname,
            });
        }

        if (status.availableSlots() > 0) {
            self.tryScheduleTasks();
        }

        var commands: std.ArrayListUnmanaged(protocol.NodeCommand) = .empty;
        defer commands.deinit(self.allocator);

        if (self.pending_tasks.getPtr(payload.node_id)) |queue| {
            for (queue.items) |task| {
                commands.append(self.allocator, .{
                    .command_type = .execute_task,
                    .task_id = task.id,
                    .execute_request = .{
                        .task_id = task.id,
                        .repo_url = task.repo_url,
                        .branch = task.branch,
                        .prompt = task.prompt,
                        .github_token = task.github_token orelse "",
                        .anthropic_api_key = self.anthropic_api_key,
                        .create_pr = task.create_pr,
                        .pr_title = task.pr_title,
                        .pr_body = task.pr_body,
                        .timeout_ms = 600000,
                        .max_tokens = 100000,
                    },
                }) catch {
                    log.err("failed to build command for task_id={s}", .{&types.formatId(task.id)});
                    continue;
                };

                log.info("delivering task to node: task_id={s} node_id={s}", .{
                    &types.formatId(task.id),
                    &types.formatId(payload.node_id),
                });
            }
            queue.clearRetainingCapacity();
        }

        const response = protocol.HeartbeatResponse{
            .timestamp = std.time.milliTimestamp(),
            .acknowledged = true,
            .commands = commands.items,
        };
        try conn.writeMessage(.heartbeat_response, request_id, response);

        if (status.availableSlots() > 0) {
            self.tryScheduleTasks();
        }
    }

    fn tryScheduleTasks(self: *Server) void {
        while (true) {
            const result = self.scheduler.scheduleNext() orelse break;

            log.info("task scheduled to node: task_id={s} node_id={s}", .{
                &types.formatId(result.task.id),
                &types.formatId(result.node_id),
            });
        }
    }

    fn tryScheduleTasks(self: *Server) void {
        while (true) {
            const result = self.scheduler.scheduleNext() orelse break;

            const entry = self.pending_tasks.getOrPut(result.node_id) catch {
                log.err("failed to store pending task: task_id={s}", .{&types.formatId(result.task.id)});
                continue;
            };
            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
            }
            entry.value_ptr.append(self.allocator, result.task) catch {
                log.err("failed to append pending task: task_id={s}", .{&types.formatId(result.task.id)});
                continue;
            };

            log.info("task queued for delivery: task_id={s} node_id={s}", .{
                &types.formatId(result.task.id),
                &types.formatId(result.node_id),
            });
        }
    }

    fn validateNodeAuth(self: *Server, payload: protocol.HeartbeatPayload) bool {
        const key = self.node_auth_key orelse return true;

        const now = std.time.milliTimestamp();
        const timestamp_diff = if (now > payload.timestamp) now - payload.timestamp else payload.timestamp - now;
        if (timestamp_diff > 5 * 60 * 1000) {
            log.warn("heartbeat timestamp too old: diff_ms={d}", .{timestamp_diff});
            return false;
        }

        var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(key);
        hmac.update(&payload.node_id);
        hmac.update(std.mem.asBytes(&payload.timestamp));
        var expected: [32]u8 = undefined;
        hmac.final(&expected);

        return std.crypto.timing_safe.eql([32]u8, expected, payload.auth_token);
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
        request_id: u32,
    ) !void {
        log.info("handleSubmitTask: client_id={s} request_id={d} repo={s}", .{ &types.formatId(&client_id), request_id, request.repo_url });

        if (!validateRepoUrl(request.repo_url)) {
            log.warn("submit rejected: invalid repo url for client_id={s}", .{&types.formatId(&client_id)});
            try conn.writeMessage(.error_response, request_id, protocol.ErrorResponse{
                .code = "INVALID_REPO_URL",
                .message = "Invalid repository URL format",
            });
            return;
        }
        log.info("handleSubmitTask: repo url validated", .{});

        if (!auth.Authenticator.validateGitHubToken(request.github_token)) {
            log.warn("submit rejected: invalid github token for client_id={s}", .{&types.formatId(&client_id)});
            try conn.writeMessage(.error_response, request_id, protocol.ErrorResponse{
                .code = "INVALID_GITHUB_TOKEN",
                .message = "Invalid GitHub token format",
            });
            return;
        }
        log.info("handleSubmitTask: github token validated", .{});

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
        task.github_token = if (request.github_token.len > 0) try self.allocator.dupe(u8, request.github_token) else null;

        if (self.task_repo) |repo| {
            log.info("handleSubmitTask: persisting task to DB", .{});
            repo.create(&task) catch |err| {
                log.err("failed to persist task: {}", .{err});
                try conn.writeMessage(.error_response, request_id, protocol.ErrorResponse{
                    .code = "DB_ERROR",
                    .message = "Failed to persist task",
                });
                return;
            };
            log.info("handleSubmitTask: task persisted to DB", .{});
        } else {
            log.info("handleSubmitTask: no task_repo configured, skipping DB persist", .{});
        }

        log.info("handleSubmitTask: submitting task to scheduler", .{});
        const task_id = try self.scheduler.submitTask(task);

        log.info("task submitted: task_id={s} client_id={s} repo={s}", .{
            &types.formatId(task_id),
            &types.formatId(&client_id),
            request.repo_url,
        });

        const event = protocol.TaskEvent{
            .task_id = task_id,
            .state = .queued,
            .timestamp = std.time.milliTimestamp(),
            .event_type = .state_change,
            .data = &[_]u8{},
        };

        log.info("handleSubmitTask: sending initial task_event (queued) for task_id={s}", .{&types.formatId(task_id)});
        try conn.writeMessage(.task_event, request_id, event);
        log.info("handleSubmitTask: queued event sent for task_id={s}", .{&types.formatId(task_id)});
    }

    fn streamTaskEvents(self: *RequestHandler, conn: *grpc.Connection, task_id: types.TaskId, request_id: u32) !void {
        log.info("streamTaskEvents: starting for task_id={s}", .{&types.formatId(task_id)});
        var last_state: ?types.TaskState = null;

        while (true) {
            const state = self.scheduler.getTaskState(task_id) orelse {
                log.info("streamTaskEvents: task not found, ending stream task_id={s}", .{&types.formatId(task_id)});
                break;
            };

            if (last_state == null or last_state.? != state) {
                log.info("streamTaskEvents: task_id={s} state={s}", .{ &types.formatId(task_id), @tagName(state) });
                last_state = state;

                const event = protocol.TaskEvent{
                    .task_id = task_id,
                    .state = state,
                    .timestamp = std.time.milliTimestamp(),
                    .event_type = if (state.isTerminal()) .complete else .state_change,
                    .data = &[_]u8{},
                };
                try conn.writeMessage(.task_event, request_id, event);

                if (state.isTerminal()) break;
            }

            common.compat.sleep(1 * std.time.ns_per_s);
        }
    }

    pub fn handleGetTask(
        self: *RequestHandler,
        conn: *grpc.Connection,
        task_id: types.TaskId,
        request_id: u32,
    ) !void {
        const snapshot = self.scheduler.getTask(task_id) orelse {
            log.warn("get_task: task not found task_id={s}", .{&types.formatId(task_id)});
            try conn.writeMessage(.error_response, request_id, protocol.ErrorResponse{
                .code = "NOT_FOUND",
                .message = "Task not found",
            });
            return;
        };

        const task = snapshot.task;
        log.info("get_task: task_id={s} state={s}", .{ &types.formatId(task_id), @tagName(task.state) });

        const response = protocol.TaskResponse{
            .task_id = task.id,
            .client_id = task.client_id,
            .state = task.state,
            .repo_url = task.repo_url,
            .branch = task.branch,
            .prompt = task.prompt,
            .node_id = task.node_id,
            .created_at = task.created_at,
            .started_at = task.started_at,
            .completed_at = task.completed_at,
            .error_message = task.error_message,
            .pr_url = task.pr_url,
            .usage = task.usage,
        };

        try conn.writeMessage(.task_response, request_id, response);
    }

    pub fn handleCancelTask(
        self: *RequestHandler,
        conn: *grpc.Connection,
        task_id: types.TaskId,
        request_id: u32,
    ) !void {
        const success = self.scheduler.cancelTask(task_id);

        log.info("cancel_task: task_id={s} success={}", .{ &types.formatId(task_id), success });

        const response = protocol.CancelResponse{
            .success = success,
            .message = if (success) "Task cancelled successfully" else "Failed to cancel task",
        };

        try conn.writeMessage(.task_response, request_id, response);
    }

    pub fn handleGetUsage(
        self: *RequestHandler,
        conn: *grpc.Connection,
        request: protocol.GetUsageRequest,
        client_id: types.ClientId,
        request_id: u32,
    ) !void {
        _ = request.client_id; // Use the client_id derived from connection for security
        const report = try self.metering.getUsageReport(client_id, request.start_time, request.end_time);
        defer self.allocator.free(report.tasks);

        log.info("get_usage: client_id={s} tasks={d} input_tokens={d} output_tokens={d}", .{
            &types.formatId(&client_id),
            report.tasks.len,
            report.total.input_tokens,
            report.total.output_tokens,
        });

        const response = protocol.UsageResponse{
            .client_id = client_id,
            .start_time = request.start_time,
            .end_time = request.end_time,
            .total_input_tokens = report.total.input_tokens,
            .total_output_tokens = report.total.output_tokens,
            .total_cache_read_tokens = report.total.cache_read_tokens,
            .total_cache_write_tokens = report.total.cache_write_tokens,
            .total_compute_time_ms = report.total.compute_time_ms,
            .total_tool_calls = report.total.tool_calls,
            .task_count = @intCast(report.tasks.len),
        };

        try conn.writeMessage(.usage_response, request_id, response);
    }

    pub fn handleListTasks(
        self: *RequestHandler,
        conn: *grpc.Connection,
        request: protocol.ListTasksRequest,
        client_id: types.ClientId,
        request_id: u32,
    ) !void {
        _ = request.client_id; // Use the client_id derived from connection for security
        const result = try self.scheduler.listTasks(
            self.allocator,
            client_id,
            request.state_filter,
            request.limit,
            request.offset,
        );
        defer self.allocator.free(result.tasks);

        log.info("list_tasks: client_id={s} returned={d} total={d}", .{
            &types.formatId(&client_id),
            result.tasks.len,
            result.total_count,
        });

        var summaries = try self.allocator.alloc(protocol.TaskSummary, result.tasks.len);
        defer self.allocator.free(summaries);

        for (result.tasks, 0..) |task, i| {
            summaries[i] = .{
                .task_id = task.id,
                .state = task.state,
                .repo_url = task.repo_url,
                .created_at = task.created_at,
                .completed_at = task.completed_at,
            };
        }

        const response = protocol.ListTasksResponse{
            .tasks = summaries,
            .total_count = result.total_count,
        };

        try conn.writeMessage(.task_response, request_id, response);
    }
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

test "validateRepoUrl - accepts valid GitHub URLs" {
    try std.testing.expect(validateRepoUrl("https://github.com/user/repo"));
    try std.testing.expect(validateRepoUrl("https://github.com/org/project.git"));
    try std.testing.expect(validateRepoUrl("git@github.com:user/repo.git"));
}

test "validateRepoUrl - accepts valid GitLab URLs" {
    try std.testing.expect(validateRepoUrl("https://gitlab.com/user/repo"));
    try std.testing.expect(validateRepoUrl("git@gitlab.com:user/repo.git"));
}

test "validateRepoUrl - accepts valid Bitbucket URLs" {
    try std.testing.expect(validateRepoUrl("https://bitbucket.org/user/repo"));
    try std.testing.expect(validateRepoUrl("git@bitbucket.org:user/repo.git"));
}

test "validateRepoUrl - rejects invalid URLs" {
    try std.testing.expect(!validateRepoUrl(""));
    try std.testing.expect(!validateRepoUrl("short"));
    try std.testing.expect(!validateRepoUrl("http://github.com/user/repo"));
    try std.testing.expect(!validateRepoUrl("ftp://github.com/user/repo"));
    try std.testing.expect(!validateRepoUrl("file:///etc/passwd"));
}
