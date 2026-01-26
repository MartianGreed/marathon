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
        try self.setupWorkspace(task);

        const env_map = try self.buildEnvMap(task);
        defer {
            var it = env_map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
        }

        var argv = std.ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();

        try argv.append(self.claude_code_path);
        try argv.append("--print");
        try argv.append("--dangerously-skip-permissions");

        if (task.create_pr) {
            const full_prompt = try std.fmt.allocPrint(
                self.allocator,
                "{s}\n\nAfter completing the task, create a pull request with title: {s}",
                .{ task.prompt, task.pr_title orelse "Automated changes" },
            );
            defer self.allocator.free(full_prompt);
            try argv.append(full_prompt);
        } else {
            try argv.append(task.prompt);
        }

        var child = std.process.Child.init(argv.items, self.allocator);
        child.cwd = self.work_dir;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        var env_array = std.ArrayList(?[*:0]const u8).init(self.allocator);
        defer env_array.deinit();

        var env_it = env_map.iterator();
        while (env_it.next()) |entry| {
            const env_str = try std.fmt.allocPrintZ(
                self.allocator,
                "{s}={s}",
                .{ entry.key_ptr.*, entry.value_ptr.* },
            );
            try env_array.append(env_str.ptr);
        }
        try env_array.append(null);

        try child.spawn();
        self.process = child;

        var total_stdout = std.ArrayList(u8).init(self.allocator);
        defer total_stdout.deinit();

        var total_stderr = std.ArrayList(u8).init(self.allocator);
        defer total_stderr.deinit();

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
            .exited => |code| @intCast(code),
            .signal => |sig| -@as(i32, @intCast(sig)),
            else => -1,
        };

        const pr_url = self.extractPrUrl(total_stdout.items);

        return .{
            .exit_code = exit_code,
            .pr_url = pr_url,
            .metrics = self.interceptor.getMetrics(),
        };
    }

    fn readOutput(
        self: *ClaudeWrapper,
        reader: std.fs.File,
        output_type: types.OutputType,
        buffer: *std.ArrayList(u8),
    ) void {
        var buf: [4096]u8 = undefined;

        while (true) {
            const n = reader.read(&buf) catch break;
            if (n == 0) break;

            buffer.appendSlice(buf[0..n]) catch {};

            if (self.output_callback) |cb| {
                if (self.output_context) |ctx| {
                    cb(output_type, buf[0..n], ctx);
                }
            }
        }
    }

    fn setupWorkspace(self: *ClaudeWrapper, task: TaskInfo) !void {
        std.fs.makeDirAbsolute(self.work_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const git_args = [_][]const u8{
            "git",
            "clone",
            "--depth",
            "1",
            "--branch",
            task.branch,
            task.repo_url,
            self.work_dir,
        };

        var clone = std.process.Child.init(&git_args, self.allocator);
        clone.cwd = "/tmp";
        try clone.spawn();
        const term = try clone.wait();

        if (term != .exited or term.exited != 0) {
            return error.GitCloneFailed;
        }

        try self.configureGit(task);
    }

    fn configureGit(self: *ClaudeWrapper, task: TaskInfo) !void {
        _ = task;

        const config_args = [_][]const u8{
            "git",
            "config",
            "user.email",
            "marathon@local",
        };

        var config = std.process.Child.init(&config_args, self.allocator);
        config.cwd = self.work_dir;
        try config.spawn();
        _ = try config.wait();

        const config_name_args = [_][]const u8{
            "git",
            "config",
            "user.name",
            "Marathon Agent",
        };

        var config_name = std.process.Child.init(&config_name_args, self.allocator);
        config_name.cwd = self.work_dir;
        try config_name.spawn();
        _ = try config_name.wait();
    }

    fn buildEnvMap(self: *ClaudeWrapper, task: TaskInfo) !std.StringHashMap([]const u8) {
        var env = std.StringHashMap([]const u8).init(self.allocator);

        try env.put(
            try self.allocator.dupe(u8, "ANTHROPIC_API_KEY"),
            try self.allocator.dupe(u8, task.anthropic_api_key),
        );
        try env.put(
            try self.allocator.dupe(u8, "GITHUB_TOKEN"),
            try self.allocator.dupe(u8, task.github_token),
        );
        try env.put(
            try self.allocator.dupe(u8, "HOME"),
            try self.allocator.dupe(u8, "/root"),
        );
        try env.put(
            try self.allocator.dupe(u8, "PATH"),
            try self.allocator.dupe(u8, "/usr/local/bin:/usr/bin:/bin"),
        );

        return env;
    }

    fn extractPrUrl(self: *ClaudeWrapper, output: []const u8) ?[]const u8 {
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
};

pub const RunResult = struct {
    exit_code: i32,
    pr_url: ?[]const u8,
    metrics: types.UsageMetrics,
};

test "claude wrapper init" {
    const allocator = std.testing.allocator;
    var interceptor = api_interceptor.ApiInterceptor.init(allocator);
    defer interceptor.deinit();

    var wrapper = ClaudeWrapper.init(allocator, "/usr/local/bin/claude", "/workspace", &interceptor);
    defer wrapper.deinit();
}
