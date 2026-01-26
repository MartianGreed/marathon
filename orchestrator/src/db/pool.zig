const std = @import("std");
const connection = @import("connection.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");

const Connection = connection.Connection;
const ConnConfig = connection.ConnConfig;
const DbError = errors.DbError;
const log = std.log.scoped(.db_pool);

pub const PoolConfig = struct {
    min_connections: u32 = 2,
    max_connections: u32 = 10,
    idle_timeout_ms: u64 = 300_000,
    max_lifetime_ms: u64 = 1_800_000,
    acquire_timeout_ms: u64 = 30_000,
    health_check_interval_ms: u64 = 30_000,
};

const PooledConnection = struct {
    conn: *Connection,
    created_at: i64,
    last_used_at: i64,
    in_use: bool,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    config: PoolConfig,
    conn_config: ConnConfig,
    connections: std.ArrayListUnmanaged(PooledConnection),
    mutex: std.Thread.Mutex,
    not_empty: std.Thread.Condition,
    closed: bool,
    total_created: u64,
    total_acquired: u64,
    total_released: u64,

    pub fn init(allocator: std.mem.Allocator, conn_config: ConnConfig, pool_config: PoolConfig) !*Pool {
        if (pool_config.min_connections > pool_config.max_connections) {
            log.err("invalid pool config: min_connections ({d}) > max_connections ({d})", .{
                pool_config.min_connections,
                pool_config.max_connections,
            });
            return DbError.InvalidConfig;
        }

        const pool = try allocator.create(Pool);
        errdefer allocator.destroy(pool);

        pool.* = .{
            .allocator = allocator,
            .config = pool_config,
            .conn_config = conn_config,
            .connections = .empty,
            .mutex = .{},
            .not_empty = .{},
            .closed = false,
            .total_created = 0,
            .total_acquired = 0,
            .total_released = 0,
        };

        var created: u32 = 0;
        var last_err: ?anyerror = null;
        for (0..pool_config.min_connections) |_| {
            pool.createConnection() catch |err| {
                log.warn("failed to create initial connection: {}", .{err});
                last_err = err;
                continue;
            };
            created += 1;
        }

        if (created == 0 and pool_config.min_connections > 0) {
            log.err("pool init failed: could not create any connections", .{});
            allocator.destroy(pool);
            return last_err orelse DbError.ConnectionFailed;
        }

        log.info("pool initialized: min={d} max={d} created={d}", .{
            pool_config.min_connections,
            pool_config.max_connections,
            pool.connections.items.len,
        });

        return pool;
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lock();
        self.closed = true;

        for (self.connections.items) |*pc| {
            pc.conn.close();
        }
        self.connections.deinit(self.allocator);

        self.mutex.unlock();
        self.allocator.destroy(self);
    }

    fn createConnection(self: *Pool) !void {
        const conn = Connection.connect(self.allocator, self.conn_config) catch |err| {
            log.err("connection create failed: {}", .{err});
            return err;
        };

        const now = std.time.milliTimestamp();
        try self.connections.append(self.allocator, .{
            .conn = conn,
            .created_at = now,
            .last_used_at = now,
            .in_use = false,
        });
        self.total_created += 1;
    }

    pub fn acquire(self: *Pool) !PooledConn {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(self.config.acquire_timeout_ms));

        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            if (self.closed) return DbError.PoolClosed;

            for (self.connections.items) |*pc| {
                if (!pc.in_use) {
                    if (!self.isConnectionValid(pc)) {
                        self.removeConnection(pc);
                        continue;
                    }
                    pc.in_use = true;
                    pc.last_used_at = std.time.milliTimestamp();
                    self.total_acquired += 1;
                    return .{ .pool = self, .conn = pc.conn };
                }
            }

            if (self.connections.items.len < self.config.max_connections) {
                self.createConnection() catch |err| {
                    log.warn("failed to create connection: {}", .{err});
                    if (std.time.milliTimestamp() >= deadline) return DbError.PoolExhausted;
                    continue;
                };

                const pc = &self.connections.items[self.connections.items.len - 1];
                pc.in_use = true;
                self.total_acquired += 1;
                return .{ .pool = self, .conn = pc.conn };
            }

            if (std.time.milliTimestamp() >= deadline) {
                log.warn("acquire timeout: active={d} max={d}", .{ self.activeCount(), self.config.max_connections });
                return DbError.PoolExhausted;
            }

            self.not_empty.timedWait(&self.mutex, @intCast(self.config.acquire_timeout_ms * 1_000_000)) catch {};
        }
    }

    fn release(self: *Pool, conn: *Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |*pc| {
            if (pc.conn == conn) {
                pc.in_use = false;
                pc.last_used_at = std.time.milliTimestamp();
                self.total_released += 1;
                self.not_empty.signal();
                return;
            }
        }

        conn.close();
    }

    fn isConnectionValid(self: *Pool, pc: *PooledConnection) bool {
        const now = std.time.milliTimestamp();

        if (now - pc.created_at > @as(i64, @intCast(self.config.max_lifetime_ms))) {
            log.debug("connection expired: lifetime exceeded", .{});
            return false;
        }

        if (now - pc.last_used_at > @as(i64, @intCast(self.config.idle_timeout_ms))) {
            log.debug("connection expired: idle timeout", .{});
            return false;
        }

        if (!pc.conn.connected or pc.conn.tx_status == .failed) {
            log.debug("connection unhealthy", .{});
            return false;
        }

        return true;
    }

    fn removeConnection(self: *Pool, pc: *PooledConnection) void {
        pc.conn.close();

        for (self.connections.items, 0..) |*item, i| {
            if (item == pc) {
                _ = self.connections.orderedRemove(i);
                break;
            }
        }
    }

    pub fn runHealthCheck(self: *Pool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.connections.items.len) {
            const pc = &self.connections.items[i];
            if (!pc.in_use and !self.isConnectionValid(pc)) {
                self.removeConnection(pc);
            } else {
                i += 1;
            }
        }

        while (self.connections.items.len < self.config.min_connections) {
            self.createConnection() catch break;
        }
    }

    fn activeCount(self: *Pool) u32 {
        var count: u32 = 0;
        for (self.connections.items) |pc| {
            if (pc.in_use) count += 1;
        }
        return count;
    }

    pub fn stats(self: *Pool) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var active: u32 = 0;
        var idle: u32 = 0;
        for (self.connections.items) |pc| {
            if (pc.in_use) {
                active += 1;
            } else {
                idle += 1;
            }
        }

        return .{
            .total = @intCast(self.connections.items.len),
            .active = active,
            .idle = idle,
            .max = self.config.max_connections,
            .total_created = self.total_created,
            .total_acquired = self.total_acquired,
            .total_released = self.total_released,
        };
    }
};

pub const PoolStats = struct {
    total: u32,
    active: u32,
    idle: u32,
    max: u32,
    total_created: u64,
    total_acquired: u64,
    total_released: u64,
};

pub const PooledConn = struct {
    pool: *Pool,
    conn: *Connection,

    pub fn release(self: *PooledConn) void {
        self.pool.release(self.conn);
    }

    pub fn query(self: *PooledConn, sql: []const u8) !types.QueryResult {
        return self.conn.query(sql);
    }

    pub fn queryParams(self: *PooledConn, sql: []const u8, params: []const types.Param) !types.QueryResult {
        return self.conn.queryParams(sql, params);
    }

    pub fn exec(self: *PooledConn, sql: []const u8) !u64 {
        return self.conn.exec(sql);
    }

    pub fn execParams(self: *PooledConn, sql: []const u8, params: []const types.Param) !u64 {
        return self.conn.execParams(sql, params);
    }

    pub fn begin(self: *PooledConn) !void {
        return self.conn.begin();
    }

    pub fn commit(self: *PooledConn) !void {
        return self.conn.commit();
    }

    pub fn rollback(self: *PooledConn) !void {
        return self.conn.rollback();
    }
};

test "pool config defaults" {
    const config = PoolConfig{};
    try std.testing.expectEqual(@as(u32, 2), config.min_connections);
    try std.testing.expectEqual(@as(u32, 10), config.max_connections);
}

test "pool stats structure" {
    const stats = PoolStats{
        .total = 5,
        .active = 2,
        .idle = 3,
        .max = 10,
        .total_created = 10,
        .total_acquired = 50,
        .total_released = 48,
    };
    try std.testing.expectEqual(@as(u32, 5), stats.total);
    try std.testing.expectEqual(@as(u32, 2), stats.active);
}
