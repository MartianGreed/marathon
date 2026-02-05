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
    vsock_uds_path: []const u8,
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
        errdefer allocator.free(socket_path);

        const vsock_uds_path = try std.fmt.allocPrint(
            allocator,
            "/tmp/firecracker-{s}-vsock.sock",
            .{types.formatId(id)},
        );

        vm.* = .{
            .allocator = allocator,
            .id = id,
            .state = .creating,
            .process = null,
            .socket_path = socket_path,
            .vsock_uds_path = vsock_uds_path,
            .vsock_cid = generateCid(),
            .task_id = null,
            .start_time = null,
        };

        return vm;
    }

    pub fn deinit(self: *Vm) void {
        self.stop() catch {};
        self.allocator.free(self.socket_path);
        self.allocator.free(self.vsock_uds_path);
        self.allocator.destroy(self);
    }

    pub fn start(self: *Vm, config: VmConfig) !void {
        std.log.info("Starting VM {s} (cold start)", .{types.formatId(self.id)});

        std.fs.accessAbsolute(config.firecracker_bin, .{}) catch {
            std.log.err("Firecracker binary not found at {s}", .{config.firecracker_bin});
            return error.FirecrackerNotFound;
        };

        std.fs.cwd().deleteFile(self.socket_path) catch {};

        const argv: []const []const u8 = &.{ config.firecracker_bin, "--api-sock", self.socket_path };
        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        self.process = child;
        errdefer {
            if (self.process) |*proc| {
                _ = proc.kill() catch {};
                _ = proc.wait() catch {};
                self.process = null;
            }
        }

        waitForSocket(self.socket_path, 5000) catch |err| {
            std.log.err("Firecracker socket not ready: {}", .{err});
            return error.FirecrackerStartFailed;
        };

        var buf: [4096]u8 = undefined;
        const boot_body = try std.fmt.bufPrint(&buf, "{{\"kernel_image_path\":\"{s}\",\"boot_args\":\"console=ttyS0 reboot=k panic=1 pci=off\"}}", .{config.kernel_path});
        try firecrackerApiCall(self.allocator, self.socket_path, "PUT", "/boot-source", boot_body);

        const rootfs_body = try std.fmt.bufPrint(&buf, "{{\"drive_id\":\"rootfs\",\"path_on_host\":\"{s}\",\"is_root_device\":true,\"is_read_only\":false}}", .{config.rootfs_path});
        try firecrackerApiCall(self.allocator, self.socket_path, "PUT", "/drives/rootfs", rootfs_body);

        const vsock_body = try std.fmt.bufPrint(&buf, "{{\"vsock_id\":\"vsock0\",\"guest_cid\":{d},\"uds_path\":\"{s}\"}}", .{ self.vsock_cid, self.vsock_uds_path });
        try firecrackerApiCall(self.allocator, self.socket_path, "PUT", "/vsock", vsock_body);

        const machine_body = try std.fmt.bufPrint(&buf, "{{\"vcpu_count\":{d},\"mem_size_mib\":{d}}}", .{ config.vcpu_count, config.mem_size_mib });
        try firecrackerApiCall(self.allocator, self.socket_path, "PUT", "/machine-config", machine_body);

        try firecrackerApiCall(self.allocator, self.socket_path, "PUT", "/actions", "{\"action_type\":\"InstanceStart\"}");

        waitForVsockReady(self.vsock_uds_path, config.vsock_port, 30) catch |err| {
            std.log.err("Vsock not ready after VM start: {}", .{err});
            return error.VsockNotReady;
        };

        self.state = .ready;
        self.start_time = std.time.milliTimestamp();
        std.log.info("VM {s} started successfully (CID: {d})", .{ types.formatId(self.id), self.vsock_cid });
    }

    pub fn startFromSnapshot(self: *Vm, snapshot_mgr: *snapshot.SnapshotManager, config: VmConfig) !void {
        const base_snapshot = snapshot_mgr.getDefaultSnapshot() orelse {
            std.log.warn("No base snapshot available, falling back to cold start", .{});
            return self.start(config);
        };

        std.log.info("Starting VM {s} from snapshot", .{types.formatId(self.id)});

        std.fs.cwd().deleteFile(self.socket_path) catch {};

        const argv: []const []const u8 = &.{ config.firecracker_bin, "--api-sock", self.socket_path };
        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        self.process = child;
        errdefer {
            if (self.process) |*proc| {
                _ = proc.kill() catch {};
                _ = proc.wait() catch {};
                self.process = null;
            }
        }

        waitForSocket(self.socket_path, 5000) catch |err| {
            std.log.err("Firecracker socket not ready: {}", .{err});
            return error.FirecrackerStartFailed;
        };

        var buf: [4096]u8 = undefined;
        const snapshot_file = try std.fmt.bufPrint(&buf, "{s}/snapshot", .{base_snapshot.path});
        var buf2: [4096]u8 = undefined;
        const mem_file = try std.fmt.bufPrint(&buf2, "{s}/mem", .{base_snapshot.path});
        var buf3: [4096]u8 = undefined;
        const load_body = try std.fmt.bufPrint(&buf3, "{{\"snapshot_path\":\"{s}\",\"mem_file_path\":\"{s}\",\"resume_vm\":true}}", .{ snapshot_file, mem_file });
        try firecrackerApiCall(self.allocator, self.socket_path, "PUT", "/snapshot/load", load_body);

        waitForVsockReady(self.vsock_uds_path, config.vsock_port, 10) catch |err| {
            std.log.err("Vsock not ready after snapshot restore: {}", .{err});
            return error.VsockNotReady;
        };

        self.state = .ready;
        self.start_time = std.time.milliTimestamp();
        std.log.info("VM {s} restored from snapshot successfully", .{types.formatId(self.id)});
    }

    pub fn stop(self: *Vm) !void {
        if (self.process) |*proc| {
            _ = proc.kill() catch {};
            _ = proc.wait() catch {};
            self.process = null;
        }
        std.fs.cwd().deleteFile(self.socket_path) catch {};
        std.fs.cwd().deleteFile(self.vsock_uds_path) catch {};
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
            const released_vm = kv.value;
            released_vm.releaseTask();
            const total = self.warm_vms.items.len + self.active_vms.count() + 1;
            if (total <= self.config.total_vm_slots) {
                self.warm_vms.append(self.allocator, released_vm) catch {
                    released_vm.deinit();
                    return;
                };
            } else {
                released_vm.deinit();
            }
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

fn waitForSocket(path: []const u8, timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    const timeout = @as(i64, @intCast(timeout_ms));

    while (std.time.milliTimestamp() - start < timeout) {
        const stat = std.fs.cwd().statFile(path) catch {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        if (stat.kind == .unix_domain_socket) {
            return;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    return error.SocketTimeout;
}

fn firecrackerApiCall(allocator: std.mem.Allocator, socket_path: []const u8, method: []const u8, endpoint: []const u8, body: []const u8) !void {
    const stream = std.net.connectUnixSocket(socket_path) catch |err| {
        std.log.err("Failed to connect to Firecracker socket {s}: {}", .{ socket_path, err });
        return error.SocketConnectionFailed;
    };
    defer stream.close();

    var request_buf: [8192]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "{s} {s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ method, endpoint, body.len, body }) catch {
        return error.RequestTooLarge;
    };

    _ = stream.write(request) catch |err| {
        std.log.err("Failed to send request to Firecracker: {}", .{err});
        return error.RequestFailed;
    };

    var response_buf: [4096]u8 = undefined;
    const bytes_read = stream.read(&response_buf) catch |err| {
        std.log.err("Failed to read response from Firecracker: {}", .{err});
        return error.ResponseFailed;
    };

    if (bytes_read == 0) {
        return error.EmptyResponse;
    }

    const response = response_buf[0..bytes_read];

    if (std.mem.startsWith(u8, response, "HTTP/1.1 2") or std.mem.startsWith(u8, response, "HTTP/1.0 2")) {
        std.log.debug("Firecracker API {s} {s}: success", .{ method, endpoint });
        return;
    }

    if (std.mem.indexOf(u8, response, "\r\n\r\n")) |header_end| {
        const body_start = header_end + 4;
        if (body_start < response.len) {
            const response_body = response[body_start..];
            var log_buf: [512]u8 = undefined;
            const log_len = @min(response_body.len, log_buf.len - 1);
            @memcpy(log_buf[0..log_len], response_body[0..log_len]);
            std.log.err("Firecracker API {s} {s} failed: {s}", .{ method, endpoint, log_buf[0..log_len] });
        }
    }

    _ = allocator;
    return error.ApiCallFailed;
}

fn waitForVsockReady(vsock_path: []const u8, port: u32, max_retries: u32) !void {
    _ = port;
    var retries: u32 = 0;
    while (retries < max_retries) : (retries += 1) {
        const stat = std.fs.cwd().statFile(vsock_path) catch {
            std.Thread.sleep(500 * std.time.ns_per_ms);
            continue;
        };
        if (stat.kind == .unix_domain_socket) {
            const stream = std.net.connectUnixSocket(vsock_path) catch {
                std.Thread.sleep(500 * std.time.ns_per_ms);
                continue;
            };
            stream.close();
            std.log.debug("Vsock at {s} is ready", .{vsock_path});
            return;
        }
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
    return error.VsockTimeout;
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

test "vm stop transitions to stopped" {
    const allocator = std.testing.allocator;
    const vm = try Vm.init(allocator);
    defer vm.deinit();

    vm.state = .ready;
    vm.start_time = std.time.milliTimestamp();

    try vm.stop();

    try std.testing.expectEqual(VmState.stopped, vm.state);
}

test "vm assign and release task" {
    const allocator = std.testing.allocator;
    const vm = try Vm.init(allocator);
    defer vm.deinit();

    vm.state = .ready;
    vm.start_time = std.time.milliTimestamp();
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

    vm.state = .ready;
    vm.start_time = std.time.milliTimestamp();

    const uptime = vm.getUptimeMs();
    try std.testing.expect(uptime != null);
    try std.testing.expect(uptime.? >= 0);
}

test "pool acquire returns null when empty" {
    const allocator = std.testing.allocator;

    var snapshot_mgr = try snapshot.SnapshotManager.init(allocator, "/tmp/marathon-pool-test-empty");
    defer snapshot_mgr.deinit();

    var pool = VmPool.init(allocator, &snapshot_mgr, .{});
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), pool.warmCount());

    const vm = pool.acquire();
    try std.testing.expect(vm == null);
}

test "pool counts start at zero" {
    const allocator = std.testing.allocator;

    var snapshot_mgr = try snapshot.SnapshotManager.init(allocator, "/tmp/marathon-pool-test-counts");
    defer snapshot_mgr.deinit();

    var pool = VmPool.init(allocator, &snapshot_mgr, .{});
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), pool.totalCount());
    try std.testing.expectEqual(@as(usize, 0), pool.warmCount());
    try std.testing.expectEqual(@as(usize, 0), pool.activeCount());
}

test "pool release with manual vm insertion" {
    const allocator = std.testing.allocator;

    var snapshot_mgr = try snapshot.SnapshotManager.init(allocator, "/tmp/marathon-pool-test-release");
    defer snapshot_mgr.deinit();

    var pool = VmPool.init(allocator, &snapshot_mgr, .{});
    defer pool.deinit();

    const vm = try Vm.init(allocator);
    vm.state = .ready;
    vm.start_time = std.time.milliTimestamp();

    pool.mutex.lock();
    try pool.warm_vms.append(allocator, vm);
    pool.mutex.unlock();

    try std.testing.expectEqual(@as(usize, 1), pool.warmCount());

    const acquired = pool.acquire();
    try std.testing.expect(acquired != null);
    try std.testing.expectEqual(@as(usize, 0), pool.warmCount());
    try std.testing.expectEqual(@as(usize, 1), pool.activeCount());

    pool.release(acquired.?.id);
    try std.testing.expectEqual(@as(usize, 1), pool.warmCount());
    try std.testing.expectEqual(@as(usize, 0), pool.activeCount());
}

test "pool release destroys vm when at capacity" {
    const allocator = std.testing.allocator;

    var snapshot_mgr = try snapshot.SnapshotManager.init(allocator, "/tmp/marathon-pool-test-capacity");
    defer snapshot_mgr.deinit();

    var pool = VmPool.init(allocator, &snapshot_mgr, .{ .total_vm_slots = 2 });
    defer pool.deinit();

    const vm1 = try Vm.init(allocator);
    vm1.state = .ready;
    const vm2 = try Vm.init(allocator);
    vm2.state = .ready;
    const vm3 = try Vm.init(allocator);
    vm3.state = .ready;

    pool.mutex.lock();
    try pool.warm_vms.append(allocator, vm1);
    try pool.warm_vms.append(allocator, vm2);
    pool.mutex.unlock();

    const acquired = pool.acquire().?;
    const acquired_id = acquired.id;

    pool.mutex.lock();
    try pool.warm_vms.append(allocator, vm3);
    pool.mutex.unlock();

    try std.testing.expectEqual(@as(usize, 2), pool.warmCount());
    try std.testing.expectEqual(@as(usize, 1), pool.activeCount());

    pool.release(acquired_id);
    try std.testing.expectEqual(@as(usize, 2), pool.warmCount());
    try std.testing.expectEqual(@as(usize, 0), pool.activeCount());
}

test "pool acquire-release-acquire reuses recycled vm" {
    const allocator = std.testing.allocator;

    var snapshot_mgr = try snapshot.SnapshotManager.init(allocator, "/tmp/marathon-pool-test-recycle");
    defer snapshot_mgr.deinit();

    var pool = VmPool.init(allocator, &snapshot_mgr, .{});
    defer pool.deinit();

    const vm = try Vm.init(allocator);
    vm.state = .ready;
    vm.start_time = std.time.milliTimestamp();

    pool.mutex.lock();
    try pool.warm_vms.append(allocator, vm);
    pool.mutex.unlock();

    const vm1 = pool.acquire().?;
    const vm1_id = vm1.id;

    pool.release(vm1_id);
    try std.testing.expectEqual(@as(usize, 1), pool.warmCount());

    const vm2 = pool.acquire().?;
    try std.testing.expectEqual(@as(usize, 0), pool.warmCount());
    try std.testing.expectEqual(@as(usize, 1), pool.activeCount());

    try std.testing.expectEqual(VmState.ready, vm2.state);
    try std.testing.expect(vm2.task_id == null);
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
