const std = @import("std");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;
const protocol_ext = @import("../common/src/protocol_extensions.zig");
const grpc = common.grpc;

pub const IntegrationCommands = struct {
    allocator: std.mem.Allocator,
    config: *const common.config.ClientConfig,

    pub fn init(allocator: std.mem.Allocator, config: *const common.config.ClientConfig) IntegrationCommands {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn handleIntegrationCommand(self: *IntegrationCommands, args: []const []const u8) !void {
        if (args.len == 0) {
            self.printIntegrationUsage();
            return;
        }

        const subcommand = args[0];
        const subargs = args[1..];

        if (std.mem.eql(u8, subcommand, "list")) {
            try self.handleList(subargs);
        } else if (std.mem.eql(u8, subcommand, "connect")) {
            try self.handleConnect(subargs);
        } else if (std.mem.eql(u8, subcommand, "status")) {
            try self.handleStatus(subargs);
        } else if (std.mem.eql(u8, subcommand, "disconnect")) {
            try self.handleDisconnect(subargs);
        } else if (std.mem.eql(u8, subcommand, "test")) {
            try self.handleTest(subargs);
        } else {
            std.debug.print("Unknown integration subcommand: {s}\n", .{subcommand});
            self.printIntegrationUsage();
        }
    }

    pub fn handleGitHubCommand(self: *IntegrationCommands, args: []const []const u8) !void {
        if (args.len == 0) {
            self.printGitHubUsage();
            return;
        }

        const subcommand = args[0];
        const subargs = args[1..];

        if (std.mem.eql(u8, subcommand, "clone")) {
            try self.handleGitHubClone(subargs);
        } else if (std.mem.eql(u8, subcommand, "create-pr")) {
            try self.handleGitHubCreatePR(subargs);
        } else if (std.mem.eql(u8, subcommand, "list-repos")) {
            try self.handleGitHubListRepos(subargs);
        } else if (std.mem.eql(u8, subcommand, "webhook")) {
            try self.handleGitHubWebhook(subargs);
        } else {
            std.debug.print("Unknown GitHub subcommand: {s}\n", .{subcommand});
            self.printGitHubUsage();
        }
    }

    pub fn handleDockerCommand(self: *IntegrationCommands, args: []const []const u8) !void {
        if (args.len == 0) {
            self.printDockerUsage();
            return;
        }

        const subcommand = args[0];
        const subargs = args[1..];

        if (std.mem.eql(u8, subcommand, "build")) {
            try self.handleDockerBuild(subargs);
        } else if (std.mem.eql(u8, subcommand, "push")) {
            try self.handleDockerPush(subargs);
        } else if (std.mem.eql(u8, subcommand, "run")) {
            try self.handleDockerRun(subargs);
        } else if (std.mem.eql(u8, subcommand, "images")) {
            try self.handleDockerListImages(subargs);
        } else {
            std.debug.print("Unknown Docker subcommand: {s}\n", .{subcommand});
            self.printDockerUsage();
        }
    }

    pub fn handleAWSCommand(self: *IntegrationCommands, args: []const []const u8) !void {
        if (args.len == 0) {
            self.printAWSUsage();
            return;
        }

        const subcommand = args[0];
        const subargs = args[1..];

        if (std.mem.eql(u8, subcommand, "deploy")) {
            try self.handleAWSDeploy(subargs);
        } else if (std.mem.eql(u8, subcommand, "s3-upload")) {
            try self.handleAWSS3Upload(subargs);
        } else if (std.mem.eql(u8, subcommand, "lambda-invoke")) {
            try self.handleAWSLambdaInvoke(subargs);
        } else if (std.mem.eql(u8, subcommand, "cloudwatch-metric")) {
            try self.handleAWSCloudWatchMetric(subargs);
        } else {
            std.debug.print("Unknown AWS subcommand: {s}\n", .{subcommand});
            self.printAWSUsage();
        }
    }

    // Integration management commands
    fn handleList(self: *IntegrationCommands, args: []const []const u8) !void {
        _ = args; // No additional arguments needed
        
        var client = grpc.Client.init(self.allocator);
        defer client.close();

        try client.connect(self.config.orchestrator_address, self.config.orchestrator_port, self.config.tls_enabled, self.config.tls_ca_path);

        const request = protocol_ext.IntegrationListRequest{};
        const response = try client.call(.integration_list, request, protocol_ext.IntegrationListResponse);
        defer protocol.freeDecoded(protocol_ext.IntegrationListResponse, self.allocator, response.payload);

        std.debug.print("📋 Available Integrations\n");
        std.debug.print("========================\n\n");

        if (response.payload.integrations.len == 0) {
            std.debug.print("No integrations configured. Use 'marathon integration connect' to add one.\n");
            return;
        }

        for (response.payload.integrations) |integration| {
            const status_icon = switch (integration.status) {
                .connected => "✅",
                .disconnected => "❌",
                .connecting => "🔄",
                .error => "⚠️ ",
                .rate_limited => "⏳",
            };

            std.debug.print("{s} {s} ({s})\n", .{ status_icon, integration.name, @tagName(integration.integration_type) });
            std.debug.print("   ID: {s}\n", .{integration.id});
            std.debug.print("   Status: {s}\n", .{@tagName(integration.status)});
            std.debug.print("   Enabled: {}\n", .{integration.enabled});
            
            if (integration.last_error) |error_msg| {
                std.debug.print("   Last Error: {s}\n", .{error_msg});
            }
            
            std.debug.print("   Created: {d}\n", .{integration.created_at});
            std.debug.print("\n");
        }
    }

    fn handleConnect(self: *IntegrationCommands, args: []const []const u8) !void {
        if (args.len < 1) {
            std.debug.print("Error: service type required\n");
            std.debug.print("Usage: marathon integration connect <service>\n");
            std.debug.print("Services: github, docker-hub, ghcr, aws-ecr, aws-s3, aws-lambda, aws-ec2, aws-cloudwatch\n");
            return;
        }

        const service = args[0];
        const integration_type = parseIntegrationType(service) orelse {
            std.debug.print("Error: unknown service type '{s}'\n", .{service});
            return;
        };

        std.debug.print("Setting up {s} integration...\n", .{@tagName(integration_type)});

        // Collect credentials interactively
        var credentials = std.ArrayList(types.EnvVar).init(self.allocator);
        defer {
            for (credentials.items) |cred| {
                self.allocator.free(cred.key);
                self.allocator.free(cred.value);
            }
            credentials.deinit();
        }

        var settings = std.ArrayList(types.EnvVar).init(self.allocator);
        defer {
            for (settings.items) |setting| {
                self.allocator.free(setting.key);
                self.allocator.free(setting.value);
            }
            settings.deinit();
        }

        try self.collectCredentials(integration_type, &credentials, &settings);

        const integration_name = try self.promptForInput("Integration name", null);
        defer self.allocator.free(integration_name);

        var client = grpc.Client.init(self.allocator);
        defer client.close();

        try client.connect(self.config.orchestrator_address, self.config.orchestrator_port, self.config.tls_enabled, self.config.tls_ca_path);

        const request = protocol_ext.IntegrationConnectRequest{
            .integration_type = integration_type,
            .name = integration_name,
            .credentials = credentials.items,
            .settings = settings.items,
        };

        const response = try client.call(.integration_connect, request, protocol_ext.IntegrationConnectResponse);
        defer protocol.freeDecoded(protocol_ext.IntegrationConnectResponse, self.allocator, response.payload);

        if (response.payload.success) {
            std.debug.print("✅ Integration connected successfully!\n");
            if (response.payload.integration_id) |id| {
                std.debug.print("Integration ID: {s}\n", .{id});
            }
        } else {
            std.debug.print("❌ Failed to connect integration: {s}\n", .{response.payload.message});
        }
    }

    fn handleStatus(self: *IntegrationCommands, args: []const []const u8) !void {
        if (args.len < 1) {
            std.debug.print("Error: integration ID required\n");
            return;
        }

        const integration_id = args[0];

        var client = grpc.Client.init(self.allocator);
        defer client.close();

        try client.connect(self.config.orchestrator_address, self.config.orchestrator_port, self.config.tls_enabled, self.config.tls_ca_path);

        const request = protocol_ext.IntegrationStatusRequest{
            .integration_id = integration_id,
        };

        const response = try client.call(.integration_status, request, protocol_ext.IntegrationStatusResponse);
        defer protocol.freeDecoded(protocol_ext.IntegrationStatusResponse, self.allocator, response.payload);

        const status_icon = switch (response.payload.status) {
            .connected => "✅",
            .disconnected => "❌",
            .connecting => "🔄",
            .error => "⚠️ ",
            .rate_limited => "⏳",
        };

        std.debug.print("{s} Integration Status: {s}\n", .{ status_icon, @tagName(response.payload.status) });
        std.debug.print("Integration ID: {s}\n", .{response.payload.integration_id});

        if (response.payload.last_error) |error_msg| {
            std.debug.print("Last Error: {s}\n", .{error_msg});
        }

        if (response.payload.rate_limit_remaining) |remaining| {
            std.debug.print("Rate Limit: {d} requests remaining\n", .{remaining});
            if (response.payload.rate_limit_reset_at) |reset_at| {
                std.debug.print("Rate Limit Reset: {d}\n", .{reset_at});
            }
        }
    }

    fn handleDisconnect(self: *IntegrationCommands, args: []const []const u8) !void {
        if (args.len < 1) {
            std.debug.print("Error: integration ID required\n");
            return;
        }

        const integration_id = args[0];

        // Confirm disconnect
        const confirm = try self.promptForInput("Are you sure you want to disconnect this integration? (yes/no)", "no");
        defer self.allocator.free(confirm);

        if (!std.mem.eql(u8, confirm, "yes")) {
            std.debug.print("Disconnect cancelled.\n");
            return;
        }

        var client = grpc.Client.init(self.allocator);
        defer client.close();

        try client.connect(self.config.orchestrator_address, self.config.orchestrator_port, self.config.tls_enabled, self.config.tls_ca_path);

        const request = protocol_ext.IntegrationDisconnectRequest{
            .integration_id = integration_id,
        };

        const response = try client.call(.integration_disconnect, request, protocol_ext.IntegrationDisconnectResponse);
        defer protocol.freeDecoded(protocol_ext.IntegrationDisconnectResponse, self.allocator, response.payload);

        if (response.payload.success) {
            std.debug.print("✅ Integration disconnected successfully.\n");
        } else {
            std.debug.print("❌ Failed to disconnect integration: {s}\n", .{response.payload.message});
        }
    }

    fn handleTest(self: *IntegrationCommands, args: []const []const u8) !void {
        if (args.len < 1) {
            std.debug.print("Error: integration ID required\n");
            return;
        }

        const integration_id = args[0];

        std.debug.print("Testing connection for integration {s}...\n", .{integration_id});

        var client = grpc.Client.init(self.allocator);
        defer client.close();

        try client.connect(self.config.orchestrator_address, self.config.orchestrator_port, self.config.tls_enabled, self.config.tls_ca_path);

        const request = protocol_ext.IntegrationTestRequest{
            .integration_id = integration_id,
        };

        const response = try client.call(.integration_test, request, protocol_ext.IntegrationTestResponse);
        defer protocol.freeDecoded(protocol_ext.IntegrationTestResponse, self.allocator, response.payload);

        const status_icon = if (response.payload.success) "✅" else "❌";
        std.debug.print("{s} Test result: {s}\n", .{ status_icon, response.payload.message });
        std.debug.print("Status: {s}\n", .{@tagName(response.payload.status)});
    }

    // GitHub commands
    fn handleGitHubClone(self: *IntegrationCommands, args: []const []const u8) !void {
        var integration_id: ?[]const u8 = null;
        var repo_url: ?[]const u8 = null;
        var branch: []const u8 = "main";
        var destination: ?[]const u8 = null;

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--integration-id")) {
                i += 1;
                if (i >= args.len) {
                    std.debug.print("Error: --integration-id requires a value\n");
                    return;
                }
                integration_id = args[i];
            } else if (std.mem.eql(u8, args[i], "--repo")) {
                i += 1;
                if (i >= args.len) {
                    std.debug.print("Error: --repo requires a value\n");
                    return;
                }
                repo_url = args[i];
            } else if (std.mem.eql(u8, args[i], "--branch")) {
                i += 1;
                if (i >= args.len) {
                    std.debug.print("Error: --branch requires a value\n");
                    return;
                }
                branch = args[i];
            } else if (std.mem.eql(u8, args[i], "--dest")) {
                i += 1;
                if (i >= args.len) {
                    std.debug.print("Error: --dest requires a value\n");
                    return;
                }
                destination = args[i];
            }
        }

        if (integration_id == null) {
            std.debug.print("Error: --integration-id is required\n");
            return;
        }

        if (repo_url == null) {
            std.debug.print("Error: --repo is required\n");
            return;
        }

        if (destination == null) {
            std.debug.print("Error: --dest is required\n");
            return;
        }

        std.debug.print("Cloning repository {s} (branch: {s}) to {s}...\n", .{ repo_url.?, branch, destination.? });

        var client = grpc.Client.init(self.allocator);
        defer client.close();

        try client.connect(self.config.orchestrator_address, self.config.orchestrator_port, self.config.tls_enabled, self.config.tls_ca_path);

        const request = protocol_ext.GitHubCloneRequest{
            .integration_id = integration_id.?,
            .repo_url = repo_url.?,
            .branch = branch,
            .destination = destination.?,
        };

        const response = try client.call(.github_clone, request, protocol_ext.GitHubCloneResponse);
        defer protocol.freeDecoded(protocol_ext.GitHubCloneResponse, self.allocator, response.payload);

        if (response.payload.success) {
            std.debug.print("✅ Repository cloned successfully.\n");
        } else {
            std.debug.print("❌ Clone failed: {s}\n", .{response.payload.message});
        }
    }

    fn handleGitHubCreatePR(self: *IntegrationCommands, args: []const []const u8) !void {
        // Implementation for creating pull requests
        _ = args;
        std.debug.print("GitHub create-pr command not yet implemented\n");
    }

    fn handleGitHubListRepos(self: *IntegrationCommands, args: []const []const u8) !void {
        // Implementation for listing repositories
        _ = args;
        std.debug.print("GitHub list-repos command not yet implemented\n");
    }

    fn handleGitHubWebhook(self: *IntegrationCommands, args: []const []const u8) !void {
        // Implementation for webhook management
        _ = args;
        std.debug.print("GitHub webhook command not yet implemented\n");
    }

    // Docker commands
    fn handleDockerBuild(self: *IntegrationCommands, args: []const []const u8) !void {
        // Implementation for building Docker images
        _ = args;
        std.debug.print("Docker build command not yet implemented\n");
    }

    fn handleDockerPush(self: *IntegrationCommands, args: []const []const u8) !void {
        // Implementation for pushing Docker images
        _ = args;
        std.debug.print("Docker push command not yet implemented\n");
    }

    fn handleDockerRun(self: *IntegrationCommands, args: []const []const u8) !void {
        // Implementation for running Docker containers
        _ = args;
        std.debug.print("Docker run command not yet implemented\n");
    }

    fn handleDockerListImages(self: *IntegrationCommands, args: []const []const u8) !void {
        // Implementation for listing Docker images
        _ = args;
        std.debug.print("Docker images command not yet implemented\n");
    }

    // AWS commands  
    fn handleAWSDeploy(self: *IntegrationCommands, args: []const []const u8) !void {
        // Implementation for AWS deployments
        _ = args;
        std.debug.print("AWS deploy command not yet implemented\n");
    }

    fn handleAWSS3Upload(self: *IntegrationCommands, args: []const []const u8) !void {
        // Implementation for S3 uploads
        _ = args;
        std.debug.print("AWS s3-upload command not yet implemented\n");
    }

    fn handleAWSLambdaInvoke(self: *IntegrationCommands, args: []const []const u8) !void {
        // Implementation for Lambda invocations
        _ = args;
        std.debug.print("AWS lambda-invoke command not yet implemented\n");
    }

    fn handleAWSCloudWatchMetric(self: *IntegrationCommands, args: []const []const u8) !void {
        // Implementation for CloudWatch metrics
        _ = args;
        std.debug.print("AWS cloudwatch-metric command not yet implemented\n");
    }

    // Helper functions
    fn parseIntegrationType(service: []const u8) ?protocol_ext.IntegrationType {
        const mapping = [_]struct { name: []const u8, type: protocol_ext.IntegrationType }{
            .{ .name = "github", .type = .github },
            .{ .name = "docker-hub", .type = .docker_hub },
            .{ .name = "ghcr", .type = .github_container_registry },
            .{ .name = "aws-ecr", .type = .aws_ecr },
            .{ .name = "aws-s3", .type = .aws_s3 },
            .{ .name = "aws-lambda", .type = .aws_lambda },
            .{ .name = "aws-ec2", .type = .aws_ec2 },
            .{ .name = "aws-cloudwatch", .type = .aws_cloudwatch },
        };

        for (mapping) |item| {
            if (std.mem.eql(u8, service, item.name)) {
                return item.type;
            }
        }
        return null;
    }

    fn collectCredentials(self: *IntegrationCommands, integration_type: protocol_ext.IntegrationType, credentials: *std.ArrayList(types.EnvVar), settings: *std.ArrayList(types.EnvVar)) !void {
        switch (integration_type) {
            .github => {
                const token = try self.promptForInput("GitHub Personal Access Token", null);
                try credentials.append(.{ .key = try self.allocator.dupe(u8, "token"), .value = token });
            },
            .docker_hub => {
                const username = try self.promptForInput("Docker Hub Username", null);
                const password = try self.promptForInput("Docker Hub Password", null);
                try credentials.append(.{ .key = try self.allocator.dupe(u8, "username"), .value = username });
                try credentials.append(.{ .key = try self.allocator.dupe(u8, "password"), .value = password });
            },
            .github_container_registry => {
                const token = try self.promptForInput("GitHub Personal Access Token (with package:read/write)", null);
                try credentials.append(.{ .key = try self.allocator.dupe(u8, "token"), .value = token });
            },
            .aws_ecr, .aws_s3, .aws_lambda, .aws_ec2, .aws_cloudwatch => {
                const access_key = try self.promptForInput("AWS Access Key ID", null);
                const secret_key = try self.promptForInput("AWS Secret Access Key", null);
                const region = try self.promptForInput("AWS Region", "us-east-1");
                try credentials.append(.{ .key = try self.allocator.dupe(u8, "access_key_id"), .value = access_key });
                try credentials.append(.{ .key = try self.allocator.dupe(u8, "secret_access_key"), .value = secret_key });
                try credentials.append(.{ .key = try self.allocator.dupe(u8, "region"), .value = region });
            },
        }
    }

    fn promptForInput(self: *IntegrationCommands, prompt: []const u8, default_value: ?[]const u8) ![]u8 {
        const stdin = std.io.getStdIn().reader();
        
        if (default_value) |default| {
            std.debug.print("{s} [{s}]: ", .{ prompt, default });
        } else {
            std.debug.print("{s}: ", .{prompt});
        }

        var input_buffer: [1024]u8 = undefined;
        if (try stdin.readUntilDelimiterOrEof(input_buffer[0..], '\n')) |input| {
            const trimmed = std.mem.trim(u8, input, " \t\r\n");
            if (trimmed.len == 0 and default_value != null) {
                return self.allocator.dupe(u8, default_value.?);
            }
            return self.allocator.dupe(u8, trimmed);
        }

        if (default_value) |default| {
            return self.allocator.dupe(u8, default);
        }
        
        return error.NoInput;
    }

    fn printIntegrationUsage(self: *IntegrationCommands) void {
        _ = self;
        const usage =
            \\Marathon Integration Management
            \\
            \\Usage: marathon integration <command> [options]
            \\
            \\Commands:
            \\  list                         List all configured integrations
            \\  connect <service>            Setup a new integration
            \\  status <integration-id>      Check integration status
            \\  disconnect <integration-id>  Remove an integration
            \\  test <integration-id>        Test integration connection
            \\
            \\Supported Services:
            \\  github           GitHub API integration
            \\  docker-hub       Docker Hub registry
            \\  ghcr             GitHub Container Registry  
            \\  aws-ecr          AWS Elastic Container Registry
            \\  aws-s3           AWS S3 storage
            \\  aws-lambda       AWS Lambda functions
            \\  aws-ec2          AWS EC2 instances
            \\  aws-cloudwatch   AWS CloudWatch monitoring
            \\
            \\Examples:
            \\  marathon integration list
            \\  marathon integration connect github
            \\  marathon integration status github-1
            \\  marathon integration test github-1
            \\  marathon integration disconnect github-1
            \\
        ;
        std.debug.print("{s}", .{usage});
    }

    fn printGitHubUsage(self: *IntegrationCommands) void {
        _ = self;
        const usage =
            \\Marathon GitHub Integration
            \\
            \\Usage: marathon github <command> [options]
            \\
            \\Commands:
            \\  clone              Clone a repository
            \\  create-pr          Create a pull request
            \\  list-repos         List repositories
            \\  webhook            Manage webhooks
            \\
            \\Clone Options:
            \\  --integration-id ID    GitHub integration ID (required)
            \\  --repo URL            Repository URL (required)
            \\  --branch NAME         Branch name (default: main)
            \\  --dest PATH           Destination path (required)
            \\
            \\Examples:
            \\  marathon github clone --integration-id github-1 --repo owner/repo --dest ./repo
            \\  marathon github create-pr --integration-id github-1 --repo owner/repo --title "Fix bug"
            \\
        ;
        std.debug.print("{s}", .{usage});
    }

    fn printDockerUsage(self: *IntegrationCommands) void {
        _ = self;
        const usage =
            \\Marathon Docker Integration
            \\
            \\Usage: marathon docker <command> [options]
            \\
            \\Commands:
            \\  build              Build container image
            \\  push               Push image to registry
            \\  run                Run container
            \\  images             List container images
            \\
            \\Examples:
            \\  marathon docker build --integration-id docker-1 --image myapp:latest
            \\  marathon docker push --integration-id docker-1 --image myapp:latest
            \\  marathon docker run --integration-id docker-1 --image myapp:latest
            \\
        ;
        std.debug.print("{s}", .{usage});
    }

    fn printAWSUsage(self: *IntegrationCommands) void {
        _ = self;
        const usage =
            \\Marathon AWS Integration
            \\
            \\Usage: marathon aws <command> [options]
            \\
            \\Commands:
            \\  deploy             Deploy service to AWS
            \\  s3-upload          Upload file to S3
            \\  lambda-invoke      Invoke Lambda function
            \\  cloudwatch-metric  Publish CloudWatch metric
            \\
            \\Examples:
            \\  marathon aws deploy --integration-id aws-1 --service lambda
            \\  marathon aws s3-upload --integration-id aws-1 --bucket mybucket --key file.txt
            \\  marathon aws lambda-invoke --integration-id aws-1 --function myfunction
            \\
        ;
        std.debug.print("{s}", .{usage});
    }
};