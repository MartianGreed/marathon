const std = @import("std");

pub const PromptWrapper = struct {
    template: []const u8,
    is_default: bool,

    pub fn init() PromptWrapper {
        const template = std.posix.getenv("MARATHON_PROMPT_TEMPLATE") orelse "{prompt}";
        return .{
            .template = template,
            .is_default = std.posix.getenv("MARATHON_PROMPT_TEMPLATE") == null,
        };
    }

    pub fn wrap(
        self: *const PromptWrapper,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        repo: []const u8,
        branch: []const u8,
    ) ![]const u8 {
        if (self.is_default) {
            return try allocator.dupe(u8, prompt);
        }

        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < self.template.len) {
            if (i + 8 <= self.template.len and std.mem.eql(u8, self.template[i .. i + 8], "{prompt}")) {
                try result.appendSlice(allocator, prompt);
                i += 8;
            } else if (i + 8 <= self.template.len and std.mem.eql(u8, self.template[i .. i + 8], "{branch}")) {
                try result.appendSlice(allocator, branch);
                i += 8;
            } else if (i + 6 <= self.template.len and std.mem.eql(u8, self.template[i .. i + 6], "{repo}")) {
                try result.appendSlice(allocator, repo);
                i += 6;
            } else {
                try result.append(allocator, self.template[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(allocator);
    }
};

test "wrap returns prompt unchanged with default template" {
    const allocator = std.testing.allocator;
    var wrapper = PromptWrapper{
        .template = "{prompt}",
        .is_default = true,
    };

    const result = try wrapper.wrap(allocator, "Fix the bug", "owner/repo", "main");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Fix the bug", result);
}

test "wrap substitutes all placeholders" {
    const allocator = std.testing.allocator;
    var wrapper = PromptWrapper{
        .template = "Working on {repo} branch {branch}. Task: {prompt}",
        .is_default = false,
    };

    const result = try wrapper.wrap(allocator, "Fix the bug", "owner/repo", "main");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Working on owner/repo branch main. Task: Fix the bug", result);
}

test "wrap handles multiple prompt placeholders" {
    const allocator = std.testing.allocator;
    var wrapper = PromptWrapper{
        .template = "{prompt} - Remember: {prompt}",
        .is_default = false,
    };

    const result = try wrapper.wrap(allocator, "Do X", "owner/repo", "main");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Do X - Remember: Do X", result);
}

test "wrap handles template without placeholders" {
    const allocator = std.testing.allocator;
    var wrapper = PromptWrapper{
        .template = "Static template with no placeholders",
        .is_default = false,
    };

    const result = try wrapper.wrap(allocator, "Fix bug", "owner/repo", "main");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Static template with no placeholders", result);
}

test "wrap handles empty prompt" {
    const allocator = std.testing.allocator;
    var wrapper = PromptWrapper{
        .template = "Task: {prompt}",
        .is_default = false,
    };

    const result = try wrapper.wrap(allocator, "", "owner/repo", "main");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Task: ", result);
}
