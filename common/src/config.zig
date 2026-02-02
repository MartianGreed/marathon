const std = @import("std");

pub const DotEnv = struct {
    map: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    keys: std.ArrayListUnmanaged([]const u8),
    values: std.ArrayListUnmanaged([]const u8),

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !?DotEnv {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        var env = DotEnv{
            .map = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
            .keys = .empty,
            .values = .empty,
        };

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                var value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

                // Strip quotes
                if (value.len >= 2) {
                    if ((value[0] == '"' and value[value.len - 1] == '"') or
                        (value[0] == '\'' and value[value.len - 1] == '\''))
                    {
                        value = value[1 .. value.len - 1];
                    }
                }

                const owned_key = try allocator.dupe(u8, key);
                const owned_value = try allocator.dupe(u8, value);
                try env.keys.append(allocator, owned_key);
                try env.values.append(allocator, owned_value);
                try env.map.put(owned_key, owned_value);
            }
        }

        return env;
    }

    pub fn get(self: *const DotEnv, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn deinit(self: *DotEnv) void {
        for (self.keys.items) |key| {
            self.allocator.free(key);
        }
        for (self.values.items) |value| {
            self.allocator.free(value);
        }
        self.keys.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.map.deinit();
    }
};

pub const OrchestratorConfig = struct {
    listen_address: []const u8 = "0.0.0.0",
    listen_port: u16 = 8080,

    node_timeout_ms: u64 = 30_000,
    heartbeat_interval_ms: u64 = 5_000,

    etcd_endpoints: []const []const u8 = &[_][]const u8{"localhost:2379"},
    redis_url: []const u8 = "redis://localhost:6379",
    postgres_url: []const u8 = "postgresql://marathon:marathon@localhost:5432/marathon",

    anthropic_api_key: []const u8 = "",

    tls_cert_path: ?[]const u8 = null,
    tls_key_path: ?[]const u8 = null,

    node_auth_key: ?[]const u8 = null,

    pub fn fromEnv(allocator: std.mem.Allocator) !OrchestratorConfig {
        var config = OrchestratorConfig{};

        if (std.posix.getenv("MARATHON_LISTEN_ADDRESS")) |v| {
            config.listen_address = try allocator.dupe(u8, v);
        }

        if (std.posix.getenv("MARATHON_LISTEN_PORT")) |v| {
            config.listen_port = try std.fmt.parseInt(u16, v, 10);
        }

        if (std.posix.getenv("MARATHON_ANTHROPIC_API_KEY")) |v| {
            config.anthropic_api_key = try allocator.dupe(u8, v);
        }

        if (std.posix.getenv("MARATHON_REDIS_URL")) |v| {
            config.redis_url = try allocator.dupe(u8, v);
        }

        if (std.posix.getenv("MARATHON_POSTGRES_URL")) |v| {
            config.postgres_url = try allocator.dupe(u8, v);
        }

        if (std.posix.getenv("MARATHON_NODE_AUTH_KEY")) |v| {
            config.node_auth_key = try allocator.dupe(u8, v);
        }

        return config;
    }
};

pub const NodeOperatorConfig = struct {
    node_id: ?[]const u8 = null,
    hostname: ?[]const u8 = null,

    listen_address: []const u8 = "0.0.0.0",
    listen_port: u16 = 8081,

    orchestrator_address: []const u8 = "127.0.0.1",
    orchestrator_port: u16 = 8080,

    heartbeat_interval_ms: u64 = 5_000,

    total_vm_slots: u32 = 10,
    warm_pool_target: u32 = 5,

    firecracker_bin: []const u8 = "/usr/bin/firecracker",
    jailer_bin: []const u8 = "/usr/bin/jailer",

    snapshot_path: []const u8 = "/tmp/marathon/snapshots",
    rootfs_path: []const u8 = "/tmp/marathon/rootfs",
    kernel_path: []const u8 = "/tmp/marathon/kernel/vmlinux",

    vsock_port: u32 = 9999,

    task_timeout_ms: u64 = 600_000,
    max_tokens_per_task: u64 = 100_000,

    auth_key: ?[]const u8 = null,

    tls_enabled: bool = false,
    tls_ca_path: ?[]const u8 = null,

    pub fn fromEnv(allocator: std.mem.Allocator) !NodeOperatorConfig {
        var config = NodeOperatorConfig{};

        if (std.posix.getenv("MARATHON_NODE_ID")) |v| {
            config.node_id = try allocator.dupe(u8, v);
        }

        if (std.posix.getenv("HOSTNAME")) |v| {
            config.hostname = try allocator.dupe(u8, v);
        }

        if (std.posix.getenv("MARATHON_ORCHESTRATOR_ADDRESS")) |v| {
            config.orchestrator_address = try allocator.dupe(u8, v);
        }

        if (std.posix.getenv("MARATHON_ORCHESTRATOR_PORT")) |v| {
            config.orchestrator_port = try std.fmt.parseInt(u16, v, 10);
        }

        if (std.posix.getenv("MARATHON_TOTAL_VM_SLOTS")) |v| {
            config.total_vm_slots = try std.fmt.parseInt(u32, v, 10);
        }

        if (std.posix.getenv("MARATHON_WARM_POOL_TARGET")) |v| {
            config.warm_pool_target = try std.fmt.parseInt(u32, v, 10);
        }

        if (std.posix.getenv("MARATHON_SNAPSHOT_PATH")) |v| {
            config.snapshot_path = try allocator.dupe(u8, v);
        }

        if (std.posix.getenv("MARATHON_FIRECRACKER_BIN")) |v| {
            config.firecracker_bin = try allocator.dupe(u8, v);
        }

        if (std.posix.getenv("MARATHON_NODE_AUTH_KEY")) |v| {
            config.auth_key = try allocator.dupe(u8, v);
        }

        if (std.posix.getenv("MARATHON_TLS_ENABLED")) |v| {
            config.tls_enabled = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        }

        if (std.posix.getenv("MARATHON_TLS_CA_PATH")) |v| {
            config.tls_ca_path = try allocator.dupe(u8, v);
        }

        return config;
    }
};

pub const VmAgentConfig = struct {
    vsock_port: u32 = 9999,
    claude_code_path: []const u8 = "/usr/local/bin/claude",
    work_dir: []const u8 = "/workspace",
    prompt_template: []const u8 = "{prompt}",
    cleanup_strategy: []const u8 = "full",

    pub fn fromEnv(allocator: std.mem.Allocator) !VmAgentConfig {
        var config = VmAgentConfig{};

        if (std.posix.getenv("MARATHON_VSOCK_PORT")) |v| {
            config.vsock_port = try std.fmt.parseInt(u32, v, 10);
        }

        if (std.posix.getenv("MARATHON_CLAUDE_CODE_PATH")) |v| {
            config.claude_code_path = try allocator.dupe(u8, v);
        }

        if (std.posix.getenv("MARATHON_WORK_DIR")) |v| {
            config.work_dir = try allocator.dupe(u8, v);
        }

        if (std.posix.getenv("MARATHON_PROMPT_TEMPLATE")) |v| {
            config.prompt_template = try allocator.dupe(u8, v);
        }

        if (std.posix.getenv("MARATHON_CLEANUP_STRATEGY")) |v| {
            config.cleanup_strategy = try allocator.dupe(u8, v);
        }

        return config;
    }
};

pub const ClientConfig = struct {
    allocator: ?std.mem.Allocator = null,
    orchestrator_address: []const u8 = "127.0.0.1",
    orchestrator_port: u16 = 8080,

    github_token: ?[]const u8 = null,

    tls_enabled: bool = false,
    tls_ca_path: ?[]const u8 = null,

    // Track which fields were allocated (from dotenv) vs borrowed (from system env)
    allocated_address: bool = false,
    allocated_token: bool = false,

    pub fn deinit(self: *ClientConfig) void {
        if (self.allocator) |alloc| {
            if (self.allocated_address) {
                alloc.free(self.orchestrator_address);
            }
            if (self.allocated_token) {
                if (self.github_token) |token| {
                    alloc.free(token);
                }
            }
        }
    }

    pub fn fromEnv(allocator: std.mem.Allocator) !ClientConfig {
        var config = ClientConfig{ .allocator = allocator };

        var dotenv = try DotEnv.load(allocator, ".env");
        defer if (dotenv) |*env| env.deinit();

        // System env: use pointer directly (persists for program lifetime)
        // Dotenv: must dupe (freed when dotenv.deinit called)
        if (std.posix.getenv("MARATHON_ORCHESTRATOR_ADDRESS")) |v| {
            config.orchestrator_address = v;
        } else if (dotenv) |*env| {
            if (env.get("MARATHON_ORCHESTRATOR_ADDRESS")) |v| {
                config.orchestrator_address = try allocator.dupe(u8, v);
                config.allocated_address = true;
            }
        }

        if (std.posix.getenv("MARATHON_ORCHESTRATOR_PORT")) |v| {
            config.orchestrator_port = try std.fmt.parseInt(u16, v, 10);
        } else if (dotenv) |*env| {
            if (env.get("MARATHON_ORCHESTRATOR_PORT")) |v| {
                config.orchestrator_port = try std.fmt.parseInt(u16, v, 10);
            }
        }

        if (std.posix.getenv("MARATHON_TLS_ENABLED")) |v| {
            config.tls_enabled = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        } else if (dotenv) |*env| {
            if (env.get("MARATHON_TLS_ENABLED")) |v| {
                config.tls_enabled = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
            }
        }

        if (!config.tls_enabled and config.orchestrator_port == 443) {
            const explicit = if (std.posix.getenv("MARATHON_TLS_ENABLED")) |_| true else if (dotenv) |*env| env.get("MARATHON_TLS_ENABLED") != null else false;
            if (!explicit) config.tls_enabled = true;
        }

        if (std.posix.getenv("MARATHON_TLS_CA_PATH")) |v| {
            config.tls_ca_path = v;
        } else if (dotenv) |*env| {
            if (env.get("MARATHON_TLS_CA_PATH")) |v| {
                config.tls_ca_path = try allocator.dupe(u8, v);
            }
        }

        if (std.posix.getenv("GITHUB_TOKEN")) |v| {
            config.github_token = v;
        } else if (dotenv) |*env| {
            if (env.get("GITHUB_TOKEN")) |v| {
                config.github_token = try allocator.dupe(u8, v);
                config.allocated_token = true;
            }
        }

        return config;
    }
};

test "config from env" {
    const allocator = std.testing.allocator;
    const config = try OrchestratorConfig.fromEnv(allocator);
    try std.testing.expectEqual(@as(u16, 8080), config.listen_port);
}
