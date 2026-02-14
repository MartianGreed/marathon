const std = @import("std");
const http = std.http;
const json = std.json;
const mod = @import("mod.zig");
const IntegrationStatus = mod.IntegrationStatus;

pub const DockerClient = struct {
    allocator: std.mem.Allocator,
    registry_configs: std.StringHashMap(RegistryConfig),

    const RegistryConfig = struct {
        registry_url: []const u8,
        username: []const u8,
        password: []const u8,
        registry_type: RegistryType,

        pub fn deinit(self: *RegistryConfig, allocator: std.mem.Allocator) void {
            allocator.free(self.registry_url);
            allocator.free(self.username);
            allocator.free(self.password);
        }
    };

    const RegistryType = enum {
        docker_hub,
        github_container_registry,
        aws_ecr,
        custom,
    };

    pub fn init(allocator: std.mem.Allocator) DockerClient {
        return .{
            .allocator = allocator,
            .registry_configs = std.StringHashMap(RegistryConfig).init(allocator),
        };
    }

    pub fn deinit(self: *DockerClient) void {
        var iter = self.registry_configs.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.registry_configs.deinit();
    }

    pub fn setCredentials(self: *DockerClient, username: []const u8, password: []const u8) !void {
        const config = RegistryConfig{
            .registry_url = try self.allocator.dupe(u8, "https://registry.hub.docker.com"),
            .username = try self.allocator.dupe(u8, username),
            .password = try self.allocator.dupe(u8, password),
            .registry_type = .docker_hub,
        };

        try self.registry_configs.put("docker_hub", config);
    }

    pub fn setGithubRegistryCredentials(self: *DockerClient, token: []const u8) !void {
        const config = RegistryConfig{
            .registry_url = try self.allocator.dupe(u8, "https://ghcr.io"),
            .username = try self.allocator.dupe(u8, "token"),
            .password = try self.allocator.dupe(u8, token),
            .registry_type = .github_container_registry,
        };

        try self.registry_configs.put("ghcr", config);
    }

    pub fn testConnection(self: *DockerClient) IntegrationStatus {
        // Test Docker daemon connection
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "docker", "version", "--format", "json" },
        }) catch return .error;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return if (result.term == .Exited and result.term.Exited == 0) .connected else .disconnected;
    }

    pub fn testGithubRegistry(self: *DockerClient) IntegrationStatus {
        const config = self.registry_configs.get("ghcr") orelse return .disconnected;
        
        // Test login to GitHub Container Registry
        const result = self.dockerLogin(config.registry_url, config.username, config.password) catch return .error;
        return if (result) .connected else .error;
    }

    /// Container Image Operations
    pub const ImageInfo = struct {
        id: []const u8,
        repository: []const u8,
        tag: []const u8,
        created: i64,
        size: u64,
        
        pub fn deinit(self: *ImageInfo, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.repository);
            allocator.free(self.tag);
        }
    };

    pub fn buildImage(self: *DockerClient, dockerfile_path: []const u8, context_path: []const u8, image_name: []const u8, tags: []const []const u8, build_args: ?std.StringHashMap([]const u8)) !void {
        var cmd_args = std.ArrayList([]const u8).init(self.allocator);
        defer cmd_args.deinit();

        try cmd_args.appendSlice(&.{ "docker", "build", "-f", dockerfile_path, "." });

        // Add build args
        if (build_args) |args| {
            var iter = args.iterator();
            while (iter.next()) |entry| {
                try cmd_args.append("--build-arg");
                const arg_str = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
                defer self.allocator.free(arg_str);
                try cmd_args.append(arg_str);
            }
        }

        // Add tags
        for (tags) |tag| {
            try cmd_args.append("-t");
            const tagged_name = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ image_name, tag });
            defer self.allocator.free(tagged_name);
            try cmd_args.append(tagged_name);
        }

        try cmd_args.append(context_path);

        var process = std.process.Child.init(cmd_args.items, self.allocator);
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Pipe;
        process.cwd = context_path;

        try process.spawn();
        const result = try process.wait();

        if (result != .Exited or result.Exited != 0) {
            return error.BuildFailed;
        }
    }

    pub fn buildMultiStageImage(self: *DockerClient, dockerfile_path: []const u8, context_path: []const u8, image_name: []const u8, stages: []const []const u8) !void {
        // Build each stage separately for optimization
        for (stages, 0..) |stage, i| {
            var cmd_args = std.ArrayList([]const u8).init(self.allocator);
            defer cmd_args.deinit();

            const stage_tag = try std.fmt.allocPrint(self.allocator, "{s}-stage-{d}", .{ image_name, i });
            defer self.allocator.free(stage_tag);

            try cmd_args.appendSlice(&.{ 
                "docker", "build", 
                "-f", dockerfile_path,
                "--target", stage,
                "-t", stage_tag,
                context_path
            });

            var process = std.process.Child.init(cmd_args.items, self.allocator);
            const result = try process.spawnAndWait();

            if (result != .Exited or result.Exited != 0) {
                return error.MultistageBuildFailed;
            }
        }
    }

    pub fn listImages(self: *DockerClient, repository_filter: ?[]const u8) ![]ImageInfo {
        var cmd_args = std.ArrayList([]const u8).init(self.allocator);
        defer cmd_args.deinit();

        try cmd_args.appendSlice(&.{ "docker", "images", "--format", "json" });
        
        if (repository_filter) |filter| {
            try cmd_args.append(filter);
        }

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = cmd_args.items,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            return error.ListImagesFailed;
        }

        var images = std.ArrayList(ImageInfo).init(self.allocator);
        var lines = std.mem.split(u8, result.stdout, "\n");
        
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            
            var parser = json.Parser.init(self.allocator, .alloc_always);
            defer parser.deinit();
            
            const tree = parser.parse(line) catch continue;
            defer tree.deinit();
            
            const obj = tree.root.object;
            const image = ImageInfo{
                .id = try self.allocator.dupe(u8, obj.get("ID").?.string),
                .repository = try self.allocator.dupe(u8, obj.get("Repository").?.string),
                .tag = try self.allocator.dupe(u8, obj.get("Tag").?.string),
                .created = self.parseCreatedTime(obj.get("CreatedAt").?.string),
                .size = self.parseSizeString(obj.get("Size").?.string),
            };
            try images.append(image);
        }

        return images.toOwnedSlice();
    }

    pub fn pushImage(self: *DockerClient, image_name: []const u8, tag: []const u8, registry: []const u8) !void {
        const full_image = try std.fmt.allocPrint(self.allocator, "{s}/{s}:{s}", .{ registry, image_name, tag });
        defer self.allocator.free(full_image);

        // Tag for registry first
        const tag_result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "docker", "tag", try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ image_name, tag }), full_image },
        });
        defer self.allocator.free(tag_result.stdout);
        defer self.allocator.free(tag_result.stderr);

        if (tag_result.term != .Exited or tag_result.term.Exited != 0) {
            return error.TagFailed;
        }

        // Push to registry
        const push_result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "docker", "push", full_image },
        });
        defer self.allocator.free(push_result.stdout);
        defer self.allocator.free(push_result.stderr);

        if (push_result.term != .Exited or push_result.term.Exited != 0) {
            return error.PushFailed;
        }
    }

    pub fn pullImage(self: *DockerClient, image_name: []const u8, tag: []const u8) !void {
        const full_image = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ image_name, tag });
        defer self.allocator.free(full_image);

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "docker", "pull", full_image },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            return error.PullFailed;
        }
    }

    /// Container Operations
    pub const ContainerInfo = struct {
        id: []const u8,
        name: []const u8,
        image: []const u8,
        status: []const u8,
        ports: []const []const u8,
        created: i64,
        
        pub fn deinit(self: *ContainerInfo, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.name);
            allocator.free(self.image);
            allocator.free(self.status);
            for (self.ports) |port| allocator.free(port);
            allocator.free(self.ports);
        }
    };

    pub const ContainerConfig = struct {
        image: []const u8,
        name: ?[]const u8 = null,
        ports: []const []const u8 = &.{},
        environment: []const []const u8 = &.{},
        volumes: []const []const u8 = &.{},
        network: ?[]const u8 = null,
        restart_policy: []const u8 = "no",
        healthcheck_cmd: ?[]const u8 = null,
    };

    pub fn runContainer(self: *DockerClient, config: ContainerConfig) ![]const u8 {
        var cmd_args = std.ArrayList([]const u8).init(self.allocator);
        defer cmd_args.deinit();

        try cmd_args.appendSlice(&.{ "docker", "run", "-d" });

        if (config.name) |name| {
            try cmd_args.appendSlice(&.{ "--name", name });
        }

        for (config.ports) |port| {
            try cmd_args.appendSlice(&.{ "-p", port });
        }

        for (config.environment) |env| {
            try cmd_args.appendSlice(&.{ "-e", env });
        }

        for (config.volumes) |volume| {
            try cmd_args.appendSlice(&.{ "-v", volume });
        }

        if (config.network) |network| {
            try cmd_args.appendSlice(&.{ "--network", network });
        }

        try cmd_args.appendSlice(&.{ "--restart", config.restart_policy });

        if (config.healthcheck_cmd) |healthcheck| {
            try cmd_args.appendSlice(&.{ "--health-cmd", healthcheck });
        }

        try cmd_args.append(config.image);

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = cmd_args.items,
        });
        defer self.allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            return error.ContainerRunFailed;
        }

        return result.stdout; // Returns container ID
    }

    pub fn listContainers(self: *DockerClient, all: bool) ![]ContainerInfo {
        var cmd_args = std.ArrayList([]const u8).init(self.allocator);
        defer cmd_args.deinit();

        try cmd_args.appendSlice(&.{ "docker", "ps", "--format", "json" });
        if (all) try cmd_args.append("-a");

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = cmd_args.items,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            return error.ListContainersFailed;
        }

        var containers = std.ArrayList(ContainerInfo).init(self.allocator);
        var lines = std.mem.split(u8, result.stdout, "\n");
        
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            
            var parser = json.Parser.init(self.allocator, .alloc_always);
            defer parser.deinit();
            
            const tree = parser.parse(line) catch continue;
            defer tree.deinit();
            
            const obj = tree.root.object;
            const container = ContainerInfo{
                .id = try self.allocator.dupe(u8, obj.get("ID").?.string),
                .name = try self.allocator.dupe(u8, obj.get("Names").?.string),
                .image = try self.allocator.dupe(u8, obj.get("Image").?.string),
                .status = try self.allocator.dupe(u8, obj.get("Status").?.string),
                .ports = try self.parsePortsString(obj.get("Ports").?.string),
                .created = self.parseCreatedTime(obj.get("CreatedAt").?.string),
            };
            try containers.append(container);
        }

        return containers.toOwnedSlice();
    }

    pub fn stopContainer(self: *DockerClient, container_id: []const u8) !void {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "docker", "stop", container_id },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            return error.StopContainerFailed;
        }
    }

    pub fn removeContainer(self: *DockerClient, container_id: []const u8, force: bool) !void {
        var cmd_args = std.ArrayList([]const u8).init(self.allocator);
        defer cmd_args.deinit();

        try cmd_args.appendSlice(&.{ "docker", "rm" });
        if (force) try cmd_args.append("-f");
        try cmd_args.append(container_id);

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = cmd_args.items,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            return error.RemoveContainerFailed;
        }
    }

    pub fn getContainerHealth(self: *DockerClient, container_id: []const u8) ![]const u8 {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "docker", "inspect", "--format", "{{.State.Health.Status}}", container_id },
        });
        defer self.allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            return error.HealthCheckFailed;
        }

        // Trim newline
        const status = std.mem.trim(u8, result.stdout, "\n");
        return try self.allocator.dupe(u8, status);
    }

    /// Docker Compose Operations
    pub fn composeUp(self: *DockerClient, compose_file: []const u8, services: []const []const u8) !void {
        var cmd_args = std.ArrayList([]const u8).init(self.allocator);
        defer cmd_args.deinit();

        try cmd_args.appendSlice(&.{ "docker", "compose", "-f", compose_file, "up", "-d" });
        for (services) |service| {
            try cmd_args.append(service);
        }

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = cmd_args.items,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            return error.ComposeUpFailed;
        }
    }

    pub fn composeDown(self: *DockerClient, compose_file: []const u8) !void {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "docker", "compose", "-f", compose_file, "down" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            return error.ComposeDownFailed;
        }
    }

    /// Helper functions
    fn dockerLogin(self: *DockerClient, registry_url: []const u8, username: []const u8, password: []const u8) !bool {
        // Use docker login with stdin for password
        var process = std.process.Child.init(&.{ "docker", "login", registry_url, "--username", username, "--password-stdin" }, self.allocator);
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Pipe;

        try process.spawn();
        try process.stdin.?.writeAll(password);
        process.stdin.?.close();
        process.stdin = null;

        const result = try process.wait();
        return result == .Exited and result.Exited == 0;
    }

    fn parseCreatedTime(self: *DockerClient, time_str: []const u8) i64 {
        _ = self;
        // Simple timestamp parsing - in real implementation would parse Docker's time format
        return std.time.timestamp();
    }

    fn parseSizeString(self: *DockerClient, size_str: []const u8) u64 {
        _ = self;
        // Parse Docker size strings like "1.2GB", "500MB", etc.
        // Simplified implementation
        return 0;
    }

    fn parsePortsString(self: *DockerClient, ports_str: []const u8) ![]const []const u8 {
        var ports = std.ArrayList([]const u8).init(self.allocator);
        var parts = std.mem.split(u8, ports_str, ", ");
        while (parts.next()) |part| {
            try ports.append(try self.allocator.dupe(u8, part));
        }
        return ports.toOwnedSlice();
    }
};

test "docker client initialization" {
    const testing = std.testing;
    
    var client = DockerClient.init(testing.allocator);
    defer client.deinit();

    try testing.expect(client.registry_configs.count() == 0);
}