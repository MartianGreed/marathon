const std = @import("std");
const common = @import("common");
const types = common.types;

const log = std.log.scoped(.metering);

pub const Metering = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(UsageRecord),
    client_totals: std.AutoHashMap(types.ClientId, types.UsageMetrics),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) Metering {
        return .{
            .allocator = allocator,
            .records = .empty,
            .client_totals = std.AutoHashMap(types.ClientId, types.UsageMetrics).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Metering) void {
        self.records.deinit(self.allocator);
        self.client_totals.deinit();
    }

    pub fn recordUsage(self: *Metering, record: UsageRecord) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.records.append(self.allocator, record);

        const entry = try self.client_totals.getOrPut(record.client_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
        }
        entry.value_ptr.add(record.usage);

        log.info("usage recorded: task_id={s} input_tokens={d} output_tokens={d}", .{
            &types.formatId(record.task_id),
            record.usage.input_tokens,
            record.usage.output_tokens,
        });
    }

    pub fn getClientTotal(self: *Metering, client_id: types.ClientId) types.UsageMetrics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.client_totals.get(client_id) orelse .{};
    }

    pub fn getUsageReport(
        self: *Metering,
        client_id: types.ClientId,
        start_time: i64,
        end_time: i64,
    ) !UsageReport {
        self.mutex.lock();
        defer self.mutex.unlock();

        var total = types.UsageMetrics{};
        var task_records: std.ArrayListUnmanaged(TaskUsageRecord) = .empty;
        errdefer task_records.deinit(self.allocator);

        for (self.records.items) |record| {
            if (!std.mem.eql(u8, &record.client_id, &client_id)) continue;
            if (record.timestamp < start_time or record.timestamp > end_time) continue;

            total.add(record.usage);
            try task_records.append(self.allocator, .{
                .task_id = record.task_id,
                .timestamp = record.timestamp,
                .usage = record.usage,
            });
        }

        return .{
            .client_id = client_id,
            .start_time = start_time,
            .end_time = end_time,
            .total = total,
            .tasks = try task_records.toOwnedSlice(self.allocator),
        };
    }

    pub fn pruneOlderThan(self: *Metering, timestamp: i64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.records.items.len) {
            if (self.records.items[i].timestamp < timestamp) {
                _ = self.records.orderedRemove(i);
                removed += 1;
            } else {
                i += 1;
            }
        }
        return removed;
    }
};

pub const UsageRecord = struct {
    client_id: types.ClientId,
    task_id: types.TaskId,
    timestamp: i64,
    usage: types.UsageMetrics,
};

pub const TaskUsageRecord = struct {
    task_id: types.TaskId,
    timestamp: i64,
    usage: types.UsageMetrics,
};

pub const UsageReport = struct {
    client_id: types.ClientId,
    start_time: i64,
    end_time: i64,
    total: types.UsageMetrics,
    tasks: []TaskUsageRecord,
};

test "metering basic operations" {
    const allocator = std.testing.allocator;

    var meter = Metering.init(allocator);
    defer meter.deinit();

    var client_id: types.ClientId = undefined;
    @memset(&client_id, 1);

    var task_id: types.TaskId = undefined;
    @memset(&task_id, 2);

    const record = UsageRecord{
        .client_id = client_id,
        .task_id = task_id,
        .timestamp = std.time.milliTimestamp(),
        .usage = .{
            .compute_time_ms = 1000,
            .input_tokens = 100,
            .output_tokens = 50,
            .cache_read_tokens = 0,
            .cache_write_tokens = 0,
            .tool_calls = 5,
        },
    };

    try meter.recordUsage(record);

    const total = meter.getClientTotal(client_id);
    try std.testing.expectEqual(@as(i64, 100), total.input_tokens);
    try std.testing.expectEqual(@as(i64, 50), total.output_tokens);
}

test "metering getUsageReport with time range" {
    const allocator = std.testing.allocator;

    var meter = Metering.init(allocator);
    defer meter.deinit();

    var client_id: types.ClientId = undefined;
    @memset(&client_id, 1);

    const base_time = std.time.milliTimestamp();

    for (0..3) |i| {
        var task_id: types.TaskId = undefined;
        @memset(&task_id, @intCast(i));

        const record = UsageRecord{
            .client_id = client_id,
            .task_id = task_id,
            .timestamp = base_time + @as(i64, @intCast(i * 1000)),
            .usage = .{
                .compute_time_ms = 100,
                .input_tokens = 10,
                .output_tokens = 5,
                .cache_read_tokens = 0,
                .cache_write_tokens = 0,
                .tool_calls = 1,
            },
        };
        try meter.recordUsage(record);
    }

    const report = try meter.getUsageReport(client_id, base_time - 1, base_time + 5000);
    defer allocator.free(report.tasks);

    try std.testing.expectEqual(@as(usize, 3), report.tasks.len);
    try std.testing.expectEqual(@as(i64, 30), report.total.input_tokens);
    try std.testing.expectEqual(@as(i64, 15), report.total.output_tokens);
}

test "metering getUsageReport filters by client" {
    const allocator = std.testing.allocator;

    var meter = Metering.init(allocator);
    defer meter.deinit();

    var client1: types.ClientId = undefined;
    @memset(&client1, 1);

    var client2: types.ClientId = undefined;
    @memset(&client2, 2);

    var task_id: types.TaskId = undefined;
    @memset(&task_id, 0);

    const now = std.time.milliTimestamp();

    try meter.recordUsage(.{
        .client_id = client1,
        .task_id = task_id,
        .timestamp = now,
        .usage = .{ .compute_time_ms = 100, .input_tokens = 100, .output_tokens = 50, .cache_read_tokens = 0, .cache_write_tokens = 0, .tool_calls = 1 },
    });

    try meter.recordUsage(.{
        .client_id = client2,
        .task_id = task_id,
        .timestamp = now,
        .usage = .{ .compute_time_ms = 200, .input_tokens = 200, .output_tokens = 100, .cache_read_tokens = 0, .cache_write_tokens = 0, .tool_calls = 2 },
    });

    const report1 = try meter.getUsageReport(client1, now - 1000, now + 1000);
    defer allocator.free(report1.tasks);
    try std.testing.expectEqual(@as(i64, 100), report1.total.input_tokens);

    const report2 = try meter.getUsageReport(client2, now - 1000, now + 1000);
    defer allocator.free(report2.tasks);
    try std.testing.expectEqual(@as(i64, 200), report2.total.input_tokens);
}

test "metering pruneOlderThan removes old records" {
    const allocator = std.testing.allocator;

    var meter = Metering.init(allocator);
    defer meter.deinit();

    var client_id: types.ClientId = undefined;
    @memset(&client_id, 1);

    var task_id: types.TaskId = undefined;
    @memset(&task_id, 0);

    const old_time: i64 = 1000;
    const new_time: i64 = 5000;

    try meter.recordUsage(.{
        .client_id = client_id,
        .task_id = task_id,
        .timestamp = old_time,
        .usage = .{ .compute_time_ms = 100, .input_tokens = 10, .output_tokens = 5, .cache_read_tokens = 0, .cache_write_tokens = 0, .tool_calls = 1 },
    });

    try meter.recordUsage(.{
        .client_id = client_id,
        .task_id = task_id,
        .timestamp = new_time,
        .usage = .{ .compute_time_ms = 100, .input_tokens = 20, .output_tokens = 10, .cache_read_tokens = 0, .cache_write_tokens = 0, .tool_calls = 1 },
    });

    const removed = meter.pruneOlderThan(3000);
    try std.testing.expectEqual(@as(usize, 1), removed);

    const report = try meter.getUsageReport(client_id, 0, 10000);
    defer allocator.free(report.tasks);
    try std.testing.expectEqual(@as(usize, 1), report.tasks.len);
    try std.testing.expectEqual(@as(i64, 20), report.total.input_tokens);
}

test "metering accumulates totals across multiple records" {
    const allocator = std.testing.allocator;

    var meter = Metering.init(allocator);
    defer meter.deinit();

    var client_id: types.ClientId = undefined;
    @memset(&client_id, 1);

    for (0..5) |i| {
        var task_id: types.TaskId = undefined;
        @memset(&task_id, @intCast(i));

        try meter.recordUsage(.{
            .client_id = client_id,
            .task_id = task_id,
            .timestamp = std.time.milliTimestamp(),
            .usage = .{
                .compute_time_ms = 100,
                .input_tokens = 10,
                .output_tokens = 5,
                .cache_read_tokens = 2,
                .cache_write_tokens = 1,
                .tool_calls = 3,
            },
        });
    }

    const total = meter.getClientTotal(client_id);
    try std.testing.expectEqual(@as(i64, 500), total.compute_time_ms);
    try std.testing.expectEqual(@as(i64, 50), total.input_tokens);
    try std.testing.expectEqual(@as(i64, 25), total.output_tokens);
    try std.testing.expectEqual(@as(i64, 10), total.cache_read_tokens);
    try std.testing.expectEqual(@as(i64, 5), total.cache_write_tokens);
    try std.testing.expectEqual(@as(i64, 15), total.tool_calls);
}
