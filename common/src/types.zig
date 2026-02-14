const std = @import("std");

// Existing ID types
pub const TaskId = [32]u8;
pub const NodeId = [16]u8;
pub const VmId = [16]u8;
pub const ClientId = [16]u8;

// New collaboration ID types
pub const UserId = struct {
    bytes: [16]u8,

    pub fn init() UserId {
        var id: [16]u8 = undefined;
        std.crypto.random.bytes(&id);
        return UserId{ .bytes = id };
    }

    pub fn format(self: UserId) [32]u8 {
        return formatId(self.bytes);
    }

    pub fn fromString(hex: []const u8) !UserId {
        const bytes = try parseId([16]u8, hex);
        return UserId{ .bytes = bytes };
    }
};

pub const TeamId = struct {
    bytes: [16]u8,

    pub fn init() TeamId {
        var id: [16]u8 = undefined;
        std.crypto.random.bytes(&id);
        return TeamId{ .bytes = id };
    }

    pub fn format(self: TeamId) [32]u8 {
        return formatId(self.bytes);
    }

    pub fn fromString(hex: []const u8) !TeamId {
        const bytes = try parseId([16]u8, hex);
        return TeamId{ .bytes = bytes };
    }
};

pub const WorkspaceId = struct {
    bytes: [16]u8,

    pub fn init() WorkspaceId {
        var id: [16]u8 = undefined;
        std.crypto.random.bytes(&id);
        return WorkspaceId{ .bytes = id };
    }

    pub fn format(self: WorkspaceId) [32]u8 {
        return formatId(self.bytes);
    }

    pub fn fromString(hex: []const u8) !WorkspaceId {
        const bytes = try parseId([16]u8, hex);
        return WorkspaceId{ .bytes = bytes };
    }
};

pub const TaskAssignmentId = struct {
    bytes: [16]u8,

    pub fn init() TaskAssignmentId {
        var id: [16]u8 = undefined;
        std.crypto.random.bytes(&id);
        return TaskAssignmentId{ .bytes = id };
    }

    pub fn format(self: TaskAssignmentId) [32]u8 {
        return formatId(self.bytes);
    }

    pub fn fromString(hex: []const u8) !TaskAssignmentId {
        const bytes = try parseId([16]u8, hex);
        return TaskAssignmentId{ .bytes = bytes };
    }
};

pub const CommentId = struct {
    bytes: [16]u8,

    pub fn init() CommentId {
        var id: [16]u8 = undefined;
        std.crypto.random.bytes(&id);
        return CommentId{ .bytes = id };
    }

    pub fn format(self: CommentId) [32]u8 {
        return formatId(self.bytes);
    }

    pub fn fromString(hex: []const u8) !CommentId {
        const bytes = try parseId([16]u8, hex);
        return CommentId{ .bytes = bytes };
    }
};

pub const MemberId = struct {
    bytes: [16]u8,

    pub fn init() MemberId {
        var id: [16]u8 = undefined;
        std.crypto.random.bytes(&id);
        return MemberId{ .bytes = id };
    }

    pub fn format(self: MemberId) [32]u8 {
        return formatId(self.bytes);
    }

    pub fn fromString(hex: []const u8) !MemberId {
        const bytes = try parseId([16]u8, hex);
        return MemberId{ .bytes = bytes };
    }
};

pub const TerminalSessionId = struct {
    bytes: [16]u8,

    pub fn init() TerminalSessionId {
        var id: [16]u8 = undefined;
        std.crypto.random.bytes(&id);
        return TerminalSessionId{ .bytes = id };
    }

    pub fn format(self: TerminalSessionId) [32]u8 {
        return formatId(self.bytes);
    }

    pub fn fromString(hex: []const u8) !TerminalSessionId {
        const bytes = try parseId([16]u8, hex);
        return TerminalSessionId{ .bytes = bytes };
    }
};

pub const MessageId = struct {
    bytes: [16]u8,

    pub fn init() MessageId {
        var id: [16]u8 = undefined;
        std.crypto.random.bytes(&id);
        return MessageId{ .bytes = id };
    }

    pub fn format(self: MessageId) [32]u8 {
        return formatId(self.bytes);
    }

    pub fn fromString(hex: []const u8) !MessageId {
        const bytes = try parseId([16]u8, hex);
        return MessageId{ .bytes = bytes };
    }
};

pub const TemplateId = struct {
    bytes: [16]u8,

    pub fn init() TemplateId {
        var id: [16]u8 = undefined;
        std.crypto.random.bytes(&id);
        return TemplateId{ .bytes = id };
    }

    pub fn format(self: TemplateId) [32]u8 {
        return formatId(self.bytes);
    }

    pub fn fromString(hex: []const u8) !TemplateId {
        const bytes = try parseId([16]u8, hex);
        return TemplateId{ .bytes = bytes };
    }
};

pub const NotificationId = struct {
    bytes: [16]u8,

    pub fn init() NotificationId {
        var id: [16]u8 = undefined;
        std.crypto.random.bytes(&id);
        return NotificationId{ .bytes = id };
    }

    pub fn format(self: NotificationId) [32]u8 {
        return formatId(self.bytes);
    }

    pub fn fromString(hex: []const u8) !NotificationId {
        const bytes = try parseId([16]u8, hex);
        return NotificationId{ .bytes = bytes };
    }
};

pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const TaskState = enum(u8) {
    unspecified = 0,
    queued = 1,
    starting = 2,
    running = 3,
    completed = 4,
    failed = 5,
    cancelled = 6,

    pub fn isTerminal(self: TaskState) bool {
        return switch (self) {
            .completed, .failed, .cancelled => true,
            else => false,
        };
    }

    pub fn canTransitionTo(self: TaskState, to: TaskState) bool {
        return switch (self) {
            .unspecified => to == .queued,
            .queued => to == .starting or to == .cancelled,
            .starting => to == .running or to == .failed or to == .cancelled,
            .running => to == .completed or to == .failed or to == .cancelled,
            .completed, .failed, .cancelled => false,
        };
    }
};

pub const UsageMetrics = struct {
    compute_time_ms: i64 = 0,
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    cache_read_tokens: i64 = 0,
    cache_write_tokens: i64 = 0,
    tool_calls: i64 = 0,

    pub fn add(self: *UsageMetrics, other: UsageMetrics) void {
        self.compute_time_ms += other.compute_time_ms;
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.cache_read_tokens += other.cache_read_tokens;
        self.cache_write_tokens += other.cache_write_tokens;
        self.tool_calls += other.tool_calls;
    }
};

pub const Task = struct {
    allocator: std.mem.Allocator,
    id: TaskId,
    client_id: ClientId,
    state: TaskState,

    repo_url: []const u8,
    branch: []const u8,
    prompt: []const u8,

    node_id: ?NodeId,
    vm_id: ?VmId,

    created_at: i64,
    started_at: ?i64,
    completed_at: ?i64,

    error_message: ?[]const u8,
    pr_url: ?[]const u8,

    usage: UsageMetrics,

    create_pr: bool,
    pr_title: ?[]const u8,
    pr_body: ?[]const u8,
    github_token: ?[]const u8,

    // Team collaboration fields
    user_id: ?UserId,
    team_id: ?TeamId,
    workspace_id: ?WorkspaceId,

    env_vars: []const EnvVar = &[_]EnvVar{},
    max_iterations: ?u32 = null,
    completion_promise: ?[]const u8 = null,

    pub fn deinit(self: *Task) void {
        self.allocator.free(self.repo_url);
        self.allocator.free(self.branch);
        self.allocator.free(self.prompt);
        if (self.error_message) |msg| self.allocator.free(msg);
        if (self.pr_url) |url| self.allocator.free(url);
        if (self.pr_title) |title| self.allocator.free(title);
        if (self.pr_body) |body| self.allocator.free(body);
        if (self.github_token) |token| self.allocator.free(token);
    }

    pub fn init(
        allocator: std.mem.Allocator,
        client_id: ClientId,
        repo_url: []const u8,
        branch: []const u8,
        prompt: []const u8,
    ) !Task {
        var id: TaskId = undefined;
        std.crypto.random.bytes(&id);

        return .{
            .allocator = allocator,
            .id = id,
            .client_id = client_id,
            .state = .queued,
            .repo_url = try allocator.dupe(u8, repo_url),
            .branch = try allocator.dupe(u8, branch),
            .prompt = try allocator.dupe(u8, prompt),
            .node_id = null,
            .vm_id = null,
            .created_at = std.time.milliTimestamp(),
            .started_at = null,
            .completed_at = null,
            .error_message = null,
            .pr_url = null,
            .usage = .{},
            .create_pr = false,
            .pr_title = null,
            .pr_body = null,
            .github_token = null,
            .user_id = null,
            .team_id = null,
            .workspace_id = null,
        };
    }
};

pub const NodeStatus = struct {
    node_id: NodeId,
    hostname: []const u8,

    total_vm_slots: u32,
    active_vms: u32,
    warm_vms: u32,

    cpu_usage: f64,
    memory_usage: f64,
    disk_available_bytes: i64,

    healthy: bool,
    draining: bool,
    uptime_seconds: i64,
    last_task_at: ?i64,

    active_task_ids: []TaskId,

    pub fn availableSlots(self: NodeStatus) u32 {
        if (self.active_vms >= self.total_vm_slots) return 0;
        return self.total_vm_slots - self.active_vms;
    }

    pub fn score(self: NodeStatus) f64 {
        if (!self.healthy or self.draining) return 0.0;
        if (self.availableSlots() == 0) return 0.0;

        const slot_factor = @as(f64, @floatFromInt(self.availableSlots())) /
            @as(f64, @floatFromInt(self.total_vm_slots));
        const warm_factor = @as(f64, @floatFromInt(self.warm_vms)) /
            @as(f64, @floatFromInt(@max(self.total_vm_slots, 1)));
        const cpu_factor = 1.0 - self.cpu_usage;
        const mem_factor = 1.0 - self.memory_usage;

        return (slot_factor * 0.3) + (warm_factor * 0.4) + (cpu_factor * 0.15) + (mem_factor * 0.15);
    }
};

pub const OutputType = enum(u8) {
    unspecified = 0,
    stdout = 1,
    stderr = 2,
    claude = 3,
};

pub fn formatId(id: anytype) [id.len * 2]u8 {
    const hex = "0123456789abcdef";
    var result: [id.len * 2]u8 = undefined;
    for (id, 0..) |byte, i| {
        result[i * 2] = hex[byte >> 4];
        result[i * 2 + 1] = hex[byte & 0x0f];
    }
    return result;
}

pub fn parseId(comptime T: type, hex: []const u8) !T {
    if (hex.len != @typeInfo(T).array.len * 2) return error.InvalidIdLength;
    var result: T = undefined;
    for (0..result.len) |i| {
        const high = try hexDigit(hex[i * 2]);
        const low = try hexDigit(hex[i * 2 + 1]);
        result[i] = (@as(u8, high) << 4) | low;
    }
    return result;
}

fn hexDigit(c: u8) !u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => error.InvalidHexDigit,
    };
}

test "task state transitions" {
    const state = TaskState.queued;
    try std.testing.expect(state.canTransitionTo(.starting));
    try std.testing.expect(state.canTransitionTo(.cancelled));
    try std.testing.expect(!state.canTransitionTo(.completed));
}

test "node score calculation" {
    const status = NodeStatus{
        .node_id = [_]u8{0} ** 16,
        .hostname = "test-node",
        .total_vm_slots = 10,
        .active_vms = 3,
        .warm_vms = 5,
        .cpu_usage = 0.5,
        .memory_usage = 0.4,
        .disk_available_bytes = 100_000_000_000,
        .healthy = true,
        .draining = false,
        .uptime_seconds = 3600,
        .last_task_at = null,
        .active_task_ids = &[_]TaskId{},
    };

    const score = status.score();
    try std.testing.expect(score > 0.0);
    try std.testing.expect(score <= 1.0);
}

test "id formatting" {
    const id = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const formatted = formatId(id);
    try std.testing.expectEqualStrings("deadbeef", &formatted);
}

test "user id generation" {
    const id1 = UserId.init();
    const id2 = UserId.init();
    
    // IDs should be different
    try std.testing.expect(!std.mem.eql(u8, &id1.bytes, &id2.bytes));
    
    // Formatting should work
    const formatted = id1.format();
    try std.testing.expectEqual(@as(usize, 32), formatted.len);
}