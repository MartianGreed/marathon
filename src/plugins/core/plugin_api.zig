const std = @import("std");

/// Plugin API version for compatibility checking
pub const PLUGIN_API_VERSION = "1.0.0";

/// Plugin permission types
pub const Permission = enum {
    /// Read access to task data
    task_read,
    /// Write access to task data
    task_write,
    /// Access to user authentication data
    user_auth,
    /// Network access
    network,
    /// File system access
    filesystem,
    /// Environment variable access
    env_vars,
    /// System command execution
    exec,
};

/// Plugin hook types for event system
pub const HookType = enum {
    /// Called before task submission
    pre_task_submit,
    /// Called after task submission
    post_task_submit,
    /// Called before task execution starts
    pre_task_execute,
    /// Called after task execution completes
    post_task_execute,
    /// Called during user authentication
    user_auth,
    /// Called during user authorization
    user_authz,
    /// Called for custom CLI commands
    cli_command,
    /// Called for configuration validation
    config_validate,
    /// Called during plugin installation
    plugin_install,
    /// Called during plugin uninstallation
    plugin_uninstall,
};

/// Plugin execution context
pub const Context = struct {
    /// Allocator for memory management
    allocator: std.mem.Allocator,
    /// Plugin name and version
    plugin_name: []const u8,
    plugin_version: []const u8,
    /// Granted permissions
    permissions: []const Permission,
    /// Task ID if hook is task-related
    task_id: ?[]const u8 = null,
    /// User ID if hook is user-related
    user_id: ?[]const u8 = null,
    /// Additional context data
    context_data: ?[]const u8 = null,
};

/// Plugin hook result
pub const HookResult = struct {
    /// Whether the hook execution was successful
    success: bool,
    /// Optional message
    message: ?[]const u8 = null,
    /// Whether to continue executing other hooks
    continue_chain: bool = true,
    /// Optional result data
    result_data: ?[]const u8 = null,
};

/// Plugin API interface
pub const PluginAPI = struct {
    /// Plugin manifest information
    pub const Manifest = struct {
        name: []const u8,
        version: []const u8,
        description: []const u8,
        author: []const u8,
        api_version: []const u8,
        permissions: []const Permission,
        hooks: []const HookType,
        dependencies: []const []const u8 = &.{},
        config_schema: ?[]const u8 = null,
    };

    /// Plugin initialization function type
    pub const InitFn = *const fn (context: *Context) anyerror!void;
    
    /// Plugin cleanup function type  
    pub const DeinitFn = *const fn (context: *Context) anyerror!void;
    
    /// Plugin hook function type
    pub const HookFn = *const fn (context: *Context, hook_type: HookType, data: ?[]const u8) anyerror!HookResult;
    
    /// Plugin command handler type
    pub const CommandFn = *const fn (context: *Context, args: []const []const u8) anyerror!HookResult;

    /// Required plugin interface
    pub const Interface = struct {
        manifest: Manifest,
        init: InitFn,
        deinit: DeinitFn,
        hook: HookFn,
        command: ?CommandFn = null,
    };
};

/// Utility functions for plugin development
pub const utils = struct {
    /// Parse JSON configuration
    pub fn parseConfig(allocator: std.mem.Allocator, config_json: []const u8) !std.json.Value {
        var parser = std.json.Parser.init(allocator, .{});
        defer parser.deinit();
        var tree = try parser.parse(config_json);
        return tree.root;
    }
    
    /// Log plugin message with standardized format
    pub fn log(context: *Context, level: std.log.Level, comptime format: []const u8, args: anytype) void {
        const prefix = std.fmt.allocPrint(context.allocator, "[plugin:{s}] ", .{context.plugin_name}) catch return;
        defer context.allocator.free(prefix);
        
        switch (level) {
            .debug => std.log.debug("{s}" ++ format, .{prefix} ++ args),
            .info => std.log.info("{s}" ++ format, .{prefix} ++ args),
            .warn => std.log.warn("{s}" ++ format, .{prefix} ++ args),
            .err => std.log.err("{s}" ++ format, .{prefix} ++ args),
        }
    }
    
    /// Check if plugin has required permission
    pub fn hasPermission(context: *Context, permission: Permission) bool {
        for (context.permissions) |perm| {
            if (perm == permission) return true;
        }
        return false;
    }
    
    /// Create success result
    pub fn success(message: ?[]const u8) HookResult {
        return HookResult{
            .success = true,
            .message = message,
        };
    }
    
    /// Create error result
    pub fn failure(message: []const u8) HookResult {
        return HookResult{
            .success = false,
            .message = message,
            .continue_chain = false,
        };
    }
};

test "plugin API basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var context = Context{
        .allocator = allocator,
        .plugin_name = "test-plugin",
        .plugin_version = "1.0.0",
        .permissions = &.{.task_read, .network},
    };
    
    // Test permission checking
    try std.testing.expect(utils.hasPermission(&context, .task_read));
    try std.testing.expect(utils.hasPermission(&context, .network));
    try std.testing.expect(!utils.hasPermission(&context, .filesystem));
    
    // Test result creation
    const success_result = utils.success("Test successful");
    try std.testing.expect(success_result.success);
    try std.testing.expect(success_result.continue_chain);
    
    const failure_result = utils.failure("Test failed");
    try std.testing.expect(!failure_result.success);
    try std.testing.expect(!failure_result.continue_chain);
}