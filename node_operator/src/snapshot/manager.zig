const std = @import("std");
const common = @import("common");
const types = common.types;

pub const SnapshotManager = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,
    snapshots: std.StringHashMap(SnapshotInfo),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, base_path: []const u8) !SnapshotManager {
        var mgr = SnapshotManager{
            .allocator = allocator,
            .base_path = try allocator.dupe(u8, base_path),
            .snapshots = std.StringHashMap(SnapshotInfo).init(allocator),
            .mutex = .{},
        };

        try mgr.scanSnapshots();
        return mgr;
    }

    pub fn deinit(self: *SnapshotManager) void {
        var it = self.snapshots.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.snapshots.deinit();
        self.allocator.free(self.base_path);
    }

    fn scanSnapshots(self: *SnapshotManager) !void {
        var dir = std.fs.openDirAbsolute(self.base_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                std.log.info("Snapshot directory not found, creating: {s}", .{self.base_path});
                try std.fs.makeDirAbsolute(self.base_path);
                return;
            }
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;

            const snapshot_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ self.base_path, entry.name },
            );
            defer self.allocator.free(snapshot_path);

            if (try self.validateSnapshot(snapshot_path)) {
                const name = try self.allocator.dupe(u8, entry.name);
                try self.snapshots.put(name, .{
                    .name = name,
                    .path = try self.allocator.dupe(u8, snapshot_path),
                    .created_at = std.time.timestamp(),
                    .size_bytes = try self.getSnapshotSize(snapshot_path),
                });
            }
        }
    }

    fn validateSnapshot(self: *SnapshotManager, path: []const u8) !bool {
        _ = self;

        const snapshot_file = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "{s}/snapshot",
            .{path},
        );
        defer std.heap.page_allocator.free(snapshot_file);

        const mem_file = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "{s}/mem",
            .{path},
        );
        defer std.heap.page_allocator.free(mem_file);

        if (!common.compat.fileExists(snapshot_file)) return false;
        if (!common.compat.fileExists(mem_file)) return false;

        return true;
    }

    fn getSnapshotSize(self: *SnapshotManager, path: []const u8) !u64 {
        _ = self;

        var total: u64 = 0;

        const snapshot_file = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "{s}/snapshot",
            .{path},
        );
        defer std.heap.page_allocator.free(snapshot_file);

        const mem_file = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "{s}/mem",
            .{path},
        );
        defer std.heap.page_allocator.free(mem_file);

        if (common.compat.fileStat(snapshot_file)) |stat| {
            total += stat.size;
        } else |_| {}

        if (common.compat.fileStat(mem_file)) |stat| {
            total += stat.size;
        } else |_| {}

        return total;
    }

    pub fn getSnapshot(self: *SnapshotManager, name: []const u8) ?SnapshotInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.snapshots.get(name);
    }

    pub fn getDefaultSnapshot(self: *SnapshotManager) ?SnapshotInfo {
        return self.getSnapshot("base");
    }

    pub fn listSnapshots(self: *SnapshotManager) ![]SnapshotInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result: std.ArrayListUnmanaged(SnapshotInfo) = .empty;
        errdefer result.deinit(self.allocator);

        var it = self.snapshots.valueIterator();
        while (it.next()) |info| {
            try result.append(self.allocator, info.*);
        }

        return result.toOwnedSlice(self.allocator);
    }
};

pub const SnapshotInfo = struct {
    name: []const u8,
    path: []const u8,
    created_at: i64,
    size_bytes: u64,
};

test "snapshot manager init" {
    _ = SnapshotManager;
}
