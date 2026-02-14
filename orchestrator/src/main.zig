const std = @import("std");
const common = @import("common");

const scheduler = @import("scheduler/scheduler.zig");
const registry = @import("registry/registry.zig");
const metering = @import("metering/metering.zig");
const auth = @import("auth/auth.zig");
const grpc_server = @import("grpc/server.zig");
const http_server = @import("http/server.zig");
const db = @import("db/root.zig");
const analytics = @import("analytics/analytics.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try common.config.OrchestratorConfig.fromEnv(allocator);

    std.log.info("Marathon Orchestrator starting...", .{});
    std.log.info("gRPC Listen: {s}:{d}", .{ config.listen_address, config.listen_port });
    std.log.info("HTTP Listen: {s}:{d}", .{ config.listen_address, config.listen_port + 1 });

    const db_pool = initDatabase(allocator, config.postgres_url) catch |err| {
        std.log.warn("database init failed: {} - running without persistence", .{err});
        return runWithoutDb(allocator, config);
    };
    defer db_pool.deinit();

    var task_repo = db.TaskRepository.init(allocator, db_pool);
    var node_repo = db.NodeRepository.init(allocator, db_pool);
    var usage_repo = db.UsageRepository.init(allocator, db_pool);
    var user_repo = db.UserRepository.init(allocator, db_pool);

    std.log.info("database connected and migrations applied", .{});

    var node_registry = registry.NodeRegistry.init(allocator);
    defer node_registry.deinit();

    var task_scheduler = scheduler.Scheduler.init(allocator, &node_registry);
    defer task_scheduler.deinit();

    var meter = metering.Metering.init(allocator);
    defer meter.deinit();

    var authenticator = if (config.jwt_secret) |secret|
        auth.Authenticator.initWithSecret(allocator, config.anthropic_api_key, secret)
    else
        auth.Authenticator.init(allocator, config.anthropic_api_key);
    defer authenticator.deinit();

    var grpc_srv = grpc_server.Server.init(
        allocator,
        &task_scheduler,
        &node_registry,
        &meter,
        &authenticator,
        config.node_auth_key,
        config.anthropic_api_key,
    );
    defer grpc_srv.deinit();

    grpc_srv.setRepositories(&task_repo, &node_repo, &usage_repo);
    grpc_srv.setUserRepository(&user_repo);

    // Initialize HTTP server
    var http_srv = http_server.HttpServer.init(
        allocator,
        &grpc_srv,
        db_pool,
        &authenticator,
    ) catch |err| {
        std.log.err("Failed to initialize HTTP server: {}", .{err});
        return;
    };
    defer http_srv.deinit();

    try grpc_srv.listen(config.listen_address, config.listen_port);
    try http_srv.listen(config.listen_address, config.listen_port + 1);
    
    std.log.info("Orchestrator ready and listening (gRPC + HTTP)", .{});

    // Start HTTP server in a separate thread
    const http_thread = try std.Thread.spawn(.{}, runHttpServer, .{&http_srv});
    http_thread.detach();

    // Run gRPC server in main thread
    try grpc_srv.run();
}

fn runHttpServer(http_srv: *http_server.HttpServer) void {
    http_srv.run() catch |err| {
        std.log.err("HTTP server error: {}", .{err});
    };
}

fn initDatabase(allocator: std.mem.Allocator, postgres_url: []const u8) !*db.Pool {
    const conn_config = try db.ConnConfig.fromUrl(postgres_url, allocator);

    const pool_config = db.PoolConfig{
        .min_connections = 2,
        .max_connections = 10,
        .idle_timeout_ms = 300_000,
        .max_lifetime_ms = 1_800_000,
    };

    const db_pool = try db.Pool.init(allocator, conn_config, pool_config);
    errdefer db_pool.deinit();

    var runner = db.MigrationRunner.init(allocator, db_pool);
    try runner.run();

    return db_pool;
}

fn runWithoutDb(allocator: std.mem.Allocator, config: common.config.OrchestratorConfig) !void {
    var node_registry = registry.NodeRegistry.init(allocator);
    defer node_registry.deinit();

    var task_scheduler = scheduler.Scheduler.init(allocator, &node_registry);
    defer task_scheduler.deinit();

    var meter = metering.Metering.init(allocator);
    defer meter.deinit();

    var authenticator = if (config.jwt_secret) |secret|
        auth.Authenticator.initWithSecret(allocator, config.anthropic_api_key, secret)
    else
        auth.Authenticator.init(allocator, config.anthropic_api_key);
    defer authenticator.deinit();

    var grpc_srv = grpc_server.Server.init(
        allocator,
        &task_scheduler,
        &node_registry,
        &meter,
        &authenticator,
        config.node_auth_key,
        config.anthropic_api_key,
    );
    defer grpc_srv.deinit();

    try grpc_srv.listen(config.listen_address, config.listen_port);
    std.log.info("Orchestrator ready and listening (no persistence)", .{});

    try grpc_srv.run();
}

test {
    _ = scheduler;
    _ = registry;
    _ = metering;
    _ = auth;
    _ = db;
    _ = analytics;
    _ = http_server;
}