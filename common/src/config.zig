const std = @import("std");

pub const OrchestratorConfig = struct {
    listen_address: []const u8 = "0.0.0.0",
    listen_port: u16 = 8080,

    node_timeout_ms: u64 = 30_000,
    heartbeat_interval_ms: u64 = 5_000,

    etcd_endpoints: []const []const u8 = &[_][]const u8{"localhost:2379"},
    redis_url: []const u8 = "redis://localhost:6379",
    postgres_url: []const u8 = "postgresql://localhost/marathon",

    anthropic_api_key: []const u8 = "",

    tls_cert_path: ?[]const u8 = null,
    tls_key_path: ?[]const u8 = null,

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

        return config;
    }
};

pub const NodeOperatorConfig = struct {
    node_id: ?[]const u8 = null,
    hostname: ?[]const u8 = null,

    listen_address: []const u8 = "0.0.0.0",
    listen_port: u16 = 8081,

    orchestrator_address: []const u8 = "localhost",
    orchestrator_port: u16 = 8080,

    heartbeat_interval_ms: u64 = 5_000,

    total_vm_slots: u32 = 10,
    warm_pool_target: u32 = 5,

    firecracker_bin: []const u8 = "/usr/bin/firecracker",
    jailer_bin: []const u8 = "/usr/bin/jailer",

    snapshot_path: []const u8 = "/var/lib/marathon/snapshots",
    rootfs_path: []const u8 = "/var/lib/marathon/rootfs",
    kernel_path: []const u8 = "/var/lib/marathon/kernel/vmlinux",

    vsock_port: u32 = 9999,

    task_timeout_ms: u64 = 600_000,
    max_tokens_per_task: u64 = 100_000,

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

        return config;
    }
};

pub const VmAgentConfig = struct {
    vsock_port: u32 = 9999,
    claude_code_path: []const u8 = "/usr/local/bin/claude",
    work_dir: []const u8 = "/workspace",

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

        return config;
    }
};

pub const ClientConfig = struct {
    orchestrator_address: []const u8 = "localhost",
    orchestrator_port: u16 = 8080,

    github_token: ?[]const u8 = null,

    tls_enabled: bool = false,
    tls_ca_path: ?[]const u8 = null,

    pub fn fromEnv(allocator: std.mem.Allocator) !ClientConfig {
        var config = ClientConfig{};

        if (std.posix.getenv("MARATHON_ORCHESTRATOR_ADDRESS")) |v| {
            config.orchestrator_address = try allocator.dupe(u8, v);
        }

        if (std.posix.getenv("MARATHON_ORCHESTRATOR_PORT")) |v| {
            config.orchestrator_port = try std.fmt.parseInt(u16, v, 10);
        }

        if (std.posix.getenv("GITHUB_TOKEN")) |v| {
            config.github_token = try allocator.dupe(u8, v);
        }

        return config;
    }
};

test "config from env" {
    const allocator = std.testing.allocator;
    const config = try OrchestratorConfig.fromEnv(allocator);
    try std.testing.expectEqual(@as(u16, 8080), config.listen_port);
}
