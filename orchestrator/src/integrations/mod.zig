const std = @import("std");
const common = @import("common");

pub const github = @import("github.zig");
pub const docker = @import("docker.zig");
pub const aws = @import("aws.zig");
pub const credentials = @import("credentials.zig");

pub const IntegrationStatus = enum {
    disconnected,
    connecting,
    connected,
    error,
    rate_limited,
};

pub const IntegrationType = enum {
    github,
    docker_hub,
    github_container_registry,
    aws_ecr,
    aws_s3,
    aws_lambda,
    aws_ec2,
    aws_cloudwatch,

    pub fn displayName(self: IntegrationType) []const u8 {
        return switch (self) {
            .github => "GitHub",
            .docker_hub => "Docker Hub",
            .github_container_registry => "GitHub Container Registry",
            .aws_ecr => "AWS ECR",
            .aws_s3 => "AWS S3",
            .aws_lambda => "AWS Lambda",
            .aws_ec2 => "AWS EC2",
            .aws_cloudwatch => "AWS CloudWatch",
        };
    }

    pub fn isAws(self: IntegrationType) bool {
        return switch (self) {
            .aws_ecr, .aws_s3, .aws_lambda, .aws_ec2, .aws_cloudwatch => true,
            else => false,
        };
    }
};

pub const IntegrationConfig = struct {
    id: []const u8,
    integration_type: IntegrationType,
    name: []const u8,
    enabled: bool,
    settings: std.StringHashMap([]const u8),
    created_at: i64,
    updated_at: i64,
    last_error: ?[]const u8,
    rate_limit_remaining: ?u32,
    rate_limit_reset_at: ?i64,

    pub fn deinit(self: *IntegrationConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.last_error) |err| allocator.free(err);
        var iter = self.settings.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.settings.deinit();
    }
};

pub const IntegrationManager = struct {
    allocator: std.mem.Allocator,
    integrations: std.StringHashMap(IntegrationConfig),
    credentials_manager: *credentials.CredentialsManager,
    github_client: github.GitHubClient,
    docker_client: docker.DockerClient,
    aws_client: aws.AwsClient,

    pub fn init(allocator: std.mem.Allocator, credentials_manager: *credentials.CredentialsManager) IntegrationManager {
        return .{
            .allocator = allocator,
            .integrations = std.StringHashMap(IntegrationConfig).init(allocator),
            .credentials_manager = credentials_manager,
            .github_client = github.GitHubClient.init(allocator),
            .docker_client = docker.DockerClient.init(allocator),
            .aws_client = aws.AwsClient.init(allocator),
        };
    }

    pub fn deinit(self: *IntegrationManager) void {
        var iter = self.integrations.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.integrations.deinit();
        self.github_client.deinit();
        self.docker_client.deinit();
        self.aws_client.deinit();
    }

    pub fn addIntegration(self: *IntegrationManager, config: IntegrationConfig) !void {
        const owned_config = try self.cloneConfig(config);
        try self.integrations.put(owned_config.id, owned_config);
        
        // Initialize the specific client
        try self.initializeClient(config.integration_type, config.id);
    }

    pub fn removeIntegration(self: *IntegrationManager, integration_id: []const u8) !void {
        if (self.integrations.fetchRemove(integration_id)) |entry| {
            entry.value.deinit(self.allocator);
        }
    }

    pub fn getIntegration(self: *IntegrationManager, integration_id: []const u8) ?*IntegrationConfig {
        return self.integrations.getPtr(integration_id);
    }

    pub fn listIntegrations(self: *IntegrationManager) std.ArrayList(IntegrationConfig) {
        var list = std.ArrayList(IntegrationConfig).init(self.allocator);
        var iter = self.integrations.valueIterator();
        while (iter.next()) |config| {
            list.append(config.*) catch continue;
        }
        return list;
    }

    pub fn testConnection(self: *IntegrationManager, integration_id: []const u8) !IntegrationStatus {
        const config = self.getIntegration(integration_id) orelse return error.IntegrationNotFound;
        
        return switch (config.integration_type) {
            .github => self.github_client.testConnection(),
            .docker_hub => self.docker_client.testConnection(),
            .github_container_registry => self.docker_client.testGithubRegistry(),
            .aws_ecr => self.aws_client.testEcrConnection(),
            .aws_s3 => self.aws_client.testS3Connection(),
            .aws_lambda => self.aws_client.testLambdaConnection(),
            .aws_ec2 => self.aws_client.testEc2Connection(),
            .aws_cloudwatch => self.aws_client.testCloudwatchConnection(),
        };
    }

    fn initializeClient(self: *IntegrationManager, integration_type: IntegrationType, integration_id: []const u8) !void {
        const creds = try self.credentials_manager.getCredentials(integration_id);
        defer creds.deinit(self.allocator);

        switch (integration_type) {
            .github => {
                const token = creds.settings.get("token") orelse return error.MissingCredentials;
                try self.github_client.setCredentials(token);
            },
            .docker_hub => {
                const username = creds.settings.get("username") orelse return error.MissingCredentials;
                const password = creds.settings.get("password") orelse return error.MissingCredentials;
                try self.docker_client.setCredentials(username, password);
            },
            .github_container_registry => {
                const token = creds.settings.get("token") orelse return error.MissingCredentials;
                try self.docker_client.setGithubRegistryCredentials(token);
            },
            .aws_ecr, .aws_s3, .aws_lambda, .aws_ec2, .aws_cloudwatch => {
                const access_key = creds.settings.get("access_key_id") orelse return error.MissingCredentials;
                const secret_key = creds.settings.get("secret_access_key") orelse return error.MissingCredentials;
                const region = creds.settings.get("region") orelse "us-east-1";
                try self.aws_client.setCredentials(access_key, secret_key, region);
            },
        }
    }

    fn cloneConfig(self: *IntegrationManager, config: IntegrationConfig) !IntegrationConfig {
        const owned_id = try self.allocator.dupe(u8, config.id);
        const owned_name = try self.allocator.dupe(u8, config.name);
        const owned_last_error = if (config.last_error) |err| try self.allocator.dupe(u8, err) else null;
        
        var owned_settings = std.StringHashMap([]const u8).init(self.allocator);
        var iter = config.settings.iterator();
        while (iter.next()) |entry| {
            const owned_key = try self.allocator.dupe(u8, entry.key_ptr.*);
            const owned_value = try self.allocator.dupe(u8, entry.value_ptr.*);
            try owned_settings.put(owned_key, owned_value);
        }

        return IntegrationConfig{
            .id = owned_id,
            .integration_type = config.integration_type,
            .name = owned_name,
            .enabled = config.enabled,
            .settings = owned_settings,
            .created_at = config.created_at,
            .updated_at = config.updated_at,
            .last_error = owned_last_error,
            .rate_limit_remaining = config.rate_limit_remaining,
            .rate_limit_reset_at = config.rate_limit_reset_at,
        };
    }
};

test "integration manager basic operations" {
    const testing = std.testing;
    var creds_manager = credentials.CredentialsManager.init(testing.allocator, "test-key");
    defer creds_manager.deinit();

    var manager = IntegrationManager.init(testing.allocator, &creds_manager);
    defer manager.deinit();

    var settings = std.StringHashMap([]const u8).init(testing.allocator);
    defer settings.deinit();
    try settings.put("repo_url", "https://github.com/test/repo");

    const config = IntegrationConfig{
        .id = "github-1",
        .integration_type = .github,
        .name = "Test GitHub",
        .enabled = true,
        .settings = settings,
        .created_at = std.time.timestamp(),
        .updated_at = std.time.timestamp(),
        .last_error = null,
        .rate_limit_remaining = null,
        .rate_limit_reset_at = null,
    };

    try manager.addIntegration(config);
    
    const retrieved = manager.getIntegration("github-1");
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("Test GitHub", retrieved.?.name);
}