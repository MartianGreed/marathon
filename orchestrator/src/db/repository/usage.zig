const std = @import("std");
const common = @import("common");
const types = common.types;
const pool = @import("../pool.zig");
const db_types = @import("../types.zig");
const errors = @import("../errors.zig");

const Param = db_types.Param;
const log = std.log.scoped(.usage_repo);

pub const UsageRepository = struct {
    db_pool: *pool.Pool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db_pool: *pool.Pool) UsageRepository {
        return .{
            .db_pool = db_pool,
            .allocator = allocator,
        };
    }

    pub fn recordUsage(self: *UsageRepository, usage_record: UsageRecord) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .bytea = &usage_record.client_id },
            .{ .bytea = &usage_record.task_id },
            .{ .i64 = usage_record.timestamp },
            .{ .i64 = usage_record.usage.compute_time_ms },
            .{ .i64 = usage_record.usage.input_tokens },
            .{ .i64 = usage_record.usage.output_tokens },
            .{ .i64 = usage_record.usage.cache_read_tokens },
            .{ .i64 = usage_record.usage.cache_write_tokens },
            .{ .i64 = usage_record.usage.tool_calls },
        };

        _ = conn.execParams(
            \\INSERT INTO usage_records (
            \\    client_id, task_id, timestamp,
            \\    compute_time_ms, input_tokens, output_tokens,
            \\    cache_read_tokens, cache_write_tokens, tool_calls
            \\) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        , &params) catch |err| {
            log.err("record usage failed: task_id={s} error={}", .{ &types.formatId(usage_record.task_id), err });
            return err;
        };

        log.debug("usage recorded: task_id={s} tokens={d}+{d}", .{
            &types.formatId(usage_record.task_id),
            usage_record.usage.input_tokens,
            usage_record.usage.output_tokens,
        });
    }

    pub fn getClientTotal(self: *UsageRepository, client_id: types.ClientId) !types.UsageMetrics {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{.{ .bytea = &client_id }};
        var result = try conn.queryParams(
            \\SELECT
            \\    COALESCE(SUM(compute_time_ms), 0),
            \\    COALESCE(SUM(input_tokens), 0),
            \\    COALESCE(SUM(output_tokens), 0),
            \\    COALESCE(SUM(cache_read_tokens), 0),
            \\    COALESCE(SUM(cache_write_tokens), 0),
            \\    COALESCE(SUM(tool_calls), 0)
            \\FROM usage_records WHERE client_id = $1
        , &params);
        defer result.deinit();

        if (result.first()) |row| {
            return .{
                .compute_time_ms = row.getI64(0) orelse 0,
                .input_tokens = row.getI64(1) orelse 0,
                .output_tokens = row.getI64(2) orelse 0,
                .cache_read_tokens = row.getI64(3) orelse 0,
                .cache_write_tokens = row.getI64(4) orelse 0,
                .tool_calls = row.getI64(5) orelse 0,
            };
        }
        return .{};
    }

    pub fn getReport(
        self: *UsageRepository,
        client_id: types.ClientId,
        start_time: i64,
        end_time: i64,
    ) !UsageReport {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var total_params = [_]Param{
            .{ .bytea = &client_id },
            .{ .i64 = start_time },
            .{ .i64 = end_time },
        };

        var total_result = try conn.queryParams(
            \\SELECT
            \\    COALESCE(SUM(compute_time_ms), 0),
            \\    COALESCE(SUM(input_tokens), 0),
            \\    COALESCE(SUM(output_tokens), 0),
            \\    COALESCE(SUM(cache_read_tokens), 0),
            \\    COALESCE(SUM(cache_write_tokens), 0),
            \\    COALESCE(SUM(tool_calls), 0)
            \\FROM usage_records
            \\WHERE client_id = $1 AND timestamp >= $2 AND timestamp <= $3
        , &total_params);
        defer total_result.deinit();

        var total = types.UsageMetrics{};
        if (total_result.first()) |row| {
            total = .{
                .compute_time_ms = row.getI64(0) orelse 0,
                .input_tokens = row.getI64(1) orelse 0,
                .output_tokens = row.getI64(2) orelse 0,
                .cache_read_tokens = row.getI64(3) orelse 0,
                .cache_write_tokens = row.getI64(4) orelse 0,
                .tool_calls = row.getI64(5) orelse 0,
            };
        }

        var detail_params = [_]Param{
            .{ .bytea = &client_id },
            .{ .i64 = start_time },
            .{ .i64 = end_time },
        };

        var detail_result = try conn.queryParams(
            \\SELECT task_id, timestamp, compute_time_ms, input_tokens,
            \\       output_tokens, cache_read_tokens, cache_write_tokens, tool_calls
            \\FROM usage_records
            \\WHERE client_id = $1 AND timestamp >= $2 AND timestamp <= $3
            \\ORDER BY timestamp DESC
        , &detail_params);
        defer detail_result.deinit();

        var tasks = std.ArrayList(TaskUsageRecord).init(self.allocator);
        errdefer tasks.deinit();

        for (detail_result.rows) |row| {
            var task_id: types.TaskId = undefined;
            if (row.getBytea(0)) |id| {
                if (id.len == 32) @memcpy(&task_id, id);
            }

            try tasks.append(.{
                .task_id = task_id,
                .timestamp = row.getI64(1) orelse 0,
                .usage = .{
                    .compute_time_ms = row.getI64(2) orelse 0,
                    .input_tokens = row.getI64(3) orelse 0,
                    .output_tokens = row.getI64(4) orelse 0,
                    .cache_read_tokens = row.getI64(5) orelse 0,
                    .cache_write_tokens = row.getI64(6) orelse 0,
                    .tool_calls = row.getI64(7) orelse 0,
                },
            });
        }

        return .{
            .client_id = client_id,
            .start_time = start_time,
            .end_time = end_time,
            .total = total,
            .tasks = try tasks.toOwnedSlice(),
        };
    }

    pub fn pruneOlderThan(self: *UsageRepository, timestamp: i64) !u64 {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{.{ .i64 = timestamp }};
        const affected = try conn.execParams(
            "DELETE FROM usage_records WHERE timestamp < $1",
            &params,
        );

        if (affected > 0) {
            log.info("pruned {d} old usage records", .{affected});
        }

        return affected;
    }

    pub fn getDailyTotals(
        self: *UsageRepository,
        client_id: types.ClientId,
        days: u32,
    ) ![]DailyUsage {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        const cutoff = std.time.milliTimestamp() - @as(i64, @intCast(days)) * 24 * 60 * 60 * 1000;

        var params = [_]Param{
            .{ .bytea = &client_id },
            .{ .i64 = cutoff },
        };

        var result = try conn.queryParams(
            \\SELECT
            \\    (timestamp / 86400000) * 86400000 as day,
            \\    SUM(compute_time_ms),
            \\    SUM(input_tokens),
            \\    SUM(output_tokens),
            \\    SUM(cache_read_tokens),
            \\    SUM(cache_write_tokens),
            \\    SUM(tool_calls)
            \\FROM usage_records
            \\WHERE client_id = $1 AND timestamp >= $2
            \\GROUP BY day
            \\ORDER BY day DESC
        , &params);
        defer result.deinit();

        var daily = std.ArrayList(DailyUsage).init(self.allocator);
        errdefer daily.deinit();

        for (result.rows) |row| {
            try daily.append(.{
                .date = row.getI64(0) orelse 0,
                .usage = .{
                    .compute_time_ms = row.getI64(1) orelse 0,
                    .input_tokens = row.getI64(2) orelse 0,
                    .output_tokens = row.getI64(3) orelse 0,
                    .cache_read_tokens = row.getI64(4) orelse 0,
                    .cache_write_tokens = row.getI64(5) orelse 0,
                    .tool_calls = row.getI64(6) orelse 0,
                },
            });
        }

        return daily.toOwnedSlice();
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

pub const DailyUsage = struct {
    date: i64,
    usage: types.UsageMetrics,
};

test "usage record structure" {
    var client_id: types.ClientId = undefined;
    @memset(&client_id, 0x01);
    var task_id: types.TaskId = undefined;
    @memset(&task_id, 0x02);

    const record = UsageRecord{
        .client_id = client_id,
        .task_id = task_id,
        .timestamp = std.time.milliTimestamp(),
        .usage = .{
            .compute_time_ms = 1000,
            .input_tokens = 100,
            .output_tokens = 50,
            .cache_read_tokens = 10,
            .cache_write_tokens = 5,
            .tool_calls = 3,
        },
    };

    try std.testing.expectEqual(@as(i64, 1000), record.usage.compute_time_ms);
    try std.testing.expectEqual(@as(i64, 100), record.usage.input_tokens);
}
