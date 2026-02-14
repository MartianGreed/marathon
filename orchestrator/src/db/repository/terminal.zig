const std = @import("std");
const pool_mod = @import("../pool.zig");
const types = @import("../types.zig");
const common_types = @import("common").types;

pub const TerminalSession = struct {
    id: common_types.TerminalSessionId,
    workspace_id: common_types.WorkspaceId,
    name: []const u8,
    created_by: common_types.UserId,
    is_active: bool,
    readonly_users: []common_types.UserId,
    settings: []const u8, // JSON
    created_at: i64,
    updated_at: i64,
};

pub const TerminalParticipant = struct {
    id: common_types.TerminalSessionId, // Using session ID as participant ID for simplicity
    session_id: common_types.TerminalSessionId,
    user_id: common_types.UserId,
    readonly: bool,
    joined_at: i64,
    last_seen_at: i64,
};

pub const TerminalHistoryEntry = struct {
    id: i64,
    session_id: common_types.TerminalSessionId,
    user_id: ?common_types.UserId,
    data: []const u8,
    timestamp: i64,
};

pub const TerminalRepository = struct {
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,

    pub fn init(allocator: std.mem.Allocator, pool: *pool_mod.Pool) TerminalRepository {
        return .{
            .allocator = allocator,
            .pool = pool,
        };
    }

    pub fn createTerminalSession(self: *TerminalRepository, session: TerminalSession) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        // Convert readonly_users to PostgreSQL BYTEA array
        var users_buf: [2048]u8 = undefined;
        var users_stream = std.io.fixedBufferStream(&users_buf);
        const writer = users_stream.writer();
        
        try writer.writeByte('{');
        for (session.readonly_users, 0..) |user, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("\"\\\\x{s}\"", .{std.fmt.fmtSliceHexLower(&user.bytes)});
        }
        try writer.writeByte('}');
        
        const users_array = users_stream.getWritten();

        const query = 
            \\INSERT INTO terminal_sessions (id, workspace_id, name, created_by, is_active, readonly_users, settings, created_at, updated_at)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        ;

        try conn.exec(query, .{
            session.id.bytes,
            session.workspace_id.bytes,
            session.name,
            session.created_by.bytes,
            session.is_active,
            users_array,
            session.settings,
            session.created_at,
            session.updated_at,
        });
    }

    pub fn getTerminalSession(self: *TerminalRepository, id: common_types.TerminalSessionId) !?TerminalSession {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT id, workspace_id, name, created_by, is_active, readonly_users, settings, created_at, updated_at
            \\FROM terminal_sessions WHERE id = $1
        ;

        const result = try conn.query(query, .{id.bytes});
        defer result.deinit();

        if (try result.next()) |row| {
            return TerminalSession{
                .id = common_types.TerminalSessionId{ .bytes = try row.get([16]u8, 0) },
                .workspace_id = common_types.WorkspaceId{ .bytes = try row.get([16]u8, 1) },
                .name = try self.allocator.dupe(u8, try row.get([]const u8, 2)),
                .created_by = common_types.UserId{ .bytes = try row.get([16]u8, 3) },
                .is_active = try row.get(bool, 4),
                .readonly_users = &[_]common_types.UserId{}, // TODO: Parse BYTEA array
                .settings = try self.allocator.dupe(u8, try row.get([]const u8, 6)),
                .created_at = try row.get(i64, 7),
                .updated_at = try row.get(i64, 8),
            };
        }
        return null;
    }

    pub fn getWorkspaceTerminalSessions(self: *TerminalRepository, workspace_id: common_types.WorkspaceId) ![]TerminalSession {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT id, workspace_id, name, created_by, is_active, readonly_users, settings, created_at, updated_at
            \\FROM terminal_sessions WHERE workspace_id = $1 AND is_active = TRUE
            \\ORDER BY name
        ;

        const result = try conn.query(query, .{workspace_id.bytes});
        defer result.deinit();

        var sessions = std.ArrayList(TerminalSession).init(self.allocator);
        defer sessions.deinit();

        while (try result.next()) |row| {
            try sessions.append(TerminalSession{
                .id = common_types.TerminalSessionId{ .bytes = try row.get([16]u8, 0) },
                .workspace_id = common_types.WorkspaceId{ .bytes = try row.get([16]u8, 1) },
                .name = try self.allocator.dupe(u8, try row.get([]const u8, 2)),
                .created_by = common_types.UserId{ .bytes = try row.get([16]u8, 3) },
                .is_active = try row.get(bool, 4),
                .readonly_users = &[_]common_types.UserId{}, // TODO: Parse BYTEA array
                .settings = try self.allocator.dupe(u8, try row.get([]const u8, 6)),
                .created_at = try row.get(i64, 7),
                .updated_at = try row.get(i64, 8),
            });
        }

        return sessions.toOwnedSlice();
    }

    pub fn addTerminalParticipant(self: *TerminalRepository, participant: TerminalParticipant) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\INSERT INTO terminal_participants (id, session_id, user_id, readonly, joined_at, last_seen_at)
            \\VALUES ($1, $2, $3, $4, $5, $6)
            \\ON CONFLICT (session_id, user_id) DO UPDATE SET
            \\  readonly = EXCLUDED.readonly,
            \\  last_seen_at = EXCLUDED.last_seen_at
        ;

        const participant_id = common_types.TerminalSessionId.init();
        try conn.exec(query, .{
            participant_id.bytes,
            participant.session_id.bytes,
            participant.user_id.bytes,
            participant.readonly,
            participant.joined_at,
            participant.last_seen_at,
        });
    }

    pub fn getTerminalParticipants(self: *TerminalRepository, session_id: common_types.TerminalSessionId) ![]TerminalParticipant {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT id, session_id, user_id, readonly, joined_at, last_seen_at
            \\FROM terminal_participants WHERE session_id = $1
            \\ORDER BY joined_at
        ;

        const result = try conn.query(query, .{session_id.bytes});
        defer result.deinit();

        var participants = std.ArrayList(TerminalParticipant).init(self.allocator);
        defer participants.deinit();

        while (try result.next()) |row| {
            try participants.append(TerminalParticipant{
                .id = common_types.TerminalSessionId{ .bytes = try row.get([16]u8, 0) },
                .session_id = common_types.TerminalSessionId{ .bytes = try row.get([16]u8, 1) },
                .user_id = common_types.UserId{ .bytes = try row.get([16]u8, 2) },
                .readonly = try row.get(bool, 3),
                .joined_at = try row.get(i64, 4),
                .last_seen_at = try row.get(i64, 5),
            });
        }

        return participants.toOwnedSlice();
    }

    pub fn updateParticipantLastSeen(self: *TerminalRepository, session_id: common_types.TerminalSessionId, user_id: common_types.UserId) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\UPDATE terminal_participants 
            \\SET last_seen_at = $1 
            \\WHERE session_id = $2 AND user_id = $3
        ;

        const now = std.time.milliTimestamp();
        try conn.exec(query, .{ now, session_id.bytes, user_id.bytes });
    }

    pub fn removeTerminalParticipant(self: *TerminalRepository, session_id: common_types.TerminalSessionId, user_id: common_types.UserId) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\DELETE FROM terminal_participants 
            \\WHERE session_id = $1 AND user_id = $2
        ;

        try conn.exec(query, .{ session_id.bytes, user_id.bytes });
    }

    pub fn addTerminalHistory(self: *TerminalRepository, entry: TerminalHistoryEntry) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\INSERT INTO terminal_history (session_id, user_id, data, timestamp)
            \\VALUES ($1, $2, $3, $4)
        ;

        try conn.exec(query, .{
            entry.session_id.bytes,
            if (entry.user_id) |user_id| user_id.bytes else null,
            entry.data,
            entry.timestamp,
        });
    }

    pub fn getTerminalHistory(self: *TerminalRepository, session_id: common_types.TerminalSessionId, since: ?i64, limit: ?i32) ![]TerminalHistoryEntry {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = if (since) |s| 
            \\SELECT id, session_id, user_id, data, timestamp
            \\FROM terminal_history 
            \\WHERE session_id = $1 AND timestamp > $2
            \\ORDER BY timestamp ASC
            \\LIMIT $3
        else
            \\SELECT id, session_id, user_id, data, timestamp
            \\FROM terminal_history 
            \\WHERE session_id = $1
            \\ORDER BY timestamp DESC
            \\LIMIT $2
        ;

        const result = if (since) |s|
            try conn.query(query, .{ session_id.bytes, s, limit orelse 1000 })
        else
            try conn.query(query, .{ session_id.bytes, limit orelse 1000 });
        defer result.deinit();

        var history = std.ArrayList(TerminalHistoryEntry).init(self.allocator);
        defer history.deinit();

        while (try result.next()) |row| {
            try history.append(TerminalHistoryEntry{
                .id = try row.get(i64, 0),
                .session_id = common_types.TerminalSessionId{ .bytes = try row.get([16]u8, 1) },
                .user_id = if (try row.get(?[16]u8, 2)) |user_id|
                    common_types.UserId{ .bytes = user_id } else null,
                .data = try self.allocator.dupe(u8, try row.get([]const u8, 3)),
                .timestamp = try row.get(i64, 4),
            });
        }

        return history.toOwnedSlice();
    }

    pub fn deactivateTerminalSession(self: *TerminalRepository, id: common_types.TerminalSessionId) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\UPDATE terminal_sessions 
            \\SET is_active = FALSE, updated_at = $1 
            \\WHERE id = $2
        ;

        const now = std.time.milliTimestamp();
        try conn.exec(query, .{ now, id.bytes });
    }

    pub fn checkTerminalAccess(self: *TerminalRepository, session_id: common_types.TerminalSessionId, user_id: common_types.UserId) !bool {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        // Check if user has access via team membership to the workspace
        const query = 
            \\SELECT 1 FROM terminal_sessions ts
            \\JOIN workspaces w ON ts.workspace_id = w.id
            \\JOIN team_members tm ON w.team_id = tm.team_id
            \\WHERE ts.id = $1 AND tm.user_id = $2
        ;

        const result = try conn.query(query, .{ session_id.bytes, user_id.bytes });
        defer result.deinit();

        return (try result.next()) != null;
    }
};