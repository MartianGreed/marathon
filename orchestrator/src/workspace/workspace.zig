const std = @import("std");
const common = @import("common");
const types = common.types;
const log = std.log.scoped(.workspace_service);

const db = @import("../db/root.zig");

pub const WorkspaceService = struct {
    allocator: std.mem.Allocator,
    workspace_repo: *db.WorkspaceRepository,

    pub fn init(allocator: std.mem.Allocator, workspace_repo: *db.WorkspaceRepository) WorkspaceService {
        return .{
            .allocator = allocator,
            .workspace_repo = workspace_repo,
        };
    }

    pub fn createWorkspace(
        self: *WorkspaceService,
        user_id: types.UserId,
        name: []const u8,
        description: ?[]const u8,
        template: ?[]const u8,
        settings: ?[]const u8,
    ) !types.Workspace {
        // Check for name conflicts
        if (try self.workspace_repo.getByNameAndUser(name, user_id)) |existing| {
            existing.deinit(self.allocator);
            return error.WorkspaceNameExists;
        }

        var workspace_id: types.WorkspaceId = undefined;
        std.crypto.random.bytes(&workspace_id);

        const now = std.time.milliTimestamp();
        
        // Load template defaults if specified
        var final_settings = settings orelse "{}";
        var env_vars_json = "{}";
        
        if (template) |tmpl_name| {
            if (try self.getTemplateByName(tmpl_name)) |tmpl| {
                defer tmpl.deinit(self.allocator);
                
                if (settings == null) {
                    final_settings = tmpl.default_settings;
                }
                env_vars_json = tmpl.default_env_vars;
            }
        }

        const workspace = types.Workspace{
            .id = workspace_id,
            .name = try self.allocator.dupe(u8, name),
            .description = if (description) |d| try self.allocator.dupe(u8, d) else null,
            .user_id = user_id,
            .template = if (template) |t| try self.allocator.dupe(u8, t) else null,
            .settings = try self.allocator.dupe(u8, final_settings),
            .created_at = now,
            .updated_at = now,
            .last_accessed_at = now,
        };

        try self.workspace_repo.create(&workspace);

        // Apply template environment variables
        if (!std.mem.eql(u8, env_vars_json, "{}")) {
            try self.applyTemplateEnvVars(workspace_id, env_vars_json);
        }

        // Log activity
        try self.workspace_repo.logActivity(
            workspace_id,
            "workspace_created",
            "Workspace created",
            "{}",
        );

        log.info("workspace created: workspace_id={s} name={s} template={?s}", .{
            &types.formatId(workspace_id),
            name,
            template,
        });

        return workspace;
    }

    pub fn getWorkspace(self: *WorkspaceService, workspace_id: types.WorkspaceId) !?types.Workspace {
        return self.workspace_repo.get(workspace_id);
    }

    pub fn getWorkspaceByName(self: *WorkspaceService, name: []const u8, user_id: types.UserId) !?types.Workspace {
        return self.workspace_repo.getByNameAndUser(name, user_id);
    }

    pub fn listWorkspaces(self: *WorkspaceService, user_id: types.UserId, limit: u32, offset: u32) ![]types.WorkspaceSummary {
        return self.workspace_repo.listByUser(user_id, limit, offset);
    }

    pub fn updateWorkspace(
        self: *WorkspaceService,
        workspace_id: types.WorkspaceId,
        name: ?[]const u8,
        description: ?[]const u8,
        settings: ?[]const u8,
    ) !bool {
        var workspace = (try self.workspace_repo.get(workspace_id)) orelse return false;
        defer workspace.deinit(self.allocator);

        var updated = false;
        
        if (name) |n| {
            self.allocator.free(workspace.name);
            workspace.name = try self.allocator.dupe(u8, n);
            updated = true;
        }
        
        if (description) |d| {
            if (workspace.description) |old| self.allocator.free(old);
            workspace.description = try self.allocator.dupe(u8, d);
            updated = true;
        }
        
        if (settings) |s| {
            self.allocator.free(workspace.settings);
            workspace.settings = try self.allocator.dupe(u8, s);
            updated = true;
        }

        if (updated) {
            workspace.updated_at = std.time.milliTimestamp();
            try self.workspace_repo.update(&workspace);
            
            // Log activity
            try self.workspace_repo.logActivity(
                workspace_id,
                "workspace_updated",
                "Workspace settings updated",
                "{}",
            );
        }

        return updated;
    }

    pub fn deleteWorkspace(self: *WorkspaceService, workspace_id: types.WorkspaceId) !bool {
        const deleted = try self.workspace_repo.delete(workspace_id);
        
        if (deleted) {
            log.info("workspace deleted: workspace_id={s}", .{&types.formatId(workspace_id)});
        }
        
        return deleted;
    }

    pub fn switchWorkspace(self: *WorkspaceService, user_id: types.UserId, workspace_id: types.WorkspaceId) !bool {
        // Verify workspace exists and belongs to user
        var workspace = (try self.workspace_repo.get(workspace_id)) orelse return false;
        defer workspace.deinit(self.allocator);
        
        if (!std.mem.eql(u8, &workspace.user_id, &user_id)) {
            return false; // Not user's workspace
        }

        try self.workspace_repo.setActiveWorkspace(user_id, workspace_id);
        
        // Log activity
        try self.workspace_repo.logActivity(
            workspace_id,
            "workspace_activated",
            "Workspace set as active",
            "{}",
        );

        log.info("workspace switched: user_id={s} workspace_id={s}", .{
            &types.formatId(user_id),
            &types.formatId(workspace_id),
        });

        return true;
    }

    pub fn switchWorkspaceByName(self: *WorkspaceService, user_id: types.UserId, name: []const u8) !bool {
        var workspace = (try self.workspace_repo.getByNameAndUser(name, user_id)) orelse return false;
        defer workspace.deinit(self.allocator);
        
        return self.switchWorkspace(user_id, workspace.id);
    }

    pub fn getCurrentWorkspace(self: *WorkspaceService, user_id: types.UserId) !?types.Workspace {
        return self.workspace_repo.getActiveWorkspace(user_id);
    }

    pub fn getWorkspaceWithEnvVars(self: *WorkspaceService, workspace_id: types.WorkspaceId) !?struct {
        workspace: types.Workspace,
        env_vars: []types.EnvVar,
    } {
        var workspace = (try self.workspace_repo.get(workspace_id)) orelse return null;
        errdefer workspace.deinit(self.allocator);
        
        const env_vars = try self.workspace_repo.getWorkspaceEnvVars(workspace_id);
        
        return .{
            .workspace = workspace,
            .env_vars = env_vars,
        };
    }

    pub fn setEnvVar(self: *WorkspaceService, workspace_id: types.WorkspaceId, key: []const u8, value: []const u8) !void {
        try self.workspace_repo.setWorkspaceEnvVar(workspace_id, key, value);
        
        // Log activity
        const metadata = std.fmt.allocPrint(self.allocator, "{{\"key\": \"{s}\"}}", .{key}) catch "{}";
        defer self.allocator.free(metadata);
        
        try self.workspace_repo.logActivity(
            workspace_id,
            "env_var_set",
            "Environment variable updated",
            metadata,
        );
    }

    pub fn deleteEnvVar(self: *WorkspaceService, workspace_id: types.WorkspaceId, key: []const u8) !bool {
        const deleted = try self.workspace_repo.deleteWorkspaceEnvVar(workspace_id, key);
        
        if (deleted) {
            // Log activity
            const metadata = std.fmt.allocPrint(self.allocator, "{{\"key\": \"{s}\"}}", .{key}) catch "{}";
            defer self.allocator.free(metadata);
            
            try self.workspace_repo.logActivity(
                workspace_id,
                "env_var_deleted",
                "Environment variable removed",
                metadata,
            );
        }
        
        return deleted;
    }

    pub fn getTemplates(self: *WorkspaceService) ![]types.WorkspaceTemplate {
        return self.workspace_repo.getTemplates();
    }

    fn getTemplateByName(self: *WorkspaceService, name: []const u8) !?types.WorkspaceTemplate {
        const templates = try self.getTemplates();
        defer {
            for (templates) |*tmpl| {
                tmpl.deinit(self.allocator);
            }
            self.allocator.free(templates);
        }
        
        for (templates) |tmpl| {
            if (std.mem.eql(u8, tmpl.name, name)) {
                return types.WorkspaceTemplate{
                    .id = tmpl.id,
                    .name = try self.allocator.dupe(u8, tmpl.name),
                    .description = if (tmpl.description) |d| try self.allocator.dupe(u8, d) else null,
                    .default_settings = try self.allocator.dupe(u8, tmpl.default_settings),
                    .default_env_vars = try self.allocator.dupe(u8, tmpl.default_env_vars),
                    .created_at = tmpl.created_at,
                };
            }
        }
        
        return null;
    }

    fn applyTemplateEnvVars(self: *WorkspaceService, workspace_id: types.WorkspaceId, env_vars_json: []const u8) !void {
        // Simple JSON parsing for environment variables
        // Format: {"KEY1": "value1", "KEY2": "value2"}
        
        var parser = std.json.Parser.init(self.allocator, .{});
        defer parser.deinit();
        
        var tree = parser.parse(env_vars_json) catch return; // Skip if invalid JSON
        defer tree.deinit();
        
        if (tree.root != .object) return;
        
        var it = tree.root.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == .string) {
                try self.setEnvVar(workspace_id, entry.key_ptr.*, entry.value_ptr.string);
            }
        }
    }

    /// Create default workspace for new users
    pub fn createDefaultWorkspace(self: *WorkspaceService, user_id: types.UserId) !types.Workspace {
        const workspace = try self.createWorkspace(
            user_id,
            "default",
            "Default workspace",
            "default",
            null,
        );
        
        // Set as active workspace
        try self.workspace_repo.setActiveWorkspace(user_id, workspace.id);
        
        return workspace;
    }

    /// Ensure user has an active workspace, creating default if none exists
    pub fn ensureActiveWorkspace(self: *WorkspaceService, user_id: types.UserId) !types.Workspace {
        if (try self.getCurrentWorkspace(user_id)) |workspace| {
            return workspace;
        }
        
        // No active workspace, check if user has any workspaces
        const workspaces = try self.listWorkspaces(user_id, 1, 0);
        defer {
            for (workspaces) |*ws| {
                ws.deinit(self.allocator);
            }
            self.allocator.free(workspaces);
        }
        
        if (workspaces.len > 0) {
            // User has workspaces but none active, activate the first one
            try self.workspace_repo.setActiveWorkspace(user_id, workspaces[0].id);
            return try self.workspace_repo.get(workspaces[0].id) orelse error.WorkspaceNotFound;
        }
        
        // No workspaces exist, create default
        return try self.createDefaultWorkspace(user_id);
    }
};

test "workspace service basic operations" {
    // This would require database setup, so keep it as a placeholder
    std.testing.log_level = .debug;
}