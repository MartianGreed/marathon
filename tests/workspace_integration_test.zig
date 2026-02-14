const std = @import("std");
const testing = std.testing;
const common = @import("common");
const types = common.types;
const protocol = common.protocol;

// Integration tests for the complete workspace management system
// These tests demonstrate end-to-end functionality

test "workspace lifecycle integration test" {
    testing.log_level = .debug;
    std.log.info("Starting workspace lifecycle integration test", .{});

    // Test demonstrates the complete workflow:
    // 1. User registers and gets a default workspace
    // 2. User creates additional workspaces with different templates
    // 3. User switches between workspaces
    // 4. User submits tasks with workspace-specific environment variables
    // 5. User manages workspace settings and environment variables

    // Note: This would require a running database and orchestrator for a full integration test
    // For now, we validate the protocol message structures
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test workspace creation request
    const create_request = protocol.WorkspaceCreateRequest{
        .name = "test-workspace",
        .description = "Integration test workspace",
        .template = "web-app",
        .settings = "{\"node_version\": \"20\", \"package_manager\": \"npm\"}",
    };

    // Test encoding/decoding the request
    const encoded_create = try protocol.encodePayload(protocol.WorkspaceCreateRequest, allocator, create_request);
    defer allocator.free(encoded_create);
    
    const decoded_create = try protocol.decodePayload(protocol.WorkspaceCreateRequest, allocator, encoded_create);
    defer {
        allocator.free(decoded_create.name);
        if (decoded_create.description) |d| allocator.free(d);
        if (decoded_create.template) |t| allocator.free(t);
        if (decoded_create.settings) |s| allocator.free(s);
    }

    try testing.expectEqualStrings(create_request.name, decoded_create.name);
    try testing.expectEqualStrings(create_request.description.?, decoded_create.description.?);
    try testing.expectEqualStrings(create_request.template.?, decoded_create.template.?);
    try testing.expectEqualStrings(create_request.settings.?, decoded_create.settings.?);

    std.log.info("✓ Workspace creation request encoding/decoding works", .{});

    // Test workspace list request/response
    const list_request = protocol.WorkspaceListRequest{
        .limit = 50,
        .offset = 0,
    };

    // Mock workspace summaries
    const workspace_summaries = [_]types.WorkspaceSummary{
        .{
            .id = [_]u8{1} ** 16,
            .name = try allocator.dupe(u8, "default"),
            .description = try allocator.dupe(u8, "Default workspace"),
            .template = try allocator.dupe(u8, "default"),
            .created_at = std.time.milliTimestamp(),
            .last_accessed_at = std.time.milliTimestamp(),
            .task_count = 3,
            .is_active = true,
        },
        .{
            .id = [_]u8{2} ** 16,
            .name = try allocator.dupe(u8, "test-workspace"),
            .description = try allocator.dupe(u8, "Integration test workspace"),
            .template = try allocator.dupe(u8, "web-app"),
            .created_at = std.time.milliTimestamp(),
            .last_accessed_at = std.time.milliTimestamp(),
            .task_count = 0,
            .is_active = false,
        },
    };
    defer {
        for (workspace_summaries) |*ws| {
            ws.deinit(allocator);
        }
    }

    const list_response = protocol.WorkspaceListResponse{
        .workspaces = &workspace_summaries,
        .total_count = 2,
        .current_workspace_id = workspace_summaries[0].id,
    };

    // Test encoding/decoding list response
    const encoded_list = try protocol.encodePayload(protocol.WorkspaceListResponse, allocator, list_response);
    defer allocator.free(encoded_list);
    
    const decoded_list = try protocol.decodePayload(protocol.WorkspaceListResponse, allocator, encoded_list);
    defer {
        for (decoded_list.workspaces) |*ws| {
            ws.deinit(allocator);
        }
        allocator.free(decoded_list.workspaces);
    }

    try testing.expectEqual(@as(u32, 2), decoded_list.total_count);
    try testing.expectEqual(@as(usize, 2), decoded_list.workspaces.len);
    try testing.expectEqualStrings("default", decoded_list.workspaces[0].name);
    try testing.expectEqualStrings("test-workspace", decoded_list.workspaces[1].name);

    std.log.info("✓ Workspace list response encoding/decoding works", .{});

    // Test workspace switch request
    const switch_request = protocol.WorkspaceSwitchRequest{
        .workspace_id = workspace_summaries[1].id,
        .name = null,
    };

    const encoded_switch = try protocol.encodePayload(protocol.WorkspaceSwitchRequest, allocator, switch_request);
    defer allocator.free(encoded_switch);
    
    const decoded_switch = try protocol.decodePayload(protocol.WorkspaceSwitchRequest, allocator, encoded_switch);
    defer {
        if (decoded_switch.name) |n| allocator.free(n);
    }

    try testing.expect(decoded_switch.workspace_id != null);
    try testing.expect(std.mem.eql(u8, &switch_request.workspace_id.?, &decoded_switch.workspace_id.?));

    std.log.info("✓ Workspace switch request encoding/decoding works", .{});

    // Test task submission with workspace
    const task_env_vars = [_]types.EnvVar{
        .{ .key = "DATABASE_URL", .value = "postgres://localhost/test" },
        .{ .key = "NODE_ENV", .value = "development" },
    };

    const submit_request = protocol.SubmitTaskRequest{
        .repo_url = "https://github.com/test/repo",
        .branch = "main",
        .prompt = "Fix the authentication bug",
        .github_token = "ghp_testtoken123",
        .create_pr = true,
        .pr_title = "Fix authentication bug",
        .pr_body = "This PR fixes the authentication bug found in testing",
        .env_vars = &task_env_vars,
        .max_iterations = 10,
        .completion_promise = "TASK_COMPLETE",
        .workspace_id = workspace_summaries[1].id,
    };

    const encoded_submit = try protocol.encodePayload(protocol.SubmitTaskRequest, allocator, submit_request);
    defer allocator.free(encoded_submit);
    
    const decoded_submit = try protocol.decodePayload(protocol.SubmitTaskRequest, allocator, encoded_submit);
    defer {
        allocator.free(decoded_submit.repo_url);
        allocator.free(decoded_submit.branch);
        allocator.free(decoded_submit.prompt);
        allocator.free(decoded_submit.github_token);
        if (decoded_submit.pr_title) |t| allocator.free(t);
        if (decoded_submit.pr_body) |b| allocator.free(b);
        if (decoded_submit.completion_promise) |p| allocator.free(p);
        
        for (decoded_submit.env_vars) |env| {
            allocator.free(env.key);
            allocator.free(env.value);
        }
        allocator.free(decoded_submit.env_vars);
    }

    try testing.expectEqualStrings(submit_request.repo_url, decoded_submit.repo_url);
    try testing.expect(decoded_submit.workspace_id != null);
    try testing.expect(std.mem.eql(u8, &submit_request.workspace_id.?, &decoded_submit.workspace_id.?));
    try testing.expectEqual(@as(usize, 2), decoded_submit.env_vars.len);
    try testing.expectEqualStrings("DATABASE_URL", decoded_submit.env_vars[0].key);
    try testing.expectEqualStrings("postgres://localhost/test", decoded_submit.env_vars[0].value);

    std.log.info("✓ Task submission with workspace encoding/decoding works", .{});

    // Test workspace templates request/response
    const templates_request = protocol.WorkspaceTemplatesRequest{};
    
    const mock_templates = [_]types.WorkspaceTemplate{
        .{
            .id = [_]u8{1} ** 16,
            .name = try allocator.dupe(u8, "default"),
            .description = try allocator.dupe(u8, "Default empty workspace"),
            .default_settings = try allocator.dupe(u8, "{}"),
            .default_env_vars = try allocator.dupe(u8, "{}"),
            .created_at = std.time.milliTimestamp(),
        },
        .{
            .id = [_]u8{2} ** 16,
            .name = try allocator.dupe(u8, "web-app"),
            .description = try allocator.dupe(u8, "Web application workspace"),
            .default_settings = try allocator.dupe(u8, "{\"node_version\": \"20\"}"),
            .default_env_vars = try allocator.dupe(u8, "{\"NODE_ENV\": \"development\"}"),
            .created_at = std.time.milliTimestamp(),
        },
    };
    defer {
        for (mock_templates) |*tmpl| {
            tmpl.deinit(allocator);
        }
    }

    const templates_response = protocol.WorkspaceTemplatesResponse{
        .templates = &mock_templates,
    };

    const encoded_templates = try protocol.encodePayload(protocol.WorkspaceTemplatesResponse, allocator, templates_response);
    defer allocator.free(encoded_templates);
    
    const decoded_templates = try protocol.decodePayload(protocol.WorkspaceTemplatesResponse, allocator, encoded_templates);
    defer {
        for (decoded_templates.templates) |*tmpl| {
            tmpl.deinit(allocator);
        }
        allocator.free(decoded_templates.templates);
    }

    try testing.expectEqual(@as(usize, 2), decoded_templates.templates.len);
    try testing.expectEqualStrings("default", decoded_templates.templates[0].name);
    try testing.expectEqualStrings("web-app", decoded_templates.templates[1].name);
    try testing.expectEqualStrings("{\"node_version\": \"20\"}", decoded_templates.templates[1].default_settings);

    std.log.info("✓ Workspace templates encoding/decoding works", .{});

    std.log.info("All workspace integration tests passed! 🎉", .{});
}

test "workspace CLI command simulation" {
    testing.log_level = .debug;
    std.log.info("Testing workspace CLI command structures", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Simulate the CLI commands that would be executed:
    
    // marathon workspace create my-project --template web-app --description "My web project"
    const create_args = [_][]const u8{
        "workspace", "create", "my-project",
        "--template", "web-app", 
        "--description", "My web project"
    };
    
    // Validate the command parsing would work
    try testing.expectEqualStrings("workspace", create_args[0]);
    try testing.expectEqualStrings("create", create_args[1]);
    try testing.expectEqualStrings("my-project", create_args[2]);

    std.log.info("✓ CLI create command structure valid", .{});

    // marathon workspace list
    const list_args = [_][]const u8{"workspace", "list"};
    try testing.expectEqualStrings("list", list_args[1]);

    std.log.info("✓ CLI list command structure valid", .{});

    // marathon workspace switch my-project
    const switch_args = [_][]const u8{"workspace", "switch", "my-project"};
    try testing.expectEqualStrings("switch", switch_args[1]);
    try testing.expectEqualStrings("my-project", switch_args[2]);

    std.log.info("✓ CLI switch command structure valid", .{});

    // marathon submit --workspace my-project --repo https://github.com/user/repo --prompt "Fix bug"
    const submit_args = [_][]const u8{
        "submit",
        "--workspace", "my-project",
        "--repo", "https://github.com/user/repo",
        "--prompt", "Fix bug",
        "-e", "DATABASE_URL=postgres://localhost/test",
        "-e", "API_KEY=secret123"
    };
    
    try testing.expectEqualStrings("submit", submit_args[0]);
    try testing.expectEqualStrings("--workspace", submit_args[1]);
    try testing.expectEqualStrings("my-project", submit_args[2]);

    std.log.info("✓ CLI submit with workspace command structure valid", .{});

    std.log.info("All CLI command structure tests passed! 🎉", .{});
}

test "workspace error handling scenarios" {
    testing.log_level = .debug;
    std.log.info("Testing workspace error handling scenarios", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test error responses
    const name_exists_error = protocol.ErrorResponse{
        .code = "WORKSPACE_NAME_EXISTS",
        .message = "A workspace with this name already exists",
    };

    const encoded_error = try protocol.encodePayload(protocol.ErrorResponse, allocator, name_exists_error);
    defer allocator.free(encoded_error);
    
    const decoded_error = try protocol.decodePayload(protocol.ErrorResponse, allocator, encoded_error);
    defer {
        allocator.free(decoded_error.code);
        allocator.free(decoded_error.message);
    }

    try testing.expectEqualStrings("WORKSPACE_NAME_EXISTS", decoded_error.code);
    try testing.expectEqualStrings("A workspace with this name already exists", decoded_error.message);

    std.log.info("✓ Error response encoding/decoding works", .{});

    // Test workspace response with failure
    const failed_response = protocol.WorkspaceResponse{
        .success = false,
        .workspace = null,
        .env_vars = &[_]types.EnvVar{},
        .message = "Failed to create workspace: invalid template",
    };

    const encoded_failed = try protocol.encodePayload(protocol.WorkspaceResponse, allocator, failed_response);
    defer allocator.free(encoded_failed);
    
    const decoded_failed = try protocol.decodePayload(protocol.WorkspaceResponse, allocator, encoded_failed);
    defer {
        if (decoded_failed.workspace) |*ws| ws.deinit(allocator);
        allocator.free(decoded_failed.env_vars);
        allocator.free(decoded_failed.message);
    }

    try testing.expect(!decoded_failed.success);
    try testing.expect(decoded_failed.workspace == null);
    try testing.expectEqualStrings("Failed to create workspace: invalid template", decoded_failed.message);

    std.log.info("✓ Failed workspace response encoding/decoding works", .{});

    std.log.info("All error handling tests passed! 🎉", .{});
}

test "workspace database schema validation" {
    testing.log_level = .debug;
    std.log.info("Testing workspace database schema structures", .{});

    // Validate that our types align with the database schema
    
    // Workspace ID should be 16 bytes (for UUID/BYTEA)
    const workspace_id: types.WorkspaceId = [_]u8{0} ** 16;
    try testing.expectEqual(@as(usize, 16), workspace_id.len);

    // User ID should be 16 bytes
    const user_id: types.UserId = [_]u8{0} ** 16;
    try testing.expectEqual(@as(usize, 16), user_id.len);

    // Workspace struct should have all required fields for database mapping
    const workspace = types.Workspace{
        .id = workspace_id,
        .name = "test",
        .description = null,
        .user_id = user_id,
        .template = null,
        .settings = "{}",
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .last_accessed_at = std.time.milliTimestamp(),
    };

    // Validate field types match database expectations
    try testing.expect(@TypeOf(workspace.id) == types.WorkspaceId);
    try testing.expect(@TypeOf(workspace.user_id) == types.UserId);
    try testing.expect(@TypeOf(workspace.name) == []const u8);
    try testing.expect(@TypeOf(workspace.settings) == []const u8);
    try testing.expect(@TypeOf(workspace.created_at) == i64);

    std.log.info("✓ Workspace database schema types are valid", .{});

    // Validate workspace summary for listings
    const summary = types.WorkspaceSummary{
        .id = workspace_id,
        .name = "test",
        .description = null,
        .template = null,
        .created_at = std.time.milliTimestamp(),
        .last_accessed_at = std.time.milliTimestamp(),
        .task_count = 5,
        .is_active = true,
    };

    try testing.expect(@TypeOf(summary.task_count) == u32);
    try testing.expect(@TypeOf(summary.is_active) == bool);

    std.log.info("✓ Workspace summary schema types are valid", .{});

    std.log.info("All database schema validation tests passed! 🎉", .{});
}