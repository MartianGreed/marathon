const std = @import("std");
const types = @import("types.zig");

pub const MessageType = enum(u8) {
    submit_task = 0x01,
    get_task = 0x02,
    cancel_task = 0x03,
    get_usage = 0x04,
    list_tasks = 0x05,
    get_task_events = 0x06,

    task_event = 0x10,
    task_response = 0x11,
    usage_response = 0x12,
    task_events_response = 0x13,
    error_response = 0x1f,

    execute_task = 0x20,
    heartbeat_request = 0x21,
    heartbeat_response = 0x22,
    node_status = 0x23,
    node_command = 0x24,
    report_task_result = 0x25,
    report_task_output = 0x26,

    vsock_ready = 0x30,
    vsock_output = 0x31,
    vsock_metrics = 0x32,
    vsock_complete = 0x33,
    vsock_error = 0x34,
    vsock_start = 0x35,
    vsock_cancel = 0x36,
    vsock_progress = 0x37,

    // Auth messages
    auth_register = 0x40,
    auth_login = 0x41,
    auth_response = 0x42,
};

pub const Header = extern struct {
    magic: [4]u8 = .{ 'M', 'R', 'T', 'N' },
    version: u8 = 1,
    msg_type: MessageType,
    flags: u8 = 0,
    reserved: u8 = 0,
    payload_len: u32,
    request_id: u32,
};

pub const Flag = struct {
    pub const streaming: u8 = 0x01;
    pub const compressed: u8 = 0x02;
    pub const encrypted: u8 = 0x04;
};

pub fn Message(comptime T: type) type {
    return struct {
        header: Header,
        payload: T,

        const Self = @This();

        pub fn encode(self: Self, allocator: std.mem.Allocator) ![]u8 {
            const payload_bytes = try encodePayload(T, allocator, self.payload);
            defer allocator.free(payload_bytes);

            var header = self.header;
            header.payload_len = @intCast(payload_bytes.len);

            const result = try allocator.alloc(u8, @sizeOf(Header) + payload_bytes.len);
            @memcpy(result[0..@sizeOf(Header)], std.mem.asBytes(&header));
            @memcpy(result[@sizeOf(Header)..], payload_bytes);
            return result;
        }

        pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Self {
            if (data.len < @sizeOf(Header)) return error.MessageTooShort;

            const header: *const Header = @ptrCast(@alignCast(data[0..@sizeOf(Header)]));
            if (!std.mem.eql(u8, &header.magic, &.{ 'M', 'R', 'T', 'N' })) {
                return error.InvalidMagic;
            }
            if (header.version != 1) return error.UnsupportedVersion;

            const payload_data = data[@sizeOf(Header)..];
            if (payload_data.len < header.payload_len) return error.IncompletPayload;

            const payload = try decodePayload(T, allocator, payload_data[0..header.payload_len]);

            return .{
                .header = header.*,
                .payload = payload,
            };
        }
    };
}

fn encodePayload(comptime T: type, allocator: std.mem.Allocator, value: T) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);

    try encodeValue(T, allocator, &list, value);
    return list.toOwnedSlice(allocator);
}

fn encodeValue(comptime T: type, allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), value: T) !void {
    const info = @typeInfo(T);

    switch (info) {
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                try encodeValue(field.type, allocator, list, @field(value, field.name));
            }
        },
        .int => {
            const bytes = std.mem.toBytes(std.mem.nativeToBig(T, value));
            try list.appendSlice(allocator, &bytes);
        },
        .@"enum" => |e| {
            try encodeValue(e.tag_type, allocator, list, @intFromEnum(value));
        },
        .bool => {
            try list.append(allocator, if (value) 1 else 0);
        },
        .optional => |o| {
            if (value) |v| {
                try list.append(allocator, 1);
                try encodeValue(o.child, allocator, list, v);
            } else {
                try list.append(allocator, 0);
            }
        },
        .pointer => |p| {
            if (p.size == .slice) {
                const len: u32 = @intCast(value.len);
                try encodeValue(u32, allocator, list, len);
                if (p.child == u8) {
                    try list.appendSlice(allocator, value);
                } else {
                    for (value) |item| {
                        try encodeValue(p.child, allocator, list, item);
                    }
                }
            } else {
                @compileError("unsupported pointer type");
            }
        },
        .array => |a| {
            if (a.child == u8) {
                try list.appendSlice(allocator, &value);
            } else {
                for (value) |item| {
                    try encodeValue(a.child, allocator, list, item);
                }
            }
        },
        .float => |f| {
            if (f.bits == 64) {
                const bits: u64 = @bitCast(value);
                try encodeValue(u64, allocator, list, bits);
            } else if (f.bits == 32) {
                const bits: u32 = @bitCast(value);
                try encodeValue(u32, allocator, list, bits);
            } else {
                @compileError("unsupported float size");
            }
        },
        else => @compileError("unsupported type for encoding: " ++ @typeName(T)),
    }
}

fn decodePayload(comptime T: type, allocator: std.mem.Allocator, data: []const u8) !T {
    var offset: usize = 0;
    return decodeValue(T, allocator, data, &offset);
}

fn decodeValue(comptime T: type, allocator: std.mem.Allocator, data: []const u8, offset: *usize) !T {
    const info = @typeInfo(T);

    switch (info) {
        .@"struct" => |s| {
            var result: T = undefined;
            inline for (s.fields) |field| {
                @field(result, field.name) = try decodeValue(field.type, allocator, data, offset);
            }
            return result;
        },
        .int => {
            const size = @sizeOf(T);
            if (offset.* + size > data.len) return error.UnexpectedEndOfData;
            const bytes = data[offset.*..][0..size];
            offset.* += size;
            return std.mem.bigToNative(T, @bitCast(bytes.*));
        },
        .@"enum" => |e| {
            const tag = try decodeValue(e.tag_type, allocator, data, offset);
            return @enumFromInt(tag);
        },
        .bool => {
            if (offset.* >= data.len) return error.UnexpectedEndOfData;
            const val = data[offset.*];
            offset.* += 1;
            return val != 0;
        },
        .optional => |o| {
            if (offset.* >= data.len) return error.UnexpectedEndOfData;
            const present = data[offset.*];
            offset.* += 1;
            if (present != 0) {
                return try decodeValue(o.child, allocator, data, offset);
            }
            return null;
        },
        .pointer => |p| {
            if (p.size == .slice) {
                const len = try decodeValue(u32, allocator, data, offset);
                if (p.child == u8) {
                    if (offset.* + len > data.len) return error.UnexpectedEndOfData;
                    const slice = try allocator.dupe(u8, data[offset.*..][0..len]);
                    offset.* += len;
                    return slice;
                } else {
                    const slice = try allocator.alloc(p.child, len);
                    for (slice) |*item| {
                        item.* = try decodeValue(p.child, allocator, data, offset);
                    }
                    return slice;
                }
            } else {
                @compileError("unsupported pointer type");
            }
        },
        .array => |a| {
            var result: T = undefined;
            if (a.child == u8) {
                if (offset.* + a.len > data.len) return error.UnexpectedEndOfData;
                @memcpy(&result, data[offset.*..][0..a.len]);
                offset.* += a.len;
            } else {
                for (&result) |*item| {
                    item.* = try decodeValue(a.child, allocator, data, offset);
                }
            }
            return result;
        },
        .float => |f| {
            if (f.bits == 64) {
                const bits = try decodeValue(u64, allocator, data, offset);
                return @bitCast(bits);
            } else if (f.bits == 32) {
                const bits = try decodeValue(u32, allocator, data, offset);
                return @bitCast(bits);
            } else {
                @compileError("unsupported float size");
            }
        },
        else => @compileError("unsupported type for decoding: " ++ @typeName(T)),
    }
}

pub const EnvVar = types.EnvVar;

pub const SubmitTaskRequest = struct {
    repo_url: []const u8,
    branch: []const u8,
    prompt: []const u8,
    github_token: []const u8,
    create_pr: bool,
    pr_title: ?[]const u8,
    pr_body: ?[]const u8,
    env_vars: []const EnvVar = &[_]EnvVar{},
    max_iterations: ?u32 = null,
    completion_promise: ?[]const u8 = null,
};

pub const ExecuteTaskRequest = struct {
    task_id: types.TaskId,
    repo_url: []const u8,
    branch: []const u8,
    prompt: []const u8,
    github_token: []const u8,
    anthropic_api_key: []const u8,
    create_pr: bool,
    pr_title: ?[]const u8,
    pr_body: ?[]const u8,
    timeout_ms: i64,
    max_tokens: i64,
    env_vars: []const EnvVar = &[_]EnvVar{},
    max_iterations: ?u32 = null,
    completion_promise: ?[]const u8 = null,
};

pub const TaskEvent = struct {
    task_id: types.TaskId,
    state: types.TaskState,
    timestamp: i64,
    event_type: EventType,
    data: []const u8,

    pub const EventType = enum(u8) {
        state_change = 0,
        output = 1,
        task_error = 2,
        complete = 3,
    };
};

pub const TaskResultReport = struct {
    task_id: types.TaskId,
    success: bool,
    error_message: ?[]const u8,
    metrics: types.UsageMetrics,
    pr_url: ?[]const u8,
};

/// Output event forwarded from node operator to orchestrator.
/// Included in heartbeat payload so the orchestrator can stream them to clients.
pub const TaskOutputEvent = struct {
    task_id: types.TaskId,
    output_type: types.OutputType,
    timestamp: i64,
    data: []const u8,
};

pub const HeartbeatPayload = struct {
    node_id: types.NodeId,
    timestamp: i64,
    auth_token: [32]u8,
    hostname: []const u8,
    total_vm_slots: u32,
    active_vms: u32,
    warm_vms: u32,
    cpu_usage: f64,
    memory_usage: f64,
    disk_available_bytes: i64,
    healthy: bool,
    draining: bool,
    completed_tasks: []const TaskResultReport,
    pending_output: []const TaskOutputEvent,
};

pub const CommandType = enum(u8) {
    execute_task = 1,
    cancel_task = 2,
    drain = 3,
    warm_pool = 4,
};

pub const NodeCommand = struct {
    command_type: CommandType,
    task_id: ?types.TaskId = null,
    execute_request: ?ExecuteTaskRequest = null,
    warm_pool_target: ?u32 = null,
};

pub const HeartbeatResponse = struct {
    timestamp: i64,
    acknowledged: bool,
    commands: []const NodeCommand = &[_]NodeCommand{},
};

pub const VsockStartPayload = struct {
    task_id: types.TaskId,
    repo_url: []const u8,
    branch: []const u8,
    prompt: []const u8,
    github_token: []const u8,
    anthropic_api_key: []const u8,
    create_pr: bool,
    pr_title: ?[]const u8,
    pr_body: ?[]const u8,
    max_iterations: ?u32,
    completion_promise: ?[]const u8,
    env_vars: []const EnvVar = &[_]EnvVar{},
};

pub const VsockOutputPayload = struct {
    output_type: types.OutputType,
    data: []const u8,
};

pub const VsockMetricsPayload = struct {
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    cache_write_tokens: i64,
    tool_calls: i64,
};

pub const VsockCompletePayload = struct {
    exit_code: i32,
    pr_url: ?[]const u8,
    metrics: VsockMetricsPayload,
    iteration: u32,
    promise_found: bool,
};

pub const VsockErrorPayload = struct {
    code: []const u8,
    message: []const u8,
};

pub const VsockProgressPayload = struct {
    iteration: u32,
    max_iterations: u32,
    status: []const u8,
};

pub const GetTaskRequest = struct {
    task_id: types.TaskId,
};

/// Request buffered events + current state for a task (used by -f/follow mode).
pub const GetTaskEventsRequest = struct {
    task_id: types.TaskId,
};

/// Response with current task state + any buffered output events since last poll.
pub const TaskEventsResponse = struct {
    task_id: types.TaskId,
    state: types.TaskState,
    events: []const TaskEvent,
    error_message: ?[]const u8,
    pr_url: ?[]const u8,
};

pub const TaskResponse = struct {
    task_id: types.TaskId,
    client_id: types.ClientId,
    state: types.TaskState,
    repo_url: []const u8,
    branch: []const u8,
    prompt: []const u8,
    node_id: ?types.NodeId,
    created_at: i64,
    started_at: ?i64,
    completed_at: ?i64,
    error_message: ?[]const u8,
    pr_url: ?[]const u8,
    usage: types.UsageMetrics,
};

pub const CancelTaskRequest = struct {
    task_id: types.TaskId,
};

pub const CancelResponse = struct {
    success: bool,
    message: []const u8,
};

pub const GetUsageRequest = struct {
    client_id: types.ClientId,
    start_time: i64,
    end_time: i64,
};

pub const UsageResponse = struct {
    client_id: types.ClientId,
    start_time: i64,
    end_time: i64,
    total_input_tokens: i64,
    total_output_tokens: i64,
    total_cache_read_tokens: i64,
    total_cache_write_tokens: i64,
    total_compute_time_ms: i64,
    total_tool_calls: i64,
    task_count: u32,
};

pub const ListTasksRequest = struct {
    client_id: types.ClientId,
    state_filter: ?types.TaskState,
    limit: u32,
    offset: u32,
};

pub const ListTasksResponse = struct {
    tasks: []TaskSummary,
    total_count: u32,
};

pub const TaskSummary = struct {
    task_id: types.TaskId,
    state: types.TaskState,
    repo_url: []const u8,
    created_at: i64,
    completed_at: ?i64,
};

pub const ErrorResponse = struct {
    code: []const u8,
    message: []const u8,
};

// Auth protocol messages
pub const AuthRegisterRequest = struct {
    email: []const u8,
    password: []const u8,
};

pub const AuthLoginRequest = struct {
    email: []const u8,
    password: []const u8,
};

pub const AuthResponse = struct {
    success: bool,
    token: ?[]const u8,
    api_key: ?[]const u8,
    message: []const u8,
};

pub fn freeDecoded(comptime T: type, allocator: std.mem.Allocator, value: T) void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.type == []const u8) {
            allocator.free(@field(value, field.name));
        } else if (field.type == ?[]const u8) {
            if (@field(value, field.name)) |s| allocator.free(s);
        }
    }
}

test "roundtrip encoding" {
    const allocator = std.testing.allocator;

    const original = SubmitTaskRequest{
        .repo_url = "https://github.com/test/repo",
        .branch = "main",
        .prompt = "Fix the bug",
        .github_token = "ghp_xxx",
        .create_pr = true,
        .pr_title = "Fix bug",
        .pr_body = null,
    };

    const encoded = try encodePayload(SubmitTaskRequest, allocator, original);
    defer allocator.free(encoded);

    const decoded = try decodePayload(SubmitTaskRequest, allocator, encoded);
    defer {
        allocator.free(decoded.repo_url);
        allocator.free(decoded.branch);
        allocator.free(decoded.prompt);
        allocator.free(decoded.github_token);
        if (decoded.pr_title) |t| allocator.free(t);
        if (decoded.pr_body) |b| allocator.free(b);
    }

    try std.testing.expectEqualStrings(original.repo_url, decoded.repo_url);
    try std.testing.expectEqualStrings(original.branch, decoded.branch);
    try std.testing.expectEqual(original.create_pr, decoded.create_pr);
}

test "NodeCommand with warm_pool_target roundtrip" {
    const allocator = std.testing.allocator;

    const original = NodeCommand{
        .command_type = .warm_pool,
        .task_id = null,
        .execute_request = null,
        .warm_pool_target = 8,
    };

    const encoded = try encodePayload(NodeCommand, allocator, original);
    defer allocator.free(encoded);

    const decoded = try decodePayload(NodeCommand, allocator, encoded);

    try std.testing.expectEqual(original.command_type, decoded.command_type);
    try std.testing.expectEqual(@as(?types.TaskId, null), decoded.task_id);
    try std.testing.expectEqual(@as(?u32, 8), decoded.warm_pool_target);
}

test "NodeCommand with null warm_pool_target roundtrip" {
    const allocator = std.testing.allocator;

    const original = NodeCommand{
        .command_type = .execute_task,
        .task_id = null,
        .execute_request = null,
        .warm_pool_target = null,
    };

    const encoded = try encodePayload(NodeCommand, allocator, original);
    defer allocator.free(encoded);

    const decoded = try decodePayload(NodeCommand, allocator, encoded);

    try std.testing.expectEqual(original.command_type, decoded.command_type);
    try std.testing.expectEqual(@as(?u32, null), decoded.warm_pool_target);
}

test "HeartbeatResponse with warm_pool command roundtrip" {
    const allocator = std.testing.allocator;

    const commands = [_]NodeCommand{
        .{ .command_type = .warm_pool, .warm_pool_target = 3 },
        .{ .command_type = .drain },
    };

    const original = HeartbeatResponse{
        .timestamp = 1234567890,
        .acknowledged = true,
        .commands = &commands,
    };

    const encoded = try encodePayload(HeartbeatResponse, allocator, original);
    defer allocator.free(encoded);

    const decoded = try decodePayload(HeartbeatResponse, allocator, encoded);
    defer allocator.free(decoded.commands);

    try std.testing.expectEqual(original.timestamp, decoded.timestamp);
    try std.testing.expectEqual(original.acknowledged, decoded.acknowledged);
    try std.testing.expectEqual(@as(usize, 2), decoded.commands.len);
    try std.testing.expectEqual(CommandType.warm_pool, decoded.commands[0].command_type);
    try std.testing.expectEqual(@as(?u32, 3), decoded.commands[0].warm_pool_target);
    try std.testing.expectEqual(CommandType.drain, decoded.commands[1].command_type);
    try std.testing.expectEqual(@as(?u32, null), decoded.commands[1].warm_pool_target);
}

test "VsockStartPayload encodes/decodes max_iterations and completion_promise" {
    const allocator = std.testing.allocator;

    const original = VsockStartPayload{
        .task_id = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 },
        .repo_url = "https://github.com/test/repo",
        .branch = "feature-branch",
        .prompt = "Implement feature X",
        .github_token = "ghp_xxx",
        .anthropic_api_key = "sk-ant-xxx",
        .create_pr = true,
        .pr_title = "Add feature X",
        .pr_body = "This PR adds feature X",
        .max_iterations = 5,
        .completion_promise = "TASK_COMPLETE",
    };

    const encoded = try encodePayload(VsockStartPayload, allocator, original);
    defer allocator.free(encoded);

    const decoded = try decodePayload(VsockStartPayload, allocator, encoded);
    defer {
        allocator.free(decoded.repo_url);
        allocator.free(decoded.branch);
        allocator.free(decoded.prompt);
        allocator.free(decoded.github_token);
        allocator.free(decoded.anthropic_api_key);
        if (decoded.pr_title) |t| allocator.free(t);
        if (decoded.pr_body) |b| allocator.free(b);
        if (decoded.completion_promise) |p| allocator.free(p);
    }

    try std.testing.expectEqual(original.task_id, decoded.task_id);
    try std.testing.expectEqualStrings(original.repo_url, decoded.repo_url);
    try std.testing.expectEqualStrings(original.branch, decoded.branch);
    try std.testing.expectEqualStrings(original.prompt, decoded.prompt);
    try std.testing.expectEqual(original.create_pr, decoded.create_pr);
    try std.testing.expectEqual(original.max_iterations, decoded.max_iterations);
    try std.testing.expectEqualStrings(original.completion_promise.?, decoded.completion_promise.?);
}

test "VsockStartPayload handles null max_iterations and completion_promise" {
    const allocator = std.testing.allocator;

    const original = VsockStartPayload{
        .task_id = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .repo_url = "https://github.com/test/repo",
        .branch = "main",
        .prompt = "Simple task",
        .github_token = "ghp_xxx",
        .anthropic_api_key = "sk-ant-xxx",
        .create_pr = false,
        .pr_title = null,
        .pr_body = null,
        .max_iterations = null,
        .completion_promise = null,
    };

    const encoded = try encodePayload(VsockStartPayload, allocator, original);
    defer allocator.free(encoded);

    const decoded = try decodePayload(VsockStartPayload, allocator, encoded);
    defer {
        allocator.free(decoded.repo_url);
        allocator.free(decoded.branch);
        allocator.free(decoded.prompt);
        allocator.free(decoded.github_token);
        allocator.free(decoded.anthropic_api_key);
    }

    try std.testing.expectEqual(@as(?u32, null), decoded.max_iterations);
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.completion_promise);
}

test "VsockCompletePayload encodes/decodes iteration and promise_found" {
    const allocator = std.testing.allocator;

    const original = VsockCompletePayload{
        .exit_code = 0,
        .pr_url = "https://github.com/owner/repo/pull/42",
        .metrics = .{
            .input_tokens = 1000,
            .output_tokens = 500,
            .cache_read_tokens = 100,
            .cache_write_tokens = 50,
            .tool_calls = 10,
        },
        .iteration = 3,
        .promise_found = true,
    };

    const encoded = try encodePayload(VsockCompletePayload, allocator, original);
    defer allocator.free(encoded);

    const decoded = try decodePayload(VsockCompletePayload, allocator, encoded);
    defer {
        if (decoded.pr_url) |url| allocator.free(url);
    }

    try std.testing.expectEqual(original.exit_code, decoded.exit_code);
    try std.testing.expectEqualStrings(original.pr_url.?, decoded.pr_url.?);
    try std.testing.expectEqual(original.metrics.input_tokens, decoded.metrics.input_tokens);
    try std.testing.expectEqual(original.metrics.output_tokens, decoded.metrics.output_tokens);
    try std.testing.expectEqual(original.metrics.cache_read_tokens, decoded.metrics.cache_read_tokens);
    try std.testing.expectEqual(original.metrics.cache_write_tokens, decoded.metrics.cache_write_tokens);
    try std.testing.expectEqual(original.metrics.tool_calls, decoded.metrics.tool_calls);
    try std.testing.expectEqual(original.iteration, decoded.iteration);
    try std.testing.expectEqual(original.promise_found, decoded.promise_found);
}

test "VsockCompletePayload handles null pr_url and false promise_found" {
    const allocator = std.testing.allocator;

    const original = VsockCompletePayload{
        .exit_code = 1,
        .pr_url = null,
        .metrics = .{
            .input_tokens = 500,
            .output_tokens = 250,
            .cache_read_tokens = 0,
            .cache_write_tokens = 0,
            .tool_calls = 5,
        },
        .iteration = 1,
        .promise_found = false,
    };

    const encoded = try encodePayload(VsockCompletePayload, allocator, original);
    defer allocator.free(encoded);

    const decoded = try decodePayload(VsockCompletePayload, allocator, encoded);

    try std.testing.expectEqual(original.exit_code, decoded.exit_code);
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.pr_url);
    try std.testing.expectEqual(original.iteration, decoded.iteration);
    try std.testing.expectEqual(original.promise_found, decoded.promise_found);
}

test "VsockProgressPayload roundtrip encoding" {
    const allocator = std.testing.allocator;

    const original = VsockProgressPayload{
        .iteration = 2,
        .max_iterations = 5,
        .status = "Running iteration 2 of 5",
    };

    const encoded = try encodePayload(VsockProgressPayload, allocator, original);
    defer allocator.free(encoded);

    const decoded = try decodePayload(VsockProgressPayload, allocator, encoded);
    defer allocator.free(decoded.status);

    try std.testing.expectEqual(original.iteration, decoded.iteration);
    try std.testing.expectEqual(original.max_iterations, decoded.max_iterations);
    try std.testing.expectEqualStrings(original.status, decoded.status);
}

test "VsockMetricsPayload roundtrip encoding" {
    const allocator = std.testing.allocator;

    const original = VsockMetricsPayload{
        .input_tokens = 12345,
        .output_tokens = 6789,
        .cache_read_tokens = 1000,
        .cache_write_tokens = 500,
        .tool_calls = 42,
    };

    const encoded = try encodePayload(VsockMetricsPayload, allocator, original);
    defer allocator.free(encoded);

    const decoded = try decodePayload(VsockMetricsPayload, allocator, encoded);

    try std.testing.expectEqual(original.input_tokens, decoded.input_tokens);
    try std.testing.expectEqual(original.output_tokens, decoded.output_tokens);
    try std.testing.expectEqual(original.cache_read_tokens, decoded.cache_read_tokens);
    try std.testing.expectEqual(original.cache_write_tokens, decoded.cache_write_tokens);
    try std.testing.expectEqual(original.tool_calls, decoded.tool_calls);
}

test "VsockErrorPayload roundtrip encoding" {
    const allocator = std.testing.allocator;

    const original = VsockErrorPayload{
        .code = "ERR_TIMEOUT",
        .message = "Task execution timed out after 30 minutes",
    };

    const encoded = try encodePayload(VsockErrorPayload, allocator, original);
    defer allocator.free(encoded);

    const decoded = try decodePayload(VsockErrorPayload, allocator, encoded);
    defer {
        allocator.free(decoded.code);
        allocator.free(decoded.message);
    }

    try std.testing.expectEqualStrings(original.code, decoded.code);
    try std.testing.expectEqualStrings(original.message, decoded.message);
}
