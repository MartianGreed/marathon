const std = @import("std");
const common = @import("common");
const types = common.types;

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
