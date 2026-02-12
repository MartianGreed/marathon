const std = @import("std");
const common = @import("common");
const types = common.types;

const vsock_client = @import("vsock_client.zig");
const claude_wrapper = @import("claude_wrapper.zig");
const api_interceptor = @import("api_interceptor.zig");
const repo_setup = @import("repo_setup.zig");
const prompt_wrapper = @import("prompt_wrapper.zig");
const cleanup = @import("cleanup.zig");
const signal_parser = @import("signal_parser.zig");
const memory = @import("memory.zig");

const DEFAULT_MAX_ITERATIONS: u32 = 50;

pub fn main() !void {
    // Redirect stderr to log file for persistent logging
    if (std.fs.createFileAbsolute("/var/log/marathon-agent-debug.log", .{ .truncate = true })) |log_file| {
        const log_fd = log_file.handle;
        std.posix.dup2(log_fd, 2) catch {};
        std.posix.close(log_fd);
    } else |_| {}

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try common.config.VmAgentConfig.fromEnv(allocator);

    std.log.info("Marathon VM Agent starting (ralph loop mode)...", .{});
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

    // Wait for network to be ready
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
    std.log.info("Received task, starting ralph loop execution", .{});

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
    const base_prompt = try prompt_wrap.wrap(allocator, task.prompt, repo_name, task.branch);
    defer allocator.free(base_prompt);

    wrapper.setOutputCallback(outputCallback, @ptrCast(&client));

    // Initialize memory manager for cross-iteration persistence
    var mem_mgr = memory.MemoryManager.init(allocator, config.work_dir);

    const max_iterations = task.max_iterations orelse DEFAULT_MAX_ITERATIONS;
    var iteration: u32 = 0;
    var cumulative_metrics = types.UsageMetrics{};
    var last_output: []const u8 = "";
    var last_output_owned = false;

    defer {
        if (last_output_owned) allocator.free(@constCast(last_output));
        cleaner.execute(config.work_dir);
        std.log.info("Cleanup complete", .{});
    }

    // === RALPH LOOP ===
    while (iteration < max_iterations) : (iteration += 1) {
        if (try client.checkCancel()) {
            std.log.info("Task cancelled by user", .{});
            try client.sendError("cancelled", "Task cancelled by user");
            return;
        }

        std.log.info("Ralph loop iteration {d}/{d}", .{ iteration + 1, max_iterations });
        try client.sendProgress(iteration + 1, max_iterations, "running");

        // Build prompt: first iteration uses base prompt, subsequent iterations get memory context
        var current_prompt: []const u8 = undefined;
        var prompt_owned = false;

        if (iteration == 0) {
            current_prompt = base_prompt;
        } else {
            const context_prefix = try mem_mgr.buildContextPrefix(iteration + 1, last_output);
            defer allocator.free(context_prefix);

            current_prompt = try std.fmt.allocPrint(allocator, "{s}{s}", .{ context_prefix, base_prompt });
            prompt_owned = true;
        }
        defer if (prompt_owned) allocator.free(@constCast(current_prompt));

        var modified_task = task;
        modified_task.prompt = current_prompt;

        const result = wrapper.run(modified_task) catch |err| {
            std.log.err("Execution failed at iteration {d}: {s}", .{ iteration + 1, @errorName(err) });
            try client.sendError("execution_failed", @errorName(err));
            return;
        };
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        cumulative_metrics.add(result.metrics);

        // Log iteration to .marathon/iterations.log for traceability
        mem_mgr.logIteration(iteration + 1, result.exit_code, result.stdout);

        // Update last_output for next iteration's context
        if (last_output_owned) allocator.free(@constCast(last_output));
        last_output = try allocator.dupe(u8, result.stdout);
        last_output_owned = true;

        // Parse signals from output (ralph-loop style)
        const signals = signal_parser.parseSignals(result.stdout, task.completion_promise);

        // Check for PR creation — this is the primary "productive output"
        if (signals.pr_created) {
            std.log.info("PR created at iteration {d}: {s}", .{ iteration + 1, signals.pr_url orelse "unknown" });
            const final_result = claude_wrapper.RunResult{
                .exit_code = result.exit_code,
                .pr_url = signals.pr_url,
                .metrics = cumulative_metrics,
                .output_contains_promise = true,
                .stdout = result.stdout,
                .stderr = result.stderr,
            };
            try client.sendComplete(final_result, iteration + 1);
            return;
        }

        // Check completion promise
        if (signals.has_completion_promise) {
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

        // Check clarification request — pause and report
        if (signals.needs_clarification) {
            std.log.info("Clarification requested at iteration {d}: {s}", .{
                iteration + 1,
                signals.clarification_question orelse "no question",
            });
            const err_msg = try std.fmt.allocPrint(allocator, "Clarification needed: {s}", .{
                signals.clarification_question orelse "Agent needs more information",
            });
            defer allocator.free(err_msg);
            try client.sendError("needs_clarification", err_msg);
            return;
        }

        // No completion signal — single iteration mode (no completion_promise set)
        if (task.completion_promise == null and max_iterations == 1) {
            std.log.info("Single iteration mode, task complete", .{});
            try client.sendComplete(result, iteration + 1);
            return;
        }

        // Default ralph loop: if no completion_promise is set, use PR detection + exit code
        if (task.completion_promise == null) {
            if (result.exit_code == 0) {
                // Check if there's a PR URL in the output even without explicit promise
                if (result.pr_url) |pr_url| {
                    std.log.info("Task completed with PR at iteration {d}: {s}", .{ iteration + 1, pr_url });
                    const final_result = claude_wrapper.RunResult{
                        .exit_code = result.exit_code,
                        .pr_url = result.pr_url,
                        .metrics = cumulative_metrics,
                        .output_contains_promise = false,
                        .stdout = result.stdout,
                        .stderr = result.stderr,
                    };
                    try client.sendComplete(final_result, iteration + 1);
                    return;
                }
                // Exit 0 without PR — agent thinks it's done
                std.log.info("Agent exited cleanly at iteration {d}, completing", .{iteration + 1});
                try client.sendComplete(result, iteration + 1);
                return;
            }
            // Non-zero exit — agent crashed or errored, continue loop
            std.log.warn("Agent exited with code {d} at iteration {d}, retrying", .{ result.exit_code, iteration + 1 });
        }

        std.log.info("Iteration {d}/{d} complete, continuing ralph loop", .{ iteration + 1, max_iterations });
    }

    std.log.warn("Max iterations ({d}) reached without completion", .{max_iterations});
    try client.sendError("max_iterations", "Reached iteration limit without completion");
}

fn waitForNetwork(allocator: std.mem.Allocator) void {
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
    _ = signal_parser;
    _ = memory;
}
