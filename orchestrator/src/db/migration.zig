const std = @import("std");
const pool = @import("pool.zig");
const errors = @import("errors.zig");

const DbError = errors.DbError;
const log = std.log.scoped(.db_migration);

pub const Migration = struct {
    version: u32,
    description: []const u8,
    up: []const u8,
    down: []const u8,
};

pub const migrations = [_]Migration{
    .{
        .version = 1,
        .description = "initial schema",
        .up = @embedFile("migrations/001_initial.sql"),
        .down =
        \\DROP TABLE IF EXISTS usage_records;
        \\DROP TABLE IF EXISTS tasks;
        \\DROP TABLE IF EXISTS nodes;
        \\DROP TABLE IF EXISTS schema_migrations;
        ,
    },
    .{
        .version = 2,
        .description = "users and authentication",
        .up = @embedFile("migrations/002_users.sql"),
        .down =
        \\ALTER TABLE usage_records DROP COLUMN IF EXISTS user_id;
        \\ALTER TABLE tasks DROP COLUMN IF EXISTS user_id;
        \\DROP TABLE IF EXISTS user_tokens;
        \\DROP TABLE IF EXISTS users;
        ,
    },
    .{
        .version = 3,
        .description = "workspace management",
        .up = @embedFile("migrations/003_workspaces.sql"),
        .down =
        \\ALTER TABLE tasks DROP COLUMN IF EXISTS workspace_id;
        \\DROP TABLE IF EXISTS workspace_activity;
        \\DROP TABLE IF EXISTS workspace_templates;
        \\DROP TABLE IF EXISTS workspace_env_vars;
        \\DROP TABLE IF EXISTS user_active_workspaces;
        \\DROP TABLE IF EXISTS workspaces;
        ,
    },
};

pub const MigrationRunner = struct {
    db_pool: *pool.Pool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db_pool: *pool.Pool) MigrationRunner {
        return .{
            .db_pool = db_pool,
            .allocator = allocator,
        };
    }

    pub fn run(self: *MigrationRunner) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        try self.ensureMigrationsTable(&conn);

        const current_version = try self.getCurrentVersion(&conn);
        log.info("current schema version: {d}", .{current_version});

        for (migrations) |migration| {
            if (migration.version > current_version) {
                log.info("applying migration {d}: {s}", .{ migration.version, migration.description });
                try self.applyMigration(&conn, migration);
            }
        }

        const new_version = try self.getCurrentVersion(&conn);
        log.info("migrations complete: version {d}", .{new_version});
    }

    fn ensureMigrationsTable(self: *MigrationRunner, conn: *pool.PooledConn) !void {
        _ = self;
        _ = conn.exec(
            \\CREATE TABLE IF NOT EXISTS schema_migrations (
            \\    version INTEGER PRIMARY KEY,
            \\    applied_at BIGINT NOT NULL,
            \\    description TEXT
            \\)
        ) catch |err| {
            log.err("failed to create migrations table: {}", .{err});
            return DbError.MigrationFailed;
        };
    }

    fn getCurrentVersion(self: *MigrationRunner, conn: *pool.PooledConn) !u32 {
        _ = self;
        var result = conn.query("SELECT COALESCE(MAX(version), 0) FROM schema_migrations") catch |err| {
            log.err("failed to get current version: {}", .{err});
            return DbError.MigrationFailed;
        };
        defer result.deinit();

        if (result.first()) |row| {
            return row.getU32(0) orelse 0;
        }
        return 0;
    }

    fn applyMigration(self: *MigrationRunner, conn: *pool.PooledConn, migration: Migration) !void {
        _ = self;

        try conn.begin();
        errdefer conn.rollback() catch {};

        var statements = std.mem.splitSequence(u8, migration.up, ";");
        while (statements.next()) |stmt| {
            const trimmed = std.mem.trim(u8, stmt, " \t\n\r");
            if (trimmed.len == 0) continue;

            var sql_buf: [8192]u8 = undefined;
            const sql = std.fmt.bufPrint(&sql_buf, "{s};", .{trimmed}) catch {
                log.err("statement too long", .{});
                return DbError.MigrationFailed;
            };

            _ = conn.exec(sql) catch |err| {
                log.err("migration {d} failed on statement: {s}", .{ migration.version, sql });
                log.err("error: {}", .{err});
                return DbError.MigrationFailed;
            };
        }

        var params = [_]@import("types.zig").Param{
            .{ .i32 = @intCast(migration.version) },
            .{ .i64 = std.time.milliTimestamp() },
            .{ .text = migration.description },
        };
        _ = conn.execParams(
            "INSERT INTO schema_migrations (version, applied_at, description) VALUES ($1, $2, $3)",
            &params,
        ) catch |err| {
            log.err("failed to record migration: {}", .{err});
            return DbError.MigrationFailed;
        };

        try conn.commit();
        log.info("migration {d} applied successfully", .{migration.version});
    }

    pub fn rollback(self: *MigrationRunner, target_version: u32) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        const current_version = try self.getCurrentVersion(&conn);
        if (current_version <= target_version) {
            log.info("no rollback needed: current={d} target={d}", .{ current_version, target_version });
            return;
        }

        var i: usize = migrations.len;
        while (i > 0) {
            i -= 1;
            const migration = migrations[i];
            if (migration.version > target_version and migration.version <= current_version) {
                log.info("rolling back migration {d}: {s}", .{ migration.version, migration.description });
                try self.rollbackMigration(&conn, migration);
            }
        }

        log.info("rollback complete: version {d}", .{target_version});
    }

    fn rollbackMigration(self: *MigrationRunner, conn: *pool.PooledConn, migration: Migration) !void {
        _ = self;

        try conn.begin();
        errdefer conn.rollback() catch {};

        var statements = std.mem.splitSequence(u8, migration.down, ";");
        while (statements.next()) |stmt| {
            const trimmed = std.mem.trim(u8, stmt, " \t\n\r");
            if (trimmed.len == 0) continue;

            var sql_buf: [4096]u8 = undefined;
            const sql = std.fmt.bufPrint(&sql_buf, "{s};", .{trimmed}) catch {
                return DbError.MigrationFailed;
            };

            _ = conn.exec(sql) catch |err| {
                log.err("rollback failed: {}", .{err});
                return DbError.MigrationFailed;
            };
        }

        var params = [_]@import("types.zig").Param{
            .{ .i32 = @intCast(migration.version) },
        };
        _ = conn.execParams(
            "DELETE FROM schema_migrations WHERE version = $1",
            &params,
        ) catch |err| {
            log.err("failed to remove migration record: {}", .{err});
            return DbError.MigrationFailed;
        };

        try conn.commit();
    }

    pub fn getAppliedMigrations(self: *MigrationRunner) ![]AppliedMigration {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var result = try conn.query(
            "SELECT version, applied_at, description FROM schema_migrations ORDER BY version",
        );
        defer result.deinit();

        var applied = std.ArrayList(AppliedMigration).init(self.allocator);
        errdefer applied.deinit();

        for (result.rows) |row| {
            const desc = row.getText(2);
            try applied.append(.{
                .version = row.getU32(0) orelse 0,
                .applied_at = row.getI64(1) orelse 0,
                .description = if (desc) |d| try self.allocator.dupe(u8, d) else "",
            });
        }

        return applied.toOwnedSlice();
    }
};

pub const AppliedMigration = struct {
    version: u32,
    applied_at: i64,
    description: []const u8,
};

test "migrations array is ordered" {
    var prev_version: u32 = 0;
    for (migrations) |m| {
        try std.testing.expect(m.version > prev_version);
        prev_version = m.version;
    }
}

test "migration has required fields" {
    for (migrations) |m| {
        try std.testing.expect(m.version > 0);
        try std.testing.expect(m.description.len > 0);
        try std.testing.expect(m.up.len > 0);
    }
}