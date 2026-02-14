const std = @import("std");
const plugin_api = @import("plugin_api.zig");
const plugin_manifest = @import("plugin_manifest.zig");

/// Security errors
pub const SecurityError = error{
    UntrustedPlugin,
    InvalidSignature,
    InvalidChecksum,
    PermissionDenied,
    ResourceLimitExceeded,
    SandboxViolation,
    UnsafeOperation,
};

/// Plugin security validator
pub const SecurityValidator = struct {
    allocator: std.mem.Allocator,
    /// Trusted plugin signatures (would be loaded from config)
    trusted_signatures: std.HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    /// Security policy configuration
    policy: SecurityPolicy,
    
    /// Security policy configuration
    pub const SecurityPolicy = struct {
        /// Require plugin signatures
        require_signatures: bool = false,
        /// Allow unsigned plugins in development
        allow_unsigned_dev: bool = true,
        /// Maximum plugin file size (bytes)
        max_plugin_size: usize = 10 * 1024 * 1024, // 10MB
        /// Allowed file extensions
        allowed_extensions: []const []const u8 = &.{ ".zig", ".json", ".md", ".txt" },
        /// Blocked directories
        blocked_directories: []const []const u8 = &.{ ".git", "__pycache__", "node_modules" },
        /// Maximum number of files in plugin
        max_files: usize = 100,
        /// Dangerous permission combinations
        dangerous_permission_combos: []const []const plugin_api.Permission = &.{
            &.{ .exec, .filesystem },
            &.{ .network, .filesystem, .exec },
        },
    };
    
    pub fn init(allocator: std.mem.Allocator, policy: SecurityPolicy) SecurityValidator {
        return SecurityValidator{
            .allocator = allocator,
            .trusted_signatures = std.HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .policy = policy,
        };
    }
    
    pub fn deinit(self: *SecurityValidator) void {
        var iterator = self.trusted_signatures.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.trusted_signatures.deinit();
    }
    
    /// Validate plugin security before installation
    pub fn validatePluginSecurity(self: *SecurityValidator, plugin_path: []const u8, manifest: *const plugin_manifest.Manifest) !void {
        std.log.debug("Validating plugin security for: {s}", .{manifest.name});
        
        // Check plugin size
        try self.validatePluginSize(plugin_path);
        
        // Validate file contents
        try self.validatePluginFiles(plugin_path);
        
        // Check permissions
        try self.validatePermissions(manifest.permissions);
        
        // Verify signature if present
        if (manifest.signature) |signature| {
            try self.verifyPluginSignature(plugin_path, signature);
        } else if (self.policy.require_signatures and !self.policy.allow_unsigned_dev) {
            std.log.err("Plugin signature required but not found: {s}", .{manifest.name});
            return SecurityError.UntrustedPlugin;
        }
        
        // Verify checksum if present
        if (manifest.checksum) |checksum| {
            try self.verifyPluginChecksum(plugin_path, checksum);
        }
        
        std.log.info("Plugin security validation passed: {s}", .{manifest.name});
    }
    
    /// Check if a plugin has permission to perform an operation
    pub fn checkPermission(self: *SecurityValidator, plugin_name: []const u8, permissions: []const plugin_api.Permission, required_permission: plugin_api.Permission) !void {
        _ = self;
        
        for (permissions) |perm| {
            if (perm == required_permission) {
                std.log.debug("Permission granted to plugin '{}': {}", .{ plugin_name, required_permission });
                return;
            }
        }
        
        std.log.warn("Permission denied to plugin '{}': {}", .{ plugin_name, required_permission });
        return SecurityError.PermissionDenied;
    }
    
    /// Create a sandboxed execution context for a plugin
    pub fn createSandbox(self: *SecurityValidator, plugin_name: []const u8, permissions: []const plugin_api.Permission) !PluginSandbox {
        _ = self;
        
        return PluginSandbox{
            .plugin_name = plugin_name,
            .permissions = permissions,
            .resource_limits = ResourceLimits{
                .max_memory = 64 * 1024 * 1024, // 64MB
                .max_cpu_time_ms = 10000, // 10 seconds
                .max_network_connections = 10,
                .max_file_descriptors = 20,
            },
        };
    }
    
    /// Add trusted plugin signature
    pub fn addTrustedSignature(self: *SecurityValidator, plugin_name: []const u8, signature: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, plugin_name);
        const owned_signature = try self.allocator.dupe(u8, signature);
        try self.trusted_signatures.put(owned_name, owned_signature);
    }
    
    // Private validation methods
    
    fn validatePluginSize(self: *SecurityValidator, plugin_path: []const u8) !void {
        const total_size = try self.calculateDirectorySize(plugin_path);
        if (total_size > self.policy.max_plugin_size) {
            std.log.err("Plugin size {} exceeds limit {}", .{ total_size, self.policy.max_plugin_size });
            return SecurityError.ResourceLimitExceeded;
        }
    }
    
    fn validatePluginFiles(self: *SecurityValidator, plugin_path: []const u8) !void {
        var file_count: usize = 0;
        try self.validateDirectoryFiles(plugin_path, &file_count);
        
        if (file_count > self.policy.max_files) {
            std.log.err("Plugin has {} files, exceeding limit {}", .{ file_count, self.policy.max_files });
            return SecurityError.ResourceLimitExceeded;
        }
    }
    
    fn validateDirectoryFiles(self: *SecurityValidator, dir_path: []const u8, file_count: *usize) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer dir.close();
        
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            // Check blocked directories
            for (self.policy.blocked_directories) |blocked| {
                if (std.mem.eql(u8, entry.name, blocked)) {
                    std.log.err("Plugin contains blocked directory: {s}", .{entry.name});
                    return SecurityError.UnsafeOperation;
                }
            }
            
            if (entry.kind == .file) {
                file_count.* += 1;
                
                // Check file extension
                const ext = std.fs.path.extension(entry.name);
                var allowed = false;
                for (self.policy.allowed_extensions) |allowed_ext| {
                    if (std.mem.eql(u8, ext, allowed_ext)) {
                        allowed = true;
                        break;
                    }
                }
                
                if (!allowed and ext.len > 0) {
                    std.log.err("Plugin contains disallowed file extension: {s}", .{ext});
                    return SecurityError.UnsafeOperation;
                }
                
                // Check file content for suspicious patterns
                try self.scanFileContent(dir, entry.name);
                
            } else if (entry.kind == .directory) {
                const subdir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
                defer self.allocator.free(subdir_path);
                try self.validateDirectoryFiles(subdir_path, file_count);
            }
        }
    }
    
    fn scanFileContent(self: *SecurityValidator, dir: std.fs.Dir, filename: []const u8) !void {
        _ = self;
        
        const file = dir.openFile(filename, .{}) catch return;
        defer file.close();
        
        // Read first 1KB for pattern scanning
        var buffer: [1024]u8 = undefined;
        const bytes_read = file.readAll(&buffer) catch return;
        const content = buffer[0..bytes_read];
        
        // Check for suspicious patterns
        const suspicious_patterns = [_][]const u8{
            "eval(",
            "exec(",
            "__import__",
            "system(",
            "popen(",
            "subprocess",
        };
        
        for (suspicious_patterns) |pattern| {
            if (std.mem.indexOf(u8, content, pattern) != null) {
                std.log.warn("Suspicious pattern found in {s}: {s}", .{ filename, pattern });
                // Note: This is just a warning, not a hard block
            }
        }
    }
    
    fn validatePermissions(self: *SecurityValidator, permissions: []const plugin_api.Permission) !void {
        // Check for dangerous permission combinations
        for (self.policy.dangerous_permission_combos) |combo| {
            if (self.hasAllPermissions(permissions, combo)) {
                std.log.err("Plugin requests dangerous permission combination");
                return SecurityError.UnsafeOperation;
            }
        }
    }
    
    fn hasAllPermissions(self: *SecurityValidator, permissions: []const plugin_api.Permission, required: []const plugin_api.Permission) bool {
        _ = self;
        
        for (required) |req_perm| {
            var found = false;
            for (permissions) |perm| {
                if (perm == req_perm) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }
    
    fn verifyPluginSignature(self: *SecurityValidator, plugin_path: []const u8, signature: []const u8) !void {
        _ = plugin_path;
        
        // TODO: Implement proper digital signature verification
        // For now, just check if signature is in trusted list
        if (self.trusted_signatures.get(signature) == null) {
            std.log.err("Plugin signature not trusted: {s}", .{signature});
            return SecurityError.InvalidSignature;
        }
    }
    
    fn verifyPluginChecksum(self: *SecurityValidator, plugin_path: []const u8, expected_checksum: []const u8) !void {
        const actual_checksum = try self.calculateDirectoryChecksum(plugin_path);
        defer self.allocator.free(actual_checksum);
        
        if (!std.mem.eql(u8, actual_checksum, expected_checksum)) {
            std.log.err("Plugin checksum mismatch. Expected: {s}, Got: {s}", .{ expected_checksum, actual_checksum });
            return SecurityError.InvalidChecksum;
        }
    }
    
    fn calculateDirectorySize(self: *SecurityValidator, dir_path: []const u8) !usize {
        _ = self;
        var total_size: usize = 0;
        
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return 0;
        defer dir.close();
        
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file) {
                const file = dir.openFile(entry.name, .{}) catch continue;
                defer file.close();
                const stat = file.stat() catch continue;
                total_size += stat.size;
            }
            // TODO: Handle subdirectories recursively
        }
        
        return total_size;
    }
    
    fn calculateDirectoryChecksum(self: *SecurityValidator, dir_path: []const u8) ![]const u8 {
        _ = dir_path;
        // TODO: Implement proper directory checksum calculation
        // For now, return a placeholder
        return try self.allocator.dupe(u8, "placeholder-checksum");
    }
};

/// Plugin execution sandbox
pub const PluginSandbox = struct {
    plugin_name: []const u8,
    permissions: []const plugin_api.Permission,
    resource_limits: ResourceLimits,
    /// Current resource usage
    current_usage: ResourceUsage = ResourceUsage{},
    
    pub const ResourceLimits = struct {
        max_memory: usize,
        max_cpu_time_ms: u64,
        max_network_connections: u32,
        max_file_descriptors: u32,
    };
    
    pub const ResourceUsage = struct {
        memory_used: usize = 0,
        cpu_time_used_ms: u64 = 0,
        network_connections: u32 = 0,
        file_descriptors: u32 = 0,
    };
    
    /// Check if resource allocation is allowed
    pub fn checkResourceAllocation(self: *PluginSandbox, resource_type: ResourceType, amount: usize) !void {
        switch (resource_type) {
            .memory => {
                if (self.current_usage.memory_used + amount > self.resource_limits.max_memory) {
                    return SecurityError.ResourceLimitExceeded;
                }
            },
            .network_connection => {
                if (self.current_usage.network_connections + @as(u32, @intCast(amount)) > self.resource_limits.max_network_connections) {
                    return SecurityError.ResourceLimitExceeded;
                }
            },
            .file_descriptor => {
                if (self.current_usage.file_descriptors + @as(u32, @intCast(amount)) > self.resource_limits.max_file_descriptors) {
                    return SecurityError.ResourceLimitExceeded;
                }
            },
        }
    }
    
    /// Update resource usage
    pub fn updateResourceUsage(self: *PluginSandbox, resource_type: ResourceType, amount: isize) void {
        switch (resource_type) {
            .memory => {
                if (amount > 0) {
                    self.current_usage.memory_used += @as(usize, @intCast(amount));
                } else {
                    self.current_usage.memory_used -= @as(usize, @intCast(-amount));
                }
            },
            .network_connection => {
                if (amount > 0) {
                    self.current_usage.network_connections += @as(u32, @intCast(amount));
                } else {
                    self.current_usage.network_connections -= @as(u32, @intCast(-amount));
                }
            },
            .file_descriptor => {
                if (amount > 0) {
                    self.current_usage.file_descriptors += @as(u32, @intCast(amount));
                } else {
                    self.current_usage.file_descriptors -= @as(u32, @intCast(-amount));
                }
            },
        }
    }
    
    pub const ResourceType = enum {
        memory,
        network_connection,
        file_descriptor,
    };
};

test "security validator basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const policy = SecurityValidator.SecurityPolicy{};
    var validator = SecurityValidator.init(allocator, policy);
    defer validator.deinit();
    
    // Test permission checking
    const permissions = [_]plugin_api.Permission{.task_read};
    try validator.checkPermission("test-plugin", &permissions, .task_read);
    
    const no_permissions = [_]plugin_api.Permission{};
    const result = validator.checkPermission("test-plugin", &no_permissions, .task_write);
    try std.testing.expectError(SecurityError.PermissionDenied, result);
}