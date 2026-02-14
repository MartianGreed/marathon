const std = @import("std");
const plugin_core = @import("../../core/root.zig");

// Plugin configuration
const Config = struct {
    greeting: []const u8 = "Hello",
    name: []const u8 = "World",
};

// Plugin state
var config: Config = Config{};
var initialized: bool = false;

// Plugin manifest
const manifest = plugin_core.Manifest{
    .name = "hello-world",
    .version = "1.0.0", 
    .description = "A simple hello world plugin",
    .author = "Marathon Team",
    .api_version = plugin_core.plugin_api.PLUGIN_API_VERSION,
    .permissions = &.{.task_read},
    .hooks = &.{ .post_task_execute, .cli_command },
};

// Plugin initialization
fn init(context: *plugin_core.Context) anyerror!void {
    plugin_core.utils.log(context, .info, "Initializing hello-world plugin", .{});
    
    // Load configuration if provided
    if (context.context_data) |config_json| {
        var parser = std.json.Parser.init(context.allocator, .{});
        defer parser.deinit();
        
        var tree = parser.parse(config_json) catch |err| {
            plugin_core.utils.log(context, .warn, "Failed to parse plugin config: {}", .{err});
            return;
        };
        defer tree.deinit();
        
        if (tree.root.object.get("greeting")) |greeting_value| {
            config.greeting = greeting_value.string;
        }
        if (tree.root.object.get("name")) |name_value| {
            config.name = name_value.string;
        }
    }
    
    initialized = true;
    plugin_core.utils.log(context, .info, "Hello-world plugin initialized with greeting: '{s} {s}'", .{ config.greeting, config.name });
}

// Plugin cleanup
fn deinit(context: *plugin_core.Context) anyerror!void {
    plugin_core.utils.log(context, .info, "Cleaning up hello-world plugin", .{});
    initialized = false;
}

// Plugin hook handler
fn hook(context: *plugin_core.Context, hook_type: plugin_core.HookType, data: ?[]const u8) anyerror!plugin_core.HookResult {
    if (!initialized) {
        return plugin_core.utils.failure("Plugin not initialized");
    }
    
    switch (hook_type) {
        .post_task_execute => {
            plugin_core.utils.log(context, .info, "Task execution completed! {s}, {s}!", .{ config.greeting, config.name });
            
            // Parse task data if provided
            var task_info = "unknown task";
            if (data) |task_json| {
                var parser = std.json.Parser.init(context.allocator, .{});
                defer parser.deinit();
                
                if (parser.parse(task_json)) |tree| {
                    defer tree.deinit();
                    if (tree.root.object.get("task_id")) |task_id| {
                        task_info = task_id.string;
                    }
                } else |_| {
                    // Ignore parse errors
                }
            }
            
            const message = std.fmt.allocPrint(context.allocator, "Hello from hello-world plugin! Task: {s}", .{task_info}) catch return plugin_core.utils.failure("Memory allocation failed");
            
            return plugin_core.HookResult{
                .success = true,
                .message = message,
                .continue_chain = true,
            };
        },
        .cli_command => {
            // This will be handled by the command function
            return plugin_core.utils.success("CLI command hook triggered");
        },
        else => {
            return plugin_core.utils.success("Hook not handled by hello-world plugin");
        },
    }
}

// Plugin command handler
fn command(context: *plugin_core.Context, args: []const []const u8) anyerror!plugin_core.HookResult {
    if (!initialized) {
        return plugin_core.utils.failure("Plugin not initialized");
    }
    
    if (args.len < 1) {
        return plugin_core.utils.failure("No command specified");
    }
    
    const cmd = args[0];
    
    if (std.mem.eql(u8, cmd, "hello")) {
        return handleHelloCommand(context, args[1..]);
    } else if (std.mem.eql(u8, cmd, "greet")) {
        return handleGreetCommand(context, args[1..]);
    } else {
        const error_msg = std.fmt.allocPrint(context.allocator, "Unknown command: {s}", .{cmd}) catch return plugin_core.utils.failure("Memory allocation failed");
        return plugin_core.utils.failure(error_msg);
    }
}

// Command handlers
fn handleHelloCommand(context: *plugin_core.Context, args: []const []const u8) !plugin_core.HookResult {
    _ = args;
    
    const message = std.fmt.allocPrint(context.allocator, "{s}, {s}!", .{ config.greeting, config.name }) catch return plugin_core.utils.failure("Memory allocation failed");
    
    plugin_core.utils.log(context, .info, "Hello command executed: {s}", .{message});
    
    return plugin_core.HookResult{
        .success = true,
        .message = message,
        .result_data = message,
    };
}

fn handleGreetCommand(context: *plugin_core.Context, args: []const []const u8) !plugin_core.HookResult {
    const target_name = if (args.len > 0) args[0] else config.name;
    
    const message = std.fmt.allocPrint(context.allocator, "{s}, {s}! Greetings from the hello-world plugin.", .{ config.greeting, target_name }) catch return plugin_core.utils.failure("Memory allocation failed");
    
    plugin_core.utils.log(context, .info, "Greet command executed: {s}", .{message});
    
    return plugin_core.HookResult{
        .success = true,
        .message = message,
        .result_data = message,
    };
}

// Export plugin interface
pub const plugin_interface = plugin_core.PluginAPI.Interface{
    .manifest = manifest,
    .init = init,
    .deinit = deinit,
    .hook = hook,
    .command = command,
};

// Tests
test "hello-world plugin basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var context = plugin_core.Context{
        .allocator = allocator,
        .plugin_name = "hello-world",
        .plugin_version = "1.0.0",
        .permissions = &.{.task_read},
    };
    
    // Test initialization
    try plugin_interface.init(&context);
    try std.testing.expect(initialized);
    
    // Test hello command
    var result = try plugin_interface.command.?(&context, &.{"hello"});
    try std.testing.expect(result.success);
    try std.testing.expect(result.message != null);
    
    // Test greet command with argument
    result = try plugin_interface.command.?(&context, &.{ "greet", "Marathon" });
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.message.?, "Marathon") != null);
    
    // Test hook
    result = try plugin_interface.hook(&context, .post_task_execute, null);
    try std.testing.expect(result.success);
    try std.testing.expect(result.continue_chain);
    
    // Test cleanup
    try plugin_interface.deinit(&context);
    try std.testing.expect(!initialized);
}