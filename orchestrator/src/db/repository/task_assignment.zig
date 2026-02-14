const std = @import("std");
const pool_mod = @import("../pool.zig");
const types = @import("../types.zig");

pub const TaskPriority = enum {
    low,
    normal,
    high,
    urgent,

    pub fn toString(self: TaskPriority) []const u8 {
        return switch (self) {
            .low => "low",
            .normal => "normal",
            .high => "high",
            .urgent => "urgent",
        };
    }

    pub fn fromString(s: []const u8) ?TaskPriority {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "normal")) return .normal;
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "urgent")) return .urgent;
        return null;
    }
};

pub const TaskStatus = enum {
    todo,
    in_progress,
    review,
    done,
    blocked,

    pub fn toString(self: TaskStatus) []const u8 {
        return switch (self) {
            .todo => "todo",
            .in_progress => "in_progress",
            .review => "review",
            .done => "done",
            .blocked => "blocked",
        };
    }

    pub fn fromString(s: []const u8) ?TaskStatus {
        if (std.mem.eql(u8, s, "todo")) return .todo;
        if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, s, "review")) return .review;
        if (std.mem.eql(u8, s, "done")) return .done;
        if (std.mem.eql(u8, s, "blocked")) return .blocked;
        return null;
    }
};

pub const TaskAssignment = struct {
    id: types.TaskAssignmentId,
    task_id: types.TaskId,
    workspace_id: ?types.WorkspaceId,
    title: []const u8,
    description: ?[]const u8,
    assigned_to: ?types.UserId,
    assigned_by: ?types.UserId,
    status: TaskStatus,
    priority: TaskPriority,
    due_date: ?i64,
    template_name: ?[]const u8,
    dependencies: []types.TaskAssignmentId,
    created_at: i64,
    updated_at: i64,
};

pub const TaskComment = struct {
    id: types.CommentId,
    task_assignment_id: types.TaskAssignmentId,
    user_id: types.UserId,
    content: []const u8,
    metadata: []const u8, // JSON
    created_at: i64,
    updated_at: i64,
};

pub const TaskTemplate = struct {
    id: types.TemplateId,
    team_id: types.TeamId,
    name: []const u8,
    description: ?[]const u8,
    prompt_template: []const u8,
    default_priority: TaskPriority,
    estimated_duration: ?i64,
    required_permissions: []const u8, // JSON
    created_by: types.UserId,
    created_at: i64,
    updated_at: i64,
};

pub const TaskAssignmentRepository = struct {
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,

    pub fn init(allocator: std.mem.Allocator, pool: *pool_mod.Pool) TaskAssignmentRepository {
        return .{
            .allocator = allocator,
            .pool = pool,
        };
    }

    pub fn createTaskAssignment(self: *TaskAssignmentRepository, assignment: TaskAssignment) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        // Convert dependencies to PostgreSQL BYTEA array
        var deps_buf: [1024]u8 = undefined;
        var deps_stream = std.io.fixedBufferStream(&deps_buf);
        const writer = deps_stream.writer();
        
        try writer.writeByte('{');
        for (assignment.dependencies, 0..) |dep, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("\"\\\\x{s}\"", .{std.fmt.fmtSliceHexLower(&dep.bytes)});
        }
        try writer.writeByte('}');
        
        const deps_array = deps_stream.getWritten();

        const query = 
            \\INSERT INTO task_assignments (id, task_id, workspace_id, title, description, assigned_to, assigned_by, status, priority, due_date, template_name, dependencies, created_at, updated_at)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
        ;

        try conn.exec(query, .{
            assignment.id.bytes,
            assignment.task_id.bytes,
            if (assignment.workspace_id) |id| id.bytes else null,
            assignment.title,
            assignment.description,
            if (assignment.assigned_to) |id| id.bytes else null,
            if (assignment.assigned_by) |id| id.bytes else null,
            assignment.status.toString(),
            assignment.priority.toString(),
            assignment.due_date,
            assignment.template_name,
            deps_array,
            assignment.created_at,
            assignment.updated_at,
        });
    }

    pub fn getTaskAssignment(self: *TaskAssignmentRepository, id: types.TaskAssignmentId) !?TaskAssignment {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT id, task_id, workspace_id, title, description, assigned_to, assigned_by, status, priority, due_date, template_name, dependencies, created_at, updated_at
            \\FROM task_assignments WHERE id = $1
        ;

        const result = try conn.query(query, .{id.bytes});
        defer result.deinit();

        if (try result.next()) |row| {
            const status_str = try row.get([]const u8, 7);
            const priority_str = try row.get([]const u8, 8);

            return TaskAssignment{
                .id = types.TaskAssignmentId{ .bytes = try row.get([16]u8, 0) },
                .task_id = types.TaskId{ .bytes = try row.get([16]u8, 1) },
                .workspace_id = if (try row.get(?[16]u8, 2)) |ws_id|
                    types.WorkspaceId{ .bytes = ws_id } else null,
                .title = try self.allocator.dupe(u8, try row.get([]const u8, 3)),
                .description = if (try row.get(?[]const u8, 4)) |desc|
                    try self.allocator.dupe(u8, desc) else null,
                .assigned_to = if (try row.get(?[16]u8, 5)) |user_id|
                    types.UserId{ .bytes = user_id } else null,
                .assigned_by = if (try row.get(?[16]u8, 6)) |user_id|
                    types.UserId{ .bytes = user_id } else null,
                .status = TaskStatus.fromString(status_str) orelse .todo,
                .priority = TaskPriority.fromString(priority_str) orelse .normal,
                .due_date = try row.get(?i64, 9),
                .template_name = if (try row.get(?[]const u8, 10)) |name|
                    try self.allocator.dupe(u8, name) else null,
                .dependencies = &[_]types.TaskAssignmentId{}, // TODO: Parse BYTEA array
                .created_at = try row.get(i64, 12),
                .updated_at = try row.get(i64, 13),
            };
        }
        return null;
    }

    pub fn getWorkspaceTaskAssignments(self: *TaskAssignmentRepository, workspace_id: types.WorkspaceId) ![]TaskAssignment {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT id, task_id, workspace_id, title, description, assigned_to, assigned_by, status, priority, due_date, template_name, dependencies, created_at, updated_at
            \\FROM task_assignments WHERE workspace_id = $1
            \\ORDER BY priority DESC, created_at ASC
        ;

        const result = try conn.query(query, .{workspace_id.bytes});
        defer result.deinit();

        var assignments = std.ArrayList(TaskAssignment).init(self.allocator);
        defer assignments.deinit();

        while (try result.next()) |row| {
            const status_str = try row.get([]const u8, 7);
            const priority_str = try row.get([]const u8, 8);

            try assignments.append(TaskAssignment{
                .id = types.TaskAssignmentId{ .bytes = try row.get([16]u8, 0) },
                .task_id = types.TaskId{ .bytes = try row.get([16]u8, 1) },
                .workspace_id = if (try row.get(?[16]u8, 2)) |ws_id|
                    types.WorkspaceId{ .bytes = ws_id } else null,
                .title = try self.allocator.dupe(u8, try row.get([]const u8, 3)),
                .description = if (try row.get(?[]const u8, 4)) |desc|
                    try self.allocator.dupe(u8, desc) else null,
                .assigned_to = if (try row.get(?[16]u8, 5)) |user_id|
                    types.UserId{ .bytes = user_id } else null,
                .assigned_by = if (try row.get(?[16]u8, 6)) |user_id|
                    types.UserId{ .bytes = user_id } else null,
                .status = TaskStatus.fromString(status_str) orelse .todo,
                .priority = TaskPriority.fromString(priority_str) orelse .normal,
                .due_date = try row.get(?i64, 9),
                .template_name = if (try row.get(?[]const u8, 10)) |name|
                    try self.allocator.dupe(u8, name) else null,
                .dependencies = &[_]types.TaskAssignmentId{}, // TODO: Parse BYTEA array
                .created_at = try row.get(i64, 12),
                .updated_at = try row.get(i64, 13),
            });
        }

        return assignments.toOwnedSlice();
    }

    pub fn getUserTaskAssignments(self: *TaskAssignmentRepository, user_id: types.UserId) ![]TaskAssignment {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT id, task_id, workspace_id, title, description, assigned_to, assigned_by, status, priority, due_date, template_name, dependencies, created_at, updated_at
            \\FROM task_assignments WHERE assigned_to = $1
            \\ORDER BY priority DESC, due_date ASC NULLS LAST, created_at ASC
        ;

        const result = try conn.query(query, .{user_id.bytes});
        defer result.deinit();

        var assignments = std.ArrayList(TaskAssignment).init(self.allocator);
        defer assignments.deinit();

        while (try result.next()) |row| {
            const status_str = try row.get([]const u8, 7);
            const priority_str = try row.get([]const u8, 8);

            try assignments.append(TaskAssignment{
                .id = types.TaskAssignmentId{ .bytes = try row.get([16]u8, 0) },
                .task_id = types.TaskId{ .bytes = try row.get([16]u8, 1) },
                .workspace_id = if (try row.get(?[16]u8, 2)) |ws_id|
                    types.WorkspaceId{ .bytes = ws_id } else null,
                .title = try self.allocator.dupe(u8, try row.get([]const u8, 3)),
                .description = if (try row.get(?[]const u8, 4)) |desc|
                    try self.allocator.dupe(u8, desc) else null,
                .assigned_to = if (try row.get(?[16]u8, 5)) |user_id_val|
                    types.UserId{ .bytes = user_id_val } else null,
                .assigned_by = if (try row.get(?[16]u8, 6)) |user_id_val|
                    types.UserId{ .bytes = user_id_val } else null,
                .status = TaskStatus.fromString(status_str) orelse .todo,
                .priority = TaskPriority.fromString(priority_str) orelse .normal,
                .due_date = try row.get(?i64, 9),
                .template_name = if (try row.get(?[]const u8, 10)) |name|
                    try self.allocator.dupe(u8, name) else null,
                .dependencies = &[_]types.TaskAssignmentId{}, // TODO: Parse BYTEA array
                .created_at = try row.get(i64, 12),
                .updated_at = try row.get(i64, 13),
            });
        }

        return assignments.toOwnedSlice();
    }

    pub fn updateTaskAssignmentStatus(self: *TaskAssignmentRepository, id: types.TaskAssignmentId, status: TaskStatus) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\UPDATE task_assignments SET status = $1, updated_at = $2 WHERE id = $3
        ;

        const now = std.time.milliTimestamp();
        try conn.exec(query, .{ status.toString(), now, id.bytes });
    }

    pub fn assignTask(self: *TaskAssignmentRepository, id: types.TaskAssignmentId, assigned_to: types.UserId, assigned_by: types.UserId) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\UPDATE task_assignments SET assigned_to = $1, assigned_by = $2, updated_at = $3 WHERE id = $4
        ;

        const now = std.time.milliTimestamp();
        try conn.exec(query, .{ assigned_to.bytes, assigned_by.bytes, now, id.bytes });
    }

    pub fn addTaskComment(self: *TaskAssignmentRepository, comment: TaskComment) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\INSERT INTO task_comments (id, task_assignment_id, user_id, content, metadata, created_at, updated_at)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7)
        ;

        try conn.exec(query, .{
            comment.id.bytes,
            comment.task_assignment_id.bytes,
            comment.user_id.bytes,
            comment.content,
            comment.metadata,
            comment.created_at,
            comment.updated_at,
        });
    }

    pub fn getTaskComments(self: *TaskAssignmentRepository, task_assignment_id: types.TaskAssignmentId) ![]TaskComment {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT id, task_assignment_id, user_id, content, metadata, created_at, updated_at
            \\FROM task_comments WHERE task_assignment_id = $1
            \\ORDER BY created_at ASC
        ;

        const result = try conn.query(query, .{task_assignment_id.bytes});
        defer result.deinit();

        var comments = std.ArrayList(TaskComment).init(self.allocator);
        defer comments.deinit();

        while (try result.next()) |row| {
            try comments.append(TaskComment{
                .id = types.CommentId{ .bytes = try row.get([16]u8, 0) },
                .task_assignment_id = types.TaskAssignmentId{ .bytes = try row.get([16]u8, 1) },
                .user_id = types.UserId{ .bytes = try row.get([16]u8, 2) },
                .content = try self.allocator.dupe(u8, try row.get([]const u8, 3)),
                .metadata = try self.allocator.dupe(u8, try row.get([]const u8, 4)),
                .created_at = try row.get(i64, 5),
                .updated_at = try row.get(i64, 6),
            });
        }

        return comments.toOwnedSlice();
    }

    pub fn createTaskTemplate(self: *TaskAssignmentRepository, template: TaskTemplate) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\INSERT INTO task_templates (id, team_id, name, description, prompt_template, default_priority, estimated_duration, required_permissions, created_by, created_at, updated_at)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
        ;

        try conn.exec(query, .{
            template.id.bytes,
            template.team_id.bytes,
            template.name,
            template.description,
            template.prompt_template,
            template.default_priority.toString(),
            template.estimated_duration,
            template.required_permissions,
            template.created_by.bytes,
            template.created_at,
            template.updated_at,
        });
    }

    pub fn getTeamTaskTemplates(self: *TaskAssignmentRepository, team_id: types.TeamId) ![]TaskTemplate {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT id, team_id, name, description, prompt_template, default_priority, estimated_duration, required_permissions, created_by, created_at, updated_at
            \\FROM task_templates WHERE team_id = $1
            \\ORDER BY name
        ;

        const result = try conn.query(query, .{team_id.bytes});
        defer result.deinit();

        var templates = std.ArrayList(TaskTemplate).init(self.allocator);
        defer templates.deinit();

        while (try result.next()) |row| {
            const priority_str = try row.get([]const u8, 5);

            try templates.append(TaskTemplate{
                .id = types.TemplateId{ .bytes = try row.get([16]u8, 0) },
                .team_id = types.TeamId{ .bytes = try row.get([16]u8, 1) },
                .name = try self.allocator.dupe(u8, try row.get([]const u8, 2)),
                .description = if (try row.get(?[]const u8, 3)) |desc|
                    try self.allocator.dupe(u8, desc) else null,
                .prompt_template = try self.allocator.dupe(u8, try row.get([]const u8, 4)),
                .default_priority = TaskPriority.fromString(priority_str) orelse .normal,
                .estimated_duration = try row.get(?i64, 6),
                .required_permissions = try self.allocator.dupe(u8, try row.get([]const u8, 7)),
                .created_by = types.UserId{ .bytes = try row.get([16]u8, 8) },
                .created_at = try row.get(i64, 9),
                .updated_at = try row.get(i64, 10),
            });
        }

        return templates.toOwnedSlice();
    }
};