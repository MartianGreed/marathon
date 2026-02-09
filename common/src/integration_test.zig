const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const protocol = @import("protocol.zig");
const vsock = @import("vsock.zig");
const types = @import("types.zig");

// Create a Connection directly from a file descriptor for testing
fn createConnectionFromFd(allocator: std.mem.Allocator, fd: posix.fd_t) vsock.Connection {
    return vsock.Connection{
        .fd = fd,
        .allocator = allocator,
    };
}

// VM Agent side - sends ready, receives start, sends output/metrics/progress/complete
fn vmAgentSide(allocator: std.mem.Allocator, fd: posix.fd_t) !void {
    var conn = createConnectionFromFd(allocator, fd);
    // Don't close - parent will handle it

    // Define an empty payload type
    const EmptyPayload = struct {};
    
    // Send vsock_ready
    try conn.send(protocol.MessageType.vsock_ready, 1, EmptyPayload{});

    // Receive vsock_start
    const start_msg = try conn.receive(protocol.VsockStartPayload);
    defer {
        allocator.free(start_msg.payload.repo_url);
        allocator.free(start_msg.payload.branch);
        allocator.free(start_msg.payload.prompt);
        allocator.free(start_msg.payload.github_token);
        allocator.free(start_msg.payload.anthropic_api_key);
        if (start_msg.payload.pr_title) |t| allocator.free(t);
        if (start_msg.payload.pr_body) |b| allocator.free(b);
        if (start_msg.payload.completion_promise) |p| allocator.free(p);
    }

    // Verify start payload
    try testing.expectEqual(protocol.MessageType.vsock_start, start_msg.header.msg_type);
    try testing.expectEqualStrings("https://github.com/test/repo", start_msg.payload.repo_url);
    try testing.expectEqualStrings("main", start_msg.payload.branch);
    try testing.expectEqualStrings("Fix the bug", start_msg.payload.prompt);
    try testing.expectEqual(true, start_msg.payload.create_pr);

    // Send vsock_output
    const output_payload = protocol.VsockOutputPayload{
        .output_type = types.OutputType.stdout,
        .data = "Running tests...",
    };
    try conn.send(protocol.MessageType.vsock_output, 2, output_payload);

    // Send vsock_metrics
    const metrics_payload = protocol.VsockMetricsPayload{
        .input_tokens = 1000,
        .output_tokens = 500,
        .cache_read_tokens = 100,
        .cache_write_tokens = 50,
        .tool_calls = 5,
    };
    try conn.send(protocol.MessageType.vsock_metrics, 3, metrics_payload);

    // Send vsock_progress
    const progress_payload = protocol.VsockProgressPayload{
        .iteration = 1,
        .max_iterations = 3,
        .status = "Running iteration 1 of 3",
    };
    try conn.send(protocol.MessageType.vsock_progress, 4, progress_payload);

    // Send vsock_complete
    const complete_payload = protocol.VsockCompletePayload{
        .exit_code = 0,
        .pr_url = "https://github.com/test/repo/pull/123",
        .metrics = metrics_payload,
        .iteration = 3,
        .promise_found = true,
    };
    try conn.send(protocol.MessageType.vsock_complete, 5, complete_payload);
}

// Node operator side - receives ready, sends start, receives output/metrics/progress/complete
fn nodeOperatorSide(allocator: std.mem.Allocator, fd: posix.fd_t) !void {
    var conn = createConnectionFromFd(allocator, fd);
    // Don't close - parent will handle it

    // Define an empty payload type for vsock_ready
    const EmptyPayload = struct {};
    
    // Receive vsock_ready
    const ready_msg = try conn.receive(EmptyPayload);
    defer {
        // Nothing to free for empty payload
    }
    try testing.expectEqual(protocol.MessageType.vsock_ready, ready_msg.header.msg_type);

    // Send vsock_start
    const start_payload = protocol.VsockStartPayload{
        .task_id = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 },
        .repo_url = "https://github.com/test/repo",
        .branch = "main",
        .prompt = "Fix the bug",
        .github_token = "ghp_test123",
        .anthropic_api_key = "sk-ant-test123",
        .create_pr = true,
        .pr_title = "Bug fix PR",
        .pr_body = "This fixes the bug",
        .max_iterations = 3,
        .completion_promise = "TASK_COMPLETE",
    };
    try conn.send(protocol.MessageType.vsock_start, 10, start_payload);

    // Receive vsock_output
    const output_msg = try conn.receive(protocol.VsockOutputPayload);
    defer {
        allocator.free(output_msg.payload.data);
    }
    try testing.expectEqual(protocol.MessageType.vsock_output, output_msg.header.msg_type);
    try testing.expectEqual(types.OutputType.stdout, output_msg.payload.output_type);
    try testing.expectEqualStrings("Running tests...", output_msg.payload.data);

    // Receive vsock_metrics
    const metrics_msg = try conn.receive(protocol.VsockMetricsPayload);
    try testing.expectEqual(protocol.MessageType.vsock_metrics, metrics_msg.header.msg_type);
    try testing.expectEqual(@as(i64, 1000), metrics_msg.payload.input_tokens);
    try testing.expectEqual(@as(i64, 500), metrics_msg.payload.output_tokens);
    try testing.expectEqual(@as(i64, 100), metrics_msg.payload.cache_read_tokens);
    try testing.expectEqual(@as(i64, 50), metrics_msg.payload.cache_write_tokens);
    try testing.expectEqual(@as(i64, 5), metrics_msg.payload.tool_calls);

    // Receive vsock_progress
    const progress_msg = try conn.receive(protocol.VsockProgressPayload);
    defer {
        allocator.free(progress_msg.payload.status);
    }
    try testing.expectEqual(protocol.MessageType.vsock_progress, progress_msg.header.msg_type);
    try testing.expectEqual(@as(u32, 1), progress_msg.payload.iteration);
    try testing.expectEqual(@as(u32, 3), progress_msg.payload.max_iterations);
    try testing.expectEqualStrings("Running iteration 1 of 3", progress_msg.payload.status);

    // Receive vsock_complete
    const complete_msg = try conn.receive(protocol.VsockCompletePayload);
    defer {
        if (complete_msg.payload.pr_url) |url| allocator.free(url);
    }
    try testing.expectEqual(protocol.MessageType.vsock_complete, complete_msg.header.msg_type);
    try testing.expectEqual(@as(i32, 0), complete_msg.payload.exit_code);
    try testing.expectEqualStrings("https://github.com/test/repo/pull/123", complete_msg.payload.pr_url.?);
    try testing.expectEqual(@as(u32, 3), complete_msg.payload.iteration);
    try testing.expectEqual(true, complete_msg.payload.promise_found);
    
    // Check metrics in complete message
    try testing.expectEqual(@as(i64, 1000), complete_msg.payload.metrics.input_tokens);
    try testing.expectEqual(@as(i64, 500), complete_msg.payload.metrics.output_tokens);
}

test "vsock protocol integration test over UDS" {
    const allocator = testing.allocator;

    // Create a Unix domain socket pair using std.os.linux
    var fds: [2]posix.fd_t = undefined;
    const sock_result = std.os.linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (sock_result != 0) return error.SocketPairFailed;
    defer {
        posix.close(fds[0]);
        posix.close(fds[1]);
    }

    // Spawn threads to simulate vm_agent and node_operator
    const vm_agent_thread = try std.Thread.spawn(.{}, vmAgentSide, .{ allocator, fds[0] });
    const node_operator_thread = try std.Thread.spawn(.{}, nodeOperatorSide, .{ allocator, fds[1] });

    // Wait for both threads to complete
    vm_agent_thread.join();
    node_operator_thread.join();
}

test "protocol error handling - invalid magic" {
    const allocator = testing.allocator;
    
    var fds: [2]posix.fd_t = undefined;
    const sock_result = std.os.linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (sock_result != 0) return error.SocketPairFailed;
    defer {
        posix.close(fds[0]);
        posix.close(fds[1]);
    }

    // Send invalid header
    const invalid_header = [_]u8{ 'B', 'A', 'D', '!', 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    _ = try posix.send(fds[0], &invalid_header, 0);
    
    // Try to receive and expect error
    var conn = createConnectionFromFd(allocator, fds[1]);
    
    const EmptyPayload = struct {};
    const receive_result = conn.receive(EmptyPayload);
    try testing.expectError(error.InvalidMagic, receive_result);
}

test "protocol error handling - connection closed during read" {
    const allocator = testing.allocator;
    
    var fds: [2]posix.fd_t = undefined;
    const sock_result = std.os.linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (sock_result != 0) return error.SocketPairFailed;
    defer posix.close(fds[1]);

    // Close one end immediately
    posix.close(fds[0]);
    
    // Try to receive from closed connection
    var conn = createConnectionFromFd(allocator, fds[1]);
    
    const EmptyPayload = struct {};
    const receive_result = conn.receive(EmptyPayload);
    try testing.expectError(error.ConnectionClosed, receive_result);
}