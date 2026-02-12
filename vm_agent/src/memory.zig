const std = @import("std");

/// Manages MEMORY.md persistence across ralph loop iterations.
/// Between iterations, reads MEMORY.md from the work dir (if Claude created/updated it)
/// and prepends it as context to the next iteration's prompt.
pub const MemoryManager = struct {
    allocator: std.mem.Allocator,
    work_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, work_dir: []const u8) MemoryManager {
        return .{
            .allocator = allocator,
            .work_dir = work_dir,
        };
    }

    /// Read MEMORY.md from the repo work directory.
    /// Returns null if file doesn't exist or is empty.
    pub fn readMemory(self: *MemoryManager) ?[]const u8 {
        const path = std.fmt.allocPrint(self.allocator, "{s}/MEMORY.md", .{self.work_dir}) catch return null;
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 256 * 1024) catch return null;
        if (content.len == 0) {
            self.allocator.free(content);
            return null;
        }
        return content;
    }

    /// Read the iteration log from .marathon/iterations.log
    /// This captures a summary of what happened in previous iterations.
    pub fn readIterationLog(self: *MemoryManager) ?[]const u8 {
        const path = std.fmt.allocPrint(self.allocator, "{s}/.marathon/iterations.log", .{self.work_dir}) catch return null;
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 128 * 1024) catch return null;
        if (content.len == 0) {
            self.allocator.free(content);
            return null;
        }
        return content;
    }

    /// Append an iteration summary to .marathon/iterations.log
    pub fn logIteration(self: *MemoryManager, iteration: u32, exit_code: i32, output_summary: []const u8) void {
        const dir_path = std.fmt.allocPrint(self.allocator, "{s}/.marathon", .{self.work_dir}) catch return;
        defer self.allocator.free(dir_path);

        std.fs.cwd().makePath(dir_path) catch {};

        const path = std.fmt.allocPrint(self.allocator, "{s}/.marathon/iterations.log", .{self.work_dir}) catch return;
        defer self.allocator.free(path);

        const file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
        defer file.close();

        file.seekFromEnd(0) catch {};

        // Truncate output summary to keep log manageable
        const max_summary = @min(output_summary.len, 2048);
        const summary = output_summary[0..max_summary];

        const header = std.fmt.allocPrint(self.allocator, "\n--- Iteration {d} (exit_code={d}) ---\n{s}\n", .{
            iteration,
            exit_code,
            summary,
        }) catch return;
        defer self.allocator.free(header);
        file.writeAll(header) catch {};
    }

    /// Build context prefix for the next iteration's prompt.
    /// Includes MEMORY.md content and iteration history.
    pub fn buildContextPrefix(self: *MemoryManager, iteration: u32, last_output: []const u8) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        const writer = result.writer(self.allocator);

        try writer.writeAll("# Context from previous iterations\n\n");
        try writer.print("This is iteration {d}. The previous iteration did not complete the task.\n\n", .{iteration});

        // Include MEMORY.md if it exists
        if (self.readMemory()) |memory| {
            defer self.allocator.free(memory);
            try writer.writeAll("## MEMORY.md (persistent notes from previous iterations)\n\n");
            // Cap at 32KB to avoid blowing context window
            const cap = @min(memory.len, 32 * 1024);
            try writer.writeAll(memory[0..cap]);
            try writer.writeAll("\n\n");
        }

        // Include last output summary (truncated)
        if (last_output.len > 0) {
            try writer.writeAll("## Last iteration output (summary)\n\n");
            const cap = @min(last_output.len, 4096);
            try writer.writeAll(last_output[0..cap]);
            if (last_output.len > cap) {
                try writer.writeAll("\n... (truncated)");
            }
            try writer.writeAll("\n\n");
        }

        try writer.writeAll("## Your task\n\nContinue working. ");
        try writer.writeAll("If you need to persist information across iterations, write to MEMORY.md.\n");
        try writer.writeAll("When complete, output <promise>TASK_COMPLETE</promise> (or the configured completion promise).\n");
        try writer.writeAll("If you need clarification, output <clarification>your question</clarification>.\n\n");

        return result.toOwnedSlice(self.allocator);
    }
};

test "MemoryManager init" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator, "/tmp/test");
    _ = &mgr;
}

test "readMemory returns null for missing file" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator, "/tmp/nonexistent-marathon-test");
    try std.testing.expect(mgr.readMemory() == null);
}

test "buildContextPrefix produces valid output" {
    const allocator = std.testing.allocator;
    var mgr = MemoryManager.init(allocator, "/tmp/nonexistent-marathon-test");

    const prefix = try mgr.buildContextPrefix(2, "Previous output here");
    defer allocator.free(prefix);

    try std.testing.expect(std.mem.indexOf(u8, prefix, "iteration 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "Previous output here") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "MEMORY.md") != null);
}
