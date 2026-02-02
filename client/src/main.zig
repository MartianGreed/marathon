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
        .status => try handleStatus(args[2..]),
        .cancel => try handleCancel(args[2..]),
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
        \\
        \\Environment Variables:
        \\  MARATHON_ORCHESTRATOR_ADDRESS  Orchestrator address
        \\  MARATHON_ORCHESTRATOR_PORT     Orchestrator port
        \\  GITHUB_TOKEN                   GitHub token for repo access
        \\
        \\Examples:
        \\  marathon submit --repo https://github.com/user/repo --prompt "Fix the bug"
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

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--repo")) {
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
    };

    std.debug.print("[client] Request: repo={s} branch={s} prompt_len={d} create_pr={}\n", .{ repo.?, branch, prompt.?.len, create_pr });

    const CallbackContext = struct {
        fn handleEvent(event: protocol.Message(protocol.TaskEvent)) bool {
            const task_id_str = types.formatId(event.payload.task_id);
            std.debug.print("[client] Event: type={s} task_id={s} state={s}\n", .{ @tagName(event.payload.event_type), &task_id_str, @tagName(event.payload.state) });

            if (event.payload.event_type == .complete or event.payload.state.isTerminal()) {
                std.debug.print("Task completed.\n", .{});
                return false;
            }
            return true;
        }
    };

    client.streamCall(.submit_task, request, protocol.TaskEvent, CallbackContext.handleEvent) catch |err| {
        std.debug.print("Error: Failed to submit task: {}\n", .{err});
        return;
    };

    std.debug.print("[client] Stream ended\n", .{});
}

fn handleStatus(args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Error: task ID required\n", .{});
        return;
    }

    std.debug.print("Checking status for task: {s}\n", .{args[0]});
}

fn handleCancel(args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Error: task ID required\n", .{});
        return;
    }

    std.debug.print("Cancelling task: {s}\n", .{args[0]});
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
