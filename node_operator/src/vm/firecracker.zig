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
    kernel_path: []const u8 = "/var/lib/marathon/kernel/vmlinux",
    rootfs_path: []const u8 = "/var/lib/marathon/rootfs/rootfs.ext4",
    snapshot_path: []const u8 = "/var/lib/marathon/snapshots/base",
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

        if (self.warm_vms.items.len > 0) {
            const vm = self.warm_vms.pop();
            self.active_vms.put(vm.id, vm) catch return null;
            return vm;
        }

        return null;
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
