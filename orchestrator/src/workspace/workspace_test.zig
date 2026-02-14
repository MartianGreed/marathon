const std = @import("std");
const testing = std.testing;
const common = @import("common");
const types = common.types;
const workspace = @import("workspace.zig");

// Mock workspace repository for testing
const MockWorkspaceRepository = struct {
    allocator: std.mem.Allocator,
    workspaces: std.ArrayList(types.Workspace),
    active_workspaces: std.AutoHashMap(types.UserId, types.WorkspaceId),
    env_vars: std.AutoHashMap(types.WorkspaceId, std.ArrayList(types.EnvVar)),
    next_id: u8 = 1,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .workspaces = std.ArrayList(types.Workspace).init(allocator),
            .active_workspaces = std.AutoHashMap(types.UserId, types.WorkspaceId).init(allocator),
            .env_vars = std.AutoHashMap(types.WorkspaceId, std.ArrayList(types.EnvVar)).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.workspaces.items) |*ws| {
            ws.deinit(self.allocator);
        }
        self.workspaces.deinit();
        self.active_workspaces.deinit();
        
        var it = self.env_vars.valueIterator();
        while (it.next()) |env_list| {
            for (env_list.items) |env_var| {
                self.allocator.free(env_var.key);
                self.allocator.free(env_var.value);
            }
            env_list.deinit();
        }
        self.env_vars.deinit();
    }

    pub fn create(self: *Self, ws: *const types.Workspace) !void {
        var new_ws = types.Workspace{
            .id = ws.id,
            .name = try self.allocator.dupe(u8, ws.name),
            .description = if (ws.description) |d| try self.allocator.dupe(u8, d) else null,
            .user_id = ws.user_id,
            .template = if (ws.template) |t| try self.allocator.dupe(u8, t) else null,
            .settings = try self.allocator.dupe(u8, ws.settings),
            .created_at = ws.created_at,
            .updated_at = ws.updated_at,
            .last_accessed_at = ws.last_accessed_at,
        };
        try self.workspaces.append(new_ws);
    }

    pub fn get(self: *Self, workspace_id: types.WorkspaceId) !?types.Workspace {
        for (self.workspaces.items) |ws| {
            if (std.mem.eql(u8, &ws.id, &workspace_id)) {
                return types.Workspace{
                    .id = ws.id,
                    .name = try self.allocator.dupe(u8, ws.name),
                    .description = if (ws.description) |d| try self.allocator.dupe(u8, d) else null,
                    .user_id = ws.user_id,
                    .template = if (ws.template) |t| try self.allocator.dupe(u8, t) else null,
                    .settings = try self.allocator.dupe(u8, ws.settings),
                    .created_at = ws.created_at,
                    .updated_at = ws.updated_at,
                    .last_accessed_at = ws.last_accessed_at,
                };
            }
        }
        return null;
    }

    pub fn getByNameAndUser(self: *Self, name: []const u8, user_id: types.UserId) !?types.Workspace {
        for (self.workspaces.items) |ws| {
            if (std.mem.eql(u8, ws.name, name) and std.mem.eql(u8, &ws.user_id, &user_id)) {
                return try self.get(ws.id);
            }
        }
        return null;
    }

    pub fn setActiveWorkspace(self: *Self, user_id: types.UserId, workspace_id: types.WorkspaceId) !void {
        try self.active_workspaces.put(user_id, workspace_id);
    }

    pub fn getActiveWorkspace(self: *Self, user_id: types.UserId) !?types.Workspace {
        if (self.active_workspaces.get(user_id)) |workspace_id| {
            return try self.get(workspace_id);
        }
        return null;
    }

    pub fn update(self: *Self, ws: *const types.Workspace) !void {
        for (&self.workspaces.items) |*existing| {
            if (std.mem.eql(u8, &existing.id, &ws.id)) {
                self.allocator.free(existing.name);
                if (existing.description) |d| self.allocator.free(d);
                self.allocator.free(existing.settings);

                existing.name = try self.allocator.dupe(u8, ws.name);
                existing.description = if (ws.description) |d| try self.allocator.dupe(u8, d) else null;
                existing.settings = try self.allocator.dupe(u8, ws.settings);
                existing.updated_at = ws.updated_at;
                return;
            }
        }
    }

    pub fn delete(self: *Self, workspace_id: types.WorkspaceId) !bool {
        for (self.workspaces.items, 0..) |ws, i| {
            if (std.mem.eql(u8, &ws.id, &workspace_id)) {
                var removed = self.workspaces.swapRemove(i);
                removed.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    pub fn getWorkspaceEnvVars(self: *Self, workspace_id: types.WorkspaceId) ![]types.EnvVar {
        if (self.env_vars.get(workspace_id)) |env_list| {
            var result = try self.allocator.alloc(types.EnvVar, env_list.items.len);
            for (env_list.items, 0..) |env, i| {
                result[i] = .{
                    .key = try self.allocator.dupe(u8, env.key),
                    .value = try self.allocator.dupe(u8, env.value),
                };
            }
            return result;
        }
        return try self.allocator.alloc(types.EnvVar, 0);
    }

    pub fn setWorkspaceEnvVar(self: *Self, workspace_id: types.WorkspaceId, key: []const u8, value: []const u8) !void {
        var entry = try self.env_vars.getOrPut(workspace_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(types.EnvVar).init(self.allocator);
        }

        // Update existing or add new
        for (entry.value_ptr.items) |*env| {
            if (std.mem.eql(u8, env.key, key)) {
                self.allocator.free(env.value);
                env.value = try self.allocator.dupe(u8, value);
                return;
            }
        }

        try entry.value_ptr.append(.{
            .key = try self.allocator.dupe(u8, key),
            .value = try self.allocator.dupe(u8, value),
        });
    }

    pub fn deleteWorkspaceEnvVar(self: *Self, workspace_id: types.WorkspaceId, key: []const u8) !bool {
        if (self.env_vars.getPtr(workspace_id)) |env_list| {
            for (env_list.items, 0..) |env, i| {
                if (std.mem.eql(u8, env.key, key)) {
                    var removed = env_list.swapRemove(i);
                    self.allocator.free(removed.key);
                    self.allocator.free(removed.value);
                    return true;
                }
            }
        }
        return false;
    }

    pub fn getTemplates(self: *Self) ![]types.WorkspaceTemplate {
        _ = self;
        // Return some mock templates
        var templates = try self.allocator.alloc(types.WorkspaceTemplate, 2);
        templates[0] = .{
            .id = [_]u8{1} ** 16,
            .name = try self.allocator.dupe(u8, "default"),
            .description = try self.allocator.dupe(u8, "Default workspace"),
            .default_settings = try self.allocator.dupe(u8, "{}"),
            .default_env_vars = try self.allocator.dupe(u8, "{}"),
            .created_at = 1000000,
        };
        templates[1] = .{
            .id = [_]u8{2} ** 16,
            .name = try self.allocator.dupe(u8, "web-app"),
            .description = try self.allocator.dupe(u8, "Web application workspace"),
            .default_settings = try self.allocator.dupe(u8, "{\"node_version\": \"20\"}"),
            .default_env_vars = try self.allocator.dupe(u8, "{\"NODE_ENV\": \"development\"}"),
            .created_at = 1000000,
        };
        return templates;
    }

    pub fn updateLastAccessed(self: *Self, workspace_id: types.WorkspaceId, timestamp: i64) !void {
        _ = workspace_id;
        _ = timestamp;
        // Mock implementation - no-op for testing
    }

    pub fn logActivity(self: *Self, workspace_id: types.WorkspaceId, activity_type: []const u8, description: ?[]const u8, metadata: []const u8) !void {
        _ = self;
        _ = workspace_id;
        _ = activity_type;
        _ = description;
        _ = metadata;
        // Mock implementation - no-op for testing
    }

    pub fn listByUser(self: *Self, user_id: types.UserId, limit: u32, offset: u32) ![]types.WorkspaceSummary {
        _ = limit;
        _ = offset;
        
        var result = std.ArrayList(types.WorkspaceSummary).init(self.allocator);
        defer result.deinit();

        for (self.workspaces.items) |ws| {
            if (std.mem.eql(u8, &ws.user_id, &user_id)) {
                const is_active = if (self.active_workspaces.get(user_id)) |active_id|
                    std.mem.eql(u8, &active_id, &ws.id)
                else
                    false;

                try result.append(.{
                    .id = ws.id,
                    .name = try self.allocator.dupe(u8, ws.name),
                    .description = if (ws.description) |d| try self.allocator.dupe(u8, d) else null,
                    .template = if (ws.template) |t| try self.allocator.dupe(u8, t) else null,
                    .created_at = ws.created_at,
                    .last_accessed_at = ws.last_accessed_at,
                    .task_count = 0, // Mock value
                    .is_active = is_active,
                });
            }
        }

        return result.toOwnedSlice();
    }

    fn generateId(self: *Self) types.WorkspaceId {
        const id_byte = self.next_id;
        self.next_id += 1;
        return [_]u8{id_byte} ++ [_]u8{0} ** 15;
    }
};

test "workspace service create and get" {
    var mock_repo = MockWorkspaceRepository.init(testing.allocator);
    defer mock_repo.deinit();

    var service = workspace.WorkspaceService.init(testing.allocator, &mock_repo);
    const user_id: types.UserId = [_]u8{1} ** 16;

    // Create a workspace
    const ws = try service.createWorkspace(
        user_id,
        "test-workspace",
        "Test workspace description",
        "default",
        null,
    );
    defer ws.deinit(testing.allocator);

    try testing.expectEqualStrings("test-workspace", ws.name);
    try testing.expectEqualStrings("Test workspace description", ws.description.?);
    try testing.expectEqualStrings("default", ws.template.?);

    // Get the workspace
    var retrieved = (try service.getWorkspace(ws.id)).?;
    defer retrieved.deinit(testing.allocator);

    try testing.expectEqualStrings(ws.name, retrieved.name);
    try testing.expectEqualStrings(ws.description.?, retrieved.description.?);
}

test "workspace service switch workspace" {
    var mock_repo = MockWorkspaceRepository.init(testing.allocator);
    defer mock_repo.deinit();

    var service = workspace.WorkspaceService.init(testing.allocator, &mock_repo);
    const user_id: types.UserId = [_]u8{1} ** 16;

    // Create two workspaces
    const ws1 = try service.createWorkspace(user_id, "workspace-1", null, null, null);
    defer ws1.deinit(testing.allocator);
    const ws2 = try service.createWorkspace(user_id, "workspace-2", null, null, null);
    defer ws2.deinit(testing.allocator);

    // Switch to workspace-2
    const switched = try service.switchWorkspace(user_id, ws2.id);
    try testing.expect(switched);

    // Verify it's the current workspace
    var current = (try service.getCurrentWorkspace(user_id)).?;
    defer current.deinit(testing.allocator);
    try testing.expectEqualStrings("workspace-2", current.name);
}

test "workspace service switch by name" {
    var mock_repo = MockWorkspaceRepository.init(testing.allocator);
    defer mock_repo.deinit();

    var service = workspace.WorkspaceService.init(testing.allocator, &mock_repo);
    const user_id: types.UserId = [_]u8{1} ** 16;

    // Create workspace
    const ws = try service.createWorkspace(user_id, "my-workspace", null, null, null);
    defer ws.deinit(testing.allocator);

    // Switch by name
    const switched = try service.switchWorkspaceByName(user_id, "my-workspace");
    try testing.expect(switched);

    // Verify it's active
    var current = (try service.getCurrentWorkspace(user_id)).?;
    defer current.deinit(testing.allocator);
    try testing.expectEqualStrings("my-workspace", current.name);
}

test "workspace service environment variables" {
    var mock_repo = MockWorkspaceRepository.init(testing.allocator);
    defer mock_repo.deinit();

    var service = workspace.WorkspaceService.init(testing.allocator, &mock_repo);
    const user_id: types.UserId = [_]u8{1} ** 16;

    // Create workspace
    const ws = try service.createWorkspace(user_id, "test-workspace", null, null, null);
    defer ws.deinit(testing.allocator);

    // Set environment variables
    try service.setEnvVar(ws.id, "DATABASE_URL", "postgres://localhost/test");
    try service.setEnvVar(ws.id, "API_KEY", "secret123");

    // Get environment variables
    const env_vars = try mock_repo.getWorkspaceEnvVars(ws.id);
    defer {
        for (env_vars) |env| {
            testing.allocator.free(env.key);
            testing.allocator.free(env.value);
        }
        testing.allocator.free(env_vars);
    }

    try testing.expectEqual(@as(usize, 2), env_vars.len);

    // Delete one env var
    const deleted = try service.deleteEnvVar(ws.id, "API_KEY");
    try testing.expect(deleted);

    // Verify it's deleted
    const updated_env_vars = try mock_repo.getWorkspaceEnvVars(ws.id);
    defer {
        for (updated_env_vars) |env| {
            testing.allocator.free(env.key);
            testing.allocator.free(env.value);
        }
        testing.allocator.free(updated_env_vars);
    }

    try testing.expectEqual(@as(usize, 1), updated_env_vars.len);
}

test "workspace service create default workspace" {
    var mock_repo = MockWorkspaceRepository.init(testing.allocator);
    defer mock_repo.deinit();

    var service = workspace.WorkspaceService.init(testing.allocator, &mock_repo);
    const user_id: types.UserId = [_]u8{1} ** 16;

    // Create default workspace
    const ws = try service.createDefaultWorkspace(user_id);
    defer ws.deinit(testing.allocator);

    try testing.expectEqualStrings("default", ws.name);
    try testing.expectEqualStrings("Default workspace", ws.description.?);

    // Verify it's active
    var current = (try service.getCurrentWorkspace(user_id)).?;
    defer current.deinit(testing.allocator);
    try testing.expectEqualStrings("default", current.name);
}

test "workspace service name conflict" {
    var mock_repo = MockWorkspaceRepository.init(testing.allocator);
    defer mock_repo.deinit();

    var service = workspace.WorkspaceService.init(testing.allocator, &mock_repo);
    const user_id: types.UserId = [_]u8{1} ** 16;

    // Create first workspace
    const ws1 = try service.createWorkspace(user_id, "duplicate-name", null, null, null);
    defer ws1.deinit(testing.allocator);

    // Try to create another with same name - should fail
    const result = service.createWorkspace(user_id, "duplicate-name", null, null, null);
    try testing.expectError(error.WorkspaceNameExists, result);
}