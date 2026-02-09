const std = @import("std");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;
const api_interceptor = @import("api_interceptor.zig");

pub const ClaudeWrapper = struct {
    allocator: std.mem.Allocator,
    claude_code_path: []const u8,
    work_dir: []const u8,
    interceptor: *api_interceptor.ApiInterceptor,
    process: ?std.process.Child,

    output_callback: ?OutputCallback,
    output_context: ?*anyopaque,
    metrics_callback: ?MetricsCallback,
    metrics_context: ?*anyopaque,

    pub const OutputCallback = *const fn (types.OutputType, []const u8, *anyopaque) void;
    pub const MetricsCallback = *const fn (types.UsageMetrics, *anyopaque) void;

    pub fn init(
        allocator: std.mem.Allocator,
        claude_code_path: []const u8,
        work_dir: []const u8,
        interceptor: *api_interceptor.ApiInterceptor,
    ) ClaudeWrapper {
        return .{
            .allocator = allocator,
            .claude_code_path = claude_code_path,
            .work_dir = work_dir,
            .interceptor = interceptor,
            .process = null,
            .output_callback = null,
            .output_context = null,
            .metrics_callback = null,
            .metrics_context = null,
        };
    }

    pub fn deinit(self: *ClaudeWrapper) void {
        self.stop() catch {};
    }

    pub fn setOutputCallback(self: *ClaudeWrapper, callback: OutputCallback, context: *anyopaque) void {
        self.output_callback = callback;
        self.output_context = context;
    }

    pub fn setMetricsCallback(self: *ClaudeWrapper, callback: MetricsCallback, context: *anyopaque) void {
        self.metrics_callback = callback;
        self.metrics_context = context;
    }

    pub fn run(self: *ClaudeWrapper, task: TaskInfo) !RunResult {
        var env_map = try self.buildEnvMap(task);
        defer env_map.deinit();

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, self.claude_code_path);
        try argv.append(self.allocator, "--print");
        try argv.append(self.allocator, "--dangerously-skip-permissions");
        try argv.append(self.allocator, "--output-format");
        try argv.append(self.allocator, "json");
        try argv.append(self.allocator, task.prompt);

        var child = std.process.Child.init(argv.items, self.allocator);
        child.cwd = self.work_dir;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.env_map = &env_map;

        try child.spawn();
        self.process = child;

        var total_stdout: std.ArrayListUnmanaged(u8) = .empty;
        errdefer total_stdout.deinit(self.allocator);

        var total_stderr: std.ArrayListUnmanaged(u8) = .empty;
        errdefer total_stderr.deinit(self.allocator);

        const stdout_thread = try std.Thread.spawn(.{}, readOutput, .{
            self,
            child.stdout.?,
            types.OutputType.stdout,
            &total_stdout,
        });

        const stderr_thread = try std.Thread.spawn(.{}, readOutput, .{
            self,
            child.stderr.?,
            types.OutputType.stderr,
            &total_stderr,
        });

        stdout_thread.join();
        stderr_thread.join();

        const term = try child.wait();
        self.process = null;

        const exit_code: i32 = switch (term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| -@as(i32, @intCast(sig)),
            else => -1,
        };

        const pr_url = self.extractPrUrl(total_stdout.items);
        const metrics = self.parseJsonMetrics(total_stdout.items);
        const promise_found = self.checkCompletionPromise(total_stdout.items, task.completion_promise);

        const stdout_copy = try self.allocator.dupe(u8, total_stdout.items);
        errdefer self.allocator.free(stdout_copy);
        const stderr_copy = try self.allocator.dupe(u8, total_stderr.items);

        return .{
            .exit_code = exit_code,
            .pr_url = pr_url,
            .metrics = metrics,
            .output_contains_promise = promise_found,
            .stdout = stdout_copy,
            .stderr = stderr_copy,
        };
    }

    pub fn parseJsonMetrics(self: *ClaudeWrapper, output: []const u8) types.UsageMetrics {
        _ = self;
        var metrics = types.UsageMetrics{};

        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, output, .{}) catch return metrics;
        defer parsed.deinit();

        if (parsed.value.object.get("usage")) |usage| {
            if (usage.object.get("input_tokens")) |v| {
                metrics.input_tokens = v.integer;
            }
            if (usage.object.get("output_tokens")) |v| {
                metrics.output_tokens = v.integer;
            }
            if (usage.object.get("cache_creation_input_tokens")) |v| {
                metrics.cache_write_tokens = v.integer;
            }
            if (usage.object.get("cache_read_input_tokens")) |v| {
                metrics.cache_read_tokens = v.integer;
            }
        }

        return metrics;
    }

    pub fn checkCompletionPromise(self: *ClaudeWrapper, output: []const u8, promise: ?[]const u8) bool {
        _ = self;
        const completion_marker = promise orelse return false;
        return std.mem.indexOf(u8, output, completion_marker) != null;
    }

    fn readOutput(
        self: *ClaudeWrapper,
        reader: std.fs.File,
        output_type: types.OutputType,
        buffer: *std.ArrayListUnmanaged(u8),
    ) void {
        var buf: [4096]u8 = undefined;

        while (true) {
            const n = reader.read(&buf) catch break;
            if (n == 0) break;

            buffer.appendSlice(self.allocator, buf[0..n]) catch {};

            if (self.output_callback) |cb| {
                if (self.output_context) |ctx| {
                    cb(output_type, buf[0..n], ctx);
                }
            }
        }
    }

    pub fn buildEnvMap(self: *ClaudeWrapper, task: TaskInfo) !std.process.EnvMap {
        var env = std.process.EnvMap.init(self.allocator);

        // Essential environment variables for Claude Code to run properly
        try env.put("HOME", "/root");
        try env.put("PATH", "/usr/local/bin:/usr/bin:/bin:/root/.local/bin");
        try env.put("TERM", "xterm-256color");
        try env.put("USER", "root");
        try env.put("SHELL", "/bin/bash");

        // Task-specific variables
        try env.put("ANTHROPIC_API_KEY", task.anthropic_api_key);
        try env.put("GITHUB_TOKEN", task.github_token);

        return env;
    }

    pub fn extractPrUrl(self: *ClaudeWrapper, output: []const u8) ?[]const u8 {
        _ = self;

        const pr_pattern = "https://github.com/";
        var i: usize = 0;

        while (i < output.len) {
            if (std.mem.startsWith(u8, output[i..], pr_pattern)) {
                const start = i;
                while (i < output.len and output[i] != '\n' and output[i] != ' ' and output[i] != '\t') {
                    i += 1;
                }
                const url = output[start..i];
                if (std.mem.indexOf(u8, url, "/pull/") != null) {
                    return url;
                }
            }
            i += 1;
        }

        return null;
    }

    pub fn stop(self: *ClaudeWrapper) !void {
        if (self.process) |*proc| {
            _ = proc.kill() catch {};
            _ = proc.wait() catch {};
            self.process = null;
        }
    }
};

pub const TaskInfo = struct {
    task_id: types.TaskId,
    repo_url: []const u8,
    branch: []const u8,
    prompt: []const u8,
    github_token: []const u8,
    anthropic_api_key: []const u8,
    create_pr: bool,
    pr_title: ?[]const u8,
    pr_body: ?[]const u8,
    max_iterations: ?u32,
    completion_promise: ?[]const u8,
};

pub const RunResult = struct {
    exit_code: i32,
    pr_url: ?[]const u8,
    metrics: types.UsageMetrics,
    output_contains_promise: bool,
    stdout: []const u8,
    stderr: []const u8,
};

test "claude wrapper init" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();
}

test "parseJsonMetrics extracts all token fields" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();

    const output =
        \\{"usage": {"input_tokens": 100, "output_tokens": 50, "cache_read_input_tokens": 10, "cache_creation_input_tokens": 5}}
    ;

    const metrics = wrapper.parseJsonMetrics(output);
    try std.testing.expectEqual(@as(i64, 100), metrics.input_tokens);
    try std.testing.expectEqual(@as(i64, 50), metrics.output_tokens);
    try std.testing.expectEqual(@as(i64, 10), metrics.cache_read_tokens);
    try std.testing.expectEqual(@as(i64, 5), metrics.cache_write_tokens);
}

test "parseJsonMetrics handles missing usage" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();

    const output =
        \\{"result": "success", "model": "claude-3"}
    ;

    const metrics = wrapper.parseJsonMetrics(output);
    try std.testing.expectEqual(@as(i64, 0), metrics.input_tokens);
    try std.testing.expectEqual(@as(i64, 0), metrics.output_tokens);
    try std.testing.expectEqual(@as(i64, 0), metrics.cache_read_tokens);
    try std.testing.expectEqual(@as(i64, 0), metrics.cache_write_tokens);
}

test "parseJsonMetrics handles invalid JSON" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();

    const metrics = wrapper.parseJsonMetrics("not valid json {{{");
    try std.testing.expectEqual(@as(i64, 0), metrics.input_tokens);
    try std.testing.expectEqual(@as(i64, 0), metrics.output_tokens);
}

test "parseJsonMetrics handles partial usage fields" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();

    const output =
        \\{"usage": {"input_tokens": 100}}
    ;

    const metrics = wrapper.parseJsonMetrics(output);
    try std.testing.expectEqual(@as(i64, 100), metrics.input_tokens);
    try std.testing.expectEqual(@as(i64, 0), metrics.output_tokens);
    try std.testing.expectEqual(@as(i64, 0), metrics.cache_read_tokens);
}

test "checkCompletionPromise returns true when found" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();

    const output = "Task completed successfully. TASK_COMPLETE: All done!";
    const found = wrapper.checkCompletionPromise(output, "TASK_COMPLETE");
    try std.testing.expect(found);
}

test "checkCompletionPromise returns false when missing" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();

    const output = "Task is still running, not complete yet.";
    const found = wrapper.checkCompletionPromise(output, "TASK_COMPLETE");
    try std.testing.expect(!found);
}

test "checkCompletionPromise returns false when null promise" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();

    const output = "TASK_COMPLETE: All done!";
    const found = wrapper.checkCompletionPromise(output, null);
    try std.testing.expect(!found);
}

test "checkCompletionPromise finds promise at start" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();

    const output = "DONE: Task finished";
    const found = wrapper.checkCompletionPromise(output, "DONE:");
    try std.testing.expect(found);
}

test "extractPrUrl finds github PR URL" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();

    const output = "Created PR: https://github.com/owner/repo/pull/123\nDone.";
    const url = wrapper.extractPrUrl(output);

    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://github.com/owner/repo/pull/123", url.?);
}

test "extractPrUrl returns null for non-PR github URLs" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();

    const output = "See issue: https://github.com/owner/repo/issues/456";
    const url = wrapper.extractPrUrl(output);

    try std.testing.expect(url == null);
}

test "extractPrUrl returns null when no URL" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();

    const output = "No URLs in this output at all.";
    const url = wrapper.extractPrUrl(output);

    try std.testing.expect(url == null);
}

test "extractPrUrl handles URL at end of output" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();

    const output = "Done! https://github.com/foo/bar/pull/42";
    const url = wrapper.extractPrUrl(output);

    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://github.com/foo/bar/pull/42", url.?);
}

test "extractPrUrl ignores gitlab URLs" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();

    const output = "Check: https://gitlab.com/owner/repo/pull/789";
    const url = wrapper.extractPrUrl(output);

    try std.testing.expect(url == null);
}

test "buildEnvMap includes required env vars" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();

    const task = TaskInfo{
        .task_id = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .repo_url = "https://github.com/test/repo",
        .branch = "main",
        .prompt = "Fix the bug",
        .github_token = "ghp_testtoken123",
        .anthropic_api_key = "sk-ant-api03-test",
        .create_pr = false,
        .pr_title = null,
        .pr_body = null,
        .max_iterations = null,
        .completion_promise = null,
    };

    var env = try wrapper.buildEnvMap(task);
    defer env.deinit();

    try std.testing.expectEqualStrings("sk-ant-api03-test", env.get("ANTHROPIC_API_KEY").?);
    try std.testing.expectEqualStrings("ghp_testtoken123", env.get("GITHUB_TOKEN").?);
    try std.testing.expectEqualStrings("/root", env.get("HOME").?);
    try std.testing.expect(env.get("PATH") != null);
}
