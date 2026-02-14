const std = @import("std");
const pool_mod = @import("../pool.zig");
const types = @import("../types.zig");

pub const TeamRole = enum {
    admin,
    lead,
    developer,
    viewer,

    pub fn toString(self: TeamRole) []const u8 {
        return switch (self) {
            .admin => "admin",
            .lead => "lead",
            .developer => "developer",
            .viewer => "viewer",
        };
    }

    pub fn fromString(s: []const u8) ?TeamRole {
        if (std.mem.eql(u8, s, "admin")) return .admin;
        if (std.mem.eql(u8, s, "lead")) return .lead;
        if (std.mem.eql(u8, s, "developer")) return .developer;
        if (std.mem.eql(u8, s, "viewer")) return .viewer;
        return null;
    }
};

pub const Team = struct {
    id: types.TeamId,
    name: []const u8,
    description: ?[]const u8,
    owner_id: types.UserId,
    created_at: i64,
    updated_at: i64,
};

pub const TeamMember = struct {
    id: types.MemberId,
    team_id: types.TeamId,
    user_id: types.UserId,
    role: TeamRole,
    permissions: []const u8, // JSON
    invited_by: ?types.UserId,
    invited_at: ?i64,
    joined_at: ?i64,
    created_at: i64,
    updated_at: i64,
};

pub const Workspace = struct {
    id: types.WorkspaceId,
    name: []const u8,
    description: ?[]const u8,
    team_id: types.TeamId,
    created_by: types.UserId,
    repo_url: ?[]const u8,
    branch: ?[]const u8,
    settings: []const u8, // JSON
    created_at: i64,
    updated_at: i64,
};

pub const TeamRepository = struct {
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,

    pub fn init(allocator: std.mem.Allocator, pool: *pool_mod.Pool) TeamRepository {
        return .{
            .allocator = allocator,
            .pool = pool,
        };
    }

    pub fn createTeam(self: *TeamRepository, team: Team) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\INSERT INTO teams (id, name, description, owner_id, created_at, updated_at)
            \\VALUES ($1, $2, $3, $4, $5, $6)
        ;

        try conn.exec(query, .{
            team.id.bytes,
            team.name,
            team.description,
            team.owner_id.bytes,
            team.created_at,
            team.updated_at,
        });
    }

    pub fn getTeam(self: *TeamRepository, id: types.TeamId) !?Team {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT id, name, description, owner_id, created_at, updated_at
            \\FROM teams WHERE id = $1
        ;

        const result = try conn.query(query, .{id.bytes});
        defer result.deinit();

        if (try result.next()) |row| {
            return Team{
                .id = types.TeamId{ .bytes = try row.get([16]u8, 0) },
                .name = try self.allocator.dupe(u8, try row.get([]const u8, 1)),
                .description = if (try row.get(?[]const u8, 2)) |desc|
                    try self.allocator.dupe(u8, desc) else null,
                .owner_id = types.UserId{ .bytes = try row.get([16]u8, 3) },
                .created_at = try row.get(i64, 4),
                .updated_at = try row.get(i64, 5),
            };
        }
        return null;
    }

    pub fn getUserTeams(self: *TeamRepository, user_id: types.UserId) ![]Team {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT t.id, t.name, t.description, t.owner_id, t.created_at, t.updated_at
            \\FROM teams t
            \\JOIN team_members tm ON t.id = tm.team_id
            \\WHERE tm.user_id = $1
            \\ORDER BY t.name
        ;

        const result = try conn.query(query, .{user_id.bytes});
        defer result.deinit();

        var teams = std.ArrayList(Team).init(self.allocator);
        defer teams.deinit();

        while (try result.next()) |row| {
            try teams.append(Team{
                .id = types.TeamId{ .bytes = try row.get([16]u8, 0) },
                .name = try self.allocator.dupe(u8, try row.get([]const u8, 1)),
                .description = if (try row.get(?[]const u8, 2)) |desc|
                    try self.allocator.dupe(u8, desc) else null,
                .owner_id = types.UserId{ .bytes = try row.get([16]u8, 3) },
                .created_at = try row.get(i64, 4),
                .updated_at = try row.get(i64, 5),
            });
        }

        return teams.toOwnedSlice();
    }

    pub fn addTeamMember(self: *TeamRepository, member: TeamMember) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\INSERT INTO team_members (id, team_id, user_id, role, permissions, invited_by, invited_at, joined_at, created_at, updated_at)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ;

        try conn.exec(query, .{
            member.id.bytes,
            member.team_id.bytes,
            member.user_id.bytes,
            member.role.toString(),
            member.permissions,
            if (member.invited_by) |id| id.bytes else null,
            member.invited_at,
            member.joined_at,
            member.created_at,
            member.updated_at,
        });
    }

    pub fn getTeamMembers(self: *TeamRepository, team_id: types.TeamId) ![]TeamMember {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT id, team_id, user_id, role, permissions, invited_by, invited_at, joined_at, created_at, updated_at
            \\FROM team_members WHERE team_id = $1
            \\ORDER BY role, created_at
        ;

        const result = try conn.query(query, .{team_id.bytes});
        defer result.deinit();

        var members = std.ArrayList(TeamMember).init(self.allocator);
        defer members.deinit();

        while (try result.next()) |row| {
            const role_str = try row.get([]const u8, 3);
            try members.append(TeamMember{
                .id = types.MemberId{ .bytes = try row.get([16]u8, 0) },
                .team_id = types.TeamId{ .bytes = try row.get([16]u8, 1) },
                .user_id = types.UserId{ .bytes = try row.get([16]u8, 2) },
                .role = TeamRole.fromString(role_str) orelse .developer,
                .permissions = try self.allocator.dupe(u8, try row.get([]const u8, 4)),
                .invited_by = if (try row.get(?[16]u8, 5)) |id|
                    types.UserId{ .bytes = id } else null,
                .invited_at = try row.get(?i64, 6),
                .joined_at = try row.get(?i64, 7),
                .created_at = try row.get(i64, 8),
                .updated_at = try row.get(i64, 9),
            });
        }

        return members.toOwnedSlice();
    }

    pub fn updateTeamMemberRole(self: *TeamRepository, member_id: types.MemberId, role: TeamRole) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\UPDATE team_members SET role = $1, updated_at = $2 WHERE id = $3
        ;

        const now = std.time.milliTimestamp();
        try conn.exec(query, .{ role.toString(), now, member_id.bytes });
    }

    pub fn removeTeamMember(self: *TeamRepository, member_id: types.MemberId) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = "DELETE FROM team_members WHERE id = $1";
        try conn.exec(query, .{member_id.bytes});
    }

    pub fn createWorkspace(self: *TeamRepository, workspace: Workspace) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\INSERT INTO workspaces (id, name, description, team_id, created_by, repo_url, branch, settings, created_at, updated_at)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ;

        try conn.exec(query, .{
            workspace.id.bytes,
            workspace.name,
            workspace.description,
            workspace.team_id.bytes,
            workspace.created_by.bytes,
            workspace.repo_url,
            workspace.branch,
            workspace.settings,
            workspace.created_at,
            workspace.updated_at,
        });
    }

    pub fn getWorkspace(self: *TeamRepository, id: types.WorkspaceId) !?Workspace {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT id, name, description, team_id, created_by, repo_url, branch, settings, created_at, updated_at
            \\FROM workspaces WHERE id = $1
        ;

        const result = try conn.query(query, .{id.bytes});
        defer result.deinit();

        if (try result.next()) |row| {
            return Workspace{
                .id = types.WorkspaceId{ .bytes = try row.get([16]u8, 0) },
                .name = try self.allocator.dupe(u8, try row.get([]const u8, 1)),
                .description = if (try row.get(?[]const u8, 2)) |desc|
                    try self.allocator.dupe(u8, desc) else null,
                .team_id = types.TeamId{ .bytes = try row.get([16]u8, 3) },
                .created_by = types.UserId{ .bytes = try row.get([16]u8, 4) },
                .repo_url = if (try row.get(?[]const u8, 5)) |url|
                    try self.allocator.dupe(u8, url) else null,
                .branch = if (try row.get(?[]const u8, 6)) |branch|
                    try self.allocator.dupe(u8, branch) else null,
                .settings = try self.allocator.dupe(u8, try row.get([]const u8, 7)),
                .created_at = try row.get(i64, 8),
                .updated_at = try row.get(i64, 9),
            };
        }
        return null;
    }

    pub fn getTeamWorkspaces(self: *TeamRepository, team_id: types.TeamId) ![]Workspace {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT id, name, description, team_id, created_by, repo_url, branch, settings, created_at, updated_at
            \\FROM workspaces WHERE team_id = $1
            \\ORDER BY name
        ;

        const result = try conn.query(query, .{team_id.bytes});
        defer result.deinit();

        var workspaces = std.ArrayList(Workspace).init(self.allocator);
        defer workspaces.deinit();

        while (try result.next()) |row| {
            try workspaces.append(Workspace{
                .id = types.WorkspaceId{ .bytes = try row.get([16]u8, 0) },
                .name = try self.allocator.dupe(u8, try row.get([]const u8, 1)),
                .description = if (try row.get(?[]const u8, 2)) |desc|
                    try self.allocator.dupe(u8, desc) else null,
                .team_id = types.TeamId{ .bytes = try row.get([16]u8, 3) },
                .created_by = types.UserId{ .bytes = try row.get([16]u8, 4) },
                .repo_url = if (try row.get(?[]const u8, 5)) |url|
                    try self.allocator.dupe(u8, url) else null,
                .branch = if (try row.get(?[]const u8, 6)) |branch|
                    try self.allocator.dupe(u8, branch) else null,
                .settings = try self.allocator.dupe(u8, try row.get([]const u8, 7)),
                .created_at = try row.get(i64, 8),
                .updated_at = try row.get(i64, 9),
            });
        }

        return workspaces.toOwnedSlice();
    }

    pub fn checkUserTeamAccess(self: *TeamRepository, user_id: types.UserId, team_id: types.TeamId) !bool {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT 1 FROM team_members WHERE user_id = $1 AND team_id = $2
        ;

        const result = try conn.query(query, .{ user_id.bytes, team_id.bytes });
        defer result.deinit();

        return (try result.next()) != null;
    }

    pub fn getUserTeamRole(self: *TeamRepository, user_id: types.UserId, team_id: types.TeamId) !?TeamRole {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const query = 
            \\SELECT role FROM team_members WHERE user_id = $1 AND team_id = $2
        ;

        const result = try conn.query(query, .{ user_id.bytes, team_id.bytes });
        defer result.deinit();

        if (try result.next()) |row| {
            const role_str = try row.get([]const u8, 0);
            return TeamRole.fromString(role_str);
        }
        return null;
    }
};