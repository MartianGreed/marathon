const std = @import("std");

pub const CleanupStrategy = enum(u8) {
    full = 0,
    keep_cache = 1,
    keep_workspace = 2,
    none = 3,

    pub fn fromEnv() CleanupStrategy {
        const val = std.posix.getenv("MARATHON_CLEANUP_STRATEGY") orelse "full";
        return fromString(val);
    }

    pub fn fromString(s: []const u8) CleanupStrategy {
        if (std.mem.eql(u8, s, "full")) return .full;
        if (std.mem.eql(u8, s, "keep_cache")) return .keep_cache;
        if (std.mem.eql(u8, s, "keep_workspace")) return .keep_workspace;
        if (std.mem.eql(u8, s, "none")) return .none;
        return .full;
    }

    pub fn toString(self: CleanupStrategy) []const u8 {
        return switch (self) {
            .full => "full",
            .keep_cache => "keep_cache",
            .keep_workspace => "keep_workspace",
            .none => "none",
        };
    }
};

pub const Cleanup = struct {
    strategy: CleanupStrategy,

    pub fn init() Cleanup {
        return .{
            .strategy = CleanupStrategy.fromEnv(),
        };
    }

    pub fn initWithStrategy(strategy: CleanupStrategy) Cleanup {
        return .{
            .strategy = strategy,
        };
    }

    pub fn execute(self: *Cleanup, work_dir: []const u8) void {
        std.log.info("Executing cleanup with strategy: {s}", .{self.strategy.toString()});

        switch (self.strategy) {
            .full => {
                deleteTree(work_dir);
                deleteTree("/root/.claude");
                deleteFile("/tmp/.git-credentials");
            },
            .keep_cache => {
                deleteTree(work_dir);
                deleteFile("/tmp/.git-credentials");
            },
            .keep_workspace => {
                deleteFile("/tmp/.git-credentials");
                clearGitCredentialConfig(work_dir);
            },
            .none => {},
        }
    }
};

fn deleteTree(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch |err| {
        if (err != error.FileNotFound) {
            std.log.warn("Failed to delete {s}: {s}", .{ path, @errorName(err) });
        }
    };
}

fn deleteFile(path: []const u8) void {
    std.fs.deleteFileAbsolute(path) catch |err| {
        if (err != error.FileNotFound) {
            std.log.warn("Failed to delete {s}: {s}", .{ path, @errorName(err) });
        }
    };
}

fn clearGitCredentialConfig(work_dir: []const u8) void {
    const args = [_][]const u8{ "git", "config", "--unset", "credential.helper" };
    var proc = std.process.Child.init(&args, std.heap.page_allocator);
    proc.cwd = work_dir;
    proc.spawn() catch return;
    _ = proc.wait() catch {};
}

test "CleanupStrategy fromString parses valid values" {
    try std.testing.expectEqual(CleanupStrategy.full, CleanupStrategy.fromString("full"));
    try std.testing.expectEqual(CleanupStrategy.keep_cache, CleanupStrategy.fromString("keep_cache"));
    try std.testing.expectEqual(CleanupStrategy.keep_workspace, CleanupStrategy.fromString("keep_workspace"));
    try std.testing.expectEqual(CleanupStrategy.none, CleanupStrategy.fromString("none"));
}

test "CleanupStrategy fromString defaults to full for invalid" {
    try std.testing.expectEqual(CleanupStrategy.full, CleanupStrategy.fromString("invalid"));
    try std.testing.expectEqual(CleanupStrategy.full, CleanupStrategy.fromString(""));
}

test "CleanupStrategy toString returns correct strings" {
    try std.testing.expectEqualStrings("full", CleanupStrategy.full.toString());
    try std.testing.expectEqualStrings("keep_cache", CleanupStrategy.keep_cache.toString());
    try std.testing.expectEqualStrings("keep_workspace", CleanupStrategy.keep_workspace.toString());
    try std.testing.expectEqualStrings("none", CleanupStrategy.none.toString());
}

test "Cleanup init creates with strategy from env default" {
    const cleanup = Cleanup.init();
    try std.testing.expectEqual(CleanupStrategy.full, cleanup.strategy);
}

test "Cleanup initWithStrategy creates with specified strategy" {
    const cleanup = Cleanup.initWithStrategy(.keep_cache);
    try std.testing.expectEqual(CleanupStrategy.keep_cache, cleanup.strategy);
}
