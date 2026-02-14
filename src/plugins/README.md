# Marathon Plugin System

This directory contains the plugin architecture for Marathon, allowing extensible functionality through a secure and managed plugin system.

## Directory Structure

```
src/plugins/
├── core/                  # Core plugin system
│   ├── plugin_manager.zig # Plugin lifecycle management
│   ├── plugin_registry.zig# Plugin discovery and registration
│   ├── plugin_loader.zig  # Plugin loading and sandboxing
│   ├── plugin_api.zig     # Plugin API interface
│   ├── event_system.zig   # Hook-based event system
│   └── security.zig       # Security and validation
├── examples/              # Example plugins
│   └── hello-world/       # Sample plugin
├── installed/             # User-installed plugins directory
└── docs/                  # Plugin development documentation
```

## Plugin Lifecycle

1. **Discovery**: Scan directories for plugin manifest files
2. **Validation**: Verify plugin manifest, dependencies, and signatures
3. **Installation**: Copy plugin files to managed location
4. **Loading**: Load plugin into sandboxed environment
5. **Registration**: Register plugin hooks and APIs
6. **Execution**: Call plugin hooks during system events
7. **Uninstallation**: Clean removal of plugin files and state

## Security Features

- Plugin manifest validation and digital signatures
- Sandboxed execution environment
- Permission-based API access
- Dependency verification
- Resource limits and monitoring

## CLI Commands

- `marathon plugin list` - List all plugins
- `marathon plugin install <name>` - Install a plugin
- `marathon plugin enable <name>` - Enable a plugin
- `marathon plugin disable <name>` - Disable a plugin
- `marathon plugin uninstall <name>` - Uninstall a plugin

See `docs/plugin-development.md` for detailed plugin development guide.