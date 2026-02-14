const std = @import("std");
const plugin_core = @import("../core/root.zig");

/// Plugin CLI command handler
pub const PluginCLI = struct {
    allocator: std.mem.Allocator,
    plugin_manager: *plugin_core.PluginManager,
    
    pub fn init(allocator: std.mem.Allocator, plugin_manager: *plugin_core.PluginManager) PluginCLI {
        return PluginCLI{
            .allocator = allocator,
            .plugin_manager = plugin_manager,
        };
    }
    
    /// Handle plugin CLI commands
    pub fn handlePluginCommand(self: *PluginCLI, args: []const []const u8) !void {
        if (args.len < 1) {
            self.printPluginUsage();
            return;
        }
        
        const subcommand = args[0];
        const subargs = args[1..];
        
        if (std.mem.eql(u8, subcommand, "list")) {
            try self.handleListCommand(subargs);
        } else if (std.mem.eql(u8, subcommand, "install")) {
            try self.handleInstallCommand(subargs);
        } else if (std.mem.eql(u8, subcommand, "uninstall")) {
            try self.handleUninstallCommand(subargs);
        } else if (std.mem.eql(u8, subcommand, "enable")) {
            try self.handleEnableCommand(subargs);
        } else if (std.mem.eql(u8, subcommand, "disable")) {
            try self.handleDisableCommand(subargs);
        } else if (std.mem.eql(u8, subcommand, "info")) {
            try self.handleInfoCommand(subargs);
        } else if (std.mem.eql(u8, subcommand, "run")) {
            try self.handleRunCommand(subargs);
        } else if (std.mem.eql(u8, subcommand, "refresh")) {
            try self.handleRefreshCommand(subargs);
        } else {
            std.debug.print("Unknown plugin command: {s}\n", .{subcommand});
            self.printPluginUsage();
        }
    }
    
    /// List all plugins
    fn handleListCommand(self: *PluginCLI, args: []const []const u8) !void {
        var filter_status: ?plugin_core.PluginStatus = null;
        
        // Parse arguments
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--status")) {
                i += 1;
                if (i >= args.len) {
                    std.debug.print("Error: --status requires a value\n");
                    return;
                }
                filter_status = std.meta.stringToEnum(plugin_core.PluginStatus, args[i]) orelse {
                    std.debug.print("Error: Unknown status '{s}'\n", .{args[i]});
                    return;
                };
            }
        }
        
        const plugins = try self.plugin_manager.registry.listPlugins(filter_status);
        defer self.allocator.free(plugins);
        
        if (plugins.len == 0) {
            if (filter_status) |status| {
                std.debug.print("No plugins found with status: {s}\n", .{@tagName(status)});
            } else {
                std.debug.print("No plugins found.\n");
            }
            return;
        }
        
        // Print header
        std.debug.print("Plugins:\n");
        std.debug.print("=========\n");
        std.debug.print("{s:<20} {s:<10} {s:<12} {s}\n", .{ "Name", "Version", "Status", "Description" });
        std.debug.print("{s:<20} {s:<10} {s:<12} {s}\n", .{ "----", "-------", "------", "-----------" });
        
        // Sort plugins by name for consistent output
        std.sort.insertion(*plugin_core.PluginEntry, plugins, {}, struct {
            pub fn lessThan(_: void, a: *plugin_core.PluginEntry, b: *plugin_core.PluginEntry) bool {
                return std.mem.lessThan(u8, a.manifest.name, b.manifest.name);
            }
        }.lessThan);
        
        // Print plugin list
        for (plugins) |plugin| {
            const status_icon = switch (plugin.status) {
                .discovered => "🔍",
                .installed => "📦",
                .loaded => "⚡",
                .enabled => "✅",
                .disabled => "⏸️",
                .error => "❌",
            };
            
            std.debug.print("{s:<20} {s:<10} {s} {s:<10} {s}\n", .{
                plugin.manifest.name,
                plugin.manifest.version,
                status_icon,
                @tagName(plugin.status),
                plugin.manifest.description,
            });
        }
        
        // Print summary
        const stats = self.plugin_manager.getStats();
        std.debug.print("\nSummary: {} total, {} enabled, {} disabled, {} errors\n", .{
            stats.total(),
            stats.enabled,
            stats.disabled,
            stats.error,
        });
    }
    
    /// Install a plugin
    fn handleInstallCommand(self: *PluginCLI, args: []const []const u8) !void {
        if (args.len < 1) {
            std.debug.print("Error: Plugin name or path required\n");
            std.debug.print("Usage: marathon plugin install <name|path>\n");
            return;
        }
        
        const plugin_spec = args[0];
        
        // Determine if this is a local path or plugin name
        const install_source = if (std.fs.path.isAbsolute(plugin_spec) or std.mem.startsWith(u8, plugin_spec, "."))
            plugin_core.InstallSource{ .local = plugin_spec }
        else
            plugin_core.InstallSource{ .builtin = plugin_spec };
        
        std.debug.print("Installing plugin: {s}\n", .{plugin_spec});
        
        self.plugin_manager.installPlugin(plugin_spec, install_source) catch |err| {
            std.debug.print("Error: Failed to install plugin '{s}': {}\n", .{ plugin_spec, err });
            return;
        };
        
        std.debug.print("✅ Plugin '{s}' installed successfully\n", .{plugin_spec});
    }
    
    /// Uninstall a plugin
    fn handleUninstallCommand(self: *PluginCLI, args: []const []const u8) !void {
        if (args.len < 1) {
            std.debug.print("Error: Plugin name required\n");
            std.debug.print("Usage: marathon plugin uninstall <name>\n");
            return;
        }
        
        const plugin_name = args[0];
        
        // Confirm uninstallation
        std.debug.print("Are you sure you want to uninstall plugin '{s}'? (y/N): ", .{plugin_name});
        
        var buffer: [10]u8 = undefined;
        if (try std.io.getStdIn().readUntilDelimiterOrEof(&buffer, '\n')) |input| {
            const trimmed = std.mem.trim(u8, input, " \t\r\n");
            if (!std.mem.eql(u8, trimmed, "y") and !std.mem.eql(u8, trimmed, "Y")) {
                std.debug.print("Uninstallation cancelled.\n");
                return;
            }
        } else {
            std.debug.print("Uninstallation cancelled.\n");
            return;
        }
        
        std.debug.print("Uninstalling plugin: {s}\n", .{plugin_name});
        
        self.plugin_manager.uninstallPlugin(plugin_name) catch |err| {
            std.debug.print("Error: Failed to uninstall plugin '{s}': {}\n", .{ plugin_name, err });
            return;
        };
        
        std.debug.print("✅ Plugin '{s}' uninstalled successfully\n", .{plugin_name});
    }
    
    /// Enable a plugin
    fn handleEnableCommand(self: *PluginCLI, args: []const []const u8) !void {
        if (args.len < 1) {
            std.debug.print("Error: Plugin name required\n");
            std.debug.print("Usage: marathon plugin enable <name>\n");
            return;
        }
        
        const plugin_name = args[0];
        
        std.debug.print("Enabling plugin: {s}\n", .{plugin_name});
        
        self.plugin_manager.enablePlugin(plugin_name) catch |err| {
            std.debug.print("Error: Failed to enable plugin '{s}': {}\n", .{ plugin_name, err });
            return;
        };
        
        std.debug.print("✅ Plugin '{s}' enabled successfully\n", .{plugin_name});
    }
    
    /// Disable a plugin
    fn handleDisableCommand(self: *PluginCLI, args: []const []const u8) !void {
        if (args.len < 1) {
            std.debug.print("Error: Plugin name required\n");
            std.debug.print("Usage: marathon plugin disable <name>\n");
            return;
        }
        
        const plugin_name = args[0];
        
        std.debug.print("Disabling plugin: {s}\n", .{plugin_name});
        
        self.plugin_manager.disablePlugin(plugin_name) catch |err| {
            std.debug.print("Error: Failed to disable plugin '{s}': {}\n", .{ plugin_name, err });
            return;
        };
        
        std.debug.print("✅ Plugin '{s}' disabled successfully\n", .{plugin_name});
    }
    
    /// Show plugin information
    fn handleInfoCommand(self: *PluginCLI, args: []const []const u8) !void {
        if (args.len < 1) {
            std.debug.print("Error: Plugin name required\n");
            std.debug.print("Usage: marathon plugin info <name>\n");
            return;
        }
        
        const plugin_name = args[0];
        const plugin = self.plugin_manager.getPlugin(plugin_name) orelse {
            std.debug.print("Error: Plugin '{s}' not found\n", .{plugin_name});
            return;
        };
        
        // Print detailed plugin information
        std.debug.print("Plugin Information:\n");
        std.debug.print("==================\n");
        std.debug.print("Name:         {s}\n", .{plugin.manifest.name});
        std.debug.print("Version:      {s}\n", .{plugin.manifest.version});
        std.debug.print("Description:  {s}\n", .{plugin.manifest.description});
        std.debug.print("Author:       {s}\n", .{plugin.manifest.author});
        std.debug.print("License:      {s}\n", .{plugin.manifest.license});
        std.debug.print("API Version:  {s}\n", .{plugin.manifest.api_version});
        std.debug.print("Status:       {s}\n", .{@tagName(plugin.status)});
        std.debug.print("Install Path: {s}\n", .{plugin.install_path});
        
        if (plugin.homepage) |homepage| {
            std.debug.print("Homepage:     {s}\n", .{homepage});
        }
        if (plugin.repository) |repo| {
            std.debug.print("Repository:   {s}\n", .{repo});
        }
        
        // Permissions
        if (plugin.manifest.permissions.len > 0) {
            std.debug.print("\nPermissions:\n");
            for (plugin.manifest.permissions) |perm| {
                std.debug.print("  - {s}\n", .{@tagName(perm)});
            }
        }
        
        // Hooks
        if (plugin.manifest.hooks.len > 0) {
            std.debug.print("\nHooks:\n");
            for (plugin.manifest.hooks) |hook| {
                std.debug.print("  - {s}\n", .{@tagName(hook)});
            }
        }
        
        // Commands
        if (plugin.manifest.commands.len > 0) {
            std.debug.print("\nCommands:\n");
            for (plugin.manifest.commands) |cmd| {
                std.debug.print("  - {s}\n", .{cmd});
            }
        }
        
        // Dependencies
        if (plugin.manifest.dependencies.len > 0) {
            std.debug.print("\nDependencies:\n");
            for (plugin.manifest.dependencies) |dep| {
                const optional_str = if (dep.optional) " (optional)" else "";
                std.debug.print("  - {s}@{s}{s}\n", .{ dep.name, dep.version, optional_str });
            }
        }
        
        // Runtime information
        if (plugin.loaded_at) |loaded_at| {
            std.debug.print("\nLoaded at:    {d}\n", .{loaded_at});
        }
        
        if (plugin.error_message) |error_msg| {
            std.debug.print("\nError:        {s}\n", .{error_msg});
        }
    }
    
    /// Run a plugin command
    fn handleRunCommand(self: *PluginCLI, args: []const []const u8) !void {
        if (args.len < 2) {
            std.debug.print("Error: Plugin name and command required\n");
            std.debug.print("Usage: marathon plugin run <plugin_name> <command> [args...]\n");
            return;
        }
        
        const plugin_name = args[0];
        const command_args = args[1..];
        
        const result = self.plugin_manager.executeCommand(plugin_name, command_args) catch |err| {
            std.debug.print("Error: Failed to execute command in plugin '{s}': {}\n", .{ plugin_name, err });
            return;
        };
        
        if (result.success) {
            if (result.message) |msg| {
                std.debug.print("{s}\n", .{msg});
            }
            if (result.result_data) |data| {
                std.debug.print("Result: {s}\n", .{data});
            }
        } else {
            std.debug.print("Command failed: {s}\n", .{result.message orelse "Unknown error"});
        }
    }
    
    /// Refresh plugin discovery
    fn handleRefreshCommand(self: *PluginCLI, args: []const []const u8) !void {
        _ = args;
        
        std.debug.print("Refreshing plugin discovery...\n");
        
        const discovery_result = try self.plugin_manager.registry.discoverPlugins();
        
        std.debug.print("✅ Discovery complete: {} plugins found", .{discovery_result.found_plugins.len});
        
        if (discovery_result.errors.len > 0) {
            std.debug.print(" ({} errors)\n", .{discovery_result.errors.len});
            for (discovery_result.errors) |err| {
                std.debug.print("  Warning: {s} - {s}\n", .{ err.path, err.message });
            }
        } else {
            std.debug.print("\n");
        }
        
        // Clean up discovery result
        self.allocator.free(discovery_result.found_plugins);
        for (discovery_result.errors) |err| {
            self.allocator.free(err.path);
            self.allocator.free(err.message);
        }
        self.allocator.free(discovery_result.errors);
    }
    
    /// Print plugin command usage
    fn printPluginUsage(self: *PluginCLI) void {
        _ = self;
        const usage =
            \\Marathon Plugin Management
            \\
            \\Usage: marathon plugin <command> [options]
            \\
            \\Commands:
            \\  list [--status <status>]     List all plugins
            \\  install <name|path>          Install a plugin
            \\  uninstall <name>             Uninstall a plugin
            \\  enable <name>                Enable a plugin
            \\  disable <name>               Disable a plugin
            \\  info <name>                  Show detailed plugin information
            \\  run <name> <command> [args]  Execute a plugin command
            \\  refresh                      Refresh plugin discovery
            \\
            \\Status options for list:
            \\  discovered, installed, loaded, enabled, disabled, error
            \\
            \\Examples:
            \\  marathon plugin list
            \\  marathon plugin list --status enabled
            \\  marathon plugin install hello-world
            \\  marathon plugin install /path/to/my-plugin
            \\  marathon plugin enable hello-world
            \\  marathon plugin info hello-world
            \\  marathon plugin run hello-world hello
            \\  marathon plugin run hello-world greet Marathon
            \\
        ;
        std.debug.print("{s}", .{usage});
    }
};

test "plugin CLI basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = plugin_core.PluginManager.Config{};
    var plugin_manager = try plugin_core.PluginManager.init(allocator, config);
    defer plugin_manager.deinit();
    
    var cli = PluginCLI.init(allocator, &plugin_manager);
    
    // Test empty list command
    try cli.handleListCommand(&.{});
}