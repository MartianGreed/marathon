const std = @import("std");
const common = @import("common");
const types = common.types;
const pool = @import("../pool.zig");
const db_types = @import("../types.zig");
const errors = @import("../errors.zig");

const Param = db_types.Param;
const log = std.log.scoped(.node_repo);

pub const NodeRepository = struct {
    db_pool: *pool.Pool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db_pool: *pool.Pool) NodeRepository {
        return .{
            .db_pool = db_pool,
            .allocator = allocator,
        };
    }

    pub fn upsert(self: *NodeRepository, status: *const types.NodeStatus) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        const now = std.time.milliTimestamp();
        var params = [_]Param{
            .{ .bytea = &status.node_id },
            .{ .text = status.hostname },
            .{ .i32 = @intCast(status.total_vm_slots) },
            .{ .i32 = @intCast(status.active_vms) },
            .{ .i32 = @intCast(status.warm_vms) },
            .{ .f64 = status.cpu_usage },
            .{ .f64 = status.memory_usage },
            .{ .i64 = status.disk_available_bytes },
            .{ .bool = status.healthy },
            .{ .bool = status.draining },
            .{ .i64 = status.uptime_seconds },
            db_types.optional(i64, status.last_task_at),
            .{ .i64 = now },
            .{ .i64 = now },
        };

        _ = conn.execParams(
            \\INSERT INTO nodes (
            \\    node_id, hostname, total_vm_slots, active_vms, warm_vms,
            \\    cpu_usage, memory_usage, disk_available_bytes,
            \\    healthy, draining, uptime_seconds, last_task_at,
            \\    last_heartbeat_at, registered_at, updated_at
            \\) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $13, $14)
            \\ON CONFLICT (node_id) DO UPDATE SET
            \\    hostname = EXCLUDED.hostname,
            \\    total_vm_slots = EXCLUDED.total_vm_slots,
            \\    active_vms = EXCLUDED.active_vms,
            \\    warm_vms = EXCLUDED.warm_vms,
            \\    cpu_usage = EXCLUDED.cpu_usage,
            \\    memory_usage = EXCLUDED.memory_usage,
            \\    disk_available_bytes = EXCLUDED.disk_available_bytes,
            \\    healthy = EXCLUDED.healthy,
            \\    draining = EXCLUDED.draining,
            \\    uptime_seconds = EXCLUDED.uptime_seconds,
            \\    last_task_at = EXCLUDED.last_task_at,
            \\    last_heartbeat_at = EXCLUDED.last_heartbeat_at,
            \\    updated_at = EXCLUDED.updated_at
        , &params) catch |err| {
            log.err("upsert node failed: node_id={s} error={}", .{ &types.formatId(status.node_id), err });
            return err;
        };
    }

    pub fn get(self: *NodeRepository, node_id: types.NodeId) !?types.NodeStatus {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{.{ .bytea = &node_id }};
        var result = try conn.queryParams(
            \\SELECT node_id, hostname, total_vm_slots, active_vms, warm_vms,
            \\       cpu_usage, memory_usage, disk_available_bytes,
            \\       healthy, draining, uptime_seconds, last_task_at
            \\FROM nodes WHERE node_id = $1
        , &params);
        defer result.deinit();

        if (result.first()) |row| {
            return self.rowToNodeStatus(row);
        }
        return null;
    }

    pub fn listHealthy(self: *NodeRepository, timeout_ms: u64) ![]types.NodeStatus {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        const cutoff = std.time.milliTimestamp() - @as(i64, @intCast(timeout_ms));
        var params = [_]Param{.{ .i64 = cutoff }};

        var result = try conn.queryParams(
            \\SELECT node_id, hostname, total_vm_slots, active_vms, warm_vms,
            \\       cpu_usage, memory_usage, disk_available_bytes,
            \\       healthy, draining, uptime_seconds, last_task_at
            \\FROM nodes
            \\WHERE healthy = TRUE AND draining = FALSE AND last_heartbeat_at > $1
            \\ORDER BY (total_vm_slots - active_vms) DESC
        , &params);
        defer result.deinit();

        return self.rowsToNodeStatuses(result.rows);
    }

    pub fn listAll(self: *NodeRepository) ![]types.NodeStatus {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var result = try conn.query(
            \\SELECT node_id, hostname, total_vm_slots, active_vms, warm_vms,
            \\       cpu_usage, memory_usage, disk_available_bytes,
            \\       healthy, draining, uptime_seconds, last_task_at
            \\FROM nodes ORDER BY hostname
        );
        defer result.deinit();

        return self.rowsToNodeStatuses(result.rows);
    }

    pub fn removeStale(self: *NodeRepository, timeout_ms: u64) ![]types.NodeId {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        const cutoff = std.time.milliTimestamp() - @as(i64, @intCast(timeout_ms));
        var params = [_]Param{.{ .i64 = cutoff }};

        var result = try conn.queryParams(
            "SELECT node_id FROM nodes WHERE last_heartbeat_at < $1",
            &params,
        );
        defer result.deinit();

        var stale = std.ArrayList(types.NodeId).init(self.allocator);
        errdefer stale.deinit();

        for (result.rows) |row| {
            if (row.getBytea(0)) |id| {
                if (id.len == 16) {
                    var node_id: types.NodeId = undefined;
                    @memcpy(&node_id, id);
                    try stale.append(node_id);
                }
            }
        }

        if (stale.items.len > 0) {
            _ = try conn.execParams(
                "DELETE FROM nodes WHERE last_heartbeat_at < $1",
                &params,
            );
            log.info("removed {d} stale nodes", .{stale.items.len});
        }

        return stale.toOwnedSlice();
    }

    pub fn setDraining(self: *NodeRepository, node_id: types.NodeId, draining: bool) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        var params = [_]Param{
            .{ .bool = draining },
            .{ .i64 = std.time.milliTimestamp() },
            .{ .bytea = &node_id },
        };

        _ = try conn.execParams(
            "UPDATE nodes SET draining = $1, updated_at = $2 WHERE node_id = $3",
            &params,
        );
    }

    pub fn updateHeartbeat(self: *NodeRepository, node_id: types.NodeId) !void {
        var conn = try self.db_pool.acquire();
        defer conn.release();

        const now = std.time.milliTimestamp();
        var params = [_]Param{
            .{ .i64 = now },
            .{ .i64 = now },
            .{ .bytea = &node_id },
        };

        _ = try conn.execParams(
            "UPDATE nodes SET last_heartbeat_at = $1, updated_at = $2 WHERE node_id = $3",
            &params,
        );
    }

    fn rowToNodeStatus(self: *NodeRepository, row: db_types.Row) types.NodeStatus {
        _ = self;
        var status = types.NodeStatus{
            .node_id = undefined,
            .hostname = "",
            .total_vm_slots = row.getU32(2) orelse 0,
            .active_vms = row.getU32(3) orelse 0,
            .warm_vms = row.getU32(4) orelse 0,
            .cpu_usage = row.getF64(5) orelse 0.0,
            .memory_usage = row.getF64(6) orelse 0.0,
            .disk_available_bytes = row.getI64(7) orelse 0,
            .healthy = row.getBool(8) orelse true,
            .draining = row.getBool(9) orelse false,
            .uptime_seconds = row.getI64(10) orelse 0,
            .last_task_at = row.getOptionalI64(11) orelse null,
            .active_task_ids = &.{},
        };

        if (row.getBytea(0)) |id| {
            if (id.len == 16) @memcpy(&status.node_id, id);
        }
        if (row.getText(1)) |hostname| {
            status.hostname = hostname;
        }

        return status;
    }

    fn rowsToNodeStatuses(self: *NodeRepository, rows: []db_types.Row) ![]types.NodeStatus {
        var statuses = try self.allocator.alloc(types.NodeStatus, rows.len);
        errdefer self.allocator.free(statuses);

        for (rows, 0..) |row, i| {
            statuses[i] = self.rowToNodeStatus(row);
        }

        return statuses;
    }
};

test "node status conversion" {
    var node_id: types.NodeId = undefined;
    @memset(&node_id, 0xAB);

    const status = types.NodeStatus{
        .node_id = node_id,
        .hostname = "test-host",
        .total_vm_slots = 10,
        .active_vms = 3,
        .warm_vms = 2,
        .cpu_usage = 0.5,
        .memory_usage = 0.6,
        .disk_available_bytes = 1000000,
        .healthy = true,
        .draining = false,
        .uptime_seconds = 3600,
        .last_task_at = null,
        .active_task_ids = &.{},
    };

    try std.testing.expectEqual(@as(u32, 7), status.availableSlots());
    try std.testing.expect(status.score() > 0.0);
}
