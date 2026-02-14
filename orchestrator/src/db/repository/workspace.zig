const std = @import("std");
const common = @import("common");
const types = common.types;
const pool = @import("../pool.zig");
const db_types = @import("../types.zig");
const errors = @import("../errors.zig");

const DbError = errors.DbError;
const Param = db_types.Param;
const log = std.log.scoped(.workspace_repo);

pub const WorkspaceRepository = struct {
    db_pool: *pool.Pool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db_pool: *pool.Pool) WorkspaceRepository {
        return .{
            .db_pool = db_pool,
            .allocator = allocator,
        };
    }

    pub fn create(self: *WorkspaceRepository, workspace: *const types.Workspace) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .bytea = &workspace.id },
            .{ .text = workspace.name },
            if (workspace.description) |desc| .{ .text = desc } else .null,
            .{ .bytea = &workspace.user_id },
            if (workspace.template) |tmpl| .{ .text = tmpl } else .null,
            .{ .text = workspace.settings },
            .{ .i64 = workspace.created_at },
            .{ .i64 = workspace.updated_at },
            .{ .i64 = workspace.last_accessed_at },
        };

        _ = conn.execParams(
            \\INSERT INTO workspaces (
            \\    id, name, description, user_id, template, settings,
            \\    created_at, updated_at, last_accessed_at
            \\) VALUES (
            \\    $1, $2, $3, $4, $5, $6, $7, $8, $9
            \\)
        , &params) catch |err| {
            log.err("create workspace failed: workspace_id={s} error={}", .{ &types.formatId(workspace.id), err });
            return err;
        };

        log.info("workspace created: workspace_id={s} name={s}", .{ &types.formatId(workspace.id), workspace.name });
    }

    pub fn get(self: *WorkspaceRepository, workspace_id: types.WorkspaceId) !?types.Workspace {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{.{ .bytea = &workspace_id }};
        var result = try conn.queryParams(
            \\SELECT id, name, description, user_id, template, settings,
            \\       created_at, updated_at, last_accessed_at
            \\FROM workspaces WHERE id = $1
        , &params);
        defer result.deinit();

        if (result.first()) |row| {
            return try self.rowToWorkspace(row);
        }
        return null;
    }

    pub fn getByNameAndUser(self: *WorkspaceRepository, name: []const u8, user_id: types.UserId) !?types.Workspace {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .text = name },
            .{ .bytea = &user_id },
        };
        var result = try conn.queryParams(
            \\SELECT id, name, description, user_id, template, settings,
            \\       created_at, updated_at, last_accessed_at
            \\FROM workspaces WHERE name = $1 AND user_id = $2
        , &params);
        defer result.deinit();

        if (result.first()) |row| {
            return try self.rowToWorkspace(row);
        }
        return null;
    }

    pub fn listByUser(self: *WorkspaceRepository, user_id: types.UserId, limit: u32, offset: u32) ![]types.WorkspaceSummary {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .bytea = &user_id },
            .{ .i32 = @intCast(limit) },
            .{ .i32 = @intCast(offset) },
        };

        var result = try conn.queryParams(
            \\SELECT w.id, w.name, w.description, w.template, w.created_at, w.last_accessed_at,
            \\       COUNT(t.id) as task_count,
            \\       CASE WHEN uaw.workspace_id IS NOT NULL THEN true ELSE false END as is_active
            \\FROM workspaces w
            \\LEFT JOIN tasks t ON w.id = t.workspace_id
            \\LEFT JOIN user_active_workspaces uaw ON uaw.workspace_id = w.id
            \\WHERE w.user_id = $1
            \\GROUP BY w.id, w.name, w.description, w.template, w.created_at, w.last_accessed_at, uaw.workspace_id
            \\ORDER BY w.last_accessed_at DESC
            \\LIMIT $2 OFFSET $3
        , &params);
        defer result.deinit();

        return self.rowsToWorkspaceSummaries(result.rows);
    }

    pub fn update(self: *WorkspaceRepository, workspace: *const types.Workspace) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .text = workspace.name },
            if (workspace.description) |desc| .{ .text = desc } else .null,
            .{ .text = workspace.settings },
            .{ .i64 = workspace.updated_at },
            .{ .bytea = &workspace.id },
        };

        const affected = try conn.execParams(
            \\UPDATE workspaces SET
            \\    name = $1,
            \\    description = $2,
            \\    settings = $3,
            \\    updated_at = $4
            \\WHERE id = $5
        , &params);

        if (affected == 0) {
            log.warn("update: workspace not found: workspace_id={s}", .{&types.formatId(workspace.id)});
        } else {
            log.info("workspace updated: workspace_id={s}", .{&types.formatId(workspace.id)});
        }
    }

    pub fn updateLastAccessed(self: *WorkspaceRepository, workspace_id: types.WorkspaceId, timestamp: i64) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .i64 = timestamp },
            .{ .bytea = &workspace_id },
        };

        _ = try conn.execParams(
            "UPDATE workspaces SET last_accessed_at = $1 WHERE id = $2",
            &params,
        );
    }

    pub fn delete(self: *WorkspaceRepository, workspace_id: types.WorkspaceId) !bool {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{.{ .bytea = &workspace_id }};

        const affected = try conn.execParams(
            "DELETE FROM workspaces WHERE id = $1",
            &params,
        );

        if (affected > 0) {
            log.info("workspace deleted: workspace_id={s}", .{&types.formatId(workspace_id)});
            return true;
        }
        return false;
    }

    pub fn setActiveWorkspace(self: *WorkspaceRepository, user_id: types.UserId, workspace_id: types.WorkspaceId) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .bytea = &user_id },
            .{ .bytea = &workspace_id },
            .{ .i64 = std.time.milliTimestamp() },
        };

        _ = try conn.execParams(
            \\INSERT INTO user_active_workspaces (user_id, workspace_id, updated_at)
            \\VALUES ($1, $2, $3)
            \\ON CONFLICT (user_id) DO UPDATE SET
            \\    workspace_id = EXCLUDED.workspace_id,
            \\    updated_at = EXCLUDED.updated_at
        , &params);

        // Also update last_accessed_at for the workspace
        try self.updateLastAccessed(workspace_id, std.time.milliTimestamp());

        log.info("active workspace set: user_id={s} workspace_id={s}", .{ &types.formatId(user_id), &types.formatId(workspace_id) });
    }

    pub fn getActiveWorkspace(self: *WorkspaceRepository, user_id: types.UserId) !?types.Workspace {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{.{ .bytea = &user_id }};
        var result = try conn.queryParams(
            \\SELECT w.id, w.name, w.description, w.user_id, w.template, w.settings,
            \\       w.created_at, w.updated_at, w.last_accessed_at
            \\FROM workspaces w
            \\JOIN user_active_workspaces uaw ON w.id = uaw.workspace_id
            \\WHERE uaw.user_id = $1
        , &params);
        defer result.deinit();

        if (result.first()) |row| {
            return try self.rowToWorkspace(row);
        }
        return null;
    }

    pub fn getWorkspaceEnvVars(self: *WorkspaceRepository, workspace_id: types.WorkspaceId) ![]types.EnvVar {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{.{ .bytea = &workspace_id }};
        var result = try conn.queryParams(
            "SELECT key, value FROM workspace_env_vars WHERE workspace_id = $1 ORDER BY key",
            &params,
        );
        defer result.deinit();

        var env_vars = try self.allocator.alloc(types.EnvVar, result.rowCount());
        errdefer self.allocator.free(env_vars);

        for (result.rows, 0..) |row, i| {
            env_vars[i] = .{
                .key = try self.allocator.dupe(u8, row.getText(0) orelse ""),
                .value = try self.allocator.dupe(u8, row.getText(1) orelse ""),
            };
        }

        return env_vars;
    }

    pub fn setWorkspaceEnvVar(self: *WorkspaceRepository, workspace_id: types.WorkspaceId, key: []const u8, value: []const u8) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var env_id: types.WorkspaceId = undefined;
        std.crypto.random.bytes(&env_id);

        var params = [_]Param{
            .{ .bytea = &env_id },
            .{ .bytea = &workspace_id },
            .{ .text = key },
            .{ .text = value },
            .{ .i64 = std.time.milliTimestamp() },
        };

        _ = try conn.execParams(
            \\INSERT INTO workspace_env_vars (id, workspace_id, key, value, created_at)
            \\VALUES ($1, $2, $3, $4, $5)
            \\ON CONFLICT (workspace_id, key) DO UPDATE SET
            \\    value = EXCLUDED.value
        , &params);
    }

    pub fn deleteWorkspaceEnvVar(self: *WorkspaceRepository, workspace_id: types.WorkspaceId, key: []const u8) !bool {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .bytea = &workspace_id },
            .{ .text = key },
        };

        const affected = try conn.execParams(
            "DELETE FROM workspace_env_vars WHERE workspace_id = $1 AND key = $2",
            &params,
        );

        return affected > 0;
    }

    pub fn getTemplates(self: *WorkspaceRepository) ![]types.WorkspaceTemplate {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var result = try conn.query(
            \\SELECT id, name, description, default_settings, default_env_vars, created_at
            \\FROM workspace_templates
            \\ORDER BY name
        );
        defer result.deinit();

        return self.rowsToWorkspaceTemplates(result.rows);
    }

    pub fn logActivity(self: *WorkspaceRepository, workspace_id: types.WorkspaceId, activity_type: []const u8, description: ?[]const u8, metadata: []const u8) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var activity_id: types.WorkspaceId = undefined;
        std.crypto.random.bytes(&activity_id);

        var params = [_]Param{
            .{ .bytea = &activity_id },
            .{ .bytea = &workspace_id },
            .{ .text = activity_type },
            if (description) |desc| .{ .text = desc } else .null,
            .{ .text = metadata },
            .{ .i64 = std.time.milliTimestamp() },
        };

        _ = try conn.execParams(
            \\INSERT INTO workspace_activity (id, workspace_id, activity_type, description, metadata, timestamp)
            \\VALUES ($1, $2, $3, $4, $5, $6)
        , &params);
    }

    fn rowToWorkspace(self: *WorkspaceRepository, row: db_types.Row) !types.Workspace {
        var workspace = types.Workspace{
            .id = undefined,
            .name = try self.allocator.dupe(u8, row.getText(1) orelse ""),
            .description = null,
            .user_id = undefined,
            .template = null,
            .settings = try self.allocator.dupe(u8, row.getText(5) orelse "{}"),
            .created_at = row.getI64(6) orelse 0,
            .updated_at = row.getI64(7) orelse 0,
            .last_accessed_at = row.getI64(8) orelse 0,
        };

        if (row.getBytea(0)) |id| {
            if (id.len == 16) @memcpy(&workspace.id, id);
        }
        if (row.getOptionalText(2) orelse null) |desc| {
            workspace.description = try self.allocator.dupe(u8, desc);
        }
        if (row.getBytea(3)) |id| {
            if (id.len == 16) @memcpy(&workspace.user_id, id);
        }
        if (row.getOptionalText(4) orelse null) |tmpl| {
            workspace.template = try self.allocator.dupe(u8, tmpl);
        }

        return workspace;
    }

    fn rowsToWorkspaceSummaries(self: *WorkspaceRepository, rows: []db_types.Row) ![]types.WorkspaceSummary {
        var summaries = try self.allocator.alloc(types.WorkspaceSummary, rows.len);
        errdefer self.allocator.free(summaries);

        for (rows, 0..) |row, i| {
            summaries[i] = types.WorkspaceSummary{
                .id = undefined,
                .name = try self.allocator.dupe(u8, row.getText(1) orelse ""),
                .description = null,
                .template = null,
                .created_at = row.getI64(4) orelse 0,
                .last_accessed_at = row.getI64(5) orelse 0,
                .task_count = @intCast(row.getI64(6) orelse 0),
                .is_active = row.getBool(7) orelse false,
            };

            if (row.getBytea(0)) |id| {
                if (id.len == 16) @memcpy(&summaries[i].id, id);
            }
            if (row.getOptionalText(2) orelse null) |desc| {
                summaries[i].description = try self.allocator.dupe(u8, desc);
            }
            if (row.getOptionalText(3) orelse null) |tmpl| {
                summaries[i].template = try self.allocator.dupe(u8, tmpl);
            }
        }

        return summaries;
    }

    fn rowsToWorkspaceTemplates(self: *WorkspaceRepository, rows: []db_types.Row) ![]types.WorkspaceTemplate {
        var templates = try self.allocator.alloc(types.WorkspaceTemplate, rows.len);
        errdefer self.allocator.free(templates);

        for (rows, 0..) |row, i| {
            templates[i] = types.WorkspaceTemplate{
                .id = undefined,
                .name = try self.allocator.dupe(u8, row.getText(1) orelse ""),
                .description = null,
                .default_settings = try self.allocator.dupe(u8, row.getText(3) orelse "{}"),
                .default_env_vars = try self.allocator.dupe(u8, row.getText(4) orelse "{}"),
                .created_at = row.getI64(5) orelse 0,
            };

            if (row.getBytea(0)) |id| {
                if (id.len == 16) @memcpy(&templates[i].id, id);
            }
            if (row.getOptionalText(2) orelse null) |desc| {
                templates[i].description = try self.allocator.dupe(u8, desc);
            }
        }

        return templates;
    }
};

test "workspace id conversion" {
    const id: types.WorkspaceId = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const formatted = types.formatId(id);
    try std.testing.expectEqual(@as(usize, 32), formatted.len);
}