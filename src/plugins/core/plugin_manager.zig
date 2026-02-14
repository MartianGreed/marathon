const std = @import("std");
const plugin_api = @import("plugin_api.zig");
const plugin_registry = @import("plugin_registry.zig");
const plugin_manifest = @import("plugin_manifest.zig");
const event_system = @import("event_system.zig");

/// Plugin manager errors
pub const PluginError = error{
    PluginNotFound,
    PluginAlreadyInstalled,
    PluginAlreadyEnabled,
    PluginNotInstalled,
    PluginNotEnabled,
    DependencyNotFound,
    CircularDependency,
    SecurityViolation,
    LoadFailed,
    InitializationFailed,
    PermissionDenied,
};

/// Plugin installation source
pub const InstallSource = union(enum) {
    /// Local directory path
    local: []const u8,
    /// Remote URL (future enhancement)
    remote: []const u8,
    /// Built-in plugin
    builtin: []const u8,
};

/// Plugin manager configuration
pub const Config = struct {
    /// Enable plugin sandboxing
    enable_sandboxing: bool = true,
    /// Maximum plugin memory usage (bytes)
    max_memory_per_plugin: usize = 64 * 1024 * 1024, // 64MB
    /// Plugin initialization timeout (milliseconds)  
    init_timeout_ms: u64 = 5000,
    /// Allow dangerous permissions
    allow_dangerous_permissions: bool = false,
    /// Plugin installation directory
    plugin_install_dir: []const u8 = "src/plugins/installed",
};

/// Plugin manager handles complete plugin lifecycle
pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    config: Config,
    registry: plugin_registry.PluginRegistry,
    event_system: event_system.EventSystem,
    /// Dependency graph for load ordering
    dependency_graph: std.HashMap([]const u8, std.ArrayList([]const u8), std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    
    pub fn init(allocator: std.mem.Allocator, config: Config) !PluginManager {
        var manager = PluginManager{
            .allocator = allocator,
            .config = config,
            .registry = plugin_registry.PluginRegistry.init(allocator),
            .event_system = event_system.EventSystem.init(allocator),
            .dependency_graph = std.HashMap([]const u8, std.ArrayList([]const u8), std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
        
        // Ensure plugin installation directory exists
        std.fs.cwd().makePath(config.plugin_install_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.log.err("Failed to create plugin installation directory: {}", .{err});
                return err;
            }
        };
        
        return manager;
    }
    
    pub fn deinit(self: *PluginManager) void {
        // Disable all enabled plugins
        self.disableAllPlugins() catch {};
        
        // Clean up dependency graph
        var dep_iterator = self.dependency_graph.iterator();
        while (dep_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.dependency_graph.deinit();
        
        self.event_system.deinit();
        self.registry.deinit();
    }
    
    /// Initialize plugin system - discover and validate plugins
    pub fn initialize(self: *PluginManager) !void {
        std.log.info("Initializing plugin system...");
        
        // Discover plugins
        const discovery_result = try self.registry.discoverPlugins();
        
        std.log.info("Discovered {} plugins", .{discovery_result.found_plugins.len});
        for (discovery_result.errors) |err| {
            std.log.warn("Plugin discovery error in {s}: {s}", .{ err.path, err.message });
        }
        
        // Build dependency graph
        try self.buildDependencyGraph();
        
        // Auto-enable previously enabled plugins (would load from state file)
        try self.autoEnablePreviouslyEnabledPlugins();
        
        std.log.info("Plugin system initialized successfully");
    }
    
    /// Install a plugin from source
    pub fn installPlugin(self: *PluginManager, name: []const u8, source: InstallSource) !void {
        // Check if plugin already installed
        if (self.registry.getPlugin(name)) |entry| {
            if (entry.status != .discovered) {
                return PluginError.PluginAlreadyInstalled;
            }
        }
        
        const install_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.config.plugin_install_dir, name });
        defer self.allocator.free(install_path);
        
        switch (source) {
            .local => |src_path| {
                try self.installFromLocal(name, src_path, install_path);
            },
            .remote => |url| {
                _ = url;
                // TODO: Implement remote installation
                return error.NotImplemented;
            },
            .builtin => |builtin_name| {
                _ = builtin_name;
                // TODO: Implement builtin plugin installation
                return error.NotImplemented;
            },
        }
        
        // Update plugin status
        try self.registry.updatePluginStatus(name, .installed);
        std.log.info("Plugin '{}' installed successfully", .{name});
        
        // Fire installation hook
        try self.event_system.fireHook(.plugin_install, name, null);
    }
    
    /// Enable a plugin (load and activate)
    pub fn enablePlugin(self: *PluginManager, name: []const u8) !void {
        const entry = self.registry.getPlugin(name) orelse return PluginError.PluginNotFound;
        
        switch (entry.status) {
            .enabled => return PluginError.PluginAlreadyEnabled,
            .error => {
                std.log.err("Cannot enable plugin '{}' in error state: {s}", .{ name, entry.error_message.? });
                return PluginError.LoadFailed;
            },
            else => {},
        }
        
        // Check dependencies
        try self.checkDependencies(name);
        
        // Load plugin if not already loaded
        if (entry.status != .loaded) {
            try self.loadPlugin(name);
        }
        
        // Initialize plugin
        try self.initializePlugin(name);
        
        // Update status
        try self.registry.updatePluginStatus(name, .enabled);
        std.log.info("Plugin '{}' enabled successfully", .{name});
    }
    
    /// Disable a plugin (deactivate but keep loaded)
    pub fn disablePlugin(self: *PluginManager, name: []const u8) !void {
        const entry = self.registry.getPlugin(name) orelse return PluginError.PluginNotFound;
        
        if (entry.status != .enabled) {
            return PluginError.PluginNotEnabled;
        }
        
        // Call plugin deinit
        if (entry.interface) |interface| {
            var context = try self.createContext(entry);
            defer self.freeContext(&context);
            
            interface.deinit(&context) catch |err| {
                std.log.warn("Plugin '{}' deinit failed: {}", .{ name, err });
            };
        }
        
        // Update status
        try self.registry.updatePluginStatus(name, .disabled);
        std.log.info("Plugin '{}' disabled", .{name});
    }
    
    /// Uninstall a plugin (remove from system)
    pub fn uninstallPlugin(self: *PluginManager, name: []const u8) !void {
        const entry = self.registry.getPlugin(name) orelse return PluginError.PluginNotFound;
        
        // Disable plugin if enabled
        if (entry.status == .enabled) {
            try self.disablePlugin(name);
        }
        
        // Fire uninstallation hook
        try self.event_system.fireHook(.plugin_uninstall, name, null);
        
        // Remove plugin files
        std.fs.cwd().deleteTree(entry.install_path) catch |err| {
            std.log.warn("Failed to remove plugin directory {s}: {}", .{ entry.install_path, err });
        };
        
        // Remove from registry
        try self.registry.unregisterPlugin(name);
        std.log.info("Plugin '{}' uninstalled", .{name});
    }
    
    /// List all plugins with their status
    pub fn listPlugins(self: *PluginManager) ![]const *plugin_registry.PluginEntry {
        return self.registry.listPlugins(null);
    }
    
    /// Get plugin by name
    pub fn getPlugin(self: *PluginManager, name: []const u8) ?*plugin_registry.PluginEntry {
        return self.registry.getPlugin(name);
    }
    
    /// Execute plugin hook
    pub fn executeHook(self: *PluginManager, hook_type: plugin_api.HookType, data: ?[]const u8) !void {
        try self.event_system.fireHook(hook_type, null, data);
    }
    
    /// Execute plugin command
    pub fn executeCommand(self: *PluginManager, plugin_name: []const u8, args: []const []const u8) !plugin_api.HookResult {
        const entry = self.registry.getPlugin(plugin_name) orelse return PluginError.PluginNotFound;
        
        if (entry.status != .enabled) {
            return plugin_api.utils.failure("Plugin not enabled");
        }
        
        if (entry.interface) |interface| {
            if (interface.command) |command_fn| {
                var context = try self.createContext(entry);
                defer self.freeContext(&context);
                
                return command_fn(&context, args);
            }
        }
        
        return plugin_api.utils.failure("Plugin does not support commands");
    }
    
    /// Get plugin manager statistics
    pub fn getStats(self: *PluginManager) plugin_registry.PluginRegistry.PluginStats {
        return self.registry.getStats();
    }
    
    // Private methods
    
    fn installFromLocal(self: *PluginManager, name: []const u8, src_path: []const u8, install_path: []const u8) !void {
        // Create installation directory
        std.fs.cwd().makePath(install_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        
        // Copy plugin files
        try self.copyDirectory(src_path, install_path);
        
        // Parse and validate manifest
        const manifest_path = try std.fmt.allocPrint(self.allocator, "{s}/plugin.json", .{install_path});
        defer self.allocator.free(manifest_path);
        
        var manifest = try self.registry.manifest_parser.parseFromFile(manifest_path);
        try self.registry.manifest_parser.validate(&manifest);
        
        // Register plugin
        try self.registry.registerPlugin(manifest, install_path);
    }
    
    fn loadPlugin(self: *PluginManager, name: []const u8) !void {
        const entry = self.registry.getPlugin(name) orelse return PluginError.PluginNotFound;
        
        // TODO: Implement dynamic library loading for Zig plugins
        // For now, this is a placeholder for the plugin loading mechanism
        
        std.log.info("Loading plugin: {s}", .{name});
        
        // Update status
        try self.registry.updatePluginStatus(name, .loaded);
    }
    
    fn initializePlugin(self: *PluginManager, name: []const u8) !void {
        const entry = self.registry.getPlugin(name) orelse return PluginError.PluginNotFound;
        
        if (entry.interface) |interface| {
            var context = try self.createContext(entry);
            defer self.freeContext(&context);
            
            // Initialize plugin with timeout
            const init_result = self.runWithTimeout(interface.init, &context, self.config.init_timeout_ms);
            init_result catch |err| {
                try self.registry.setPluginError(name, try std.fmt.allocPrint(self.allocator, "Initialization failed: {}", .{err}));
                return PluginError.InitializationFailed;
            };
        }
    }
    
    fn createContext(self: *PluginManager, entry: *plugin_registry.PluginEntry) !plugin_api.Context {
        return plugin_api.Context{
            .allocator = self.allocator,
            .plugin_name = entry.manifest.name,
            .plugin_version = entry.manifest.version,
            .permissions = entry.manifest.permissions,
        };
    }
    
    fn freeContext(self: *PluginManager, context: *plugin_api.Context) void {
        _ = self;
        _ = context;
        // Context cleanup if needed
    }
    
    fn checkDependencies(self: *PluginManager, name: []const u8) !void {
        const entry = self.registry.getPlugin(name) orelse return PluginError.PluginNotFound;
        
        for (entry.manifest.dependencies) |dep| {
            const dep_plugin = self.registry.getPlugin(dep.name);
            if (dep_plugin == null and !dep.optional) {
                return PluginError.DependencyNotFound;
            }
            if (dep_plugin != null and dep_plugin.?.status != .enabled and !dep.optional) {
                // Try to enable dependency
                self.enablePlugin(dep.name) catch |err| {
                    std.log.err("Failed to enable dependency '{}' for plugin '{}': {}", .{ dep.name, name, err });
                    return PluginError.DependencyNotFound;
                };
            }
        }
    }
    
    fn buildDependencyGraph(self: *PluginManager) !void {
        var plugin_list = try self.registry.listPlugins(null);
        defer self.allocator.free(plugin_list);
        
        for (plugin_list) |entry| {
            const plugin_name = try self.allocator.dupe(u8, entry.manifest.name);
            var deps = std.ArrayList([]const u8).init(self.allocator);
            
            for (entry.manifest.dependencies) |dep| {
                try deps.append(try self.allocator.dupe(u8, dep.name));
            }
            
            try self.dependency_graph.put(plugin_name, deps);
        }
    }
    
    fn autoEnablePreviouslyEnabledPlugins(self: *PluginManager) !void {
        // TODO: Load previous state from configuration file
        // For now, this is a placeholder
        _ = self;
        std.log.debug("Auto-enabling previously enabled plugins (not implemented)");
    }
    
    fn disableAllPlugins(self: *PluginManager) !void {
        var enabled_plugins = try self.registry.listPlugins(.enabled);
        defer self.allocator.free(enabled_plugins);
        
        for (enabled_plugins) |entry| {
            self.disablePlugin(entry.manifest.name) catch |err| {
                std.log.warn("Failed to disable plugin '{}': {}", .{ entry.manifest.name, err });
            };
        }
    }
    
    fn copyDirectory(self: *PluginManager, src: []const u8, dst: []const u8) !void {
        _ = self;
        // TODO: Implement recursive directory copying
        // For now, this is a placeholder
        std.log.debug("Copying directory from {s} to {s}", .{ src, dst });
        
        // Simple implementation - copy all files
        var src_dir = try std.fs.cwd().openDir(src, .{ .iterate = true });
        defer src_dir.close();
        
        var dst_dir = try std.fs.cwd().makeOpenPath(dst, .{});
        defer dst_dir.close();
        
        var iterator = src_dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file) {
                try src_dir.copyFile(entry.name, dst_dir, entry.name, .{});
            }
            // TODO: Handle subdirectories recursively
        }
    }
    
    fn runWithTimeout(self: *PluginManager, func: plugin_api.PluginAPI.InitFn, context: *plugin_api.Context, timeout_ms: u64) !void {
        _ = self;
        _ = timeout_ms;
        // TODO: Implement timeout mechanism
        // For now, just run the function directly
        try func(context);
    }
};

test "plugin manager initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = Config{
        .enable_sandboxing = false,
        .plugin_install_dir = "/tmp/test-plugins",
    };
    
    var manager = try PluginManager.init(allocator, config);
    defer manager.deinit();
    
    const stats = manager.getStats();
    try std.testing.expectEqual(@as(u32, 0), stats.total());
}