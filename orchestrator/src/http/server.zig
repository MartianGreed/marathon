const std = @import("std");
const common = @import("common");
const types = common.types;

const auth = @import("../auth/auth.zig");
const db = @import("../db/root.zig");
const user_repo = @import("../db/repository/user.zig");
const scheduler_mod = @import("../scheduler/scheduler.zig");
const metering_mod = @import("../metering/metering.zig");

const log = std.log.scoped(.http);

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    authenticator: *auth.Authenticator,
    user_repo: ?*user_repo.UserRepository,
    task_scheduler: ?*scheduler_mod.Scheduler,
    meter: ?*metering_mod.Metering,
    listener: ?std.net.Server,
    running: std.atomic.Value(bool),

    pub fn init(
        allocator: std.mem.Allocator,
        authenticator: *auth.Authenticator,
    ) HttpServer {
        return .{
            .allocator = allocator,
            .authenticator = authenticator,
            .user_repo = null,
            .task_scheduler = null,
            .meter = null,
            .listener = null,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn setUserRepository(self: *HttpServer, repo: *user_repo.UserRepository) void {
        self.user_repo = repo;
    }

    pub fn setScheduler(self: *HttpServer, sched: *scheduler_mod.Scheduler) void {
        self.task_scheduler = sched;
    }

    pub fn setMetering(self: *HttpServer, meter: *metering_mod.Metering) void {
        self.meter = meter;
    }

    pub fn listen(self: *HttpServer, address: []const u8, port: u16) !void {
        const addr = try std.net.Address.parseIp(address, port);
        self.listener = try addr.listen(.{ .reuse_address = true });
        self.running.store(true, .release);
        log.info("HTTP server listening on {s}:{d}", .{ address, port });
    }

    pub fn run(self: *HttpServer) !void {
        var listener = self.listener orelse return error.NotListening;

        while (self.running.load(.acquire)) {
            const conn = listener.accept() catch |err| {
                if (err == error.ConnectionAborted) continue;
                return err;
            };

            const thread = try std.Thread.spawn(.{}, handleConnection, .{ self, conn });
            thread.detach();
        }
    }

    pub fn stop(self: *HttpServer) void {
        self.running.store(false, .release);
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
    }

    pub fn deinit(self: *HttpServer) void {
        self.stop();
    }

    fn handleConnection(self: *HttpServer, conn: std.net.Server.Connection) void {
        defer conn.stream.close();

        var buf: [8192]u8 = undefined;
        const n = conn.stream.read(&buf) catch |err| {
            log.warn("read error: {}", .{err});
            return;
        };
        if (n == 0) return;

        const request_data = buf[0..n];
        self.processRequest(conn.stream, request_data) catch |err| {
            log.warn("request processing error: {}", .{err});
            sendError(conn.stream, 500, "Internal Server Error") catch {};
        };
    }

    fn processRequest(self: *HttpServer, stream: std.net.Stream, data: []const u8) !void {
        // Parse request line
        const line_end = std.mem.indexOf(u8, data, "\r\n") orelse return sendError(stream, 400, "Bad Request");
        const request_line = data[0..line_end];

        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse return sendError(stream, 400, "Bad Request");
        const path = parts.next() orelse return sendError(stream, 400, "Bad Request");

        // Parse headers
        const headers_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return sendError(stream, 400, "Bad Request");
        const headers_section = data[line_end + 2 .. headers_end];
        const body = if (headers_end + 4 < data.len) data[headers_end + 4 ..] else "";

        // Extract Authorization header
        const auth_token = extractHeader(headers_section, "Authorization");

        // CORS preflight
        if (std.mem.eql(u8, method, "OPTIONS")) {
            return sendCorsResponse(stream);
        }

        // Route
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/auth/register")) {
            return self.handleRegister(stream, body);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/auth/login")) {
            return self.handleLogin(stream, body);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/tasks")) {
            return self.handleListTasks(stream, auth_token);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/tasks/")) {
            return self.handleGetTask(stream, path[7..], auth_token);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/usage")) {
            return self.handleGetUsage(stream, auth_token);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/health")) {
            return sendJson(stream, 200, "{\"status\":\"ok\"}");
        } else {
            return sendError(stream, 404, "Not Found");
        }
    }

    fn extractBearerToken(auth_header: ?[]const u8) ?[]const u8 {
        const header = auth_header orelse return null;
        if (std.mem.startsWith(u8, header, "Bearer ")) {
            return header[7..];
        }
        return null;
    }

    fn authenticateRequest(self: *HttpServer, auth_header: ?[]const u8) ?types.ClientId {
        const token = extractBearerToken(auth_header) orelse return null;
        return self.authenticator.authenticateJwt(self.allocator, token) catch null;
    }

    fn handleRegister(self: *HttpServer, stream: std.net.Stream, body: []const u8) !void {
        const email = extractJsonString(body, "email") orelse return sendJsonError(stream, 400, "Email required");
        const password = extractJsonString(body, "password") orelse return sendJsonError(stream, 400, "Password required");

        const repo = self.user_repo orelse return sendJsonError(stream, 503, "Registration not available");

        if (try repo.findByEmail(email)) |_| {
            return sendJsonError(stream, 409, "Email already registered");
        }

        const password_hash = try auth.PasswordHash.hash(self.allocator, password);
        defer self.allocator.free(password_hash);

        var user_id: [16]u8 = undefined;
        std.crypto.random.bytes(&user_id);

        const api_key = try auth.Authenticator.generateApiKey(self.allocator);
        defer self.allocator.free(api_key);

        const now = std.time.milliTimestamp();
        const new_user = user_repo.User{
            .id = user_id,
            .email = email,
            .password_hash = password_hash,
            .github_id = null,
            .api_key = api_key,
            .created_at = now,
            .updated_at = now,
        };

        repo.create(&new_user) catch return sendJsonError(stream, 500, "Failed to create user");

        try self.authenticator.registerApiKey(api_key, user_id);

        const token = try self.authenticator.createToken(self.allocator, user_id, email);
        defer self.allocator.free(token);

        var resp_buf: [1024]u8 = undefined;
        const resp = std.fmt.bufPrint(&resp_buf, "{{\"success\":true,\"token\":\"{s}\",\"api_key\":\"{s}\",\"message\":\"Registration successful\"}}", .{ token, api_key }) catch return sendJsonError(stream, 500, "Response too large");

        return sendJson(stream, 200, resp);
    }

    fn handleLogin(self: *HttpServer, stream: std.net.Stream, body: []const u8) !void {
        const email = extractJsonString(body, "email") orelse return sendJsonError(stream, 400, "Email required");
        const password = extractJsonString(body, "password") orelse return sendJsonError(stream, 400, "Password required");

        const repo = self.user_repo orelse return sendJsonError(stream, 503, "Authentication not available");

        var found_user = (try repo.findByEmail(email)) orelse return sendJsonError(stream, 401, "Invalid email or password");
        defer found_user.deinit(self.allocator);

        if (!auth.PasswordHash.verify(password, found_user.password_hash)) {
            return sendJsonError(stream, 401, "Invalid email or password");
        }

        const token = try self.authenticator.createToken(self.allocator, found_user.id, found_user.email);
        defer self.allocator.free(token);

        var resp_buf: [1024]u8 = undefined;
        const resp = std.fmt.bufPrint(&resp_buf, "{{\"success\":true,\"token\":\"{s}\",\"api_key\":\"{s}\",\"message\":\"Login successful\"}}", .{ token, found_user.api_key }) catch return sendJsonError(stream, 500, "Response too large");

        return sendJson(stream, 200, resp);
    }

    fn handleListTasks(self: *HttpServer, stream: std.net.Stream, auth_header: ?[]const u8) !void {
        const client_id = self.authenticateRequest(auth_header) orelse return sendJsonError(stream, 401, "Unauthorized");

        const sched = self.task_scheduler orelse return sendJsonError(stream, 503, "Task service not available");

        const result = try sched.listTasks(self.allocator, client_id, null, 100, 0);
        defer self.allocator.free(result.tasks);

        // Build JSON array
        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator, "[");
        for (result.tasks, 0..) |task, i| {
            if (i > 0) try json.appendSlice(self.allocator, ",");
            try appendTaskJson(self.allocator, &json, &task);
        }
        try json.appendSlice(self.allocator, "]");

        return sendJson(stream, 200, json.items);
    }

    fn handleGetTask(self: *HttpServer, stream: std.net.Stream, task_id_hex: []const u8, auth_header: ?[]const u8) !void {
        _ = self.authenticateRequest(auth_header) orelse return sendJsonError(stream, 401, "Unauthorized");

        const sched = self.task_scheduler orelse return sendJsonError(stream, 503, "Task service not available");

        if (task_id_hex.len != 32) return sendJsonError(stream, 400, "Invalid task ID");

        var task_id: types.TaskId = undefined;
        _ = std.fmt.hexToBytes(&task_id, task_id_hex) catch return sendJsonError(stream, 400, "Invalid task ID format");

        const snapshot = sched.getTask(task_id) orelse return sendJsonError(stream, 404, "Task not found");

        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(self.allocator);

        try appendTaskJson(self.allocator, &json, snapshot.task);
        return sendJson(stream, 200, json.items);
    }

    fn handleGetUsage(self: *HttpServer, stream: std.net.Stream, auth_header: ?[]const u8) !void {
        const client_id = self.authenticateRequest(auth_header) orelse return sendJsonError(stream, 401, "Unauthorized");

        const meter = self.meter orelse return sendJsonError(stream, 503, "Usage service not available");

        const report = try meter.getUsageReport(client_id, 0, std.time.milliTimestamp());
        defer self.allocator.free(report.tasks);

        var resp_buf: [512]u8 = undefined;
        const resp = std.fmt.bufPrint(&resp_buf, "{{\"total_input_tokens\":{d},\"total_output_tokens\":{d},\"total_compute_time_ms\":{d},\"total_tool_calls\":{d},\"task_count\":{d}}}", .{
            report.total.input_tokens,
            report.total.output_tokens,
            report.total.compute_time_ms,
            report.total.tool_calls,
            report.tasks.len,
        }) catch return sendJsonError(stream, 500, "Response too large");

        return sendJson(stream, 200, resp);
    }

    fn appendTaskJson(allocator: std.mem.Allocator, json: *std.ArrayListUnmanaged(u8), task: *const types.Task) !void {
        const id_hex = std.fmt.bytesToHex(task.id, .lower);
        var buf: [2048]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"state\":\"{s}\",\"repo_url\":\"{s}\",\"branch\":\"{s}\",\"prompt\":\"{s}\",\"created_at\":{d}", .{
            &id_hex,
            @tagName(task.state),
            task.repo_url,
            task.branch,
            task.prompt,
            task.created_at,
        }) catch return;
        try json.appendSlice(allocator, s);

        if (task.started_at) |v| {
            var b2: [64]u8 = undefined;
            const s2 = std.fmt.bufPrint(&b2, ",\"started_at\":{d}", .{v}) catch return;
            try json.appendSlice(allocator, s2);
        }
        if (task.completed_at) |v| {
            var b2: [64]u8 = undefined;
            const s2 = std.fmt.bufPrint(&b2, ",\"completed_at\":{d}", .{v}) catch return;
            try json.appendSlice(allocator, s2);
        }
        if (task.error_message) |msg| {
            try json.appendSlice(allocator, ",\"error_message\":\"");
            try json.appendSlice(allocator, msg);
            try json.appendSlice(allocator, "\"");
        }
        if (task.pr_url) |url| {
            try json.appendSlice(allocator, ",\"pr_url\":\"");
            try json.appendSlice(allocator, url);
            try json.appendSlice(allocator, "\"");
        }

        var usage_buf: [256]u8 = undefined;
        const usage_s = std.fmt.bufPrint(&usage_buf, ",\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"compute_time_ms\":{d},\"tool_calls\":{d}}}", .{
            task.usage.input_tokens,
            task.usage.output_tokens,
            task.usage.compute_time_ms,
            task.usage.tool_calls,
        }) catch return;
        try json.appendSlice(allocator, usage_s);

        try json.appendSlice(allocator, "}");
    }
};

fn extractHeader(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len > name.len + 2 and std.ascii.eqlIgnoreCase(line[0..name.len], name) and line[name.len] == ':') {
            var value = line[name.len + 1 ..];
            value = std.mem.trim(u8, value, " ");
            return value;
        }
    }
    return null;
}

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Look for "key":"value"
    // Build the search pattern: "key":"
    var search_buf: [128]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, search) orelse return null;
    const start = pos + search.len;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
    return json[start..end];
}

fn sendJson(stream: std.net.Stream, status: u16, body: []const u8) !void {
    const status_text = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        409 => "Conflict",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "Unknown",
    };

    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nConnection: close\r\n\r\n", .{ status, status_text, body.len }) catch return;

    _ = stream.write(header) catch return;
    _ = stream.write(body) catch return;
}

fn sendError(stream: std.net.Stream, status: u16, message: []const u8) !void {
    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{message}) catch return;
    return sendJson(stream, status, body);
}

fn sendJsonError(stream: std.net.Stream, status: u16, message: []const u8) !void {
    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"success\":false,\"message\":\"{s}\"}}", .{message}) catch return;
    return sendJson(stream, status, body);
}

fn sendCorsResponse(stream: std.net.Stream) !void {
    const response = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Max-Age: 86400\r\nConnection: close\r\n\r\n";
    _ = stream.write(response) catch {};
}
