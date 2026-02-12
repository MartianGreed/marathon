const std = @import("std");

/// Signals parsed from Claude's output, matching the ralph-loop pattern.
pub const ClaudeSignals = struct {
    has_completion_promise: bool = false,
    needs_clarification: bool = false,
    clarification_question: ?[]const u8 = null,
    pr_created: bool = false,
    pr_url: ?[]const u8 = null,
};

/// Parse Claude output for structured signals.
/// Looks for:
///   <promise>COMPLETION_TEXT</promise>
///   <clarification>question</clarification>
///   PR URLs (https://github.com/.../pull/N)
pub fn parseSignals(output: []const u8, completion_promise: ?[]const u8) ClaudeSignals {
    var signals = ClaudeSignals{};

    // Check completion promise
    if (completion_promise) |promise| {
        if (extractTagContent(output, "promise")) |content| {
            if (std.mem.eql(u8, std.mem.trim(u8, content, " \t\r\n"), promise)) {
                signals.has_completion_promise = true;
            }
        }
        // Also check for raw promise text in output (backward compat)
        if (!signals.has_completion_promise) {
            if (std.mem.indexOf(u8, output, promise) != null) {
                signals.has_completion_promise = true;
            }
        }
    }

    // Check clarification
    if (extractTagContent(output, "clarification")) |question| {
        signals.needs_clarification = true;
        signals.clarification_question = question;
    }

    // Check PR URL
    if (extractPrUrl(output)) |url| {
        signals.pr_created = true;
        signals.pr_url = url;
    }

    return signals;
}

/// Extract content between <tag>...</tag>
fn extractTagContent(output: []const u8, tag: []const u8) ?[]const u8 {
    // Build open/close tags
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;

    const open_tag = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return null;
    const close_tag = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;

    const start_idx = std.mem.indexOf(u8, output, open_tag) orelse return null;
    const content_start = start_idx + open_tag.len;
    const end_idx = std.mem.indexOf(u8, output[content_start..], close_tag) orelse return null;

    return output[content_start .. content_start + end_idx];
}

/// Extract a GitHub PR URL from output
fn extractPrUrl(output: []const u8) ?[]const u8 {
    const pattern = "https://github.com/";
    var i: usize = 0;

    while (i < output.len) {
        if (i + pattern.len <= output.len and std.mem.eql(u8, output[i..][0..pattern.len], pattern)) {
            const start = i;
            while (i < output.len and output[i] != '\n' and output[i] != ' ' and output[i] != '\t' and output[i] != '"' and output[i] != '\'') {
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

// Tests

test "parseSignals detects promise tag" {
    const output = "Working on it...\n<promise>TASK_COMPLETE</promise>\nDone.";
    const signals = parseSignals(output, "TASK_COMPLETE");
    try std.testing.expect(signals.has_completion_promise);
}

test "parseSignals detects raw promise text" {
    const output = "All done. TASK_COMPLETE";
    const signals = parseSignals(output, "TASK_COMPLETE");
    try std.testing.expect(signals.has_completion_promise);
}

test "parseSignals no false positive" {
    const output = "Working on it...";
    const signals = parseSignals(output, "TASK_COMPLETE");
    try std.testing.expect(!signals.has_completion_promise);
}

test "parseSignals detects clarification" {
    const output = "I need more info.\n<clarification>What database should I use?</clarification>";
    const signals = parseSignals(output, null);
    try std.testing.expect(signals.needs_clarification);
    try std.testing.expectEqualStrings("What database should I use?", signals.clarification_question.?);
}

test "parseSignals detects PR URL" {
    const output = "Created PR: https://github.com/owner/repo/pull/42\nDone.";
    const signals = parseSignals(output, null);
    try std.testing.expect(signals.pr_created);
    try std.testing.expectEqualStrings("https://github.com/owner/repo/pull/42", signals.pr_url.?);
}

test "parseSignals no PR for non-pull URLs" {
    const output = "See https://github.com/owner/repo/issues/10";
    const signals = parseSignals(output, null);
    try std.testing.expect(!signals.pr_created);
}

test "extractTagContent works" {
    const output = "Before <promise>DONE</promise> after";
    const content = extractTagContent(output, "promise");
    try std.testing.expectEqualStrings("DONE", content.?);
}

test "extractTagContent returns null for missing tag" {
    const output = "No tags here";
    const content = extractTagContent(output, "promise");
    try std.testing.expect(content == null);
}
