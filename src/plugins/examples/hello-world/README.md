# Hello World Plugin

A simple example plugin that demonstrates the Marathon plugin API and showcases basic plugin functionality.

## Overview

The Hello World plugin serves as a tutorial and reference implementation for Marathon plugin development. It demonstrates:

- Plugin initialization and cleanup
- Hook handling for system events
- Custom CLI commands
- Configuration management
- Logging and error handling
- Permission usage
- Testing patterns

## Features

### Commands

- `hello`: Displays a greeting message
- `greet <name>`: Displays a personalized greeting

### Hooks

- `post_task_execute`: Reacts to task completion events
- `cli_command`: Handles custom CLI command execution

### Permissions

- `task_read`: Allows reading task information

## Installation

1. The plugin comes pre-installed as an example in `src/plugins/examples/hello-world/`

2. Install the plugin:
   ```bash
   marathon plugin install hello-world
   ```

3. Enable the plugin:
   ```bash
   marathon plugin enable hello-world
   ```

## Usage

### Basic Commands

```bash
# Display basic greeting
marathon plugin run hello-world hello

# Display personalized greeting
marathon plugin run hello-world greet Marathon

# Display personalized greeting with custom name
marathon plugin run hello-world greet "World of Zig"
```

### Configuration

The plugin supports configuration via JSON:

```json
{
  "greeting": "Hello",
  "name": "World"
}
```

You can modify the default greeting and name through the plugin configuration system (when implemented).

## Example Output

```bash
$ marathon plugin run hello-world hello
Hello, World!

$ marathon plugin run hello-world greet Marathon
Hello, Marathon! Greetings from the hello-world plugin.

$ marathon plugin info hello-world
Plugin Information:
==================
Name:         hello-world
Version:      1.0.0
Description:  A simple hello world plugin that demonstrates the Marathon plugin API
Author:       Marathon Team
License:      MIT
API Version:  1.0.0
Status:       enabled
...
```

## Development

This plugin serves as a template for developing your own plugins. Key files:

- `plugin.json`: Plugin manifest with metadata and permissions
- `plugin.zig`: Main plugin implementation
- `README.md`: This documentation

### Code Structure

```zig
// Plugin state management
var config: Config = Config{};
var initialized: bool = false;

// Plugin interface implementation
pub const plugin_interface = plugin_core.PluginAPI.Interface{
    .manifest = manifest,
    .init = init,           // Initialization function
    .deinit = deinit,       // Cleanup function
    .hook = hook,           // Hook event handler
    .command = command,     // CLI command handler
};
```

### Key Concepts Demonstrated

1. **State Management**: Proper initialization and cleanup
2. **Configuration**: Loading and using configuration data
3. **Error Handling**: Graceful error handling and reporting
4. **Memory Management**: Proper use of allocators
5. **Logging**: Using the plugin logging utilities
6. **Permission Checking**: Validating required permissions
7. **Hook Processing**: Responding to system events
8. **Command Processing**: Handling CLI commands with arguments

### Testing

The plugin includes comprehensive tests:

```bash
# Run plugin-specific tests
zig test src/plugins/examples/hello-world/plugin.zig

# Test plugin functionality
marathon plugin run hello-world hello
marathon plugin run hello-world greet test
```

## Plugin Manifest

The `plugin.json` file defines the plugin metadata:

```json
{
  "name": "hello-world",
  "version": "1.0.0",
  "description": "A simple hello world plugin that demonstrates the Marathon plugin API",
  "author": "Marathon Team",
  "license": "MIT",
  "api_version": "1.0.0",
  "marathon_version": ">=0.1.0",
  "main_file": "plugin.zig",
  "permissions": ["task_read"],
  "hooks": ["post_task_execute", "cli_command"],
  "commands": ["hello", "greet"],
  "dependencies": [],
  "config_schema": {
    "type": "object",
    "properties": {
      "greeting": {
        "type": "string",
        "default": "Hello"
      },
      "name": {
        "type": "string", 
        "default": "World"
      }
    }
  },
  "metadata": {
    "category": "example",
    "tags": ["demo", "tutorial", "hello-world"],
    "documentation": "https://github.com/MartianGreed/marathon/docs/plugins/hello-world.md"
  }
}
```

## Extending the Plugin

You can extend this plugin by:

1. **Adding new commands**: Implement additional command handlers
2. **Supporting more hooks**: Register for additional system events  
3. **Adding configuration**: Expand the configuration schema
4. **Enhancing functionality**: Add more complex business logic
5. **Improving error handling**: Add more robust error handling

### Example Extension

```zig
// Add a new command handler
fn farewellCommand(context: *plugin_core.Context, args: []const []const u8) !plugin_core.HookResult {
    const target_name = if (args.len > 0) args[0] else config.name;
    
    const message = std.fmt.allocPrint(context.allocator, "Goodbye, {s}! Thanks for using hello-world plugin.", .{target_name}) catch return plugin_core.utils.failure("Memory allocation failed");
    
    return plugin_core.HookResult{
        .success = true,
        .message = message,
        .result_data = message,
    };
}

// Update command handler to support new command
fn command(context: *plugin_core.Context, args: []const []const u8) anyerror!plugin_core.HookResult {
    // ... existing code ...
    } else if (std.mem.eql(u8, cmd, "farewell")) {
        return farewellCommand(context, args[1..]);
    // ... rest of function ...
}
```

Don't forget to update the manifest to include the new command:

```json
{
  "commands": ["hello", "greet", "farewell"]
}
```

## Troubleshooting

### Common Issues

1. **Plugin not found**: Ensure the plugin is installed and enabled
   ```bash
   marathon plugin list
   marathon plugin enable hello-world
   ```

2. **Permission denied**: Check that required permissions are granted
   ```bash
   marathon plugin info hello-world
   ```

3. **Command not recognized**: Verify the command is listed in the manifest
   ```bash
   marathon plugin info hello-world
   ```

4. **Initialization errors**: Check plugin logs and status
   ```bash
   marathon plugin info hello-world
   ```

### Debug Mode

Enable verbose logging to see detailed plugin execution:

```bash
RUST_LOG=debug marathon plugin run hello-world hello
```

## Contributing

This example plugin is part of the Marathon project. To contribute improvements:

1. Fork the repository
2. Make your changes
3. Add tests
4. Submit a pull request

## License

MIT License - see the `LICENSE` file for details.

## Related Documentation

- [Plugin Development Guide](../../docs/plugin-development.md)
- [Plugin API Reference](../../core/plugin_api.zig)
- [Marathon CLI Documentation](../../../../docs/)

## Support

For questions or issues:

- Open an issue on GitHub
- Check the documentation
- Review other example plugins
- Ask in the community forums