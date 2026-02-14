# Marathon Plugin Development Guide

This guide explains how to develop plugins for the Marathon platform, providing extensible functionality through a secure and managed plugin system.

## Table of Contents

1. [Plugin Architecture Overview](#plugin-architecture-overview)
2. [Getting Started](#getting-started)
3. [Plugin Manifest](#plugin-manifest)
4. [Plugin API](#plugin-api)
5. [Hooks and Events](#hooks-and-events)
6. [Command Handlers](#command-handlers)
7. [Security and Permissions](#security-and-permissions)
8. [Testing Your Plugin](#testing-your-plugin)
9. [Distribution](#distribution)
10. [Best Practices](#best-practices)

## Plugin Architecture Overview

Marathon's plugin system is built on several key components:

- **Plugin Manager**: Handles plugin lifecycle (install, enable, disable, uninstall)
- **Plugin Registry**: Discovers and registers plugins
- **Event System**: Provides hook-based event handling
- **Security Validator**: Ensures plugin safety and manages permissions
- **Plugin API**: Standard interface for plugin development

### Plugin Lifecycle

1. **Discovery**: System scans plugin directories for `plugin.json` manifests
2. **Installation**: Plugin files are copied to managed location
3. **Validation**: Manifest and code are validated for security
4. **Loading**: Plugin is loaded into memory
5. **Initialization**: Plugin initialization function is called
6. **Execution**: Plugin responds to hooks and commands
7. **Cleanup**: Plugin is properly shut down when disabled

## Getting Started

### Prerequisites

- Zig programming language knowledge
- Understanding of Marathon's core functionality
- Basic knowledge of event-driven programming

### Creating Your First Plugin

1. Create a new directory for your plugin:

```bash
mkdir src/plugins/examples/my-plugin
cd src/plugins/examples/my-plugin
```

2. Create a `plugin.json` manifest file:

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "My first Marathon plugin",
  "author": "Your Name",
  "license": "MIT",
  "api_version": "1.0.0",
  "main_file": "plugin.zig",
  "permissions": ["task_read"],
  "hooks": ["post_task_execute"],
  "commands": ["my-command"]
}
```

3. Create the plugin implementation in `plugin.zig`:

```zig
const std = @import("std");
const plugin_core = @import("../../core/root.zig");

// Plugin state
var initialized: bool = false;

// Plugin manifest
const manifest = plugin_core.Manifest{
    .name = "my-plugin",
    .version = "1.0.0", 
    .description = "My first Marathon plugin",
    .author = "Your Name",
    .api_version = plugin_core.plugin_api.PLUGIN_API_VERSION,
    .permissions = &.{.task_read},
    .hooks = &.{.post_task_execute},
};

// Plugin initialization
fn init(context: *plugin_core.Context) anyerror!void {
    plugin_core.utils.log(context, .info, "Initializing my-plugin", .{});
    initialized = true;
}

// Plugin cleanup
fn deinit(context: *plugin_core.Context) anyerror!void {
    plugin_core.utils.log(context, .info, "Cleaning up my-plugin", .{});
    initialized = false;
}

// Plugin hook handler
fn hook(context: *plugin_core.Context, hook_type: plugin_core.HookType, data: ?[]const u8) anyerror!plugin_core.HookResult {
    switch (hook_type) {
        .post_task_execute => {
            plugin_core.utils.log(context, .info, "Task execution completed!", .{});
            return plugin_core.utils.success("Task hook executed");
        },
        else => {
            return plugin_core.utils.success("Hook not handled");
        },
    }
}

// Plugin command handler
fn command(context: *plugin_core.Context, args: []const []const u8) anyerror!plugin_core.HookResult {
    if (args.len < 1) {
        return plugin_core.utils.failure("No command specified");
    }
    
    const cmd = args[0];
    
    if (std.mem.eql(u8, cmd, "my-command")) {
        const message = "Hello from my-plugin!";
        plugin_core.utils.log(context, .info, "Command executed: {s}", .{message});
        return plugin_core.HookResult{
            .success = true,
            .message = message,
            .result_data = message,
        };
    }
    
    return plugin_core.utils.failure("Unknown command");
}

// Export plugin interface
pub const plugin_interface = plugin_core.PluginAPI.Interface{
    .manifest = manifest,
    .init = init,
    .deinit = deinit,
    .hook = hook,
    .command = command,
};
```

## Plugin Manifest

The `plugin.json` file defines your plugin's metadata, permissions, and capabilities:

### Required Fields

- `name`: Unique plugin identifier (alphanumeric, hyphens, underscores only)
- `version`: Semantic version (e.g., "1.0.0")
- `description`: Brief description of plugin functionality
- `author`: Plugin author/maintainer
- `api_version`: Compatible API version (currently "1.0.0")

### Optional Fields

- `license`: License identifier (default: "MIT")
- `homepage`: Plugin homepage URL
- `repository`: Source code repository URL
- `marathon_version`: Compatible Marathon version (default: ">=0.1.0")
- `main_file`: Entry point file (default: "plugin.zig")
- `permissions`: Array of required permissions
- `hooks`: Array of event hooks to register
- `commands`: Array of CLI commands provided
- `dependencies`: Array of plugin dependencies
- `config_schema`: JSON schema for plugin configuration
- `signature`: Digital signature (for verified plugins)
- `checksum`: File integrity checksum
- `metadata`: Custom metadata object

### Example with All Fields

```json
{
  "name": "advanced-plugin",
  "version": "2.1.0",
  "description": "An advanced plugin demonstrating all features",
  "author": "Marathon Team <team@marathon.dev>",
  "license": "MIT",
  "homepage": "https://marathon.dev/plugins/advanced",
  "repository": "https://github.com/MartianGreed/marathon-plugins",
  "api_version": "1.0.0",
  "marathon_version": ">=0.2.0",
  "main_file": "plugin.zig",
  "permissions": [
    "task_read",
    "task_write",
    "network",
    "env_vars"
  ],
  "hooks": [
    "pre_task_submit",
    "post_task_execute",
    "user_auth",
    "config_validate"
  ],
  "commands": [
    "process",
    "analyze", 
    "report"
  ],
  "dependencies": [
    {
      "name": "utility-plugin",
      "version": "^1.0.0",
      "optional": false
    }
  ],
  "config_schema": {
    "type": "object",
    "properties": {
      "api_endpoint": {
        "type": "string",
        "format": "uri"
      },
      "timeout_seconds": {
        "type": "integer",
        "minimum": 1,
        "maximum": 300,
        "default": 30
      }
    },
    "required": ["api_endpoint"]
  },
  "metadata": {
    "category": "analysis",
    "tags": ["data", "reporting", "analytics"],
    "min_memory_mb": 128,
    "supports_hot_reload": true
  }
}
```

## Plugin API

### Core Types

#### Context

The plugin context provides access to system resources:

```zig
pub const Context = struct {
    allocator: std.mem.Allocator,    // Memory allocator
    plugin_name: []const u8,         // Plugin name
    plugin_version: []const u8,      // Plugin version
    permissions: []const Permission, // Granted permissions
    task_id: ?[]const u8,           // Current task ID (if applicable)
    user_id: ?[]const u8,           // Current user ID (if applicable)
    context_data: ?[]const u8,       // Additional context data
};
```

#### HookResult

Plugin functions return results indicating success/failure:

```zig
pub const HookResult = struct {
    success: bool,                   // Whether operation succeeded
    message: ?[]const u8,           // Optional message
    continue_chain: bool = true,     // Continue executing other hooks
    result_data: ?[]const u8,       // Optional result data
};
```

#### Plugin Interface

Every plugin must export a `plugin_interface` with these functions:

```zig
pub const Interface = struct {
    manifest: Manifest,              // Plugin metadata
    init: InitFn,                   // Initialization function
    deinit: DeinitFn,              // Cleanup function
    hook: HookFn,                  // Hook handler
    command: ?CommandFn = null,     // Command handler (optional)
};
```

### Utility Functions

The plugin API provides helpful utilities:

```zig
// Logging with plugin context
plugin_core.utils.log(context, .info, "Message: {s}", .{value});

// Permission checking
if (plugin_core.utils.hasPermission(context, .network)) {
    // Network access allowed
}

// Result creation
return plugin_core.utils.success("Operation completed");
return plugin_core.utils.failure("Operation failed");
```

## Hooks and Events

### Available Hook Types

- `pre_task_submit`: Before task submission
- `post_task_submit`: After task submission
- `pre_task_execute`: Before task execution starts
- `post_task_execute`: After task execution completes
- `user_auth`: During user authentication
- `user_authz`: During user authorization
- `cli_command`: For custom CLI commands
- `config_validate`: During configuration validation
- `plugin_install`: During plugin installation
- `plugin_uninstall`: During plugin uninstallation

### Hook Handler Implementation

```zig
fn hook(context: *plugin_core.Context, hook_type: plugin_core.HookType, data: ?[]const u8) anyerror!plugin_core.HookResult {
    switch (hook_type) {
        .pre_task_submit => {
            // Validate task before submission
            if (data) |task_data| {
                // Parse and validate task_data
                // Return failure to prevent submission
            }
            return plugin_core.utils.success("Task validated");
        },
        .post_task_execute => {
            // React to task completion
            plugin_core.utils.log(context, .info, "Task completed successfully", .{});
            
            // Optional: stop other plugins from processing
            return plugin_core.HookResult{
                .success = true,
                .message = "Task processed",
                .continue_chain = false,  // Stop hook chain
            };
        },
        .user_auth => {
            // Custom authentication logic
            if (plugin_core.utils.hasPermission(context, .user_auth)) {
                // Perform authentication check
                return plugin_core.utils.success("User authenticated");
            }
            return plugin_core.utils.failure("Permission denied");
        },
        else => {
            // Ignore unhandled hooks
            return plugin_core.utils.success("Hook not handled");
        },
    }
}
```

### Hook Data Format

Hook data is typically JSON-formatted:

```zig
// Parse hook data
if (data) |json_data| {
    var parser = std.json.Parser.init(context.allocator, .{});
    defer parser.deinit();
    
    var tree = parser.parse(json_data) catch |err| {
        plugin_core.utils.log(context, .err, "Failed to parse hook data: {}", .{err});
        return plugin_core.utils.failure("Invalid hook data");
    };
    defer tree.deinit();
    
    // Access parsed data
    if (tree.root.object.get("task_id")) |task_id| {
        plugin_core.utils.log(context, .info, "Processing task: {s}", .{task_id.string});
    }
}
```

## Command Handlers

### CLI Command Integration

Plugins can provide custom CLI commands accessible via:

```bash
marathon plugin run <plugin-name> <command> [args...]
```

### Command Handler Implementation

```zig
fn command(context: *plugin_core.Context, args: []const []const u8) anyerror!plugin_core.HookResult {
    if (args.len < 1) {
        return plugin_core.utils.failure("No command specified");
    }
    
    const cmd = args[0];
    const cmd_args = args[1..];
    
    if (std.mem.eql(u8, cmd, "process")) {
        return processCommand(context, cmd_args);
    } else if (std.mem.eql(u8, cmd, "analyze")) {
        return analyzeCommand(context, cmd_args);
    } else if (std.mem.eql(u8, cmd, "help")) {
        return showHelp(context);
    }
    
    const error_msg = std.fmt.allocPrint(context.allocator, "Unknown command: {s}", .{cmd}) catch 
        return plugin_core.utils.failure("Memory allocation failed");
    return plugin_core.utils.failure(error_msg);
}

fn processCommand(context: *plugin_core.Context, args: []const []const u8) !plugin_core.HookResult {
    // Validate permissions
    if (!plugin_core.utils.hasPermission(context, .task_write)) {
        return plugin_core.utils.failure("Insufficient permissions");
    }
    
    // Process command logic
    var result_buffer: [256]u8 = undefined;
    const result = std.fmt.bufPrint(&result_buffer, "Processed {} items", .{args.len}) catch
        return plugin_core.utils.failure("Buffer overflow");
    
    const owned_result = context.allocator.dupe(u8, result) catch
        return plugin_core.utils.failure("Memory allocation failed");
    
    return plugin_core.HookResult{
        .success = true,
        .message = owned_result,
        .result_data = owned_result,
    };
}

fn showHelp(context: *plugin_core.Context) !plugin_core.HookResult {
    const help_text = 
        \\Available commands:
        \\  process [args...]  Process items with given arguments
        \\  analyze           Analyze current state
        \\  help              Show this help
    ;
    
    const owned_help = context.allocator.dupe(u8, help_text) catch
        return plugin_core.utils.failure("Memory allocation failed");
    
    return plugin_core.HookResult{
        .success = true,
        .message = owned_help,
        .result_data = owned_help,
    };
}
```

## Security and Permissions

### Permission System

Plugins must declare required permissions in their manifest:

```json
{
  "permissions": [
    "task_read",      // Read task data
    "task_write",     // Modify task data  
    "user_auth",      // Access user authentication
    "network",        // Network access
    "filesystem",     // File system access
    "env_vars",       // Environment variable access
    "exec"            // Execute system commands
  ]
}
```

### Permission Checking

Always check permissions before performing restricted operations:

```zig
// Check single permission
if (plugin_core.utils.hasPermission(context, .network)) {
    // Safe to make network requests
} else {
    return plugin_core.utils.failure("Network permission required");
}

// Check multiple permissions
const required_perms = &.{.task_read, .task_write};
var has_all = true;
for (required_perms) |perm| {
    if (!plugin_core.utils.hasPermission(context, perm)) {
        has_all = false;
        break;
    }
}

if (!has_all) {
    return plugin_core.utils.failure("Insufficient permissions");
}
```

### Security Best Practices

1. **Principle of Least Privilege**: Request only necessary permissions
2. **Input Validation**: Always validate input data and arguments
3. **Memory Safety**: Use provided allocator and free resources properly
4. **Error Handling**: Handle all potential error conditions
5. **Avoid Dangerous Operations**: Don't perform system-level operations without proper permissions

### Dangerous Permission Combinations

The security system flags dangerous permission combinations:

- `exec` + `filesystem`: Can execute arbitrary system commands with file access
- `network` + `filesystem` + `exec`: Full system access

## Testing Your Plugin

### Unit Tests

Add tests to your plugin file:

```zig
test "plugin initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var context = plugin_core.Context{
        .allocator = allocator,
        .plugin_name = "my-plugin",
        .plugin_version = "1.0.0",
        .permissions = &.{.task_read},
    };
    
    // Test initialization
    try plugin_interface.init(&context);
    try std.testing.expect(initialized);
    
    // Test hook handling
    const result = try plugin_interface.hook(&context, .post_task_execute, null);
    try std.testing.expect(result.success);
    
    // Test cleanup
    try plugin_interface.deinit(&context);
    try std.testing.expect(!initialized);
}

test "command handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var context = plugin_core.Context{
        .allocator = allocator,
        .plugin_name = "my-plugin",
        .plugin_version = "1.0.0",
        .permissions = &.{.task_read},
    };
    
    try plugin_interface.init(&context);
    defer plugin_interface.deinit(&context) catch {};
    
    // Test valid command
    var result = try plugin_interface.command.?(&context, &.{"my-command"});
    try std.testing.expect(result.success);
    
    // Test invalid command
    result = try plugin_interface.command.?(&context, &.{"invalid-command"});
    try std.testing.expect(!result.success);
}
```

### Integration Testing

1. Install your plugin:
   ```bash
   marathon plugin install src/plugins/examples/my-plugin
   ```

2. Enable the plugin:
   ```bash
   marathon plugin enable my-plugin
   ```

3. Test plugin commands:
   ```bash
   marathon plugin run my-plugin my-command
   ```

4. Check plugin status:
   ```bash
   marathon plugin info my-plugin
   ```

### Running Tests

```bash
# Run plugin-specific tests
zig test src/plugins/examples/my-plugin/plugin.zig

# Run all plugin system tests
zig test src/plugins/core/root.zig
```

## Distribution

### Local Distribution

For local development and testing:

1. Place plugin in `src/plugins/examples/` or `src/plugins/installed/`
2. Run `marathon plugin refresh` to discover
3. Install with `marathon plugin install <plugin-name>`

### Package Distribution

For wider distribution:

1. Create a plugin package directory with:
   - `plugin.json` (manifest)
   - `plugin.zig` (implementation)
   - `README.md` (documentation)
   - `LICENSE` (license file)

2. Compress as tar.gz or zip archive

3. Distribute via:
   - GitHub releases
   - Package registries (future)
   - Direct download URLs

### Digital Signatures

For trusted distribution:

1. Generate signing key pair
2. Sign plugin package
3. Include signature in manifest:
   ```json
   {
     "signature": "your-signature-hash",
     "checksum": "package-checksum"
   }
   ```

## Best Practices

### Code Organization

```
my-plugin/
├── plugin.json          # Manifest
├── plugin.zig          # Main implementation
├── README.md           # Documentation
├── LICENSE             # License file
├── tests.zig          # Additional tests
└── config/            # Configuration templates
    └── default.json
```

### Error Handling

```zig
// Good: Proper error handling
fn processData(context: *plugin_core.Context, data: []const u8) !plugin_core.HookResult {
    const result = parseData(data) catch |err| {
        const error_msg = std.fmt.allocPrint(context.allocator, "Failed to parse data: {}", .{err}) catch 
            return plugin_core.utils.failure("Parse error");
        return plugin_core.utils.failure(error_msg);
    };
    
    // Process result...
    return plugin_core.utils.success("Data processed");
}

// Bad: Ignoring errors
fn processDataBad(context: *plugin_core.Context, data: []const u8) !plugin_core.HookResult {
    const result = parseData(data) catch unreachable; // Never do this!
    return plugin_core.utils.success("Data processed");
}
```

### Memory Management

```zig
// Good: Proper memory management
fn allocateResult(context: *plugin_core.Context) !plugin_core.HookResult {
    const message = std.fmt.allocPrint(context.allocator, "Result: {d}", .{42}) catch 
        return plugin_core.utils.failure("Memory allocation failed");
    
    return plugin_core.HookResult{
        .success = true,
        .message = message, // Will be freed by caller
    };
}

// Good: Stack allocation when possible
fn simpleResult(context: *plugin_core.Context) !plugin_core.HookResult {
    _ = context;
    return plugin_core.utils.success("Simple success message");
}
```

### Configuration Handling

```zig
const Config = struct {
    endpoint: []const u8 = "https://api.example.com",
    timeout: u32 = 30,
    retries: u32 = 3,
};

fn loadConfig(context: *plugin_core.Context, config_json: []const u8) !Config {
    var config = Config{};
    
    var parser = std.json.Parser.init(context.allocator, .{});
    defer parser.deinit();
    
    var tree = parser.parse(config_json) catch |err| {
        plugin_core.utils.log(context, .warn, "Using default config due to parse error: {}", .{err});
        return config; // Return defaults
    };
    defer tree.deinit();
    
    const obj = tree.root.object;
    
    if (obj.get("endpoint")) |endpoint| {
        config.endpoint = endpoint.string;
    }
    if (obj.get("timeout")) |timeout| {
        config.timeout = @intCast(timeout.integer);
    }
    if (obj.get("retries")) |retries| {
        config.retries = @intCast(retries.integer);
    }
    
    return config;
}
```

### Documentation

Always include comprehensive documentation:

1. **README.md**: Overview, installation, usage examples
2. **Inline comments**: Explain complex logic
3. **Function documentation**: Document all public functions
4. **Configuration examples**: Show typical configurations
5. **Troubleshooting**: Common issues and solutions

This guide provides the foundation for developing Marathon plugins. For additional examples and advanced patterns, refer to the plugins in `src/plugins/examples/`.