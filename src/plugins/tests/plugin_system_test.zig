const std = @import("std");
const plugin_core = @import("../core/root.zig");

/// Comprehensive tests for the Marathon plugin system
const PluginSystemTest = struct {
    allocator: std.mem.Allocator,
    temp_dir: std.testing.TmpDir,
    plugin_manager: *plugin_core.PluginManager,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        var temp_dir = std.testing.tmpDir(.{});
        const temp_path = try temp_dir.dir.realpathAlloc(allocator, ".");
        defer allocator.free(temp_path);
        
        const config = plugin_core.PluginManager.Config{
            .enable_sandboxing = false,
            .plugin_install_dir = temp_path,
        };
        
        var manager = try allocator.create(plugin_core.PluginManager);
        manager.* = try plugin_core.PluginManager.init(allocator, config);
        
        return Self{
            .allocator = allocator,
            .temp_dir = temp_dir,
            .plugin_manager = manager,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.plugin_manager.deinit();
        self.allocator.destroy(self.plugin_manager);
        self.temp_dir.cleanup();
    }
    
    /// Test plugin manifest parsing and validation
    pub fn testManifestParsing(self: *Self) !void {
        var parser = plugin_core.ManifestParser.init(self.allocator);
        
        const valid_manifest =
            \\{
            \\  "name": "test-plugin",
            \\  "version": "1.0.0",
            \\  "description": "A test plugin",
            \\  "author": "Test Author",
            \\  "api_version": "1.0.0",
            \\  "permissions": ["task_read", "network"],
            \\  "hooks": ["post_task_execute"],
            \\  "commands": ["test-command"]
            \\}
        ;
        
        var manifest = try parser.parseFromString(valid_manifest);
        defer parser.freeManifest(&manifest);
        
        // Validate parsed fields
        try std.testing.expectEqualSlices(u8, "test-plugin", manifest.name);
        try std.testing.expectEqualSlices(u8, "1.0.0", manifest.version);
        try std.testing.expectEqualSlices(u8, "A test plugin", manifest.description);
        try std.testing.expectEqual(@as(usize, 2), manifest.permissions.len);
        try std.testing.expectEqual(plugin_core.Permission.task_read, manifest.permissions[0]);
        try std.testing.expectEqual(plugin_core.Permission.network, manifest.permissions[1]);
        try std.testing.expectEqual(@as(usize, 1), manifest.hooks.len);
        try std.testing.expectEqual(plugin_core.HookType.post_task_execute, manifest.hooks[0]);
        try std.testing.expectEqual(@as(usize, 1), manifest.commands.len);
        try std.testing.expectEqualSlices(u8, "test-command", manifest.commands[0]);
        
        // Test manifest validation
        try parser.validate(&manifest);
    }
    
    /// Test invalid manifest rejection
    pub fn testInvalidManifest(self: *Self) !void {
        var parser = plugin_core.ManifestParser.init(self.allocator);
        
        const invalid_manifest =
            \\{
            \\  "name": "invalid/plugin",
            \\  "version": "not-a-version",
            \\  "description": "Invalid plugin",
            \\  "author": "Test Author",
            \\  "api_version": "999.0.0"
            \\}
        ;
        
        var manifest = parser.parseFromString(invalid_manifest) catch |err| {
            try std.testing.expect(err == plugin_core.plugin_manifest.ValidationError.InvalidManifest or 
                                  err == plugin_core.plugin_manifest.ValidationError.UnsupportedAPIVersion);
            return;
        };
        defer parser.freeManifest(&manifest);
        
        // Validation should fail
        const validation_result = parser.validate(&manifest);
        try std.testing.expectError(plugin_core.plugin_manifest.ValidationError.InvalidManifest, validation_result);
    }
    
    /// Test plugin registry operations
    pub fn testPluginRegistry(self: *Self) !void {
        // Test empty registry
        var stats = self.plugin_manager.getStats();
        try std.testing.expectEqual(@as(u32, 0), stats.total());
        
        // Create a test plugin directory
        try self.temp_dir.dir.makePath("test-plugin");
        
        const manifest_json =
            \\{
            \\  "name": "test-plugin",
            \\  "version": "1.0.0",
            \\  "description": "A test plugin for registry testing",
            \\  "author": "Test Suite",
            \\  "api_version": "1.0.0",
            \\  "permissions": ["task_read"],
            \\  "hooks": ["post_task_execute"]
            \\}
        ;
        
        const plugin_dir = try self.temp_dir.dir.openDir("test-plugin", .{});
        const manifest_file = try plugin_dir.createFile("plugin.json", .{});
        try manifest_file.writeAll(manifest_json);
        manifest_file.close();
        
        // Test plugin discovery
        const discovery_result = try self.plugin_manager.registry.discoverPlugins();
        defer {
            self.allocator.free(discovery_result.found_plugins);
            for (discovery_result.errors) |err| {
                self.allocator.free(err.path);
                self.allocator.free(err.message);
            }
            self.allocator.free(discovery_result.errors);
        }
        
        // Should find our test plugin
        try std.testing.expectEqual(@as(usize, 1), discovery_result.found_plugins.len);
        try std.testing.expectEqualSlices(u8, "test-plugin", discovery_result.found_plugins[0]);
        
        // Check registry stats
        stats = self.plugin_manager.getStats();
        try std.testing.expectEqual(@as(u32, 1), stats.total());
        try std.testing.expectEqual(@as(u32, 1), stats.discovered);
    }
    
    /// Test event system
    pub fn testEventSystem(self: *Self) !void {
        var event_system = plugin_core.EventSystem.init(self.allocator);
        defer event_system.deinit();
        
        // Test initial state
        var stats = event_system.getStats();
        try std.testing.expectEqual(@as(usize, 0), stats.total_subscriptions);
        try std.testing.expectEqual(@as(usize, 0), stats.total_events);
        
        // Test firing hook with no subscriptions
        try event_system.fireHook(.post_task_execute, null, null);
        
        stats = event_system.getStats();
        try std.testing.expectEqual(@as(usize, 1), stats.total_events);
        
        // Test recent events
        const events = event_system.getRecentEvents(10);
        try std.testing.expectEqual(@as(usize, 1), events.len);
        try std.testing.expectEqual(plugin_core.HookType.post_task_execute, events[0].hook_type);
        try std.testing.expect(events[0].success);
    }
    
    /// Test security validator
    pub fn testSecurityValidator(self: *Self) !void {
        const policy = plugin_core.SecurityValidator.SecurityPolicy{
            .require_signatures = false,
            .allow_unsigned_dev = true,
        };
        
        var validator = plugin_core.SecurityValidator.init(self.allocator, policy);
        defer validator.deinit();
        
        // Test permission checking
        const permissions = [_]plugin_core.Permission{.task_read, .network};
        try validator.checkPermission("test-plugin", &permissions, .task_read);
        try validator.checkPermission("test-plugin", &permissions, .network);
        
        // Test permission denial
        const no_permissions = [_]plugin_core.Permission{};
        const result = validator.checkPermission("test-plugin", &no_permissions, .filesystem);
        try std.testing.expectError(plugin_core.SecurityError.PermissionDenied, result);
    }
    
    /// Test plugin sandboxing
    pub fn testPluginSandbox(self: *Self) !void {
        const policy = plugin_core.SecurityValidator.SecurityPolicy{};
        var validator = plugin_core.SecurityValidator.init(self.allocator, policy);
        defer validator.deinit();
        
        const permissions = [_]plugin_core.Permission{.task_read, .network};
        var sandbox = try validator.createSandbox("test-plugin", &permissions);
        
        // Test resource allocation
        try sandbox.checkResourceAllocation(.memory, 1024);
        sandbox.updateResourceUsage(.memory, 1024);
        try std.testing.expectEqual(@as(usize, 1024), sandbox.current_usage.memory_used);
        
        // Test resource limit enforcement
        const large_allocation = sandbox.checkResourceAllocation(.memory, sandbox.resource_limits.max_memory);
        try std.testing.expectError(plugin_core.SecurityError.ResourceLimitExceeded, large_allocation);
    }
    
    /// Test complete plugin lifecycle
    pub fn testPluginLifecycle(self: *Self) !void {
        // Create test plugin files
        try self.createTestPlugin();
        
        // Test plugin discovery
        try self.plugin_manager.initialize();
        
        var stats = self.plugin_manager.getStats();
        try std.testing.expectEqual(@as(u32, 1), stats.total());
        
        // Test plugin installation (from discovered state)
        const plugin = self.plugin_manager.getPlugin("lifecycle-test") orelse {
            try std.testing.expect(false); // Plugin should exist
            return;
        };
        
        try std.testing.expectEqual(plugin_core.PluginStatus.discovered, plugin.status);
        
        // Note: Full lifecycle testing (enable/disable) would require 
        // actual plugin loading which is complex in the test environment
        
        // Test plugin info retrieval
        const retrieved_plugin = self.plugin_manager.getPlugin("lifecycle-test");
        try std.testing.expect(retrieved_plugin != null);
        try std.testing.expectEqualSlices(u8, "lifecycle-test", retrieved_plugin.?.manifest.name);
    }
    
    /// Create a test plugin for lifecycle testing
    fn createTestPlugin(self: *Self) !void {
        try self.temp_dir.dir.makePath("lifecycle-test");
        
        const manifest_json =
            \\{
            \\  "name": "lifecycle-test",
            \\  "version": "1.0.0",
            \\  "description": "Plugin for lifecycle testing",
            \\  "author": "Test Suite",
            \\  "api_version": "1.0.0",
            \\  "permissions": ["task_read"],
            \\  "hooks": ["post_task_execute"],
            \\  "commands": ["test"]
            \\}
        ;
        
        const plugin_zig =
            \\const std = @import("std");
            \\const plugin_core = @import("../../../core/root.zig");
            \\
            \\// Minimal plugin implementation for testing
            \\var initialized: bool = false;
            \\
            \\const manifest = plugin_core.Manifest{
            \\    .name = "lifecycle-test",
            \\    .version = "1.0.0",
            \\    .description = "Plugin for lifecycle testing",
            \\    .author = "Test Suite",
            \\    .api_version = plugin_core.plugin_api.PLUGIN_API_VERSION,
            \\    .permissions = &.{.task_read},
            \\    .hooks = &.{.post_task_execute},
            \\};
            \\
            \\fn init(context: *plugin_core.Context) anyerror!void {
            \\    _ = context;
            \\    initialized = true;
            \\}
            \\
            \\fn deinit(context: *plugin_core.Context) anyerror!void {
            \\    _ = context;
            \\    initialized = false;
            \\}
            \\
            \\fn hook(context: *plugin_core.Context, hook_type: plugin_core.HookType, data: ?[]const u8) anyerror!plugin_core.HookResult {
            \\    _ = context;
            \\    _ = hook_type;
            \\    _ = data;
            \\    return plugin_core.utils.success("Test hook executed");
            \\}
            \\
            \\fn command(context: *plugin_core.Context, args: []const []const u8) anyerror!plugin_core.HookResult {
            \\    _ = context;
            \\    _ = args;
            \\    return plugin_core.utils.success("Test command executed");
            \\}
            \\
            \\pub const plugin_interface = plugin_core.PluginAPI.Interface{
            \\    .manifest = manifest,
            \\    .init = init,
            \\    .deinit = deinit,
            \\    .hook = hook,
            \\    .command = command,
            \\};
        ;
        
        const plugin_dir = try self.temp_dir.dir.openDir("lifecycle-test", .{});
        
        const manifest_file = try plugin_dir.createFile("plugin.json", .{});
        try manifest_file.writeAll(manifest_json);
        manifest_file.close();
        
        const plugin_file = try plugin_dir.createFile("plugin.zig", .{});
        try plugin_file.writeAll(plugin_zig);
        plugin_file.close();
    }
};

// Test runner
test "plugin system comprehensive tests" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var test_suite = try PluginSystemTest.init(allocator);
    defer test_suite.deinit();
    
    // Run all tests
    try test_suite.testManifestParsing();
    try test_suite.testInvalidManifest();
    try test_suite.testPluginRegistry();
    try test_suite.testEventSystem();
    try test_suite.testSecurityValidator();
    try test_suite.testPluginSandbox();
    try test_suite.testPluginLifecycle();
}

// Individual component tests for better test isolation

test "plugin API utilities" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var context = plugin_core.Context{
        .allocator = allocator,
        .plugin_name = "test-plugin",
        .plugin_version = "1.0.0",
        .permissions = &.{.task_read, .network},
    };
    
    // Test permission checking
    try std.testing.expect(plugin_core.utils.hasPermission(&context, .task_read));
    try std.testing.expect(plugin_core.utils.hasPermission(&context, .network));
    try std.testing.expect(!plugin_core.utils.hasPermission(&context, .filesystem));
    
    // Test result creation
    const success_result = plugin_core.utils.success("Test successful");
    try std.testing.expect(success_result.success);
    try std.testing.expect(success_result.continue_chain);
    
    const failure_result = plugin_core.utils.failure("Test failed");
    try std.testing.expect(!failure_result.success);
    try std.testing.expect(!failure_result.continue_chain);
}

test "manifest parser error handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var parser = plugin_core.ManifestParser.init(allocator);
    
    // Test malformed JSON
    const malformed_json = "{ invalid json }";
    const result = parser.parseFromString(malformed_json);
    try std.testing.expectError(plugin_core.plugin_manifest.ValidationError.InvalidManifest, result);
    
    // Test missing required fields
    const missing_fields =
        \\{
        \\  "name": "test",
        \\  "description": "Missing version and author"
        \\}
    ;
    const result2 = parser.parseFromString(missing_fields);
    try std.testing.expectError(plugin_core.plugin_manifest.ValidationError.MissingRequiredField, result2);
}

test "event system hook subscriptions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var event_system = plugin_core.EventSystem.init(allocator);
    defer event_system.deinit();
    
    var context = plugin_core.Context{
        .allocator = allocator,
        .plugin_name = "test-plugin",
        .plugin_version = "1.0.0",
        .permissions = &.{.task_read},
    };
    
    // Mock hook function
    const MockHookFn = struct {
        fn hook(ctx: *plugin_core.Context, hook_type: plugin_core.HookType, data: ?[]const u8) anyerror!plugin_core.HookResult {
            _ = ctx;
            _ = hook_type;
            _ = data;
            return plugin_core.utils.success("Mock hook executed");
        }
    };
    
    // Test subscription
    try event_system.subscribeHook(.post_task_execute, "test-plugin", MockHookFn.hook, &context, 0);
    
    var stats = event_system.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats.total_subscriptions);
    
    // Test hook firing
    try event_system.fireHook(.post_task_execute, null, null);
    
    stats = event_system.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats.total_events);
    
    // Test unsubscription
    try event_system.unsubscribeHook(.post_task_execute, "test-plugin");
    
    stats = event_system.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats.total_subscriptions);
}

test "security validator policy enforcement" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test strict policy
    const strict_policy = plugin_core.SecurityValidator.SecurityPolicy{
        .require_signatures = true,
        .allow_unsigned_dev = false,
        .max_plugin_size = 1024, // 1KB limit
    };
    
    var validator = plugin_core.SecurityValidator.init(allocator, strict_policy);
    defer validator.deinit();
    
    // Create a mock manifest without signature
    const manifest = plugin_core.plugin_manifest.Manifest{
        .name = "unsigned-plugin",
        .version = "1.0.0",
        .description = "Test plugin",
        .author = "Test",
        .api_version = "1.0.0",
        .permissions = &.{.task_read},
        .hooks = &.{},
        .commands = &.{},
        .dependencies = &.{},
        .signature = null, // No signature
    };
    
    // Should fail validation due to missing signature
    const result = validator.validatePluginSecurity("/fake/path", &manifest);
    try std.testing.expectError(plugin_core.SecurityError.UntrustedPlugin, result);
}