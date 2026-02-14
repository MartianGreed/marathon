const std = @import("std");
const plugin_api = @import("plugin_api.zig");
const plugin_manifest = @import("plugin_manifest.zig");

/// Plugin status in the registry
pub const PluginStatus = enum {
    discovered,   // Found but not installed
    installed,    // Installed but not loaded
    loaded,       // Loaded but not enabled
    enabled,      // Active and running
    disabled,     // Installed but disabled
    error,        // In error state
};

/// Plugin registry entry
pub const PluginEntry = struct {
    /// Plugin manifest
    manifest: plugin_manifest.Manifest,
    /// Current status
    status: PluginStatus,
    /// Installation path
    install_path: []const u8,
    /// Load timestamp
    loaded_at: ?i64 = null,
    /// Error message if status is error
    error_message: ?[]const u8 = null,
    /// Plugin interface (when loaded)
    interface: ?plugin_api.PluginAPI.Interface = null,
    /// Plugin library handle (for dynamic loading)
    lib_handle: ?*anyopaque = null,
};

/// Plugin discovery result
pub const DiscoveryResult = struct {
    found_plugins: []const []const u8,
    errors: []const DiscoveryError,
    
    pub const DiscoveryError = struct {
        path: []const u8,
        error: anyerror,
        message: []const u8,
    };
};

/// Plugin registry manages all plugins in the system
pub const PluginRegistry = struct {
    allocator: std.mem.Allocator,
    /// Registry of all plugins (name -> entry)
    plugins: std.HashMap([]const u8, *PluginEntry, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    /// Plugin search paths
    search_paths: std.ArrayList([]const u8),
    /// Manifest parser
    manifest_parser: plugin_manifest.ManifestParser,
    
    /// Default plugin directories
    const DEFAULT_PLUGIN_PATHS = [_][]const u8{
        "src/plugins/installed",
        "src/plugins/examples", 
        "/usr/local/share/marathon/plugins",
        "~/.marathon/plugins",
    };
    
    pub fn init(allocator: std.mem.Allocator) PluginRegistry {
        var registry = PluginRegistry{
            .allocator = allocator,
            .plugins = std.HashMap([]const u8, *PluginEntry, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .search_paths = std.ArrayList([]const u8).init(allocator),
            .manifest_parser = plugin_manifest.ManifestParser.init(allocator),
        };
        
        // Add default search paths
        for (DEFAULT_PLUGIN_PATHS) |path| {
            registry.addSearchPath(path) catch {}; // Ignore errors for default paths
        }
        
        return registry;
    }
    
    pub fn deinit(self: *PluginRegistry) void {
        // Cleanup all plugins
        var iterator = self.plugins.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.freePluginEntry(entry.value_ptr.*);
        }
        self.plugins.deinit();
        
        // Cleanup search paths
        for (self.search_paths.items) |path| {
            self.allocator.free(path);
        }
        self.search_paths.deinit();
    }
    
    /// Add a plugin search path
    pub fn addSearchPath(self: *PluginRegistry, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        try self.search_paths.append(owned_path);
    }
    
    /// Discover plugins in all search paths
    pub fn discoverPlugins(self: *PluginRegistry) !DiscoveryResult {
        var found_plugins = std.ArrayList([]const u8).init(self.allocator);
        var errors = std.ArrayList(DiscoveryResult.DiscoveryError).init(self.allocator);
        
        for (self.search_paths.items) |search_path| {
            self.discoverPluginsInPath(search_path, &found_plugins, &errors) catch |err| {
                try errors.append(.{
                    .path = try self.allocator.dupe(u8, search_path),
                    .error = err,
                    .message = try std.fmt.allocPrint(self.allocator, "Failed to scan directory: {}", .{err}),
                });
            };
        }
        
        return DiscoveryResult{
            .found_plugins = found_plugins.toOwnedSlice(),
            .errors = errors.toOwnedSlice(),
        };
    }
    
    /// Discover plugins in a specific path
    fn discoverPluginsInPath(
        self: *PluginRegistry, 
        path: []const u8, 
        found_plugins: *std.ArrayList([]const u8),
        errors: *std.ArrayList(DiscoveryResult.DiscoveryError)
    ) !void {
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
            if (err != error.FileNotFound) {
                return err;
            }
            return; // Skip non-existent directories
        };
        defer dir.close();
        
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .directory) continue;
            
            // Look for plugin.json in subdirectory
            const manifest_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/plugin.json", .{ path, entry.name });
            defer self.allocator.free(manifest_path);
            
            if (std.fs.cwd().access(manifest_path, .{})) |_| {
                try self.discoverPlugin(path, entry.name, found_plugins, errors);
            } else |_| {
                // No manifest found, skip
            }
        }
    }
    
    /// Discover a single plugin
    fn discoverPlugin(
        self: *PluginRegistry, 
        base_path: []const u8, 
        plugin_name: []const u8,
        found_plugins: *std.ArrayList([]const u8),
        errors: *std.ArrayList(DiscoveryResult.DiscoveryError)
    ) !void {
        const plugin_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, plugin_name });
        defer self.allocator.free(plugin_dir);
        
        const manifest_path = try std.fmt.allocPrint(self.allocator, "{s}/plugin.json", .{plugin_dir});
        defer self.allocator.free(manifest_path);
        
        // Parse manifest
        var manifest = self.manifest_parser.parseFromFile(manifest_path) catch |err| {
            try errors.append(.{
                .path = try self.allocator.dupe(u8, plugin_dir),
                .error = err,
                .message = try std.fmt.allocPrint(self.allocator, "Failed to parse manifest: {}", .{err}),
            });
            return;
        };
        
        // Validate manifest
        self.manifest_parser.validate(&manifest) catch |err| {
            try errors.append(.{
                .path = try self.allocator.dupe(u8, plugin_dir),
                .error = err,
                .message = try std.fmt.allocPrint(self.allocator, "Manifest validation failed: {}", .{err}),
            });
            self.manifest_parser.freeManifest(&manifest);
            return;
        };
        
        // Register plugin
        try self.registerPlugin(manifest, plugin_dir);
        try found_plugins.append(try self.allocator.dupe(u8, manifest.name));
    }
    
    /// Register a plugin in the registry
    pub fn registerPlugin(self: *PluginRegistry, manifest: plugin_manifest.Manifest, install_path: []const u8) !void {
        const plugin_name = try self.allocator.dupe(u8, manifest.name);
        
        // Check if plugin already exists
        if (self.plugins.get(plugin_name)) |existing| {
            std.log.warn("Plugin '{}' already registered, updating...", .{plugin_name});
            self.freePluginEntry(existing);
        }
        
        const entry = try self.allocator.create(PluginEntry);
        entry.* = PluginEntry{
            .manifest = manifest,
            .status = .discovered,
            .install_path = try self.allocator.dupe(u8, install_path),
        };
        
        try self.plugins.put(plugin_name, entry);
        std.log.info("Registered plugin: {s} v{s}", .{ manifest.name, manifest.version });
    }
    
    /// Get plugin by name
    pub fn getPlugin(self: *PluginRegistry, name: []const u8) ?*PluginEntry {
        return self.plugins.get(name);
    }
    
    /// List all plugins with optional status filter
    pub fn listPlugins(self: *PluginRegistry, status_filter: ?PluginStatus) ![]const *PluginEntry {
        var result = std.ArrayList(*PluginEntry).init(self.allocator);
        
        var iterator = self.plugins.valueIterator();
        while (iterator.next()) |entry| {
            if (status_filter == null or entry.*.status == status_filter.?) {
                try result.append(entry.*);
            }
        }
        
        return result.toOwnedSlice();
    }
    
    /// Update plugin status
    pub fn updatePluginStatus(self: *PluginRegistry, name: []const u8, status: PluginStatus) !void {
        if (self.plugins.getPtr(name)) |entry| {
            entry.status = status;
            if (status == .enabled or status == .loaded) {
                entry.loaded_at = std.time.timestamp();
            }
            std.log.debug("Updated plugin '{}' status to {}", .{ name, status });
        } else {
            return error.PluginNotFound;
        }
    }
    
    /// Set plugin error state
    pub fn setPluginError(self: *PluginRegistry, name: []const u8, error_message: []const u8) !void {
        if (self.plugins.getPtr(name)) |entry| {
            entry.status = .error;
            if (entry.error_message) |old_msg| {
                self.allocator.free(old_msg);
            }
            entry.error_message = try self.allocator.dupe(u8, error_message);
            std.log.err("Plugin '{}' error: {s}", .{ name, error_message });
        } else {
            return error.PluginNotFound;
        }
    }
    
    /// Remove plugin from registry
    pub fn unregisterPlugin(self: *PluginRegistry, name: []const u8) !void {
        if (self.plugins.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.freePluginEntry(kv.value);
            std.log.info("Unregistered plugin: {s}", .{name});
        } else {
            return error.PluginNotFound;
        }
    }
    
    /// Get plugin statistics
    pub fn getStats(self: *PluginRegistry) PluginStats {
        var stats = PluginStats{};
        
        var iterator = self.plugins.valueIterator();
        while (iterator.next()) |entry| {
            switch (entry.*.status) {
                .discovered => stats.discovered += 1,
                .installed => stats.installed += 1,
                .loaded => stats.loaded += 1,
                .enabled => stats.enabled += 1,
                .disabled => stats.disabled += 1,
                .error => stats.error += 1,
            }
        }
        
        return stats;
    }
    
    /// Plugin statistics
    pub const PluginStats = struct {
        discovered: u32 = 0,
        installed: u32 = 0,
        loaded: u32 = 0,
        enabled: u32 = 0,
        disabled: u32 = 0,
        error: u32 = 0,
        
        pub fn total(self: PluginStats) u32 {
            return self.discovered + self.installed + self.loaded + self.enabled + self.disabled + self.error;
        }
    };
    
    /// Free plugin entry memory
    fn freePluginEntry(self: *PluginRegistry, entry: *PluginEntry) void {
        self.manifest_parser.freeManifest(&entry.manifest);
        self.allocator.free(entry.install_path);
        if (entry.error_message) |msg| {
            self.allocator.free(msg);
        }
        self.allocator.destroy(entry);
    }
};

test "plugin registry basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();
    
    // Test adding search path
    try registry.addSearchPath("/test/plugins");
    try std.testing.expectEqual(@as(usize, 1 + PluginRegistry.DEFAULT_PLUGIN_PATHS.len), registry.search_paths.items.len);
    
    // Test plugin stats
    const stats = registry.getStats();
    try std.testing.expectEqual(@as(u32, 0), stats.total());
}