const std = @import("std");

pub const TaskId = [32]u8;
pub const NodeId = [16]u8;
pub const VmId = [16]u8;
pub const ClientId = [16]u8;

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

        return (slot_factor * 0.4) + (warm_factor * 0.3) + (cpu_factor * 0.15) + (mem_factor * 0.15);
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
        result[i] = (high << 4) | low;
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
