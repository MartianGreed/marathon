const std = @import("std");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;
const grpc = common.grpc;

const Command = enum {
    submit,
    status,
    cancel,
    usage,
    help,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = try common.config.ClientConfig.fromEnv(allocator);
    defer config.deinit();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = parseCommand(args[1]) orelse {
        std.debug.print("Unknown command: {s}\n", .{args[1]});
        printUsage();
        return;
    };

    switch (command) {
        .submit => try handleSubmit(config, args[2..]),
        .status => try handleStatus(config, allocator, args[2..]),
        .cancel => try handleCancel(config, allocator, args[2..]),
        .usage => try handleUsage(),
        .help => printUsage(),
    }
}

fn parseCommand(arg: []const u8) ?Command {
    const commands = [_]struct { name: []const u8, cmd: Command }{
        .{ .name = "submit", .cmd = .submit },
        .{ .name = "status", .cmd = .status },
        .{ .name = "cancel", .cmd = .cancel },
        .{ .name = "usage", .cmd = .usage },
        .{ .name = "help", .cmd = .help },
        .{ .name = "--help", .cmd = .help },
        .{ .name = "-h", .cmd = .help },
    };

    for (commands) |c| {
        if (std.mem.eql(u8, arg, c.name)) return c.cmd;
    }
    return null;
}

fn printUsage() void {
    const usage =
        \\Marathon CLI - Distributed Claude Code Runner
        \\
        \\Usage: marathon <command> [options]
        \\
        \\Commands:
        \\  submit   Submit a new task
        \\  status   Check task status
        \\  cancel   Cancel a running task
        \\  usage    Get usage report
        \\  help     Show this help
        \\
        \\Submit Options:
        \\  --repo <url>       Repository URL (required)
        \\  --branch <name>    Branch name (default: main)
        \\  --prompt <text>    Task prompt (required)
        \\  --pr               Create a PR on completion
        \\  --pr-title <text>  PR title
        \\  --pr-body <text>   PR body
        \\  -e KEY=VALUE       Environment variable for the agent (repeatable)
        \\  --max-iterations N Max ralph loop iterations (default: 50)
        \\  --completion-promise <text>  String that signals task completion
        \\  -f, --follow       Stream task events in real-time until completion
        \\
        \\Environment Variables:
        \\  MARATHON_ORCHESTRATOR_ADDRESS  Orchestrator address
        \\  MARATHON_ORCHESTRATOR_PORT     Orchestrator port
        \\  GITHUB_TOKEN                   GitHub token for repo access
        \\
        \\Examples:
        \\  marathon submit --repo https://github.com/user/repo --prompt "Fix the bug"
        \\  marathon submit --repo https://github.com/user/repo --prompt "Build feature" -e DATABASE_URL=postgres://... -e API_KEY=sk-xxx --max-iterations 10 --completion-promise "TASK_COMPLETE"
        \\  marathon status abc123
        \\  marathon cancel abc123
        \\  marathon usage
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn handleSubmit(config: common.config.ClientConfig, args: []const []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var repo: ?[]const u8 = null;
    var branch: []const u8 = "main";
    var prompt: ?[]const u8 = null;
    var create_pr = false;
    var pr_title: ?[]const u8 = null;
    var pr_body: ?[]const u8 = null;
    var max_iterations: ?u32 = null;
    var completion_promise: ?[]const u8 = null;
    var follow = false;

    var env_vars_list: std.ArrayListUnmanaged(protocol.EnvVar) = .empty;
    defer env_vars_list.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--env")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: -e requires KEY=VALUE\n", .{});
                return;
            }
            const env_arg = args[i];
            if (std.mem.indexOfScalar(u8, env_arg, '=')) |eq_pos| {
                try env_vars_list.append(allocator, .{
                    .key = env_arg[0..eq_pos],
                    .value = env_arg[eq_pos + 1 ..],
                });
            } else {
                std.debug.print("Error: -e requires KEY=VALUE format, got: {s}\n", .{env_arg});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--max-iterations")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --max-iterations requires a value\n", .{});
                return;
            }
            max_iterations = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--completion-promise")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --completion-promise requires a value\n", .{});
                return;
            }
            completion_promise = args[i];
        } else if (std.mem.eql(u8, arg, "--repo")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --repo requires a value\n", .{});
                return;
            }
            repo = args[i];
        } else if (std.mem.eql(u8, arg, "--branch")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --branch requires a value\n", .{});
                return;
            }
            branch = args[i];
        } else if (std.mem.eql(u8, arg, "--prompt")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --prompt requires a value\n", .{});
                return;
            }
            prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--pr")) {
            create_pr = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--follow")) {
            follow = true;
        } else if (std.mem.eql(u8, arg, "--pr-title")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --pr-title requires a value\n", .{});
                return;
            }
            pr_title = args[i];
        } else if (std.mem.eql(u8, arg, "--pr-body")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --pr-body requires a value\n", .{});
                return;
            }
            pr_body = args[i];
        }
    }

    if (repo == null) {
        std.debug.print("Error: --repo is required\n", .{});
        return;
    }

    if (prompt == null) {
        std.debug.print("Error: --prompt is required\n", .{});
        return;
    }

    if (config.github_token == null) {
        std.debug.print("Error: GITHUB_TOKEN environment variable is required\n", .{});
        return;
    }

    std.debug.print("Connecting to orchestrator at {s}:{d}...\n", .{ config.orchestrator_address, config.orchestrator_port });

    var client = grpc.Client.init(allocator);
    defer client.close();

    client.connect(config.orchestrator_address, config.orchestrator_port, config.tls_enabled, config.tls_ca_path) catch |err| {
        std.debug.print("Error: Failed to connect to orchestrator: {}\n", .{err});
        return;
    };

    std.debug.print("[client] Connected, TLS enabled: {}\n", .{config.tls_enabled});
    std.debug.print("Submitting task...\n", .{});

    const request = protocol.SubmitTaskRequest{
        .repo_url = repo.?,
        .branch = branch,
        .prompt = prompt.?,
        .github_token = config.github_token.?,
        .create_pr = create_pr,
        .pr_title = pr_title,
        .pr_body = pr_body,
        .env_vars = env_vars_list.items,
        .max_iterations = max_iterations,
        .completion_promise = completion_promise,
    };

    var raw_response = client.callWithHeader(.submit_task, request) catch |err| {
        std.debug.print("Error: Failed to submit task: {}\n", .{err});
        return;
    };
    defer raw_response.deinit();

    // Check if server returned an error
    if (raw_response.header.msg_type == .error_response) {
        const err_resp = raw_response.decodeAs(protocol.ErrorResponse) catch {
            std.debug.print("Error: Server returned an error (could not decode)\n", .{});
            return;
        };
        std.debug.print("Error: {s} — {s}\n", .{ err_resp.code, err_resp.message });
        return;
    }

    const event = raw_response.decodeAs(protocol.TaskEvent) catch |err| {
        std.debug.print("Error: Failed to decode response: {}\n", .{err});
        return;
    };

    const task_id_str = types.formatId(event.task_id);

    if (!follow) {
        std.debug.print("{s}\n", .{&task_id_str});
        return;
    }

    // Follow mode: poll for task events until terminal state
    const stdout = std.io.getStdOut().writer();
    stdout.print("⏳ Task submitted: {s}\n", .{&task_id_str}) catch {};
    stdout.print("📋 State: {s}\n", .{@tagName(event.state)}) catch {};

    // Close the submit connection and poll with get_task + get_task_events
    client.close();
    var poll_client = grpc.Client.init(allocator);
    defer poll_client.close();

    poll_client.connect(config.orchestrator_address, config.orchestrator_port, config.tls_enabled, config.tls_ca_path) catch |err| {
        stdout.print("⚠️  Failed to connect for follow mode: {}\n", .{err}) catch {};
        return;
    };

    var last_state: types.TaskState = event.state;

    while (true) {
        // Poll task status + events
        var status_resp = poll_client.callWithHeader(.get_task_events, protocol.GetTaskEventsRequest{
            .task_id = event.task_id,
        }) catch |err| {
            // Fall back to simple status poll
            var simple_resp = poll_client.callWithHeader(.get_task, protocol.GetTaskRequest{
                .task_id = event.task_id,
            }) catch {
                stdout.print("⚠️  Connection lost: {}\n", .{err}) catch {};
                break;
            };
            defer simple_resp.deinit();

            if (simple_resp.header.msg_type == .task_response) {
                const r = simple_resp.decodeAs(protocol.TaskResponse) catch continue;
                if (r.state != last_state) {
                    last_state = r.state;
                    printStateChange(stdout, r.state);
                }
                if (r.state.isTerminal()) {
                    if (r.error_message) |msg| stdout.print("   Error: {s}\n", .{msg}) catch {};
                    if (r.pr_url) |url| stdout.print("   PR: {s}\n", .{url}) catch {};
                    break;
                }
            }
            std.time.sleep(2 * std.time.ns_per_s);
            continue;
        };
        defer status_resp.deinit();

        if (status_resp.header.msg_type == .task_events_response) {
            const events_resp = status_resp.decodeAs(protocol.TaskEventsResponse) catch {
                std.time.sleep(2 * std.time.ns_per_s);
                continue;
            };

            if (events_resp.state != last_state) {
                last_state = events_resp.state;
                printStateChange(stdout, events_resp.state);
            }

            for (events_resp.events) |evt| {
                if (evt.data.len > 0) {
                    stdout.print("📋 {s}\n", .{evt.data}) catch {};
                }
            }

            if (events_resp.state.isTerminal()) {
                if (events_resp.error_message) |msg| stdout.print("   Error: {s}\n", .{msg}) catch {};
                if (events_resp.pr_url) |url| stdout.print("   PR: {s}\n", .{url}) catch {};
                break;
            }
        }

        std.time.sleep(2 * std.time.ns_per_s);
    }
}

fn printStateChange(writer: anytype, state: types.TaskState) void {
    const icon: []const u8 = switch (state) {
        .queued => "⏳",
        .starting => "🖥️ ",
        .running => "🔥",
        .completed => "✅",
        .failed => "❌",
        .cancelled => "🚫",
        .unspecified => "❓",
    };
    writer.print("{s} State: {s}\n", .{ icon, @tagName(state) }) catch {};
}

fn handleStatus(config: common.config.ClientConfig, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Error: task ID required\n", .{});
        return;
    }

    const task_id = types.parseId(types.TaskId, args[0]) catch {
        std.debug.print("Error: invalid task ID: {s}\n", .{args[0]});
        return;
    };

    var client = grpc.Client.init(allocator);
    defer client.close();

    client.connect(config.orchestrator_address, config.orchestrator_port, config.tls_enabled, config.tls_ca_path) catch |err| {
        std.debug.print("Error: Failed to connect to orchestrator: {}\n", .{err});
        return;
    };

    const response = client.call(.get_task, protocol.GetTaskRequest{ .task_id = task_id }, protocol.TaskResponse) catch |err| {
        std.debug.print("Error: Failed to get task status: {}\n", .{err});
        return;
    };
    defer protocol.freeDecoded(protocol.TaskResponse, allocator, response.payload);

    const r = response.payload;
    const id_str = types.formatId(r.task_id);
    std.debug.print("Task:      {s}\n", .{&id_str});
    std.debug.print("State:     {s}\n", .{@tagName(r.state)});
    std.debug.print("Repo:      {s}\n", .{r.repo_url});
    std.debug.print("Branch:    {s}\n", .{r.branch});
    std.debug.print("Created:   {d}\n", .{r.created_at});
    if (r.started_at) |t| std.debug.print("Started:   {d}\n", .{t});
    if (r.completed_at) |t| std.debug.print("Completed: {d}\n", .{t});
    if (r.error_message) |msg| std.debug.print("Error:     {s}\n", .{msg});
    if (r.pr_url) |url| std.debug.print("PR:        {s}\n", .{url});
}

fn handleCancel(config: common.config.ClientConfig, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Error: task ID required\n", .{});
        return;
    }

    const task_id = types.parseId(types.TaskId, args[0]) catch {
        std.debug.print("Error: invalid task ID: {s}\n", .{args[0]});
        return;
    };

    var client = grpc.Client.init(allocator);
    defer client.close();

    client.connect(config.orchestrator_address, config.orchestrator_port, config.tls_enabled, config.tls_ca_path) catch |err| {
        std.debug.print("Error: Failed to connect to orchestrator: {}\n", .{err});
        return;
    };

    const response = client.call(.cancel_task, protocol.CancelTaskRequest{ .task_id = task_id }, protocol.CancelResponse) catch |err| {
        std.debug.print("Error: Failed to cancel task: {}\n", .{err});
        return;
    };
    defer protocol.freeDecoded(protocol.CancelResponse, allocator, response.payload);

    if (response.payload.success) {
        std.debug.print("Task cancelled.\n", .{});
    } else {
        std.debug.print("Cancel failed: {s}\n", .{response.payload.message});
    }
}

fn handleUsage() !void {
    std.debug.print("Usage Report\n", .{});
    std.debug.print("============\n", .{});
    std.debug.print("(Not connected to orchestrator)\n", .{});
}

test "command parsing" {
    try std.testing.expectEqual(Command.submit, parseCommand("submit").?);
    try std.testing.expectEqual(Command.help, parseCommand("help").?);
    try std.testing.expect(parseCommand("invalid") == null);
}
