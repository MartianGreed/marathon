const std = @import("std");
const testing = std.testing;
const mod = @import("mod.zig");
const github = @import("github.zig");
const docker = @import("docker.zig");
const aws = @import("aws.zig");
const credentials = @import("credentials.zig");

// Integration Manager Tests
test "integration manager lifecycle" {
    var creds_manager = credentials.CredentialsManager.init(testing.allocator, "test-master-key");
    defer creds_manager.deinit();

    var manager = mod.IntegrationManager.init(testing.allocator, &creds_manager);
    defer manager.deinit();

    // Test creating an integration
    var settings = std.StringHashMap([]const u8).init(testing.allocator);
    defer settings.deinit();
    try settings.put("repo_url", "https://github.com/test/repo");

    const config = mod.IntegrationConfig{
        .id = "test-integration",
        .integration_type = .github,
        .name = "Test GitHub Integration",
        .enabled = true,
        .settings = settings,
        .created_at = std.time.timestamp(),
        .updated_at = std.time.timestamp(),
        .last_error = null,
        .rate_limit_remaining = 5000,
        .rate_limit_reset_at = null,
    };

    // Add integration
    try manager.addIntegration(config);

    // Verify it was added
    const retrieved = manager.getIntegration("test-integration");
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("Test GitHub Integration", retrieved.?.name);
    try testing.expectEqual(mod.IntegrationType.github, retrieved.?.integration_type);
    try testing.expect(retrieved.?.enabled);

    // List integrations
    var integrations_list = manager.listIntegrations();
    defer integrations_list.deinit();
    try testing.expectEqual(@as(usize, 1), integrations_list.items.len);

    // Remove integration
    try manager.removeIntegration("test-integration");

    // Verify it was removed
    const removed = manager.getIntegration("test-integration");
    try testing.expect(removed == null);
}

test "integration manager multiple integrations" {
    var creds_manager = credentials.CredentialsManager.init(testing.allocator, "test-master-key");
    defer creds_manager.deinit();

    var manager = mod.IntegrationManager.init(testing.allocator, &creds_manager);
    defer manager.deinit();

    // Add multiple integrations
    const integrations = [_]struct {
        id: []const u8,
        name: []const u8,
        integration_type: mod.IntegrationType,
    }{
        .{ .id = "github-1", .name = "GitHub Integration", .integration_type = .github },
        .{ .id = "docker-1", .name = "Docker Hub", .integration_type = .docker_hub },
        .{ .id = "aws-s3-1", .name = "AWS S3 Storage", .integration_type = .aws_s3 },
    };

    for (integrations) |integration| {
        var settings = std.StringHashMap([]const u8).init(testing.allocator);
        defer settings.deinit();

        const config = mod.IntegrationConfig{
            .id = integration.id,
            .integration_type = integration.integration_type,
            .name = integration.name,
            .enabled = true,
            .settings = settings,
            .created_at = std.time.timestamp(),
            .updated_at = std.time.timestamp(),
            .last_error = null,
            .rate_limit_remaining = null,
            .rate_limit_reset_at = null,
        };

        try manager.addIntegration(config);
    }

    // Verify all were added
    var integrations_list = manager.listIntegrations();
    defer integrations_list.deinit();
    try testing.expectEqual(@as(usize, 3), integrations_list.items.len);

    // Test getting specific integrations
    const github_integration = manager.getIntegration("github-1");
    try testing.expect(github_integration != null);
    try testing.expectEqualStrings("GitHub Integration", github_integration.?.name);

    const docker_integration = manager.getIntegration("docker-1");
    try testing.expect(docker_integration != null);
    try testing.expectEqualStrings("Docker Hub", docker_integration.?.name);
}

// GitHub Client Tests
test "github client initialization and credentials" {
    var client = github.GitHubClient.init(testing.allocator);
    defer client.deinit();

    try testing.expect(client.access_token == null);

    // Test setting credentials
    try client.setCredentials("ghp_test_token_12345");
    try testing.expect(client.access_token != null);
    try testing.expectEqualStrings("ghp_test_token_12345", client.access_token.?);
}

test "github rate limiter" {
    var rate_limiter = github.GitHubClient.RateLimiter.init();

    // Should start with default limits
    try testing.expect(rate_limiter.canMakeRequest());
    try testing.expectEqual(@as(u32, 5000), rate_limiter.requests_remaining);

    // Test rate limiting
    rate_limiter.recordRequest(0, std.time.timestamp() + 3600);
    try testing.expect(!rate_limiter.canMakeRequest());
    try testing.expectEqual(@as(u32, 0), rate_limiter.requests_remaining);

    // Test rate limit reset
    rate_limiter.recordRequest(4999, std.time.timestamp() - 1);
    try testing.expect(rate_limiter.canMakeRequest());
}

test "github repository parsing" {
    // This would test JSON parsing of GitHub API responses
    // Mock data would be used in real implementation
    const mock_repo_json =
        \\{
        \\  "id": 123456,
        \\  "name": "test-repo",
        \\  "full_name": "owner/test-repo",
        \\  "private": false,
        \\  "clone_url": "https://github.com/owner/test-repo.git",
        \\  "default_branch": "main",
        \\  "description": "Test repository"
        \\}
    ;

    var parser = std.json.Parser.init(testing.allocator, .alloc_always);
    defer parser.deinit();

    var tree = try parser.parse(mock_repo_json);
    defer tree.deinit();

    // Verify parsing
    try testing.expect(tree.root == .object);
    const obj = tree.root.object;
    try testing.expectEqual(@as(i64, 123456), obj.get("id").?.integer);
    try testing.expectEqualStrings("test-repo", obj.get("name").?.string);
    try testing.expectEqualStrings("owner/test-repo", obj.get("full_name").?.string);
    try testing.expect(!obj.get("private").?.bool);
}

// Docker Client Tests
test "docker client initialization" {
    var client = docker.DockerClient.init(testing.allocator);
    defer client.deinit();

    try testing.expectEqual(@as(usize, 0), client.registry_configs.count());
}

test "docker registry configuration" {
    var client = docker.DockerClient.init(testing.allocator);
    defer client.deinit();

    // Test Docker Hub credentials
    try client.setCredentials("testuser", "testpass");
    try testing.expect(client.registry_configs.contains("docker_hub"));

    // Test GitHub Container Registry credentials
    try client.setGithubRegistryCredentials("ghp_test_token");
    try testing.expect(client.registry_configs.contains("ghcr"));

    // Verify configurations
    const docker_hub_config = client.registry_configs.get("docker_hub").?;
    try testing.expectEqualStrings("https://registry.hub.docker.com", docker_hub_config.registry_url);
    try testing.expectEqualStrings("testuser", docker_hub_config.username);

    const ghcr_config = client.registry_configs.get("ghcr").?;
    try testing.expectEqualStrings("https://ghcr.io", ghcr_config.registry_url);
    try testing.expectEqualStrings("token", ghcr_config.username);
}

test "docker container config validation" {
    const config = docker.DockerClient.ContainerConfig{
        .image = "nginx:latest",
        .name = "test-container",
        .ports = &.{ "80:8080", "443:8443" },
        .environment = &.{ "NODE_ENV=production", "PORT=8080" },
        .volumes = &.{ "/host/data:/container/data:ro" },
        .network = "bridge",
        .restart_policy = "unless-stopped",
        .healthcheck_cmd = "curl -f http://localhost:8080/health",
    };

    // Test configuration fields
    try testing.expectEqualStrings("nginx:latest", config.image);
    try testing.expectEqualStrings("test-container", config.name.?);
    try testing.expectEqual(@as(usize, 2), config.ports.len);
    try testing.expectEqualStrings("80:8080", config.ports[0]);
    try testing.expectEqual(@as(usize, 2), config.environment.len);
    try testing.expectEqualStrings("NODE_ENV=production", config.environment[0]);
    try testing.expectEqualStrings("unless-stopped", config.restart_policy);
}

// AWS Client Tests
test "aws client initialization" {
    var client = aws.AwsClient.init(testing.allocator);
    defer client.deinit();

    try testing.expect(client.access_key_id == null);
    try testing.expect(client.secret_access_key == null);
    try testing.expectEqualStrings("us-east-1", client.region);
}

test "aws client credentials" {
    var client = aws.AwsClient.init(testing.allocator);
    defer client.deinit();

    try client.setCredentials("AKIATEST12345", "secretkey12345", "eu-west-1");

    try testing.expect(client.access_key_id != null);
    try testing.expectEqualStrings("AKIATEST12345", client.access_key_id.?);
    try testing.expect(client.secret_access_key != null);
    try testing.expectEqualStrings("secretkey12345", client.secret_access_key.?);
    try testing.expectEqualStrings("eu-west-1", client.region);
}

test "aws lambda function creation request" {
    const request = aws.AwsClient.LambdaCreateRequest{
        .function_name = "test-function",
        .runtime = "nodejs18.x",
        .role = "arn:aws:iam::123456789012:role/lambda-role",
        .handler = "index.handler",
        .zip_file = "dummy-zip-content",
        .timeout = 30,
        .memory_size = 256,
    };

    try testing.expectEqualStrings("test-function", request.function_name);
    try testing.expectEqualStrings("nodejs18.x", request.runtime);
    try testing.expectEqual(@as(?u32, 30), request.timeout);
    try testing.expectEqual(@as(?u32, 256), request.memory_size);
}

test "aws cloudwatch metric dimensions" {
    const dimensions = [_]aws.AwsClient.CloudWatchMetric.Dimension{
        .{ .name = "Environment", .value = "production" },
        .{ .name = "Service", .value = "web-server" },
    };

    try testing.expectEqual(@as(usize, 2), dimensions.len);
    try testing.expectEqualStrings("Environment", dimensions[0].name);
    try testing.expectEqualStrings("production", dimensions[0].value);
    try testing.expectEqualStrings("Service", dimensions[1].name);
    try testing.expectEqualStrings("web-server", dimensions[1].value);
}

// Credentials Manager Tests
test "credentials manager encryption roundtrip" {
    var manager = credentials.CredentialsManager.init(testing.allocator, "test-encryption-key-12345");
    defer manager.deinit();

    // Test basic health check
    try testing.expect(manager.healthCheck());

    // Test storing and retrieving credentials
    var test_settings = std.StringHashMap([]const u8).init(testing.allocator);
    defer test_settings.deinit();
    
    try test_settings.put("api_key", "sk-test-api-key-12345");
    try test_settings.put("secret", "very-secret-value");
    try test_settings.put("endpoint", "https://api.example.com");

    const integration_id = "test-integration-123";
    try manager.storeCredentials(integration_id, test_settings);

    // Retrieve and verify
    var retrieved = try manager.getCredentials(integration_id);
    defer retrieved.deinit(testing.allocator);

    try testing.expectEqualStrings(integration_id, retrieved.integration_id);
    try testing.expectEqualStrings("sk-test-api-key-12345", retrieved.settings.get("api_key").?);
    try testing.expectEqualStrings("very-secret-value", retrieved.settings.get("secret").?);
    try testing.expectEqualStrings("https://api.example.com", retrieved.settings.get("endpoint").?);

    // Test deletion
    try manager.deleteCredentials(integration_id);
    
    // Should not be able to retrieve after deletion
    const deleted_result = manager.getCredentials(integration_id);
    try testing.expectError(error.CredentialsNotFound, deleted_result);
}

test "credentials manager key rotation" {
    var manager = credentials.CredentialsManager.init(testing.allocator, "original-key-12345");
    defer manager.deinit();

    // Store credentials with original key
    var settings = std.StringHashMap([]const u8).init(testing.allocator);
    defer settings.deinit();
    try settings.put("token", "sensitive-token-data");
    try settings.put("refresh_token", "refresh-token-data");

    const integration_id = "key-rotation-test";
    try manager.storeCredentials(integration_id, settings);

    // Verify we can retrieve with original key
    var original_retrieval = try manager.getCredentials(integration_id);
    defer original_retrieval.deinit(testing.allocator);
    try testing.expectEqualStrings("sensitive-token-data", original_retrieval.settings.get("token").?);

    // Rotate to new key
    try manager.rotateEncryptionKey("new-rotated-key-67890");

    // Should still be able to retrieve after rotation
    var post_rotation_retrieval = try manager.getCredentials(integration_id);
    defer post_rotation_retrieval.deinit(testing.allocator);
    try testing.expectEqualStrings("sensitive-token-data", post_rotation_retrieval.settings.get("token").?);
    try testing.expectEqualStrings("refresh-token-data", post_rotation_retrieval.settings.get("refresh_token").?);
}

test "credentials manager multiple integrations" {
    var manager = credentials.CredentialsManager.init(testing.allocator, "multi-integration-key");
    defer manager.deinit();

    const test_cases = [_]struct {
        id: []const u8,
        key: []const u8,
        value: []const u8,
    }{
        .{ .id = "github-integration", .key = "token", .value = "ghp_github_token_12345" },
        .{ .id = "docker-integration", .key = "password", .value = "docker_hub_password_67890" },
        .{ .id = "aws-integration", .key = "access_key", .value = "AKIAAWS12345" },
    };

    // Store multiple credentials
    for (test_cases) |test_case| {
        var settings = std.StringHashMap([]const u8).init(testing.allocator);
        defer settings.deinit();
        try settings.put(test_case.key, test_case.value);
        
        try manager.storeCredentials(test_case.id, settings);
    }

    // Verify all can be retrieved correctly
    for (test_cases) |test_case| {
        var retrieved = try manager.getCredentials(test_case.id);
        defer retrieved.deinit(testing.allocator);
        
        try testing.expectEqualStrings(test_case.id, retrieved.integration_id);
        try testing.expectEqualStrings(test_case.value, retrieved.settings.get(test_case.key).?);
    }
}

// Error Handling Tests
test "integration manager error conditions" {
    var creds_manager = credentials.CredentialsManager.init(testing.allocator, "test-key");
    defer creds_manager.deinit();

    var manager = mod.IntegrationManager.init(testing.allocator, &creds_manager);
    defer manager.deinit();

    // Test getting non-existent integration
    const missing = manager.getIntegration("non-existent");
    try testing.expect(missing == null);

    // Test removing non-existent integration
    // Should not error, just do nothing
    try manager.removeIntegration("non-existent");
}

test "github client error conditions" {
    var client = github.GitHubClient.init(testing.allocator);
    defer client.deinit();

    // Test operations without credentials
    const status = client.testConnection();
    try testing.expectEqual(mod.IntegrationStatus.disconnected, status);
}

test "aws client error conditions" {
    var client = aws.AwsClient.init(testing.allocator);
    defer client.deinit();

    // Test operations without credentials
    const s3_status = client.testS3Connection();
    try testing.expectEqual(mod.IntegrationStatus.disconnected, s3_status);

    const lambda_status = client.testLambdaConnection();
    try testing.expectEqual(mod.IntegrationStatus.disconnected, lambda_status);
}

test "credentials manager error conditions" {
    var manager = credentials.CredentialsManager.init(testing.allocator, "test-key");
    defer manager.deinit();

    // Test retrieving non-existent credentials
    const result = manager.getCredentials("non-existent");
    try testing.expectError(error.CredentialsNotFound, result);

    // Test deleting non-existent credentials (should not error)
    try manager.deleteCredentials("non-existent");
}

// Integration Test
test "full integration workflow" {
    var creds_manager = credentials.CredentialsManager.init(testing.allocator, "workflow-test-key");
    defer creds_manager.deinit();

    var manager = mod.IntegrationManager.init(testing.allocator, &creds_manager);
    defer manager.deinit();

    // 1. Create GitHub integration
    var github_settings = std.StringHashMap([]const u8).init(testing.allocator);
    defer github_settings.deinit();
    try github_settings.put("repo_url", "https://github.com/test/repo");

    const github_config = mod.IntegrationConfig{
        .id = "github-workflow",
        .integration_type = .github,
        .name = "GitHub Workflow Test",
        .enabled = true,
        .settings = github_settings,
        .created_at = std.time.timestamp(),
        .updated_at = std.time.timestamp(),
        .last_error = null,
        .rate_limit_remaining = 5000,
        .rate_limit_reset_at = null,
    };

    try manager.addIntegration(github_config);

    // 2. Store credentials separately
    var github_creds = std.StringHashMap([]const u8).init(testing.allocator);
    defer github_creds.deinit();
    try github_creds.put("token", "ghp_workflow_test_token");

    try creds_manager.storeCredentials("github-workflow", github_creds);

    // 3. Verify integration exists
    const integration = manager.getIntegration("github-workflow");
    try testing.expect(integration != null);
    try testing.expectEqual(mod.IntegrationType.github, integration.?.integration_type);

    // 4. Verify credentials can be retrieved
    var retrieved_creds = try creds_manager.getCredentials("github-workflow");
    defer retrieved_creds.deinit(testing.allocator);
    try testing.expectEqualStrings("ghp_workflow_test_token", retrieved_creds.settings.get("token").?);

    // 5. Test connection (would normally make API call)
    const status = manager.testConnection("github-workflow");
    // In test environment, this would return disconnected since we can't make real API calls
    try testing.expectError(error.IntegrationNotFound, status);

    // 6. Clean up
    try manager.removeIntegration("github-workflow");
    try creds_manager.deleteCredentials("github-workflow");
}

// Performance Tests
test "integration manager performance with many integrations" {
    var creds_manager = credentials.CredentialsManager.init(testing.allocator, "perf-test-key");
    defer creds_manager.deinit();

    var manager = mod.IntegrationManager.init(testing.allocator, &creds_manager);
    defer manager.deinit();

    const num_integrations = 100;
    
    // Add many integrations
    var i: usize = 0;
    while (i < num_integrations) : (i += 1) {
        const id = try std.fmt.allocPrint(testing.allocator, "perf-test-{d}", .{i});
        defer testing.allocator.free(id);

        var settings = std.StringHashMap([]const u8).init(testing.allocator);
        defer settings.deinit();
        
        const config = mod.IntegrationConfig{
            .id = id,
            .integration_type = .github,
            .name = "Performance Test Integration",
            .enabled = true,
            .settings = settings,
            .created_at = std.time.timestamp(),
            .updated_at = std.time.timestamp(),
            .last_error = null,
            .rate_limit_remaining = null,
            .rate_limit_reset_at = null,
        };

        try manager.addIntegration(config);
    }

    // Verify all were added
    var integrations = manager.listIntegrations();
    defer integrations.deinit();
    try testing.expectEqual(num_integrations, integrations.items.len);

    // Test retrieval performance
    i = 0;
    while (i < num_integrations) : (i += 1) {
        const id = try std.fmt.allocPrint(testing.allocator, "perf-test-{d}", .{i});
        defer testing.allocator.free(id);

        const integration = manager.getIntegration(id);
        try testing.expect(integration != null);
    }
}

// Concurrency Tests (basic simulation)
test "credentials manager thread safety simulation" {
    var manager = credentials.CredentialsManager.init(testing.allocator, "thread-safety-test");
    defer manager.deinit();

    // Simulate concurrent operations by doing them sequentially
    // In a real test environment, these would be done in separate threads
    const operations = [_]struct {
        id: []const u8,
        key: []const u8,
        value: []const u8,
    }{
        .{ .id = "concurrent-1", .key = "token1", .value = "value1" },
        .{ .id = "concurrent-2", .key = "token2", .value = "value2" },
        .{ .id = "concurrent-3", .key = "token3", .value = "value3" },
    };

    // Store all credentials
    for (operations) |op| {
        var settings = std.StringHashMap([]const u8).init(testing.allocator);
        defer settings.deinit();
        try settings.put(op.key, op.value);
        try manager.storeCredentials(op.id, settings);
    }

    // Verify all can be retrieved
    for (operations) |op| {
        var retrieved = try manager.getCredentials(op.id);
        defer retrieved.deinit(testing.allocator);
        try testing.expectEqualStrings(op.value, retrieved.settings.get(op.key).?);
    }
}

// Memory Management Tests
test "integration manager memory management" {
    var creds_manager = credentials.CredentialsManager.init(testing.allocator, "memory-test");
    defer creds_manager.deinit();

    var manager = mod.IntegrationManager.init(testing.allocator, &creds_manager);
    defer manager.deinit();

    // Test that adding and removing integrations doesn't leak memory
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const id = try std.fmt.allocPrint(testing.allocator, "memory-test-{d}", .{i});
        defer testing.allocator.free(id);

        var settings = std.StringHashMap([]const u8).init(testing.allocator);
        defer settings.deinit();

        const config = mod.IntegrationConfig{
            .id = id,
            .integration_type = .docker_hub,
            .name = "Memory Test Integration",
            .enabled = true,
            .settings = settings,
            .created_at = std.time.timestamp(),
            .updated_at = std.time.timestamp(),
            .last_error = null,
            .rate_limit_remaining = null,
            .rate_limit_reset_at = null,
        };

        try manager.addIntegration(config);
        try manager.removeIntegration(id);
    }

    // Verify no integrations remain
    var final_list = manager.listIntegrations();
    defer final_list.deinit();
    try testing.expectEqual(@as(usize, 0), final_list.items.len);
}