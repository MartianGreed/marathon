const std = @import("std");
const plugin_api = @import("plugin_api.zig");

/// Plugin manifest file name
pub const MANIFEST_FILENAME = "plugin.json";

/// Plugin manifest structure matching plugin.json format
pub const Manifest = struct {
    /// Plugin metadata
    name: []const u8,
    version: []const u8,
    description: []const u8,
    author: []const u8,
    license: []const u8 = "MIT",
    homepage: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    
    /// API compatibility
    api_version: []const u8,
    marathon_version: []const u8 = ">=0.1.0",
    
    /// Plugin configuration
    main_file: []const u8 = "plugin.zig",
    permissions: []const plugin_api.Permission = &.{},
    hooks: []const plugin_api.HookType = &.{},
    commands: []const []const u8 = &.{},
    
    /// Dependencies
    dependencies: []const Dependency = &.{},
    
    /// Configuration schema (optional JSON schema)
    config_schema: ?[]const u8 = null,
    
    /// Security
    signature: ?[]const u8 = null,
    checksum: ?[]const u8 = null,
    
    /// Plugin-specific metadata
    metadata: ?std.json.Value = null,

    const Dependency = struct {
        name: []const u8,
        version: []const u8,
        optional: bool = false,
    };
};

/// Manifest validation errors
pub const ValidationError = error{
    InvalidManifest,
    MissingRequiredField,
    InvalidVersion,
    UnsupportedAPIVersion,
    InvalidPermissions,
    InvalidHooks,
    InvalidDependencies,
    SecurityViolation,
};

/// Manifest parser and validator
pub const ManifestParser = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ManifestParser {
        return ManifestParser{ .allocator = allocator };
    }
    
    /// Parse manifest from JSON string
    pub fn parseFromString(self: *ManifestParser, json_str: []const u8) !Manifest {
        var parser = std.json.Parser.init(self.allocator, .{});
        defer parser.deinit();
        
        var tree = parser.parse(json_str) catch |err| {
            std.log.err("Failed to parse plugin manifest JSON: {}", .{err});
            return ValidationError.InvalidManifest;
        };
        defer tree.deinit();
        
        return self.parseFromValue(tree.root);
    }
    
    /// Parse manifest from JSON file
    pub fn parseFromFile(self: *ManifestParser, file_path: []const u8) !Manifest {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            std.log.err("Failed to open plugin manifest file '{s}': {}", .{ file_path, err });
            return ValidationError.InvalidManifest;
        };
        defer file.close();
        
        const content = try file.readToEndAlloc(self.allocator, 64 * 1024); // Max 64KB manifest
        defer self.allocator.free(content);
        
        return self.parseFromString(content);
    }
    
    /// Parse manifest from JSON value
    fn parseFromValue(self: *ManifestParser, value: std.json.Value) !Manifest {
        const obj = value.object;
        
        // Required fields
        const name = self.getStringField(obj, "name") orelse return ValidationError.MissingRequiredField;
        const version = self.getStringField(obj, "version") orelse return ValidationError.MissingRequiredField;
        const description = self.getStringField(obj, "description") orelse return ValidationError.MissingRequiredField;
        const author = self.getStringField(obj, "author") orelse return ValidationError.MissingRequiredField;
        const api_version = self.getStringField(obj, "api_version") orelse return ValidationError.MissingRequiredField;
        
        // Validate API version compatibility
        if (!self.isCompatibleAPIVersion(api_version)) {
            std.log.err("Plugin API version '{}' is not compatible with current version '{s}'", .{ api_version, plugin_api.PLUGIN_API_VERSION });
            return ValidationError.UnsupportedAPIVersion;
        }
        
        // Optional fields with defaults
        const license = self.getStringField(obj, "license") orelse "MIT";
        const homepage = self.getStringField(obj, "homepage");
        const repository = self.getStringField(obj, "repository");
        const marathon_version = self.getStringField(obj, "marathon_version") orelse ">=0.1.0";
        const main_file = self.getStringField(obj, "main_file") orelse "plugin.zig";
        const config_schema = self.getStringField(obj, "config_schema");
        const signature = self.getStringField(obj, "signature");
        const checksum = self.getStringField(obj, "checksum");
        
        // Parse arrays
        const permissions = try self.parsePermissions(obj.get("permissions"));
        const hooks = try self.parseHooks(obj.get("hooks"));
        const commands = try self.parseStringArray(obj.get("commands"));
        const dependencies = try self.parseDependencies(obj.get("dependencies"));
        
        // Get metadata object
        const metadata = obj.get("metadata");
        
        return Manifest{
            .name = try self.allocator.dupe(u8, name),
            .version = try self.allocator.dupe(u8, version),
            .description = try self.allocator.dupe(u8, description),
            .author = try self.allocator.dupe(u8, author),
            .license = try self.allocator.dupe(u8, license),
            .homepage = if (homepage) |hp| try self.allocator.dupe(u8, hp) else null,
            .repository = if (repository) |repo| try self.allocator.dupe(u8, repo) else null,
            .api_version = try self.allocator.dupe(u8, api_version),
            .marathon_version = try self.allocator.dupe(u8, marathon_version),
            .main_file = try self.allocator.dupe(u8, main_file),
            .permissions = permissions,
            .hooks = hooks,
            .commands = commands,
            .dependencies = dependencies,
            .config_schema = if (config_schema) |cs| try self.allocator.dupe(u8, cs) else null,
            .signature = if (signature) |sig| try self.allocator.dupe(u8, sig) else null,
            .checksum = if (checksum) |cs| try self.allocator.dupe(u8, cs) else null,
            .metadata = metadata,
        };
    }
    
    /// Validate manifest against security rules
    pub fn validate(self: *ManifestParser, manifest: *const Manifest) !void {
        // Validate name (must be alphanumeric + hyphens/underscores)
        if (!self.isValidPluginName(manifest.name)) {
            std.log.err("Invalid plugin name: {s}", .{manifest.name});
            return ValidationError.InvalidManifest;
        }
        
        // Validate version (must be semver)
        if (!self.isValidVersion(manifest.version)) {
            std.log.err("Invalid plugin version: {s}", .{manifest.version});
            return ValidationError.InvalidVersion;
        }
        
        // Check for dangerous permission combinations
        if (self.hasDangerousPermissions(manifest.permissions)) {
            std.log.err("Plugin requests dangerous permission combination");
            return ValidationError.SecurityViolation;
        }
        
        // Validate dependencies
        for (manifest.dependencies) |dep| {
            if (!self.isValidVersion(dep.version)) {
                std.log.err("Invalid dependency version: {s}@{s}", .{ dep.name, dep.version });
                return ValidationError.InvalidDependencies;
            }
        }
    }
    
    // Helper methods
    
    fn getStringField(self: *ManifestParser, obj: std.json.ObjectMap, field_name: []const u8) ?[]const u8 {
        _ = self;
        if (obj.get(field_name)) |value| {
            return value.string;
        }
        return null;
    }
    
    fn isCompatibleAPIVersion(self: *ManifestParser, version: []const u8) bool {
        _ = self;
        // Simple version compatibility check - in production this should be more sophisticated
        return std.mem.eql(u8, version, plugin_api.PLUGIN_API_VERSION) or 
               std.mem.startsWith(u8, version, "1.0");
    }
    
    fn parsePermissions(self: *ManifestParser, value: ?std.json.Value) ![]const plugin_api.Permission {
        if (value == null) return &.{};
        
        const array = value.?.array;
        var permissions = try self.allocator.alloc(plugin_api.Permission, array.items.len);
        
        for (array.items, 0..) |item, i| {
            const perm_str = item.string;
            permissions[i] = std.meta.stringToEnum(plugin_api.Permission, perm_str) orelse {
                std.log.err("Unknown permission: {s}", .{perm_str});
                return ValidationError.InvalidPermissions;
            };
        }
        
        return permissions;
    }
    
    fn parseHooks(self: *ManifestParser, value: ?std.json.Value) ![]const plugin_api.HookType {
        if (value == null) return &.{};
        
        const array = value.?.array;
        var hooks = try self.allocator.alloc(plugin_api.HookType, array.items.len);
        
        for (array.items, 0..) |item, i| {
            const hook_str = item.string;
            hooks[i] = std.meta.stringToEnum(plugin_api.HookType, hook_str) orelse {
                std.log.err("Unknown hook type: {s}", .{hook_str});
                return ValidationError.InvalidHooks;
            };
        }
        
        return hooks;
    }
    
    fn parseStringArray(self: *ManifestParser, value: ?std.json.Value) ![]const []const u8 {
        if (value == null) return &.{};
        
        const array = value.?.array;
        var strings = try self.allocator.alloc([]const u8, array.items.len);
        
        for (array.items, 0..) |item, i| {
            strings[i] = try self.allocator.dupe(u8, item.string);
        }
        
        return strings;
    }
    
    fn parseDependencies(self: *ManifestParser, value: ?std.json.Value) ![]const Manifest.Dependency {
        if (value == null) return &.{};
        
        const array = value.?.array;
        var dependencies = try self.allocator.alloc(Manifest.Dependency, array.items.len);
        
        for (array.items, 0..) |item, i| {
            const dep_obj = item.object;
            dependencies[i] = Manifest.Dependency{
                .name = try self.allocator.dupe(u8, self.getStringField(dep_obj, "name") orelse return ValidationError.InvalidDependencies),
                .version = try self.allocator.dupe(u8, self.getStringField(dep_obj, "version") orelse return ValidationError.InvalidDependencies),
                .optional = if (dep_obj.get("optional")) |opt| opt.bool else false,
            };
        }
        
        return dependencies;
    }
    
    fn isValidPluginName(self: *ManifestParser, name: []const u8) bool {
        _ = self;
        if (name.len == 0 or name.len > 128) return false;
        
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
                return false;
            }
        }
        return true;
    }
    
    fn isValidVersion(self: *ManifestParser, version: []const u8) bool {
        _ = self;
        // Simple semver validation - should be enhanced in production
        if (version.len == 0) return false;
        
        var parts = std.mem.split(u8, version, ".");
        var part_count: usize = 0;
        
        while (parts.next()) |part| {
            part_count += 1;
            if (part_count > 3) return false; // Too many parts
            
            for (part) |c| {
                if (!std.ascii.isDigit(c)) return false;
            }
        }
        
        return part_count >= 2; // At least major.minor
    }
    
    fn hasDangerousPermissions(self: *ManifestParser, permissions: []const plugin_api.Permission) bool {
        _ = self;
        var has_exec = false;
        var has_filesystem = false;
        
        for (permissions) |perm| {
            switch (perm) {
                .exec => has_exec = true,
                .filesystem => has_filesystem = true,
                else => {},
            }
        }
        
        // Dangerous combination: exec + filesystem access
        return has_exec and has_filesystem;
    }
    
    /// Free manifest memory
    pub fn freeManifest(self: *ManifestParser, manifest: *Manifest) void {
        self.allocator.free(manifest.name);
        self.allocator.free(manifest.version);
        self.allocator.free(manifest.description);
        self.allocator.free(manifest.author);
        self.allocator.free(manifest.license);
        if (manifest.homepage) |hp| self.allocator.free(hp);
        if (manifest.repository) |repo| self.allocator.free(repo);
        self.allocator.free(manifest.api_version);
        self.allocator.free(manifest.marathon_version);
        self.allocator.free(manifest.main_file);
        if (manifest.config_schema) |cs| self.allocator.free(cs);
        if (manifest.signature) |sig| self.allocator.free(sig);
        if (manifest.checksum) |cs| self.allocator.free(cs);
        
        self.allocator.free(manifest.permissions);
        self.allocator.free(manifest.hooks);
        
        for (manifest.commands) |cmd| {
            self.allocator.free(cmd);
        }
        self.allocator.free(manifest.commands);
        
        for (manifest.dependencies) |dep| {
            self.allocator.free(dep.name);
            self.allocator.free(dep.version);
        }
        self.allocator.free(manifest.dependencies);
    }
};

test "manifest parsing and validation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var parser = ManifestParser.init(allocator);
    
    const manifest_json =
        \\{
        \\  "name": "hello-world",
        \\  "version": "1.0.0",
        \\  "description": "A simple hello world plugin",
        \\  "author": "Marathon Team",
        \\  "api_version": "1.0.0",
        \\  "permissions": ["task_read"],
        \\  "hooks": ["post_task_execute"],
        \\  "commands": ["hello"]
        \\}
    ;
    
    var manifest = try parser.parseFromString(manifest_json);
    defer parser.freeManifest(&manifest);
    
    try std.testing.expectEqualSlices(u8, "hello-world", manifest.name);
    try std.testing.expectEqualSlices(u8, "1.0.0", manifest.version);
    try std.testing.expectEqual(@as(usize, 1), manifest.permissions.len);
    try std.testing.expectEqual(plugin_api.Permission.task_read, manifest.permissions[0]);
    
    try parser.validate(&manifest);
}