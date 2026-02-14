const std = @import("std");
const db = @import("root.zig");
const types = @import("../../../common/src/types.zig");
const integration_types = @import("../integrations/mod.zig");

pub const IntegrationRepository = struct {
    allocator: std.mem.Allocator,
    pool: *db.Pool,

    pub fn init(allocator: std.mem.Allocator, pool: *db.Pool) IntegrationRepository {
        return .{
            .allocator = allocator,
            .pool = pool,
        };
    }

    pub fn createIntegration(self: *IntegrationRepository, integration: integration_types.IntegrationConfig) ![]const u8 {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        // Generate UUID for integration ID
        var id_buf: [36]u8 = undefined;
        const integration_id = std.fmt.bufPrint(&id_buf, "integration_{d}_{}", .{ 
            std.time.timestamp(), 
            std.crypto.random.int(u32) 
        }) catch unreachable;

        // Serialize settings as JSON
        var settings_json = std.ArrayList(u8).init(self.allocator);
        defer settings_json.deinit();

        try settings_json.append('{');
        var iter = integration.settings.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try settings_json.append(',');
            first = false;
            try std.fmt.format(settings_json.writer(), "\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try settings_json.append('}');

        const query =
            \\INSERT INTO integrations (
            \\    id, integration_type, name, enabled, settings, 
            \\    created_at, updated_at, last_error, 
            \\    rate_limit_remaining, rate_limit_reset_at
            \\) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            \\RETURNING id;
        ;

        var stmt = try conn.prepare(query);
        defer stmt.deinit();

        const result = try stmt.queryRow(
            integration_id,
            @intFromEnum(integration.integration_type),
            integration.name,
            integration.enabled,
            settings_json.items,
            integration.created_at,
            integration.updated_at,
            integration.last_error,
            integration.rate_limit_remaining,
            integration.rate_limit_reset_at,
        );

        if (result) |row| {
            return try self.allocator.dupe(u8, row.get([]const u8, 0));
        }

        return error.InsertFailed;
    }

    pub fn getIntegration(self: *IntegrationRepository, integration_id: []const u8) !?integration_types.IntegrationConfig {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query =
            \\SELECT id, integration_type, name, enabled, settings,
            \\       created_at, updated_at, last_error,
            \\       rate_limit_remaining, rate_limit_reset_at
            \\FROM integrations 
            \\WHERE id = $1;
        ;

        var stmt = try conn.prepare(query);
        defer stmt.deinit();

        const result = try stmt.queryRow(integration_id);
        const row = result orelse return null;

        var settings = std.StringHashMap([]const u8).init(self.allocator);
        const settings_json = row.get([]const u8, 4);
        try self.parseJsonSettings(&settings, settings_json);

        return integration_types.IntegrationConfig{
            .id = try self.allocator.dupe(u8, row.get([]const u8, 0)),
            .integration_type = @enumFromInt(row.get(u8, 1)),
            .name = try self.allocator.dupe(u8, row.get([]const u8, 2)),
            .enabled = row.get(bool, 3),
            .settings = settings,
            .created_at = row.get(i64, 5),
            .updated_at = row.get(i64, 6),
            .last_error = if (row.isNull(7)) null else try self.allocator.dupe(u8, row.get([]const u8, 7)),
            .rate_limit_remaining = if (row.isNull(8)) null else row.get(u32, 8),
            .rate_limit_reset_at = if (row.isNull(9)) null else row.get(i64, 9),
        };
    }

    pub fn listIntegrations(self: *IntegrationRepository, user_id: ?[]const u8) ![]integration_types.IntegrationConfig {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = if (user_id != null)
            \\SELECT id, integration_type, name, enabled, settings,
            \\       created_at, updated_at, last_error,
            \\       rate_limit_remaining, rate_limit_reset_at
            \\FROM integrations 
            \\WHERE user_id = $1
            \\ORDER BY created_at DESC;
        else
            \\SELECT id, integration_type, name, enabled, settings,
            \\       created_at, updated_at, last_error,
            \\       rate_limit_remaining, rate_limit_reset_at
            \\FROM integrations 
            \\ORDER BY created_at DESC;
        ;

        var stmt = try conn.prepare(query);
        defer stmt.deinit();

        const rows = if (user_id) |uid|
            try stmt.queryAll(uid)
        else
            try stmt.queryAll();
        defer conn.freeRows(rows);

        var integrations = std.ArrayList(integration_types.IntegrationConfig).init(self.allocator);

        for (rows) |row| {
            var settings = std.StringHashMap([]const u8).init(self.allocator);
            const settings_json = row.get([]const u8, 4);
            try self.parseJsonSettings(&settings, settings_json);

            const integration = integration_types.IntegrationConfig{
                .id = try self.allocator.dupe(u8, row.get([]const u8, 0)),
                .integration_type = @enumFromInt(row.get(u8, 1)),
                .name = try self.allocator.dupe(u8, row.get([]const u8, 2)),
                .enabled = row.get(bool, 3),
                .settings = settings,
                .created_at = row.get(i64, 5),
                .updated_at = row.get(i64, 6),
                .last_error = if (row.isNull(7)) null else try self.allocator.dupe(u8, row.get([]const u8, 7)),
                .rate_limit_remaining = if (row.isNull(8)) null else row.get(u32, 8),
                .rate_limit_reset_at = if (row.isNull(9)) null else row.get(i64, 9),
            };

            try integrations.append(integration);
        }

        return integrations.toOwnedSlice();
    }

    pub fn updateIntegration(self: *IntegrationRepository, integration_id: []const u8, updates: struct {
        enabled: ?bool = null,
        last_error: ?[]const u8 = null,
        rate_limit_remaining: ?u32 = null,
        rate_limit_reset_at: ?i64 = null,
    }) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        var query_parts = std.ArrayList([]const u8).init(self.allocator);
        defer query_parts.deinit();
        
        var args = std.ArrayList(db.QueryArg).init(self.allocator);
        defer args.deinit();

        var arg_idx: u8 = 1;

        if (updates.enabled) |enabled| {
            try query_parts.append("enabled = $" ++ std.fmt.allocPrint(self.allocator, "{}", .{arg_idx}));
            try args.append(.{ .bool = enabled });
            arg_idx += 1;
        }

        if (updates.last_error) |error_msg| {
            try query_parts.append("last_error = $" ++ std.fmt.allocPrint(self.allocator, "{}", .{arg_idx}));
            try args.append(.{ .string = error_msg });
            arg_idx += 1;
        }

        if (updates.rate_limit_remaining) |remaining| {
            try query_parts.append("rate_limit_remaining = $" ++ std.fmt.allocPrint(self.allocator, "{}", .{arg_idx}));
            try args.append(.{ .int = @intCast(remaining) });
            arg_idx += 1;
        }

        if (updates.rate_limit_reset_at) |reset_at| {
            try query_parts.append("rate_limit_reset_at = $" ++ std.fmt.allocPrint(self.allocator, "{}", .{arg_idx}));
            try args.append(.{ .int = reset_at });
            arg_idx += 1;
        }

        try query_parts.append("updated_at = $" ++ std.fmt.allocPrint(self.allocator, "{}", .{arg_idx}));
        try args.append(.{ .int = std.time.timestamp() });
        arg_idx += 1;

        if (query_parts.items.len == 1) return; // Only updated_at, nothing to update

        const set_clause = try std.mem.join(self.allocator, ", ", query_parts.items);
        defer self.allocator.free(set_clause);

        const query = try std.fmt.allocPrint(self.allocator, 
            "UPDATE integrations SET {s} WHERE id = ${}", 
            .{ set_clause, arg_idx }
        );
        defer self.allocator.free(query);

        try args.append(.{ .string = integration_id });

        var stmt = try conn.prepare(query);
        defer stmt.deinit();

        _ = try stmt.exec(args.items);
    }

    pub fn deleteIntegration(self: *IntegrationRepository, integration_id: []const u8) !bool {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = "DELETE FROM integrations WHERE id = $1";
        var stmt = try conn.prepare(query);
        defer stmt.deinit();

        const affected_rows = try stmt.exec(integration_id);
        return affected_rows > 0;
    }

    pub fn getIntegrationsByType(self: *IntegrationRepository, integration_type: integration_types.IntegrationType) ![]integration_types.IntegrationConfig {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query =
            \\SELECT id, integration_type, name, enabled, settings,
            \\       created_at, updated_at, last_error,
            \\       rate_limit_remaining, rate_limit_reset_at
            \\FROM integrations 
            \\WHERE integration_type = $1 AND enabled = true
            \\ORDER BY created_at DESC;
        ;

        var stmt = try conn.prepare(query);
        defer stmt.deinit();

        const rows = try stmt.queryAll(@intFromEnum(integration_type));
        defer conn.freeRows(rows);

        var integrations = std.ArrayList(integration_types.IntegrationConfig).init(self.allocator);

        for (rows) |row| {
            var settings = std.StringHashMap([]const u8).init(self.allocator);
            const settings_json = row.get([]const u8, 4);
            try self.parseJsonSettings(&settings, settings_json);

            const integration = integration_types.IntegrationConfig{
                .id = try self.allocator.dupe(u8, row.get([]const u8, 0)),
                .integration_type = @enumFromInt(row.get(u8, 1)),
                .name = try self.allocator.dupe(u8, row.get([]const u8, 2)),
                .enabled = row.get(bool, 3),
                .settings = settings,
                .created_at = row.get(i64, 5),
                .updated_at = row.get(i64, 6),
                .last_error = if (row.isNull(7)) null else try self.allocator.dupe(u8, row.get([]const u8, 7)),
                .rate_limit_remaining = if (row.isNull(8)) null else row.get(u32, 8),
                .rate_limit_reset_at = if (row.isNull(9)) null else row.get(i64, 9),
            };

            try integrations.append(integration);
        }

        return integrations.toOwnedSlice();
    }

    fn parseJsonSettings(self: *IntegrationRepository, settings: *std.StringHashMap([]const u8), json: []const u8) !void {
        var parser = std.json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();

        var tree = try parser.parse(json);
        defer tree.deinit();

        if (tree.root != .object) return error.InvalidJson;

        var iter = tree.root.object.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;

            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            const value = try self.allocator.dupe(u8, entry.value_ptr.string);
            try settings.put(key, value);
        }
    }
};

/// Migration for creating the integrations table
pub const CreateIntegrationsTableMigration = struct {
    pub fn up(conn: *db.Connection) !void {
        const query =
            \\CREATE TABLE integrations (
            \\    id VARCHAR(255) PRIMARY KEY,
            \\    integration_type SMALLINT NOT NULL,
            \\    name VARCHAR(255) NOT NULL,
            \\    enabled BOOLEAN NOT NULL DEFAULT true,
            \\    settings JSONB NOT NULL DEFAULT '{}',
            \\    created_at BIGINT NOT NULL,
            \\    updated_at BIGINT NOT NULL,
            \\    last_error TEXT,
            \\    rate_limit_remaining INTEGER,
            \\    rate_limit_reset_at BIGINT,
            \\    user_id VARCHAR(255),
            \\    
            \\    CONSTRAINT fk_integrations_user FOREIGN KEY (user_id) 
            \\        REFERENCES users(id) ON DELETE CASCADE
            \\);
            \\
            \\CREATE INDEX idx_integrations_type ON integrations(integration_type);
            \\CREATE INDEX idx_integrations_user ON integrations(user_id);
            \\CREATE INDEX idx_integrations_enabled ON integrations(enabled);
        ;

        var stmt = try conn.prepare(query);
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    pub fn down(conn: *db.Connection) !void {
        const query = "DROP TABLE IF EXISTS integrations;";
        var stmt = try conn.prepare(query);
        defer stmt.deinit();
        _ = try stmt.exec();
    }
};

/// Migration for creating the integration_credentials table  
pub const CreateIntegrationCredentialsTableMigration = struct {
    pub fn up(conn: *db.Connection) !void {
        const query =
            \\CREATE TABLE integration_credentials (
            \\    id SERIAL PRIMARY KEY,
            \\    integration_id VARCHAR(255) NOT NULL,
            \\    encrypted_data BYTEA NOT NULL,
            \\    nonce BYTEA NOT NULL,
            \\    created_at BIGINT NOT NULL,
            \\    updated_at BIGINT NOT NULL,
            \\    rotation_count INTEGER NOT NULL DEFAULT 0,
            \\    
            \\    CONSTRAINT fk_credentials_integration FOREIGN KEY (integration_id) 
            \\        REFERENCES integrations(id) ON DELETE CASCADE,
            \\    CONSTRAINT uq_credentials_integration UNIQUE (integration_id)
            \\);
        ;

        var stmt = try conn.prepare(query);
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    pub fn down(conn: *db.Connection) !void {
        const query = "DROP TABLE IF EXISTS integration_credentials;";
        var stmt = try conn.prepare(query);
        defer stmt.deinit();
        _ = try stmt.exec();
    }
};

/// Migration for creating the integration_activity_log table
pub const CreateIntegrationActivityLogTableMigration = struct {
    pub fn up(conn: *db.Connection) !void {
        const query =
            \\CREATE TABLE integration_activity_log (
            \\    id SERIAL PRIMARY KEY,
            \\    integration_id VARCHAR(255) NOT NULL,
            \\    activity_type VARCHAR(50) NOT NULL,
            \\    description TEXT,
            \\    metadata JSONB,
            \\    success BOOLEAN NOT NULL,
            \\    error_message TEXT,
            \\    timestamp BIGINT NOT NULL,
            \\    
            \\    CONSTRAINT fk_activity_integration FOREIGN KEY (integration_id) 
            \\        REFERENCES integrations(id) ON DELETE CASCADE
            \\);
            \\
            \\CREATE INDEX idx_activity_integration ON integration_activity_log(integration_id);
            \\CREATE INDEX idx_activity_timestamp ON integration_activity_log(timestamp);
            \\CREATE INDEX idx_activity_type ON integration_activity_log(activity_type);
        ;

        var stmt = try conn.prepare(query);
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    pub fn down(conn: *db.Connection) !void {
        const query = "DROP TABLE IF EXISTS integration_activity_log;";
        var stmt = try conn.prepare(query);
        defer stmt.deinit();
        _ = try stmt.exec();
    }
};

test "integration repository basic operations" {
    const testing = std.testing;
    
    // Mock database operations would go here
    // For now, just test that the repository can be created
    const allocator = testing.allocator;
    
    // This would require a real database connection pool in practice
    // const pool = try db.Pool.init(allocator, conn_config, pool_config);
    // defer pool.deinit();
    
    // var repo = IntegrationRepository.init(allocator, pool);
    
    // Test basic operations here
}