const std = @import("std");
const common = @import("common");
const types = common.types;

const vsock_client = @import("vsock_client.zig");
const claude_wrapper = @import("claude_wrapper.zig");
const api_interceptor = @import("api_interceptor.zig");
const repo_setup = @import("repo_setup.zig");
const prompt_wrapper = @import("prompt_wrapper.zig");
const cleanup = @import("cleanup.zig");

const DEFAULT_MAX_ITERATIONS: u32 = 50;

pub fn main() !void {
    // Redirect stderr to log file for persistent logging
    // OpenRC's output_log/error_log may not capture all output
    if (std.fs.createFileAbsolute("/var/log/marathon-agent-debug.log", .{ .truncate = true })) |log_file| {
        const log_fd = log_file.handle;
        // dup2 the log file to stderr (fd 2)
        std.posix.dup2(log_fd, 2) catch {};
        std.posix.close(log_fd);
    } else |_| {}

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try common.config.VmAgentConfig.fromEnv(allocator);

    std.log.info("Marathon VM Agent starting...", .{});
    std.log.info("  Vsock port: {d}", .{config.vsock_port});
    std.log.info("  Work dir: {s}", .{config.work_dir});
    std.log.info("  Claude Code path: {s}", .{config.claude_code_path});
    std.log.info("  Cleanup strategy: {s}", .{config.cleanup_strategy});

    if (!common.compat.VsockSupported) {
        std.log.warn("Vsock not supported on this platform (Linux only)", .{});
    }

    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = claude_wrapper.ClaudeWrapper.init(
        allocator,
        config.claude_code_path,
        config.work_dir,
        &interceptor,
    );
    defer wrapper.deinit();

    var client = try vsock_client.VsockClient.init(allocator, config.vsock_port);
    defer client.deinit();

    const prompt_wrap = prompt_wrapper.PromptWrapper.init();
    var cleaner = cleanup.Cleanup.initWithStrategy(cleanup.CleanupStrategy.fromString(config.cleanup_strategy));

    // Wait for network to be ready (init scripts may not have finished)
    waitForNetwork(allocator);

    var task: claude_wrapper.TaskInfo = undefined;
    while (true) {
        client.sendReady() catch |err| {
            std.log.warn("Connection closed during ready handshake (probe?), re-listening", .{});
            client.resetConnection();
            if (err == error.ConnectionClosed) continue;
            return err;
        };
        std.log.info("Agent ready, waiting for task...", .{});

        task = client.receiveTask() catch |err| {
            std.log.warn("Connection closed before task received (probe?), re-listening", .{});
            client.resetConnection();
            if (err == error.ConnectionClosed) continue;
            return err;
        };
        break;
    }
    std.log.info("Received task, starting execution", .{});

    var setup = repo_setup.RepoSetup.init(allocator, config.work_dir, task.github_token);
    setup.clone(task.repo_url, task.branch) catch |err| {
        std.log.err("Repository setup failed: {s}", .{@errorName(err)});
        try client.sendError("setup_failed", @errorName(err));
        return;
    };
    setup.configureDefaults() catch |err| {
        std.log.err("Git config failed: {s}", .{@errorName(err)});
        try client.sendError("setup_failed", @errorName(err));
        return;
    };

    std.log.info("Repository setup complete", .{});

    const repo_name = extractRepoName(task.repo_url);
    const wrapped_prompt = try prompt_wrap.wrap(allocator, task.prompt, repo_name, task.branch);
    defer allocator.free(wrapped_prompt);

    var modified_task = task;
    modified_task.prompt = wrapped_prompt;

    wrapper.setOutputCallback(outputCallback, @ptrCast(&client));

    const max_iterations = task.max_iterations orelse DEFAULT_MAX_ITERATIONS;
    var iteration: u32 = 0;
    var cumulative_metrics = types.UsageMetrics{};

    defer {
        cleaner.execute(config.work_dir);
        std.log.info("Cleanup complete", .{});
    }

    while (iteration < max_iterations) : (iteration += 1) {
        if (try client.checkCancel()) {
            std.log.info("Task cancelled by user", .{});
            try client.sendError("cancelled", "Task cancelled by user");
            return;
        }

        std.log.info("Starting iteration {d}/{d}", .{ iteration + 1, max_iterations });

        try client.sendProgress(iteration + 1, max_iterations, "running");

        const result = wrapper.run(modified_task) catch |err| {
            std.log.err("Execution failed: {s}", .{@errorName(err)});
            try client.sendError("execution_failed", @errorName(err));
            return;
        };
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        cumulative_metrics.add(result.metrics);

        if (task.completion_promise != null) {
            if (result.output_contains_promise) {
                std.log.info("Completion promise found at iteration {d}", .{iteration + 1});
                const final_result = claude_wrapper.RunResult{
                    .exit_code = result.exit_code,
                    .pr_url = result.pr_url,
                    .metrics = cumulative_metrics,
                    .output_contains_promise = true,
                    .stdout = result.stdout,
                    .stderr = result.stderr,
                };
                try client.sendComplete(final_result, iteration + 1);
                return;
            }
            std.log.info("Iteration {d}/{d} - no completion promise found, continuing", .{ iteration + 1, max_iterations });
        } else {
            std.log.info("Single iteration mode, task complete", .{});
            try client.sendComplete(result, iteration + 1);
            return;
        }
    }

    std.log.warn("Max iterations ({d}) reached without completion promise", .{max_iterations});
    try client.sendError("max_iterations", "Reached iteration limit without completion");
}

fn waitForNetwork(allocator: std.mem.Allocator) void {
    // Wait up to 30s for network connectivity (DNS resolution)
    var attempt: u32 = 0;
    while (attempt < 15) : (attempt += 1) {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "ping", "-c", "1", "-W", "1", "8.8.8.8" },
        }) catch {
            common.compat.sleep(2 * std.time.ns_per_s);
            continue;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term.Exited == 0) {
            std.log.info("Network ready after {d} attempts", .{attempt + 1});
            return;
        }
        common.compat.sleep(2 * std.time.ns_per_s);
    }
    std.log.warn("Network not available after 30s, continuing anyway", .{});
}

fn extractRepoName(repo_url: []const u8) []const u8 {
    const github_https = "https://github.com/";
    const github_ssh = "git@github.com:";

    var spec = repo_url;
    if (std.mem.startsWith(u8, repo_url, github_https)) {
        spec = repo_url[github_https.len..];
    } else if (std.mem.startsWith(u8, repo_url, github_ssh)) {
        spec = repo_url[github_ssh.len..];
    }

    if (std.mem.endsWith(u8, spec, ".git")) {
        spec = spec[0 .. spec.len - 4];
    }

    return spec;
}

fn outputCallback(output_type: types.OutputType, data: []const u8, ctx: *anyopaque) void {
    const client: *vsock_client.VsockClient = @ptrCast(@alignCast(ctx));
    client.sendOutput(output_type, data) catch |err| {
        std.log.warn("Failed to send output: {s}", .{@errorName(err)});
    };
}

test "extractRepoName handles https URL" {
    const result = extractRepoName("https://github.com/owner/repo");
    try std.testing.expectEqualStrings("owner/repo", result);
}

test "extractRepoName handles https URL with .git" {
    const result = extractRepoName("https://github.com/owner/repo.git");
    try std.testing.expectEqualStrings("owner/repo", result);
}

test "extractRepoName handles ssh URL" {
    const result = extractRepoName("git@github.com:owner/repo.git");
    try std.testing.expectEqualStrings("owner/repo", result);
}

test "extractRepoName handles short form" {
    const result = extractRepoName("owner/repo");
    try std.testing.expectEqualStrings("owner/repo", result);
}

test "vm agent" {
    _ = common.compat;
    _ = vsock_client;
    _ = claude_wrapper;
    _ = api_interceptor;
    _ = repo_setup;
    _ = prompt_wrapper;
    _ = cleanup;
}
