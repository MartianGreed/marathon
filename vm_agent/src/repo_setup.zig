const std = @import("std");

pub const RepoSetup = struct {
    allocator: std.mem.Allocator,
    work_dir: []const u8,
    github_token: []const u8,

    pub fn init(allocator: std.mem.Allocator, work_dir: []const u8, github_token: []const u8) RepoSetup {
        return .{
            .allocator = allocator,
            .work_dir = work_dir,
            .github_token = github_token,
        };
    }

    pub fn clone(self: *RepoSetup, repo_url: []const u8, branch: []const u8) !void {
        std.fs.makeDirAbsolute(self.work_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const repo_spec = try self.extractRepoSpec(repo_url);

        var env_map = std.process.EnvMap.init(self.allocator);
        defer env_map.deinit();
        try env_map.put("GH_TOKEN", self.github_token);
        try env_map.put("PATH", "/usr/local/bin:/usr/bin:/bin");
        try env_map.put("HOME", "/root");

        const gh_args = [_][]const u8{
            "gh",
            "repo",
            "clone",
            repo_spec,
            self.work_dir,
            "--",
            "--branch",
            branch,
            "--depth",
            "1",
        };

        var clone_proc = std.process.Child.init(&gh_args, self.allocator);
        clone_proc.cwd = "/tmp";
        clone_proc.env_map = &env_map;
        clone_proc.stderr_behavior = .Pipe;
        clone_proc.stdout_behavior = .Pipe;

        try clone_proc.spawn();
        const term = try clone_proc.wait();

        const success = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };

        if (!success) {
            std.log.err("gh repo clone failed for {s}", .{repo_spec});
            return error.GitCloneFailed;
        }

        std.log.info("Cloned {s} to {s}", .{ repo_spec, self.work_dir });
    }

    pub fn configureDefaults(self: *RepoSetup) !void {
        try self.runGitConfig("user.name", "Marathon Agent");
        try self.runGitConfig("user.email", "marathon@local");
        try self.runGitConfig("credential.helper", "store --file=/tmp/.git-credentials");

        try self.writeCredentials();
    }

    fn runGitConfig(self: *RepoSetup, key: []const u8, value: []const u8) !void {
        const args = [_][]const u8{ "git", "config", key, value };
        var proc = std.process.Child.init(&args, self.allocator);
        proc.cwd = self.work_dir;
        try proc.spawn();
        const term = try proc.wait();

        const success = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };

        if (!success) {
            std.log.err("git config {s} failed", .{key});
            return error.GitConfigFailed;
        }
    }

    fn writeCredentials(self: *RepoSetup) !void {
        const creds_path = "/tmp/.git-credentials";
        const file = try std.fs.createFileAbsolute(creds_path, .{ .mode = 0o600 });
        defer file.close();

        const creds = try std.fmt.allocPrint(
            self.allocator,
            "https://x-access-token:{s}@github.com\n",
            .{self.github_token},
        );
        defer self.allocator.free(creds);

        try file.writeAll(creds);
    }

    fn extractRepoSpec(self: *RepoSetup, repo_url: []const u8) ![]const u8 {
        const github_https = "https://github.com/";
        const github_ssh = "git@github.com:";

        if (std.mem.startsWith(u8, repo_url, github_https)) {
            var spec = repo_url[github_https.len..];
            if (std.mem.endsWith(u8, spec, ".git")) {
                spec = spec[0 .. spec.len - 4];
            }
            return spec;
        }

        if (std.mem.startsWith(u8, repo_url, github_ssh)) {
            var spec = repo_url[github_ssh.len..];
            if (std.mem.endsWith(u8, spec, ".git")) {
                spec = spec[0 .. spec.len - 4];
            }
            return spec;
        }

        if (std.mem.indexOf(u8, repo_url, "/") != null and
            std.mem.indexOf(u8, repo_url, "://") == null)
        {
            return repo_url;
        }

        _ = self;
        std.log.err("Unsupported repo URL format: {s}", .{repo_url});
        return error.UnsupportedRepoUrl;
    }
};

test "extractRepoSpec handles https URL" {
    const allocator = std.testing.allocator;
    var setup = RepoSetup.init(allocator, "/workspace", "token");

    const spec = try setup.extractRepoSpec("https://github.com/owner/repo");
    try std.testing.expectEqualStrings("owner/repo", spec);
}

test "extractRepoSpec handles https URL with .git" {
    const allocator = std.testing.allocator;
    var setup = RepoSetup.init(allocator, "/workspace", "token");

    const spec = try setup.extractRepoSpec("https://github.com/owner/repo.git");
    try std.testing.expectEqualStrings("owner/repo", spec);
}

test "extractRepoSpec handles ssh URL" {
    const allocator = std.testing.allocator;
    var setup = RepoSetup.init(allocator, "/workspace", "token");

    const spec = try setup.extractRepoSpec("git@github.com:owner/repo.git");
    try std.testing.expectEqualStrings("owner/repo", spec);
}

test "extractRepoSpec handles short form" {
    const allocator = std.testing.allocator;
    var setup = RepoSetup.init(allocator, "/workspace", "token");

    const spec = try setup.extractRepoSpec("owner/repo");
    try std.testing.expectEqualStrings("owner/repo", spec);
}
