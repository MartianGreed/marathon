const std = @import("std");
const pool_mod = @import("../pool.zig");
const types = @import("../types.zig");
const common_types = @import("common").types;

pub const MessageType = enum {
    text,
    file,
    code_snippet,
    system,

    pub fn toString(self: MessageType) []const u8 {
        return switch (self) {
            .text => "text",
            .file => "file",
            .code_snippet => "code_snippet",
            .system => "system",
        };
    }

    pub fn fromString(s: []const u8) ?MessageType {
        if (std.mem.eql(u8, s, "text")) return .text;
        if (std.mem.eql(u8, s, "file")) return .file;
        if (std.mem.eql(u8, s, "code_snippet")) return .code_snippet;
        if (std.mem.eql(u8, s, "system")) return .system;
        return null;
    }
};

pub const Message = struct {
    id: common_types.MessageId,
    workspace_id: ?common_types.WorkspaceId,
    task_assignment_id: ?common_types.TaskAssignmentId,
    user_id: common_types.UserId,
    content: []const u8,
    message_type: MessageType,
    metadata: []const u8, // JSON for mentions, files, code blocks, etc.
    reply_to: ?common_types.MessageId,
    created_at: i64,
    updated_at: i64,
};

pub const UserPresence = struct {
    user_id: common_types.UserId,
    status: PresenceStatus,
    workspace_id: ?common_types.WorkspaceId,
    last_seen_at: i64,
    custom_status: ?[]const u8,
    updated_at: i64,
};

pub const PresenceStatus = enum {
    offline,
    online,
    busy,
    away,

    pub fn toString(self: PresenceStatus) []const u8 {
        return switch (self) {
            .offline => "offline",
            .online => "online",
            .busy => "busy",
            .away => "away",
        };
    }

    pub fn fromString(s: []const u8) ?PresenceStatus {
        if (std.mem.eql(u8, s, "offline")) return .offline;
        if (std.mem.eql(u8, s, "online")) return .online;
        if (std.mem.eql(u8, s, "busy")) return .busy;
        if (std.mem.eql(u8, s, "away")) return .away;
        return null;
    }
};

pub const NotificationType = enum {
    task_assigned,
    mention,
    task_comment,
    team_invite,
    terminal_invite,
    system,

    pub fn toString(self: NotificationType) []const u8 {
        return switch (self) {
            .task_assigned => "task_assigned",
            .mention => "mention",
            .task_comment => "task_comment",
            .team_invite => "team_invite",
            .terminal_invite => "terminal_invite",
            .system => "system",
        };
    }

    pub fn fromString(s: []const u8) ?NotificationType {
        if (std.mem.eql(u8, s, "task_assigned")) return .task_assigned;
        if (std.mem.eql(u8, s, "mention")) return .mention;
        if (std.mem.eql(u8, s, "task_comment")) return .task_comment;
        if (std.mem.eql(u8, s, "team_invite")) return .team_invite;
        if (std.mem.eql(u8, s, "terminal_invite")) return .terminal_invite;
        if (std.mem.eql(u8, s, "system")) return .system;
        return null;
    }
};

pub const NotificationChannel = enum {
    in_app,
    email,
    webhook,

    pub fn toString(self: NotificationChannel) []const u8 {
        return switch (self) {
            .in_app => "in_app",
            .email => "email",
            .webhook => "webhook",
        };
    }

    pub fn fromString(s: []const u8) ?NotificationChannel {
        if (std.mem.eql(u8, s, "in_app")) return .in_app;
        if (std.mem.eql(u8, s, "email")) return .email;
        if (std.mem.eql(u8, s, "webhook")) return .webhook;
        return null;
    }
};

pub const Notification = struct {
    id: common_types.NotificationId,
    user_id: common_types.UserId,
    type: NotificationType,
    title: []const u8,
    content: []const u8,
    metadata: []const u8, // JSON
    channels: []NotificationChannel,
    read_at: ?i64,
    sent_at: ?i64,
    created_at: i64,
};

pub const MessagingRepository = struct {
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,

    pub fn init(allocator: std.mem.Allocator, pool: *pool_mod.Pool) MessagingRepository {
        return .{
            .allocator = allocator,
            .pool = pool,
        };
    }

    pub fn sendMessage(self: *MessagingRepository, message: Message) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\INSERT INTO messages (id, workspace_id, task_assignment_id, user_id, content, message_type, metadata, reply_to, created_at, updated_at)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ;

        try conn.exec(query, .{
            message.id.bytes,
            if (message.workspace_id) |id| id.bytes else null,
            if (message.task_assignment_id) |id| id.bytes else null,
            message.user_id.bytes,
            message.content,
            message.message_type.toString(),
            message.metadata,
            if (message.reply_to) |id| id.bytes else null,
            message.created_at,
            message.updated_at,
        });
    }

    pub fn getWorkspaceMessages(self: *MessagingRepository, workspace_id: common_types.WorkspaceId, limit: ?i32, before: ?i64) ![]Message {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = if (before) |b|
            \\SELECT id, workspace_id, task_assignment_id, user_id, content, message_type, metadata, reply_to, created_at, updated_at
            \\FROM messages 
            \\WHERE workspace_id = $1 AND created_at < $2
            \\ORDER BY created_at DESC
            \\LIMIT $3
        else
            \\SELECT id, workspace_id, task_assignment_id, user_id, content, message_type, metadata, reply_to, created_at, updated_at
            \\FROM messages 
            \\WHERE workspace_id = $1
            \\ORDER BY created_at DESC
            \\LIMIT $2
        ;

        const result = if (before) |b|
            try conn.query(query, .{ workspace_id.bytes, b, limit orelse 50 })
        else
            try conn.query(query, .{ workspace_id.bytes, limit orelse 50 });
        defer result.deinit();

        var messages = std.ArrayList(Message).init(self.allocator);
        defer messages.deinit();

        while (try result.next()) |row| {
            const msg_type_str = try row.get([]const u8, 5);
            
            try messages.append(Message{
                .id = common_types.MessageId{ .bytes = try row.get([16]u8, 0) },
                .workspace_id = if (try row.get(?[16]u8, 1)) |id|
                    common_types.WorkspaceId{ .bytes = id } else null,
                .task_assignment_id = if (try row.get(?[16]u8, 2)) |id|
                    common_types.TaskAssignmentId{ .bytes = id } else null,
                .user_id = common_types.UserId{ .bytes = try row.get([16]u8, 3) },
                .content = try self.allocator.dupe(u8, try row.get([]const u8, 4)),
                .message_type = MessageType.fromString(msg_type_str) orelse .text,
                .metadata = try self.allocator.dupe(u8, try row.get([]const u8, 6)),
                .reply_to = if (try row.get(?[16]u8, 7)) |id|
                    common_types.MessageId{ .bytes = id } else null,
                .created_at = try row.get(i64, 8),
                .updated_at = try row.get(i64, 9),
            });
        }

        return messages.toOwnedSlice();
    }

    pub fn getTaskMessages(self: *MessagingRepository, task_assignment_id: common_types.TaskAssignmentId, limit: ?i32) ![]Message {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT id, workspace_id, task_assignment_id, user_id, content, message_type, metadata, reply_to, created_at, updated_at
            \\FROM messages 
            \\WHERE task_assignment_id = $1
            \\ORDER BY created_at ASC
            \\LIMIT $2
        ;

        const result = try conn.query(query, .{ task_assignment_id.bytes, limit orelse 100 });
        defer result.deinit();

        var messages = std.ArrayList(Message).init(self.allocator);
        defer messages.deinit();

        while (try result.next()) |row| {
            const msg_type_str = try row.get([]const u8, 5);
            
            try messages.append(Message{
                .id = common_types.MessageId{ .bytes = try row.get([16]u8, 0) },
                .workspace_id = if (try row.get(?[16]u8, 1)) |id|
                    common_types.WorkspaceId{ .bytes = id } else null,
                .task_assignment_id = if (try row.get(?[16]u8, 2)) |id|
                    common_types.TaskAssignmentId{ .bytes = id } else null,
                .user_id = common_types.UserId{ .bytes = try row.get([16]u8, 3) },
                .content = try self.allocator.dupe(u8, try row.get([]const u8, 4)),
                .message_type = MessageType.fromString(msg_type_str) orelse .text,
                .metadata = try self.allocator.dupe(u8, try row.get([]const u8, 6)),
                .reply_to = if (try row.get(?[16]u8, 7)) |id|
                    common_types.MessageId{ .bytes = id } else null,
                .created_at = try row.get(i64, 8),
                .updated_at = try row.get(i64, 9),
            });
        }

        return messages.toOwnedSlice();
    }

    pub fn updateUserPresence(self: *MessagingRepository, presence: UserPresence) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\INSERT INTO user_presence (user_id, status, workspace_id, last_seen_at, custom_status, updated_at)
            \\VALUES ($1, $2, $3, $4, $5, $6)
            \\ON CONFLICT (user_id) DO UPDATE SET
            \\  status = EXCLUDED.status,
            \\  workspace_id = EXCLUDED.workspace_id,
            \\  last_seen_at = EXCLUDED.last_seen_at,
            \\  custom_status = EXCLUDED.custom_status,
            \\  updated_at = EXCLUDED.updated_at
        ;

        try conn.exec(query, .{
            presence.user_id.bytes,
            presence.status.toString(),
            if (presence.workspace_id) |id| id.bytes else null,
            presence.last_seen_at,
            presence.custom_status,
            presence.updated_at,
        });
    }

    pub fn getUserPresence(self: *MessagingRepository, user_id: common_types.UserId) !?UserPresence {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT user_id, status, workspace_id, last_seen_at, custom_status, updated_at
            \\FROM user_presence WHERE user_id = $1
        ;

        const result = try conn.query(query, .{user_id.bytes});
        defer result.deinit();

        if (try result.next()) |row| {
            const status_str = try row.get([]const u8, 1);
            
            return UserPresence{
                .user_id = common_types.UserId{ .bytes = try row.get([16]u8, 0) },
                .status = PresenceStatus.fromString(status_str) orelse .offline,
                .workspace_id = if (try row.get(?[16]u8, 2)) |id|
                    common_types.WorkspaceId{ .bytes = id } else null,
                .last_seen_at = try row.get(i64, 3),
                .custom_status = if (try row.get(?[]const u8, 4)) |status|
                    try self.allocator.dupe(u8, status) else null,
                .updated_at = try row.get(i64, 5),
            };
        }
        return null;
    }

    pub fn getWorkspacePresence(self: *MessagingRepository, workspace_id: common_types.WorkspaceId) ![]UserPresence {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT p.user_id, p.status, p.workspace_id, p.last_seen_at, p.custom_status, p.updated_at
            \\FROM user_presence p
            \\JOIN team_members tm ON p.user_id = tm.user_id
            \\JOIN workspaces w ON tm.team_id = w.team_id
            \\WHERE w.id = $1 AND p.status != 'offline'
            \\ORDER BY p.updated_at DESC
        ;

        const result = try conn.query(query, .{workspace_id.bytes});
        defer result.deinit();

        var presence_list = std.ArrayList(UserPresence).init(self.allocator);
        defer presence_list.deinit();

        while (try result.next()) |row| {
            const status_str = try row.get([]const u8, 1);
            
            try presence_list.append(UserPresence{
                .user_id = common_types.UserId{ .bytes = try row.get([16]u8, 0) },
                .status = PresenceStatus.fromString(status_str) orelse .offline,
                .workspace_id = if (try row.get(?[16]u8, 2)) |id|
                    common_types.WorkspaceId{ .bytes = id } else null,
                .last_seen_at = try row.get(i64, 3),
                .custom_status = if (try row.get(?[]const u8, 4)) |status|
                    try self.allocator.dupe(u8, status) else null,
                .updated_at = try row.get(i64, 5),
            });
        }

        return presence_list.toOwnedSlice();
    }

    pub fn createNotification(self: *MessagingRepository, notification: Notification) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        // Convert channels to PostgreSQL text array
        var channels_buf: [512]u8 = undefined;
        var channels_stream = std.io.fixedBufferStream(&channels_buf);
        const writer = channels_stream.writer();
        
        try writer.writeByte('{');
        for (notification.channels, 0..) |channel, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("\"{s}\"", .{channel.toString()});
        }
        try writer.writeByte('}');
        
        const channels_array = channels_stream.getWritten();

        const query = 
            \\INSERT INTO notifications (id, user_id, type, title, content, metadata, channels, read_at, sent_at, created_at)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ;

        try conn.exec(query, .{
            notification.id.bytes,
            notification.user_id.bytes,
            notification.type.toString(),
            notification.title,
            notification.content,
            notification.metadata,
            channels_array,
            notification.read_at,
            notification.sent_at,
            notification.created_at,
        });
    }

    pub fn getUserNotifications(self: *MessagingRepository, user_id: common_types.UserId, unread_only: bool, limit: ?i32) ![]Notification {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = if (unread_only)
            \\SELECT id, user_id, type, title, content, metadata, channels, read_at, sent_at, created_at
            \\FROM notifications 
            \\WHERE user_id = $1 AND read_at IS NULL
            \\ORDER BY created_at DESC
            \\LIMIT $2
        else
            \\SELECT id, user_id, type, title, content, metadata, channels, read_at, sent_at, created_at
            \\FROM notifications 
            \\WHERE user_id = $1
            \\ORDER BY created_at DESC
            \\LIMIT $2
        ;

        const result = try conn.query(query, .{ user_id.bytes, limit orelse 50 });
        defer result.deinit();

        var notifications = std.ArrayList(Notification).init(self.allocator);
        defer notifications.deinit();

        while (try result.next()) |row| {
            const type_str = try row.get([]const u8, 2);
            
            try notifications.append(Notification{
                .id = common_types.NotificationId{ .bytes = try row.get([16]u8, 0) },
                .user_id = common_types.UserId{ .bytes = try row.get([16]u8, 1) },
                .type = NotificationType.fromString(type_str) orelse .system,
                .title = try self.allocator.dupe(u8, try row.get([]const u8, 3)),
                .content = try self.allocator.dupe(u8, try row.get([]const u8, 4)),
                .metadata = try self.allocator.dupe(u8, try row.get([]const u8, 5)),
                .channels = &[_]NotificationChannel{.in_app}, // TODO: Parse array
                .read_at = try row.get(?i64, 7),
                .sent_at = try row.get(?i64, 8),
                .created_at = try row.get(i64, 9),
            });
        }

        return notifications.toOwnedSlice();
    }

    pub fn markNotificationAsRead(self: *MessagingRepository, notification_id: common_types.NotificationId) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\UPDATE notifications 
            \\SET read_at = $1 
            \\WHERE id = $2 AND read_at IS NULL
        ;

        const now = std.time.milliTimestamp();
        try conn.exec(query, .{ now, notification_id.bytes });
    }

    pub fn getUnreadNotificationCount(self: *MessagingRepository, user_id: common_types.UserId) !i64 {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT COUNT(*) FROM notifications 
            \\WHERE user_id = $1 AND read_at IS NULL
        ;

        const result = try conn.query(query, .{user_id.bytes});
        defer result.deinit();

        if (try result.next()) |row| {
            return try row.get(i64, 0);
        }
        return 0;
    }
};