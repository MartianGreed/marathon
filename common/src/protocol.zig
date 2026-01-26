const std = @import("std");
const types = @import("types.zig");

pub const MessageType = enum(u8) {
    submit_task = 0x01,
    get_task = 0x02,
    cancel_task = 0x03,
    get_usage = 0x04,
    list_tasks = 0x05,

    task_event = 0x10,
    task_response = 0x11,
    usage_response = 0x12,
    error_response = 0x1f,

    execute_task = 0x20,
    heartbeat_request = 0x21,
    heartbeat_response = 0x22,
    node_status = 0x23,
    node_command = 0x24,

    vsock_ready = 0x30,
    vsock_output = 0x31,
    vsock_metrics = 0x32,
    vsock_complete = 0x33,
    vsock_error = 0x34,
    vsock_start = 0x35,
    vsock_cancel = 0x36,
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

pub const SubmitTaskRequest = struct {
    repo_url: []const u8,
    branch: []const u8,
    prompt: []const u8,
    github_token: []const u8,
    create_pr: bool,
    pr_title: ?[]const u8,
    pr_body: ?[]const u8,
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

pub const HeartbeatPayload = struct {
    node_id: types.NodeId,
    timestamp: i64,
    total_vm_slots: u32,
    active_vms: u32,
    warm_vms: u32,
    cpu_usage: f64,
    memory_usage: f64,
    disk_available_bytes: i64,
    healthy: bool,
    draining: bool,
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
};

pub const VsockErrorPayload = struct {
    code: []const u8,
    message: []const u8,
};

pub const GetTaskRequest = struct {
    task_id: types.TaskId,
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
