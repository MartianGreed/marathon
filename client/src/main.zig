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
    login,
    register,
    whoami,
    logout,
    help,
    // Workspace commands
    workspace,
};

const WorkspaceSubcommand = enum {
    create,
    list,
    switch,
    delete,
    current,
    info,
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
        .login => try handleLogin(config, allocator, args[2..]),
        .register => try handleRegister(config, allocator, args[2..]),
        .whoami => try handleWhoami(allocator),
        .logout => try handleLogout(allocator),
        .workspace => try handleWorkspace(config, allocator, args[2..]),
        .help => printUsage(),
    }
}

fn parseCommand(arg: []const u8) ?Command {
    const commands = [_]struct { name: []const u8, cmd: Command }{
        .{ .name = "submit", .cmd = .submit },
        .{ .name = "status", .cmd = .status },
        .{ .name = "cancel", .cmd = .cancel },
        .{ .name = "usage", .cmd = .usage },
        .{ .name = "login", .cmd = .login },
        .{ .name = "register", .cmd = .register },
        .{ .name = "whoami", .cmd = .whoami },
        .{ .name = "logout", .cmd = .logout },
        .{ .name = "workspace", .cmd = .workspace },
        .{ .name = "help", .cmd = .help },
        .{ .name = "--help", .cmd = .help },
        .{ .name = "-h", .cmd = .help },
    };

    for (commands) |c| {
        if (std.mem.eql(u8, arg, c.name)) return c.cmd;
    }
    return null;
}

fn parseWorkspaceSubcommand(arg: []const u8) ?WorkspaceSubcommand {
    const subcommands = [_]struct { name: []const u8, cmd: WorkspaceSubcommand }{
        .{ .name = "create", .cmd = .create },
        .{ .name = "list", .cmd = .list },
        .{ .name = "switch", .cmd = .switch },
        .{ .name = "delete", .cmd = .delete },
        .{ .name = "current", .cmd = .current },
        .{ .name = "info", .cmd = .info },
        .{ .name = "help", .cmd = .help },
        .{ .name = "--help", .cmd = .help },
        .{ .name = "-h", .cmd = .help },
    };

    for (subcommands) |c| {
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
        \\  register             Create a new account
        \\  login                Authenticate with your account
        \\  logout               Remove stored credentials
        \\  whoami               Show current authenticated user
        \\  submit               Submit a new task
        \\  status <task-id>     Check task status
        \\  cancel <task-id>     Cancel a running task
        \\  usage                Get usage report
        \\  workspace            Manage workspaces
        \\  help                 Show this help
        \\
        \\Auth Options (login/register):
        \\  --email <email>      Email address
        \\  --password <pass>    Password (prompted if not provided)
        \\
        \\Submit Options:
        \\  --repo <url>       Repository URL (required)
        \\  --branch <name>    Branch name (default: main)
        \\  --prompt <text>    Task prompt (required)
        \\  --workspace <name> Use specific workspace (default: current active)
        \\  --pr               Create a PR on completion
        \\  --pr-title <text>  PR title
        \\  --pr-body <text>   PR body
        \\  -e KEY=VALUE       Environment variable for the agent (repeatable)
        \\  --max-iterations N Max ralph loop iterations (default: 50)
        \\  --completion-promise <text>  String that signals task completion
        \\  -f, --follow       Stream task events in real-time until completion
        \\
        \\Workspace Commands:
        \\  marathon workspace create <name> [options]  Create a new workspace
        \\  marathon workspace list                     List all workspaces
        \\  marathon workspace switch <name>            Switch to a workspace
        \\  marathon workspace delete <name>            Delete a workspace
        \\  marathon workspace current                  Show current workspace
        \\  marathon workspace info [name]              Show workspace details
        \\
        \\Workspace Create Options:
        \\  --template <name>     Use workspace template (default, web-app, python-ml, rust-backend)
        \\  --description <text>  Workspace description
        \\  --settings <json>     JSON settings (overrides template defaults)
        \\
        \\Environment Variables:
        \\  MARATHON_ORCHESTRATOR_ADDRESS  Orchestrator address
        \\  MARATHON_ORCHESTRATOR_PORT     Orchestrator port
        \\  GITHUB_TOKEN                   GitHub token for repo access
        \\
        \\Examples:
        \\  marathon register --email user@example.com --password mypassword
        \\  marathon login --email user@example.com --password mypassword
        \\  marathon whoami
        \\  marathon workspace create my-project --template web-app --description "My web project"
        \\  marathon workspace list
        \\  marathon workspace switch my-project
        \\  marathon workspace current
        \\  marathon submit --repo https://github.com/user/repo --prompt "Fix the bug"
        \\  marathon submit --repo https://github.com/user/repo --prompt "Build feature" --workspace my-project -e DATABASE_URL=postgres://... -e API_KEY=sk-xxx --max-iterations 10 --completion-promise "TASK_COMPLETE"
        \\  marathon status abc123
        \\  marathon cancel abc123
        \\  marathon usage
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn printWorkspaceUsage() void {
    const usage =
        \\Marathon Workspace Management
        \\
        \\Usage: marathon workspace <subcommand> [options]
        \\
        \\Subcommands:
        \\  create <name>        Create a new workspace
        \\  list                 List all workspaces
        \\  switch <name>        Switch to a workspace
        \\  delete <name>        Delete a workspace
        \\  current              Show current active workspace
        \\  info [name]          Show workspace details (current if no name)
        \\  help                 Show this help
        \\
        \\Create Options:
        \\  --template <name>     Template to use (default, web-app, python-ml, rust-backend)
        \\  --description <text>  Workspace description
        \\  --settings <json>     JSON settings (overrides template defaults)
        \\
        \\Examples:
        \\  marathon workspace create my-project --template web-app --description "My web application"
        \\  marathon workspace list
        \\  marathon workspace switch my-project
        \\  marathon workspace current
        \\  marathon workspace info my-project
        \\  marathon workspace delete old-project
        \\
    ;
    std.debug.print("{s}", .{usage});
}

// --- Credential file management ---

const Credentials = struct {
    token: []const u8,
    api_key: []const u8,
    email: []const u8,
};

fn getCredentialsPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.marathon/credentials", .{home});
    }
    return std.fmt.allocPrint(allocator, "/tmp/.marathon/credentials", .{});
}

fn saveCredentials(allocator: std.mem.Allocator, token: []const u8, api_key: []const u8, email: []const u8) !void {
    const path = try getCredentialsPath(allocator);
    defer allocator.free(path);

    // Create directory
    const dir_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidPath;
    const dir_path = path[0..dir_end];

    std.fs.cwd().makePath(dir_path) catch {};

    const file = try std.fs.cwd().createFile(path, .{ .mode = 0o600 });
    defer file.close();

    // Build credentials content
    var content_buf: [2048]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf, "token={s}\napi_key={s}\nemail={s}\n", .{ token, api_key, email }) catch return error.BufferTooSmall;
    try file.writeAll(content);

    std.debug.print("Credentials saved to {s}\n", .{path});
}

fn loadCredentials(allocator: std.mem.Allocator) !?Credentials {
    const path = try getCredentialsPath(allocator);
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 4096);

    var token: ?[]const u8 = null;
    var api_key: ?[]const u8 = null;
    var email: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "token=")) {
            token = line[6..];
        } else if (std.mem.startsWith(u8, line, "api_key=")) {
            api_key = line[8..];
        } else if (std.mem.startsWith(u8, line, "email=")) {
            email = line[6..];
        }
    }

    if (token != null and api_key != null and email != null) {
        return Credentials{
            .token = token.?,
            .api_key = api_key.?,
            .email = email.?,
        };
    }
    return null;
}

fn deleteCredentials(allocator: std.mem.Allocator) !void {
    const path = try getCredentialsPath(allocator);
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}

// --- Auth handlers ---

fn handleRegister(config: common.config.ClientConfig, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var email: ?[]const u8 = null;
    var password: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--email")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --email requires a value\n", .{});
                return;
            }
            email = args[i];
        } else if (std.mem.eql(u8, args[i], "--password")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --password requires a value\n", .{});
                return;
            }
            password = args[i];
        }
    }

    if (email == null) {
        std.debug.print("Error: --email is required\n", .{});
        return;
    }
    if (password == null) {
        std.debug.print("Error: --password is required\n", .{});
        return;
    }

    std.debug.print("Connecting to {s}:{d}...\n", .{ config.orchestrator_address, config.orchestrator_port });

    var client = grpc.Client.init(allocator);
    defer client.close();

    client.connect(config.orchestrator_address, config.orchestrator_port, config.tls_enabled, config.tls_ca_path) catch |err| {
        std.debug.print("Error: Failed to connect to orchestrator: {}\n", .{err});
        return;
    };

    const request = protocol.AuthRegisterRequest{
        .email = email.?,
        .password = password.?,
    };

    var raw_response = client.callWithHeader(.auth_register, request) catch |err| {
        std.debug.print("Error: Failed to register: {}\n", .{err});
        return;
    };
    defer raw_response.deinit();

    if (raw_response.header.msg_type == .error_response) {
        const err_resp = raw_response.decodeAs(protocol.ErrorResponse) catch {
            std.debug.print("Error: Server returned an error (could not decode)\n", .{});
            return;
        };
        std.debug.print("Error: {s} — {s}\n", .{ err_resp.code, err_resp.message });
        return;
    }

    const response = raw_response.decodeAs(protocol.AuthResponse) catch |err| {
        std.debug.print("Error: Failed to decode response: {}\n", .{err});
        return;
    };

    if (response.success) {
        std.debug.print("✓ Registration successful!\n", .{});
        if (response.token != null and response.api_key != null) {
            try saveCredentials(allocator, response.token.?, response.api_key.?, email.?);
            std.debug.print("API Key: {s}\n", .{response.api_key.?});
        }
    } else {
        std.debug.print("Registration failed: {s}\n", .{response.message});
    }
}

fn handleLogin(config: common.config.ClientConfig, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var email: ?[]const u8 = null;
    var password: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--email")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --email requires a value\n", .{});
                return;
            }
            email = args[i];
        } else if (std.mem.eql(u8, args[i], "--password")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --password requires a value\n", .{});
                return;
            }
            password = args[i];
        }
    }

    if (email == null) {
        std.debug.print("Error: --email is required\n", .{});
        return;
    }
    if (password == null) {
        std.debug.print("Error: --password is required\n", .{});
        return;
    }

    std.debug.print("Connecting to {s}:{d}...\n", .{ config.orchestrator_address, config.orchestrator_port });

    var client = grpc.Client.init(allocator);
    defer client.close();

    client.connect(config.orchestrator_address, config.orchestrator_port, config.tls_enabled, config.tls_ca_path) catch |err| {
        std.debug.print("Error: Failed to connect to orchestrator: {}\n", .{err});
        return;
    };

    const request = protocol.AuthLoginRequest{
        .email = email.?,
        .password = password.?,
    };

    var raw_response = client.callWithHeader(.auth_login, request) catch |err| {
        std.debug.print("Error: Failed to login: {}\n", .{err});
        return;
    };
    defer raw_response.deinit();

    if (raw_response.header.msg_type == .error_response) {
        const err_resp = raw_response.decodeAs(protocol.ErrorResponse) catch {
            std.debug.print("Error: Server returned an error (could not decode)\n", .{});
            return;
        };
        std.debug.print("Error: {s} — {s}\n", .{ err_resp.code, err_resp.message });
        return;
    }

    const response = raw_response.decodeAs(protocol.AuthResponse) catch |err| {
        std.debug.print("Error: Failed to decode response: {}\n", .{err});
        return;
    };

    if (response.success) {
        std.debug.print("✓ Login successful!\n", .{});
        if (response.token != null and response.api_key != null) {
            try saveCredentials(allocator, response.token.?, response.api_key.?, email.?);
        }
    } else {
        std.debug.print("Login failed: {s}\n", .{response.message});
    }
}

fn handleWhoami(allocator: std.mem.Allocator) !void {
    const creds = try loadCredentials(allocator) orelse {
        std.debug.print("Not logged in. Run 'marathon login' or 'marathon register' first.\n", .{});
        return;
    };

    std.debug.print("Logged in as: {s}\n", .{creds.email});
    std.debug.print("API Key:      {s}...{s}\n", .{ creds.api_key[0..8], creds.api_key[creds.api_key.len - 4 ..] });
}

fn handleLogout(allocator: std.mem.Allocator) !void {
    try deleteCredentials(allocator);
    std.debug.print("✓ Logged out. Credentials removed.\n", .{});
}

// --- Workspace handlers ---

fn handleWorkspace(config: common.config.ClientConfig, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        printWorkspaceUsage();
        return;
    }

    const subcommand = parseWorkspaceSubcommand(args[0]) orelse {
        std.debug.print("Unknown workspace subcommand: {s}\n", .{args[0]});
        printWorkspaceUsage();
        return;
    };

    switch (subcommand) {
        .create => try handleWorkspaceCreate(config, allocator, args[1..]),
        .list => try handleWorkspaceList(config, allocator, args[1..]),
        .switch => try handleWorkspaceSwitch(config, allocator, args[1..]),
        .delete => try handleWorkspaceDelete(config, allocator, args[1..]),
        .current => try handleWorkspaceCurrent(config, allocator, args[1..]),
        .info => try handleWorkspaceInfo(config, allocator, args[1..]),
        .help => printWorkspaceUsage(),
    }
}

fn handleWorkspaceCreate(config: common.config.ClientConfig, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: workspace name required\n", .{});
        return;
    }

    const name = args[0];
    var template: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var settings: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--template")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --template requires a value\n", .{});
                return;
            }
            template = args[i];
        } else if (std.mem.eql(u8, args[i], "--description")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --description requires a value\n", .{});
                return;
            }
            description = args[i];
        } else if (std.mem.eql(u8, args[i], "--settings")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --settings requires a value\n", .{});
                return;
            }
            settings = args[i];
        }
    }

    var client = grpc.Client.init(allocator);
    defer client.close();

    client.connect(config.orchestrator_address, config.orchestrator_port, config.tls_enabled, config.tls_ca_path) catch |err| {
        std.debug.print("Error: Failed to connect to orchestrator: {}\n", .{err});
        return;
    };

    const request = protocol.WorkspaceCreateRequest{
        .name = name,
        .description = description,
        .template = template,
        .settings = settings,
    };

    var raw_response = client.callWithHeader(.workspace_create, request) catch |err| {
        std.debug.print("Error: Failed to create workspace: {}\n", .{err});
        return;
    };
    defer raw_response.deinit();

    if (raw_response.header.msg_type == .error_response) {
        const err_resp = raw_response.decodeAs(protocol.ErrorResponse) catch {
            std.debug.print("Error: Server returned an error (could not decode)\n", .{});
            return;
        };
        std.debug.print("Error: {s} — {s}\n", .{ err_resp.code, err_resp.message });
        return;
    }

    const response = raw_response.decodeAs(protocol.WorkspaceResponse) catch |err| {
        std.debug.print("Error: Failed to decode response: {}\n", .{err});
        return;
    };

    if (response.success) {
        if (response.workspace) |ws| {
            std.debug.print("✓ Workspace created: {s}\n", .{ws.name});
            if (ws.description) |desc| {
                std.debug.print("  Description: {s}\n", .{desc});
            }
            if (ws.template) |tmpl| {
                std.debug.print("  Template: {s}\n", .{tmpl});
            }
            std.debug.print("  ID: {s}\n", .{&types.formatId(ws.id)});

            if (response.env_vars.len > 0) {
                std.debug.print("  Environment Variables:\n");
                for (response.env_vars) |env_var| {
                    std.debug.print("    {s}={s}\n", .{ env_var.key, env_var.value });
                }
            }
        } else {
            std.debug.print("✓ Workspace created successfully\n", .{});
        }
    } else {
        std.debug.print("Failed to create workspace: {s}\n", .{response.message});
    }
}

fn handleWorkspaceList(config: common.config.ClientConfig, allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;

    var client = grpc.Client.init(allocator);
    defer client.close();

    client.connect(config.orchestrator_address, config.orchestrator_port, config.tls_enabled, config.tls_ca_path) catch |err| {
        std.debug.print("Error: Failed to connect to orchestrator: {}\n", .{err});
        return;
    };

    const request = protocol.WorkspaceListRequest{
        .limit = 50,
        .offset = 0,
    };

    var raw_response = client.callWithHeader(.workspace_list, request) catch |err| {
        std.debug.print("Error: Failed to list workspaces: {}\n", .{err});
        return;
    };
    defer raw_response.deinit();

    if (raw_response.header.msg_type == .error_response) {
        const err_resp = raw_response.decodeAs(protocol.ErrorResponse) catch {
            std.debug.print("Error: Server returned an error (could not decode)\n", .{});
            return;
        };
        std.debug.print("Error: {s} — {s}\n", .{ err_resp.code, err_resp.message });
        return;
    }

    const response = raw_response.decodeAs(protocol.WorkspaceListResponse) catch |err| {
        std.debug.print("Error: Failed to decode response: {}\n", .{err});
        return;
    };

    if (response.workspaces.len == 0) {
        std.debug.print("No workspaces found.\n", .{});
        return;
    }

    std.debug.print("Workspaces:\n");
    for (response.workspaces) |ws| {
        const active_indicator = if (ws.is_active) " (active)" else "";
        std.debug.print("  {s}{s}\n", .{ ws.name, active_indicator });
        if (ws.description) |desc| {
            std.debug.print("    Description: {s}\n", .{desc});
        }
        if (ws.template) |tmpl| {
            std.debug.print("    Template: {s}\n", .{tmpl});
        }
        std.debug.print("    Tasks: {d}\n", .{ws.task_count});
        std.debug.print("    Created: {d}\n", .{ws.created_at});
        std.debug.print("    Last accessed: {d}\n", .{ws.last_accessed_at});
        std.debug.print("    ID: {s}\n", .{&types.formatId(ws.id)});
        std.debug.print("\n");
    }
}

fn handleWorkspaceSwitch(config: common.config.ClientConfig, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: workspace name required\n", .{});
        return;
    }

    const name = args[0];

    var client = grpc.Client.init(allocator);
    defer client.close();

    client.connect(config.orchestrator_address, config.orchestrator_port, config.tls_enabled, config.tls_ca_path) catch |err| {
        std.debug.print("Error: Failed to connect to orchestrator: {}\n", .{err});
        return;
    };

    const request = protocol.WorkspaceSwitchRequest{
        .workspace_id = null,
        .name = name,
    };

    var raw_response = client.callWithHeader(.workspace_switch, request) catch |err| {
        std.debug.print("Error: Failed to switch workspace: {}\n", .{err});
        return;
    };
    defer raw_response.deinit();

    if (raw_response.header.msg_type == .error_response) {
        const err_resp = raw_response.decodeAs(protocol.ErrorResponse) catch {
            std.debug.print("Error: Server returned an error (could not decode)\n", .{});
            return;
        };
        std.debug.print("Error: {s} — {s}\n", .{ err_resp.code, err_resp.message });
        return;
    }

    const response = raw_response.decodeAs(protocol.WorkspaceResponse) catch |err| {
        std.debug.print("Error: Failed to decode response: {}\n", .{err});
        return;
    };

    if (response.success) {
        std.debug.print("✓ Switched to workspace: {s}\n", .{name});
    } else {
        std.debug.print("Failed to switch workspace: {s}\n", .{response.message});
    }
}

fn handleWorkspaceDelete(config: common.config.ClientConfig, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: workspace name required\n", .{});
        return;
    }

    const name = args[0];

    // First get the workspace ID by name
    var client = grpc.Client.init(allocator);
    defer client.close();

    client.connect(config.orchestrator_address, config.orchestrator_port, config.tls_enabled, config.tls_ca_path) catch |err| {
        std.debug.print("Error: Failed to connect to orchestrator: {}\n", .{err});
        return;
    };

    const get_request = protocol.WorkspaceGetRequest{
        .workspace_id = null,
        .name = name,
    };

    var get_response = client.callWithHeader(.workspace_get, get_request) catch |err| {
        std.debug.print("Error: Failed to get workspace: {}\n", .{err});
        return;
    };
    defer get_response.deinit();

    if (get_response.header.msg_type == .error_response) {
        std.debug.print("Error: Workspace not found: {s}\n", .{name});
        return;
    }

    const workspace_response = get_response.decodeAs(protocol.WorkspaceResponse) catch |err| {
        std.debug.print("Error: Failed to decode response: {}\n", .{err});
        return;
    };

    if (!workspace_response.success or workspace_response.workspace == null) {
        std.debug.print("Error: Workspace not found: {s}\n", .{name});
        return;
    }

    const workspace_id = workspace_response.workspace.?.id;

    // Confirm deletion
    std.debug.print("Are you sure you want to delete workspace '{s}'? [y/N]: ", .{name});
    const stdin = std.io.getStdIn().reader();
    var buf: [10]u8 = undefined;
    if (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |input| {
        if (input.len == 0 or !(std.mem.eql(u8, input, "y") or std.mem.eql(u8, input, "Y") or std.mem.eql(u8, input, "yes"))) {
            std.debug.print("Deletion cancelled.\n", .{});
            return;
        }
    } else {
        std.debug.print("Deletion cancelled.\n", .{});
        return;
    }

    const delete_request = protocol.WorkspaceDeleteRequest{
        .workspace_id = workspace_id,
    };

    var delete_response = client.callWithHeader(.workspace_delete, delete_request) catch |err| {
        std.debug.print("Error: Failed to delete workspace: {}\n", .{err});
        return;
    };
    defer delete_response.deinit();

    if (delete_response.header.msg_type == .error_response) {
        const err_resp = delete_response.decodeAs(protocol.ErrorResponse) catch {
            std.debug.print("Error: Server returned an error (could not decode)\n", .{});
            return;
        };
        std.debug.print("Error: {s} — {s}\n", .{ err_resp.code, err_resp.message });
        return;
    }

    const response = delete_response.decodeAs(protocol.WorkspaceResponse) catch |err| {
        std.debug.print("Error: Failed to decode response: {}\n", .{err});
        return;
    };

    if (response.success) {
        std.debug.print("✓ Workspace deleted: {s}\n", .{name});
    } else {
        std.debug.print("Failed to delete workspace: {s}\n", .{response.message});
    }
}

fn handleWorkspaceCurrent(config: common.config.ClientConfig, allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;

    var client = grpc.Client.init(allocator);
    defer client.close();

    client.connect(config.orchestrator_address, config.orchestrator_port, config.tls_enabled, config.tls_ca_path) catch |err| {
        std.debug.print("Error: Failed to connect to orchestrator: {}\n", .{err});
        return;
    };

    const request = protocol.WorkspaceCurrentRequest{};

    var raw_response = client.callWithHeader(.workspace_current, request) catch |err| {
        std.debug.print("Error: Failed to get current workspace: {}\n", .{err});
        return;
    };
    defer raw_response.deinit();

    if (raw_response.header.msg_type == .error_response) {
        const err_resp = raw_response.decodeAs(protocol.ErrorResponse) catch {
            std.debug.print("Error: Server returned an error (could not decode)\n", .{});
            return;
        };
        std.debug.print("Error: {s} — {s}\n", .{ err_resp.code, err_resp.message });
        return;
    }

    const response = raw_response.decodeAs(protocol.WorkspaceResponse) catch |err| {
        std.debug.print("Error: Failed to decode response: {}\n", .{err});
        return;
    };

    if (response.success and response.workspace != null) {
        const ws = response.workspace.?;
        std.debug.print("Current workspace: {s}\n", .{ws.name});
        if (ws.description) |desc| {
            std.debug.print("  Description: {s}\n", .{desc});
        }
        if (ws.template) |tmpl| {
            std.debug.print("  Template: {s}\n", .{tmpl});
        }
        std.debug.print("  ID: {s}\n", .{&types.formatId(ws.id)});
        std.debug.print("  Created: {d}\n", .{ws.created_at});
        std.debug.print("  Last accessed: {d}\n", .{ws.last_accessed_at});

        if (response.env_vars.len > 0) {
            std.debug.print("  Environment Variables:\n");
            for (response.env_vars) |env_var| {
                std.debug.print("    {s}={s}\n", .{ env_var.key, env_var.value });
            }
        }
    } else {
        std.debug.print("No active workspace. Create one with 'marathon workspace create <name>'.\n", .{});
    }
}

fn handleWorkspaceInfo(config: common.config.ClientConfig, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var name: ?[]const u8 = null;
    if (args.len > 0) {
        name = args[0];
    }

    var client = grpc.Client.init(allocator);
    defer client.close();

    client.connect(config.orchestrator_address, config.orchestrator_port, config.tls_enabled, config.tls_ca_path) catch |err| {
        std.debug.print("Error: Failed to connect to orchestrator: {}\n", .{err});
        return;
    };

    const request = protocol.WorkspaceGetRequest{
        .workspace_id = null,
        .name = name,
    };

    var raw_response = client.callWithHeader(.workspace_get, request) catch |err| {
        std.debug.print("Error: Failed to get workspace: {}\n", .{err});
        return;
    };
    defer raw_response.deinit();

    if (raw_response.header.msg_type == .error_response) {
        const err_resp = raw_response.decodeAs(protocol.ErrorResponse) catch {
            std.debug.print("Error: Server returned an error (could not decode)\n", .{});
            return;
        };
        std.debug.print("Error: {s} — {s}\n", .{ err_resp.code, err_resp.message });
        return;
    }

    const response = raw_response.decodeAs(protocol.WorkspaceResponse) catch |err| {
        std.debug.print("Error: Failed to decode response: {}\n", .{err});
        return;
    };

    if (response.success and response.workspace != null) {
        const ws = response.workspace.?;
        const workspace_type = if (name) |_| "Workspace" else "Current workspace";
        std.debug.print("{s}: {s}\n", .{ workspace_type, ws.name });
        if (ws.description) |desc| {
            std.debug.print("  Description: {s}\n", .{desc});
        }
        if (ws.template) |tmpl| {
            std.debug.print("  Template: {s}\n", .{tmpl});
        }
        std.debug.print("  ID: {s}\n", .{&types.formatId(ws.id)});
        std.debug.print("  Created: {d}\n", .{ws.created_at});
        std.debug.print("  Updated: {d}\n", .{ws.updated_at});
        std.debug.print("  Last accessed: {d}\n", .{ws.last_accessed_at});

        if (!std.mem.eql(u8, ws.settings, "{}")) {
            std.debug.print("  Settings: {s}\n", .{ws.settings});
        }

        if (response.env_vars.len > 0) {
            std.debug.print("  Environment Variables:\n");
            for (response.env_vars) |env_var| {
                std.debug.print("    {s}={s}\n", .{ env_var.key, env_var.value });
            }
        }
    } else {
        const not_found_msg = if (name) |n| 
            std.fmt.allocPrint(allocator, "Workspace not found: {s}", .{n}) catch "Workspace not found" 
        else 
            "No active workspace";
        std.debug.print("{s}\n", .{not_found_msg});
        if (name == null) {
            std.debug.print("Create one with 'marathon workspace create <name>'.\n", .{});
        }
    }
}

// --- Existing handlers (same as before) ---

fn handleSubmit(config: common.config.ClientConfig, args: []const []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var repo: ?[]const u8 = null;
    var branch: []const u8 = "main";
    var prompt: ?[]const u8 = null;
    var workspace_name: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, arg, "--workspace")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --workspace requires a value\n", .{});
                return;
            }
            workspace_name = args[i];
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

    // Get workspace ID if workspace name is specified
    var workspace_id: ?types.WorkspaceId = null;
    if (workspace_name) |ws_name| {
        const get_request = protocol.WorkspaceGetRequest{
            .workspace_id = null,
            .name = ws_name,
        };

        var ws_response = client.callWithHeader(.workspace_get, get_request) catch |err| {
            std.debug.print("Error: Failed to get workspace '{s}': {}\n", .{ ws_name, err });
            return;
        };
        defer ws_response.deinit();

        if (ws_response.header.msg_type == .workspace_response) {
            const ws_result = ws_response.decodeAs(protocol.WorkspaceResponse) catch {
                std.debug.print("Error: Failed to decode workspace response\n", .{});
                return;
            };
            if (ws_result.success and ws_result.workspace != null) {
                workspace_id = ws_result.workspace.?.id;
                std.debug.print("Using workspace: {s}\n", .{ws_name});
            } else {
                std.debug.print("Error: Workspace not found: {s}\n", .{ws_name});
                return;
            }
        } else {
            std.debug.print("Error: Failed to find workspace: {s}\n", .{ws_name});
            return;
        }
    }

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
        .workspace_id = workspace_id,
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
    std.debug.print("⏳ Task submitted: {s}\n", .{&task_id_str});
    std.debug.print("📋 State: {s}\n", .{@tagName(event.state)});

    // Close the submit connection and poll with get_task + get_task_events
    client.close();
    var poll_client = grpc.Client.init(allocator);
    defer poll_client.close();

    poll_client.connect(config.orchestrator_address, config.orchestrator_port, config.tls_enabled, config.tls_ca_path) catch |err| {
        std.debug.print("⚠️  Failed to connect for follow mode: {}\n", .{err});
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
                std.debug.print("⚠️  Connection lost: {}\n", .{err});
                break;
            };
            defer simple_resp.deinit();

            if (simple_resp.header.msg_type == .task_response) {
                const r = simple_resp.decodeAs(protocol.TaskResponse) catch continue;
                if (r.state != last_state) {
                    last_state = r.state;
                    printStateChange(r.state);
                }
                if (r.state.isTerminal()) {
                    if (r.error_message) |msg| std.debug.print("   Error: {s}\n", .{msg});
                    if (r.pr_url) |url| std.debug.print("   PR: {s}\n", .{url});
                    break;
                }
            }
            common.compat.sleep(2 * std.time.ns_per_s);
            continue;
        };
        defer status_resp.deinit();

        if (status_resp.header.msg_type == .task_events_response) {
            const events_resp = status_resp.decodeAs(protocol.TaskEventsResponse) catch {
                common.compat.sleep(2 * std.time.ns_per_s);
                continue;
            };

            if (events_resp.state != last_state) {
                last_state = events_resp.state;
                printStateChange(events_resp.state);
            }

            for (events_resp.events) |evt| {
                if (evt.data.len > 0) {
                    std.debug.print("📋 {s}\n", .{evt.data});
                }
            }

            if (events_resp.state.isTerminal()) {
                if (events_resp.error_message) |msg| std.debug.print("   Error: {s}\n", .{msg});
                if (events_resp.pr_url) |url| std.debug.print("   PR: {s}\n", .{url});
                break;
            }
        }

        common.compat.sleep(2 * std.time.ns_per_s);
    }
}

fn printStateChange(state: types.TaskState) void {
    const icon: []const u8 = switch (state) {
        .queued => "⏳",
        .starting => "🖥️ ",
        .running => "🔥",
        .completed => "✅",
        .failed => "❌",
        .cancelled => "🚫",
        .unspecified => "❓",
    };
    std.debug.print("{s} State: {s}\n", .{ icon, @tagName(state) });
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
    try std.testing.expectEqual(Command.login, parseCommand("login").?);
    try std.testing.expectEqual(Command.register, parseCommand("register").?);
    try std.testing.expectEqual(Command.whoami, parseCommand("whoami").?);
    try std.testing.expectEqual(Command.logout, parseCommand("logout").?);
    try std.testing.expectEqual(Command.workspace, parseCommand("workspace").?);
    try std.testing.expectEqual(Command.help, parseCommand("help").?);
    try std.testing.expect(parseCommand("invalid") == null);
}

test "workspace subcommand parsing" {
    try std.testing.expectEqual(WorkspaceSubcommand.create, parseWorkspaceSubcommand("create").?);
    try std.testing.expectEqual(WorkspaceSubcommand.list, parseWorkspaceSubcommand("list").?);
    try std.testing.expectEqual(WorkspaceSubcommand.switch, parseWorkspaceSubcommand("switch").?);
    try std.testing.expectEqual(WorkspaceSubcommand.current, parseWorkspaceSubcommand("current").?);
    try std.testing.expect(parseWorkspaceSubcommand("invalid") == null);
}