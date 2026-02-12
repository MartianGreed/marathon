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
        // Clean workspace to ensure fresh clone (rootfs may be reused)
        std.fs.deleteTreeAbsolute(self.work_dir) catch {};
        std.fs.makeDirAbsolute(self.work_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Chown workspace to marathon user (uid 1000) so Claude Code can write to it
        if (std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "chown", "-R", "1000:1000", self.work_dir },
        })) |r| {
            self.allocator.free(r.stdout);
            self.allocator.free(r.stderr);
        } else |_| {}

        // Build authenticated git URL: https://x-access-token:TOKEN@github.com/owner/repo
        const repo_spec = try self.extractRepoSpec(repo_url);
        const auth_url = try std.fmt.allocPrint(self.allocator, "https://x-access-token:{s}@github.com/{s}", .{ self.github_token, repo_spec });
        defer self.allocator.free(auth_url);

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "git", "clone", "--branch", branch, "--depth", "1", auth_url, self.work_dir },
            .cwd = null,
        }) catch |err| {
            std.log.err("git clone spawn failed: {s}", .{@errorName(err)});
            return error.GitCloneFailed;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        const success = switch (result.term) {
            .Exited => |code| code == 0,
            else => false,
        };

        if (!success) {
            std.log.err("git clone failed for {s}: {s}", .{ repo_spec, result.stderr });
            return error.GitCloneFailed;
        }

        // Chown cloned files to marathon user so Claude Code can modify them
        if (std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "chown", "-R", "1000:1000", self.work_dir },
        })) |r| {
            self.allocator.free(r.stdout);
            self.allocator.free(r.stderr);
        } else |_| {}

        std.log.info("Cloned {s} to {s}", .{ repo_spec, self.work_dir });
    }

    pub fn configureDefaults(self: *RepoSetup) !void {
        // Mark workspace as safe for root (vm_agent runs as root)
        self.runGitConfigGlobal("safe.directory", self.work_dir) catch {};

        // Mark workspace as safe for marathon user (uid 1000) who runs Claude Code.
        // Without this, git refuses to operate in a directory owned by a different user.
        self.runGitConfigForUser("safe.directory", self.work_dir) catch {};

        try self.runGitConfig("user.name", "Marathon Agent");
        try self.runGitConfig("user.email", "marathon@local");
        try self.runGitConfig("credential.helper", "store --file=/tmp/.git-credentials");

        try self.writeCredentials();
    }

    /// Run git config --global as the marathon user (uid 1000) so that Claude Code
    /// inherits the setting. Writes to /home/marathon/.gitconfig.
    fn runGitConfigForUser(self: *RepoSetup, key: []const u8, value: []const u8) !void {
        const cmd = std.fmt.allocPrint(self.allocator, "git config --global --add {s} {s}", .{ key, value }) catch return error.GitConfigFailed;
        defer self.allocator.free(cmd);
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "su", "-s", "/bin/sh", "marathon", "-c", cmd },
        }) catch return error.GitConfigFailed;
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);

        const success = switch (result.term) {
            .Exited => |code| code == 0,
            else => false,
        };
        if (!success) {
            std.log.warn("git config --global (as marathon) {s} failed", .{key});
            return error.GitConfigFailed;
        }
    }

    fn runGitConfigGlobal(self: *RepoSetup, key: []const u8, value: []const u8) !void {
        const args = [_][]const u8{ "git", "config", "--global", "--add", key, value };
        var proc = std.process.Child.init(&args, self.allocator);
        try proc.spawn();
        const term = try proc.wait();
        const success = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
        if (!success) {
            std.log.warn("git config --global {s} failed", .{key});
            return error.GitConfigFailed;
        }
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

        // Chown credentials file to marathon user (uid 1000) so Claude Code can read it.
        // Without this, credential.helper fails because the file is root-owned with mode 0600.
        const chown = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "chown", "1000:1000", creds_path },
        }) catch return;
        self.allocator.free(chown.stdout);
        self.allocator.free(chown.stderr);
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
