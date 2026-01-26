const std = @import("std");
const common = @import("common");
const types = common.types;
const pool = @import("../pool.zig");
const db_types = @import("../types.zig");
const errors = @import("../errors.zig");

const DbError = errors.DbError;
const Param = db_types.Param;
const log = std.log.scoped(.task_repo);

pub const TaskRepository = struct {
    db_pool: *pool.Pool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db_pool: *pool.Pool) TaskRepository {
        return .{
            .db_pool = db_pool,
            .allocator = allocator,
        };
    }

    pub fn create(self: *TaskRepository, task: *const types.Task) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .bytea = &task.id },
            .{ .bytea = &task.client_id },
            .{ .i16 = @intFromEnum(task.state) },
            .{ .text = task.repo_url },
            .{ .text = task.branch },
            .{ .text = task.prompt },
            if (task.node_id) |*id| .{ .bytea = id } else .null,
            if (task.vm_id) |*id| .{ .bytea = id } else .null,
            .{ .i64 = task.created_at },
            db_types.optional(i64, task.started_at),
            db_types.optional(i64, task.completed_at),
            if (task.error_message) |msg| .{ .text = msg } else .null,
            if (task.pr_url) |url| .{ .text = url } else .null,
            .{ .i64 = task.usage.compute_time_ms },
            .{ .i64 = task.usage.input_tokens },
            .{ .i64 = task.usage.output_tokens },
            .{ .i64 = task.usage.cache_read_tokens },
            .{ .i64 = task.usage.cache_write_tokens },
            .{ .i64 = task.usage.tool_calls },
            .{ .bool = task.create_pr },
            if (task.pr_title) |t| .{ .text = t } else .null,
            if (task.pr_body) |b| .{ .text = b } else .null,
        };

        _ = conn.execParams(
            \\INSERT INTO tasks (
            \\    id, client_id, state, repo_url, branch, prompt,
            \\    node_id, vm_id, created_at, started_at, completed_at,
            \\    error_message, pr_url, compute_time_ms, input_tokens,
            \\    output_tokens, cache_read_tokens, cache_write_tokens,
            \\    tool_calls, create_pr, pr_title, pr_body
            \\) VALUES (
            \\    $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11,
            \\    $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22
            \\)
        , &params) catch |err| {
            log.err("create task failed: task_id={s} error={}", .{ &types.formatId(task.id), err });
            return err;
        };

        log.info("task created: task_id={s}", .{&types.formatId(task.id)});
    }

    pub fn get(self: *TaskRepository, task_id: types.TaskId) !?types.Task {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{.{ .bytea = &task_id }};
        var result = try conn.queryParams(
            \\SELECT id, client_id, state, repo_url, branch, prompt,
            \\       node_id, vm_id, created_at, started_at, completed_at,
            \\       error_message, pr_url, compute_time_ms, input_tokens,
            \\       output_tokens, cache_read_tokens, cache_write_tokens,
            \\       tool_calls, create_pr, pr_title, pr_body
            \\FROM tasks WHERE id = $1
        , &params);
        defer result.deinit();

        if (result.first()) |row| {
            return try self.rowToTask(row);
        }
        return null;
    }

    pub fn updateState(self: *TaskRepository, task_id: types.TaskId, state: types.TaskState) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .i16 = @intFromEnum(state) },
            .{ .bytea = &task_id },
        };

        const affected = try conn.execParams(
            "UPDATE tasks SET state = $1 WHERE id = $2",
            &params,
        );

        if (affected == 0) {
            log.warn("updateState: task not found: task_id={s}", .{&types.formatId(task_id)});
        }
    }

    pub fn updateStarted(self: *TaskRepository, task_id: types.TaskId, node_id: types.NodeId) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .i16 = @intFromEnum(types.TaskState.starting) },
            .{ .bytea = &node_id },
            .{ .i64 = std.time.milliTimestamp() },
            .{ .bytea = &task_id },
        };

        _ = try conn.execParams(
            "UPDATE tasks SET state = $1, node_id = $2, started_at = $3 WHERE id = $4",
            &params,
        );
    }

    pub fn complete(
        self: *TaskRepository,
        task_id: types.TaskId,
        state: types.TaskState,
        usage: types.UsageMetrics,
        error_message: ?[]const u8,
        pr_url: ?[]const u8,
    ) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .i16 = @intFromEnum(state) },
            .{ .i64 = std.time.milliTimestamp() },
            .{ .i64 = usage.compute_time_ms },
            .{ .i64 = usage.input_tokens },
            .{ .i64 = usage.output_tokens },
            .{ .i64 = usage.cache_read_tokens },
            .{ .i64 = usage.cache_write_tokens },
            .{ .i64 = usage.tool_calls },
            if (error_message) |msg| .{ .text = msg } else .null,
            if (pr_url) |url| .{ .text = url } else .null,
            .{ .bytea = &task_id },
        };

        _ = try conn.execParams(
            \\UPDATE tasks SET
            \\    state = $1,
            \\    completed_at = $2,
            \\    compute_time_ms = $3,
            \\    input_tokens = $4,
            \\    output_tokens = $5,
            \\    cache_read_tokens = $6,
            \\    cache_write_tokens = $7,
            \\    tool_calls = $8,
            \\    error_message = $9,
            \\    pr_url = $10
            \\WHERE id = $11
        , &params);

        log.info("task completed: task_id={s} state={s}", .{ &types.formatId(task_id), @tagName(state) });
    }

    pub fn listByClient(self: *TaskRepository, client_id: types.ClientId, limit: u32, offset: u32) ![]types.Task {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .bytea = &client_id },
            .{ .i32 = @intCast(limit) },
            .{ .i32 = @intCast(offset) },
        };

        var result = try conn.queryParams(
            \\SELECT id, client_id, state, repo_url, branch, prompt,
            \\       node_id, vm_id, created_at, started_at, completed_at,
            \\       error_message, pr_url, compute_time_ms, input_tokens,
            \\       output_tokens, cache_read_tokens, cache_write_tokens,
            \\       tool_calls, create_pr, pr_title, pr_body
            \\FROM tasks WHERE client_id = $1
            \\ORDER BY created_at DESC
            \\LIMIT $2 OFFSET $3
        , &params);
        defer result.deinit();

        return self.rowsToTasks(result.rows);
    }

    pub fn listQueued(self: *TaskRepository, limit: u32) ![]types.Task {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .i16 = @intFromEnum(types.TaskState.queued) },
            .{ .i32 = @intCast(limit) },
        };

        var result = try conn.queryParams(
            \\SELECT id, client_id, state, repo_url, branch, prompt,
            \\       node_id, vm_id, created_at, started_at, completed_at,
            \\       error_message, pr_url, compute_time_ms, input_tokens,
            \\       output_tokens, cache_read_tokens, cache_write_tokens,
            \\       tool_calls, create_pr, pr_title, pr_body
            \\FROM tasks WHERE state = $1
            \\ORDER BY created_at ASC
            \\LIMIT $2
        , &params);
        defer result.deinit();

        return self.rowsToTasks(result.rows);
    }

    pub fn countByState(self: *TaskRepository, state: types.TaskState) !u64 {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{.{ .i16 = @intFromEnum(state) }};
        var result = try conn.queryParams("SELECT COUNT(*) FROM tasks WHERE state = $1", &params);
        defer result.deinit();

        if (result.first()) |row| {
            return @intCast(row.getI64(0) orelse 0);
        }
        return 0;
    }

    fn rowToTask(self: *TaskRepository, row: db_types.Row) !types.Task {
        var task = types.Task{
            .allocator = self.allocator,
            .id = undefined,
            .client_id = undefined,
            .state = @enumFromInt(@as(u8, @intCast(row.getI32(2) orelse 1))),
            .repo_url = try self.allocator.dupe(u8, row.getText(3) orelse ""),
            .branch = try self.allocator.dupe(u8, row.getText(4) orelse ""),
            .prompt = try self.allocator.dupe(u8, row.getText(5) orelse ""),
            .node_id = null,
            .vm_id = null,
            .created_at = row.getI64(8) orelse 0,
            .started_at = row.getOptionalI64(9) orelse null,
            .completed_at = row.getOptionalI64(10) orelse null,
            .error_message = null,
            .pr_url = null,
            .usage = .{
                .compute_time_ms = row.getI64(13) orelse 0,
                .input_tokens = row.getI64(14) orelse 0,
                .output_tokens = row.getI64(15) orelse 0,
                .cache_read_tokens = row.getI64(16) orelse 0,
                .cache_write_tokens = row.getI64(17) orelse 0,
                .tool_calls = row.getI64(18) orelse 0,
            },
            .create_pr = row.getBool(19) orelse false,
            .pr_title = null,
            .pr_body = null,
        };

        if (row.getBytea(0)) |id| {
            if (id.len == 32) @memcpy(&task.id, id);
        }
        if (row.getBytea(1)) |id| {
            if (id.len == 16) @memcpy(&task.client_id, id);
        }
        if (row.getOptionalBytea(6) orelse null) |id| {
            if (id.len == 16) {
                task.node_id = undefined;
                @memcpy(&task.node_id.?, id);
            }
        }
        if (row.getOptionalBytea(7) orelse null) |id| {
            if (id.len == 16) {
                task.vm_id = undefined;
                @memcpy(&task.vm_id.?, id);
            }
        }
        if (row.getOptionalText(11) orelse null) |msg| {
            task.error_message = try self.allocator.dupe(u8, msg);
        }
        if (row.getOptionalText(12) orelse null) |url| {
            task.pr_url = try self.allocator.dupe(u8, url);
        }
        if (row.getOptionalText(20) orelse null) |t| {
            task.pr_title = try self.allocator.dupe(u8, t);
        }
        if (row.getOptionalText(21) orelse null) |b| {
            task.pr_body = try self.allocator.dupe(u8, b);
        }

        return task;
    }

    fn rowsToTasks(self: *TaskRepository, rows: []db_types.Row) ![]types.Task {
        var tasks = try self.allocator.alloc(types.Task, rows.len);
        errdefer self.allocator.free(tasks);

        var i: usize = 0;
        for (rows) |row| {
            tasks[i] = try self.rowToTask(row);
            i += 1;
        }

        return tasks;
    }
};

test "task state enum conversion" {
    const state = types.TaskState.queued;
    const int_val: i16 = @intFromEnum(state);
    try std.testing.expectEqual(@as(i16, 1), int_val);

    const back: types.TaskState = @enumFromInt(@as(u8, @intCast(int_val)));
    try std.testing.expectEqual(types.TaskState.queued, back);
}
