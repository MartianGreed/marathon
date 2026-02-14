/// Marathon Plugin System Core
/// 
/// This module provides the foundational plugin architecture for Marathon,
/// including plugin lifecycle management, security, and event handling.

pub const plugin_api = @import("plugin_api.zig");
pub const plugin_manifest = @import("plugin_manifest.zig");
pub const plugin_registry = @import("plugin_registry.zig");
pub const plugin_manager = @import("plugin_manager.zig");
pub const event_system = @import("event_system.zig");
pub const security = @import("security.zig");

// Re-export commonly used types for convenience
pub const PluginAPI = plugin_api.PluginAPI;
pub const Permission = plugin_api.Permission;
pub const HookType = plugin_api.HookType;
pub const Context = plugin_api.Context;
pub const HookResult = plugin_api.HookResult;

pub const Manifest = plugin_manifest.Manifest;
pub const ManifestParser = plugin_manifest.ManifestParser;

pub const PluginRegistry = plugin_registry.PluginRegistry;
pub const PluginStatus = plugin_registry.PluginStatus;
pub const PluginEntry = plugin_registry.PluginEntry;

pub const PluginManager = plugin_manager.PluginManager;
pub const PluginError = plugin_manager.PluginError;
pub const InstallSource = plugin_manager.InstallSource;

pub const EventSystem = event_system.EventSystem;

pub const SecurityValidator = security.SecurityValidator;
pub const SecurityError = security.SecurityError;
pub const PluginSandbox = security.PluginSandbox;

// Utility functions
pub const utils = plugin_api.utils;

test {
    // Import all submodules for testing
    _ = plugin_api;
    _ = plugin_manifest;
    _ = plugin_registry;
    _ = plugin_manager;
    _ = event_system;
    _ = security;
}