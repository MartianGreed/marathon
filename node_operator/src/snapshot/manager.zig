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
        errdefer allocator.free(mgr.base_path);

        try mgr.scanSnapshots();
        return mgr;
    }

    pub fn deinit(self: *SnapshotManager) void {
        var it = self.snapshots.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.path);
        }
        self.snapshots.deinit();
        self.allocator.free(self.base_path);
    }

    fn scanSnapshots(self: *SnapshotManager) !void {
        var dir = std.fs.openDirAbsolute(self.base_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                std.log.info("Snapshot directory not found, creating: {s}", .{self.base_path});
                try std.fs.cwd().makePath(self.base_path);
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

test "snapshot manager init with temp dir" {
    const allocator = std.testing.allocator;

    var mgr = try SnapshotManager.init(allocator, "/tmp/marathon-test-snapshots");
    defer mgr.deinit();

    try std.testing.expectEqualStrings("/tmp/marathon-test-snapshots", mgr.base_path);
}

test "getSnapshot returns null for unknown name" {
    const allocator = std.testing.allocator;

    var mgr = try SnapshotManager.init(allocator, "/tmp");
    defer mgr.deinit();

    const result = mgr.getSnapshot("nonexistent-snapshot");
    try std.testing.expect(result == null);
}

test "getDefaultSnapshot returns null when no base snapshot" {
    const allocator = std.testing.allocator;

    var mgr = try SnapshotManager.init(allocator, "/tmp");
    defer mgr.deinit();

    const result = mgr.getDefaultSnapshot();
    try std.testing.expect(result == null);
}

test "listSnapshots returns empty for empty directory" {
    const allocator = std.testing.allocator;

    var mgr = try SnapshotManager.init(allocator, "/tmp/marathon-test-empty-snapshots");
    defer mgr.deinit();

    const snapshots = try mgr.listSnapshots();
    defer allocator.free(snapshots);

    try std.testing.expectEqual(@as(usize, 0), snapshots.len);
}

test "SnapshotInfo struct fields" {
    const info = SnapshotInfo{
        .name = "test-snapshot",
        .path = "/tmp/test-snapshot",
        .created_at = 1234567890,
        .size_bytes = 1024,
    };

    try std.testing.expectEqualStrings("test-snapshot", info.name);
    try std.testing.expectEqual(@as(u64, 1024), info.size_bytes);
}

test "snapshot manager with valid snapshot directory" {
    const allocator = std.testing.allocator;

    // Create temp directory structure with valid snapshot
    const base_path = "/tmp/marathon-test-valid-snapshots";
    const snapshot_dir = "/tmp/marathon-test-valid-snapshots/test-snap";

    // Clean up any previous test artifacts
    std.fs.deleteTreeAbsolute(base_path) catch {};

    // Create directories
    std.fs.makeDirAbsolute(base_path) catch {};
    defer std.fs.deleteTreeAbsolute(base_path) catch {};

    std.fs.makeDirAbsolute(snapshot_dir) catch {};

    // Create snapshot and mem files
    const snapshot_file = try std.fs.createFileAbsolute("/tmp/marathon-test-valid-snapshots/test-snap/snapshot", .{});
    _ = try snapshot_file.write("snapshot data content");
    snapshot_file.close();

    const mem_file = try std.fs.createFileAbsolute("/tmp/marathon-test-valid-snapshots/test-snap/mem", .{});
    _ = try mem_file.write("memory data content here");
    mem_file.close();

    // Initialize manager - should discover the snapshot
    var mgr = try SnapshotManager.init(allocator, base_path);
    defer mgr.deinit();

    // Verify snapshot was found
    const snap = mgr.getSnapshot("test-snap");
    try std.testing.expect(snap != null);
    try std.testing.expectEqualStrings("test-snap", snap.?.name);
    try std.testing.expect(snap.?.size_bytes > 0);

    // Test listSnapshots with actual snapshot
    const snapshots = try mgr.listSnapshots();
    defer allocator.free(snapshots);
    try std.testing.expectEqual(@as(usize, 1), snapshots.len);
}

test "snapshot manager creates directory when not found" {
    const allocator = std.testing.allocator;

    const test_path = "/tmp/marathon-test-create-dir-" ++ "12345";

    // Ensure directory doesn't exist
    std.fs.deleteTreeAbsolute(test_path) catch {};

    // Init should create the directory
    var mgr = try SnapshotManager.init(allocator, test_path);
    defer mgr.deinit();

    // Clean up
    defer std.fs.deleteTreeAbsolute(test_path) catch {};

    // Verify directory was created by checking we can init again
    var mgr2 = try SnapshotManager.init(allocator, test_path);
    defer mgr2.deinit();
}

test "validateSnapshot returns false for missing snapshot file" {
    const allocator = std.testing.allocator;

    const base_path = "/tmp/marathon-test-invalid-snap";
    const snap_dir = "/tmp/marathon-test-invalid-snap/incomplete";

    std.fs.deleteTreeAbsolute(base_path) catch {};
    std.fs.makeDirAbsolute(base_path) catch {};
    defer std.fs.deleteTreeAbsolute(base_path) catch {};

    std.fs.makeDirAbsolute(snap_dir) catch {};

    // Create only mem file, no snapshot file
    const mem_file = try std.fs.createFileAbsolute("/tmp/marathon-test-invalid-snap/incomplete/mem", .{});
    mem_file.close();

    var mgr = try SnapshotManager.init(allocator, base_path);
    defer mgr.deinit();

    // Should not find the incomplete snapshot
    const snap = mgr.getSnapshot("incomplete");
    try std.testing.expect(snap == null);
}
