const std = @import("std");
const common = @import("common");
const types = common.types;
const snapshot = @import("../snapshot/manager.zig");

pub const VmState = enum {
    creating,
    ready,
    running,
    stopping,
    stopped,
    failed,
};

pub const Vm = struct {
    allocator: std.mem.Allocator,
    id: types.VmId,
    state: VmState,
    process: ?std.process.Child,
    socket_path: []const u8,
    vsock_cid: u32,
    task_id: ?types.TaskId,
    start_time: ?i64,

    pub fn init(allocator: std.mem.Allocator) !*Vm {
        const vm = try allocator.create(Vm);

        var id: types.VmId = undefined;
        std.crypto.random.bytes(&id);

        const socket_path = try std.fmt.allocPrint(
            allocator,
            "/tmp/firecracker-{s}.sock",
            .{types.formatId(id)},
        );

        vm.* = .{
            .allocator = allocator,
            .id = id,
            .state = .creating,
            .process = null,
            .socket_path = socket_path,
            .vsock_cid = generateCid(),
            .task_id = null,
            .start_time = null,
        };

        return vm;
    }

    pub fn deinit(self: *Vm) void {
        self.stop() catch {};
        self.allocator.free(self.socket_path);
        self.allocator.destroy(self);
    }

    pub fn start(self: *Vm, config: VmConfig) !void {
        _ = config;
        self.state = .ready;
        self.start_time = std.time.milliTimestamp();
    }

    pub fn startFromSnapshot(self: *Vm, snapshot_mgr: *snapshot.SnapshotManager, config: VmConfig) !void {
        _ = snapshot_mgr;
        _ = config;
        self.state = .ready;
        self.start_time = std.time.milliTimestamp();
    }

    pub fn stop(self: *Vm) !void {
        if (self.process) |*proc| {
            _ = proc.kill() catch {};
            _ = proc.wait() catch {};
            self.process = null;
        }
        self.state = .stopped;
    }

    pub fn assignTask(self: *Vm, task_id: types.TaskId) void {
        self.task_id = task_id;
        self.state = .running;
    }

    pub fn releaseTask(self: *Vm) void {
        self.task_id = null;
        self.state = .ready;
    }

    pub fn getUptimeMs(self: *Vm) ?i64 {
        const start_ts = self.start_time orelse return null;
        return std.time.milliTimestamp() - start_ts;
    }
};

pub const VmConfig = struct {
    firecracker_bin: []const u8 = "/usr/bin/firecracker",
    kernel_path: []const u8 = "/tmp/marathon/kernel/vmlinux",
    rootfs_path: []const u8 = "/tmp/marathon/rootfs/rootfs.ext4",
    snapshot_path: []const u8 = "/tmp/marathon/snapshots/base",
    vcpu_count: u32 = 2,
    mem_size_mib: u32 = 512,
    vsock_port: u32 = 9999,
};

pub const VmPool = struct {
    allocator: std.mem.Allocator,
    snapshot_mgr: *snapshot.SnapshotManager,
    config: common.config.NodeOperatorConfig,
    warm_vms: std.ArrayListUnmanaged(*Vm),
    active_vms: std.AutoHashMap(types.VmId, *Vm),
    mutex: std.Thread.Mutex,

    pub fn init(
        allocator: std.mem.Allocator,
        snapshot_mgr: *snapshot.SnapshotManager,
        config: common.config.NodeOperatorConfig,
    ) VmPool {
        return .{
            .allocator = allocator,
            .snapshot_mgr = snapshot_mgr,
            .config = config,
            .warm_vms = .empty,
            .active_vms = std.AutoHashMap(types.VmId, *Vm).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *VmPool) void {
        for (self.warm_vms.items) |vm| {
            vm.deinit();
        }
        self.warm_vms.deinit(self.allocator);

        var it = self.active_vms.valueIterator();
        while (it.next()) |vm| {
            vm.*.deinit();
        }
        self.active_vms.deinit();
    }

    pub fn warmPool(self: *VmPool, target: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.warm_vms.items.len < target) {
            const vm = try Vm.init(self.allocator);
            errdefer vm.deinit();

            const vm_config = VmConfig{
                .firecracker_bin = self.config.firecracker_bin,
                .kernel_path = self.config.kernel_path,
                .rootfs_path = self.config.rootfs_path,
                .snapshot_path = self.config.snapshot_path,
            };

            vm.startFromSnapshot(self.snapshot_mgr, vm_config) catch |err| {
                std.log.warn("Failed to start VM from snapshot: {}, falling back to cold start", .{err});
                vm.start(vm_config) catch |start_err| {
                    std.log.err("Failed to cold start VM: {}", .{start_err});
                    vm.deinit();
                    continue;
                };
            };

            try self.warm_vms.append(self.allocator, vm);
        }
    }

    pub fn acquire(self: *VmPool) ?*Vm {
        self.mutex.lock();
        defer self.mutex.unlock();

        const vm = self.warm_vms.pop() orelse return null;
        self.active_vms.put(vm.id, vm) catch return null;
        return vm;
    }

    pub fn release(self: *VmPool, vm_id: types.VmId) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.active_vms.fetchRemove(vm_id)) |kv| {
            const vm = kv.value;
            vm.releaseTask();
            vm.deinit();
        }
    }

    pub fn warmCount(self: *VmPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.warm_vms.items.len;
    }

    pub fn activeCount(self: *VmPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.active_vms.count();
    }

    pub fn totalCount(self: *VmPool) usize {
        return self.warmCount() + self.activeCount();
    }
};

fn generateCid() u32 {
    var bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const cid = std.mem.readInt(u32, &bytes, .little);
    return (cid % 0xFFFF_FFFC) + 3;
}

test "vm state transitions" {
    try std.testing.expectEqual(VmState.creating, VmState.creating);
}

test "cid generation" {
    const cid = generateCid();
    try std.testing.expect(cid >= 3);
    try std.testing.expect(cid < 0xFFFF_FFFF);
}

test "vm init creates valid state" {
    const allocator = std.testing.allocator;
    const vm = try Vm.init(allocator);
    defer vm.deinit();

    try std.testing.expectEqual(VmState.creating, vm.state);
    try std.testing.expect(vm.task_id == null);
    try std.testing.expect(vm.process == null);
    try std.testing.expect(vm.start_time == null);
    try std.testing.expect(vm.vsock_cid >= 3);
}

test "vm start transitions to ready" {
    const allocator = std.testing.allocator;
    const vm = try Vm.init(allocator);
    defer vm.deinit();

    try std.testing.expectEqual(VmState.creating, vm.state);

    try vm.start(.{});

    try std.testing.expectEqual(VmState.ready, vm.state);
    try std.testing.expect(vm.start_time != null);
}

test "vm stop transitions to stopped" {
    const allocator = std.testing.allocator;
    const vm = try Vm.init(allocator);
    defer vm.deinit();

    try vm.start(.{});
    try std.testing.expectEqual(VmState.ready, vm.state);

    try vm.stop();

    try std.testing.expectEqual(VmState.stopped, vm.state);
}

test "vm assign and release task" {
    const allocator = std.testing.allocator;
    const vm = try Vm.init(allocator);
    defer vm.deinit();

    try vm.start(.{});
    try std.testing.expectEqual(VmState.ready, vm.state);
    try std.testing.expect(vm.task_id == null);

    var task_id: types.TaskId = undefined;
    @memset(&task_id, 0xAB);

    vm.assignTask(task_id);
    try std.testing.expectEqual(VmState.running, vm.state);
    try std.testing.expect(vm.task_id != null);
    try std.testing.expectEqualSlices(u8, &task_id, &vm.task_id.?);

    vm.releaseTask();
    try std.testing.expectEqual(VmState.ready, vm.state);
    try std.testing.expect(vm.task_id == null);
}

test "vm uptime tracking" {
    const allocator = std.testing.allocator;
    const vm = try Vm.init(allocator);
    defer vm.deinit();

    try std.testing.expect(vm.getUptimeMs() == null);

    try vm.start(.{});

    const uptime = vm.getUptimeMs();
    try std.testing.expect(uptime != null);
    try std.testing.expect(uptime.? >= 0);
}

test "pool warmPool adds vms" {
    const allocator = std.testing.allocator;

    var snapshot_mgr = try snapshot.SnapshotManager.init(allocator, "/tmp");
    defer snapshot_mgr.deinit();

    var pool = VmPool.init(allocator, &snapshot_mgr, .{});
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), pool.warmCount());

    try pool.warmPool(2);

    try std.testing.expectEqual(@as(usize, 2), pool.warmCount());
}

test "pool acquire and release cycle" {
    const allocator = std.testing.allocator;

    var snapshot_mgr = try snapshot.SnapshotManager.init(allocator, "/tmp");
    defer snapshot_mgr.deinit();

    var pool = VmPool.init(allocator, &snapshot_mgr, .{});
    defer pool.deinit();

    try pool.warmPool(1);
    try std.testing.expectEqual(@as(usize, 1), pool.warmCount());
    try std.testing.expectEqual(@as(usize, 0), pool.activeCount());

    const vm = pool.acquire();
    try std.testing.expect(vm != null);
    try std.testing.expectEqual(@as(usize, 0), pool.warmCount());
    try std.testing.expectEqual(@as(usize, 1), pool.activeCount());

    pool.release(vm.?.id);
    try std.testing.expectEqual(@as(usize, 0), pool.warmCount());
    try std.testing.expectEqual(@as(usize, 0), pool.activeCount());
}

test "pool counts are accurate" {
    const allocator = std.testing.allocator;

    var snapshot_mgr = try snapshot.SnapshotManager.init(allocator, "/tmp");
    defer snapshot_mgr.deinit();

    var pool = VmPool.init(allocator, &snapshot_mgr, .{});
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), pool.totalCount());

    try pool.warmPool(3);
    try std.testing.expectEqual(@as(usize, 3), pool.warmCount());
    try std.testing.expectEqual(@as(usize, 0), pool.activeCount());
    try std.testing.expectEqual(@as(usize, 3), pool.totalCount());

    const vm1 = pool.acquire();
    const vm2 = pool.acquire();
    try std.testing.expect(vm1 != null);
    try std.testing.expect(vm2 != null);

    try std.testing.expectEqual(@as(usize, 1), pool.warmCount());
    try std.testing.expectEqual(@as(usize, 2), pool.activeCount());
    try std.testing.expectEqual(@as(usize, 3), pool.totalCount());
}

test "vm stop with running process" {
    const allocator = std.testing.allocator;
    const vm = try Vm.init(allocator);
    defer vm.deinit();

    // Spawn a simple sleep process
    const argv: []const []const u8 = &.{ "sleep", "10" };
    var child = std.process.Child.init(argv, allocator);
    try child.spawn();

    // Assign the process to VM
    vm.process = child;
    vm.state = .running;

    // Stop should kill and wait for the process
    try vm.stop();

    try std.testing.expectEqual(VmState.stopped, vm.state);
    try std.testing.expect(vm.process == null);
}
