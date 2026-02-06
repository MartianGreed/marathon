const std = @import("std");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;
const vm = @import("../vm/firecracker.zig");
const vsock = @import("../vsock/handler.zig");

const log = std.log.scoped(.task_executor);

pub const TaskExecutor = struct {
    allocator: std.mem.Allocator,
    vm_pool: *vm.VmPool,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, vm_pool: *vm.VmPool) TaskExecutor {
        return .{
            .allocator = allocator,
            .vm_pool = vm_pool,
        };
    }

    pub fn executeTask(self: *TaskExecutor, request: protocol.ExecuteTaskRequest) !void {
        const vm_instance = self.vm_pool.acquireOrCreate() catch |err| {
            log.err("failed to acquire VM for task_id={s} err={}", .{ &types.formatId(request.task_id), err });
            return error.NoAvailableVm;
        };

        log.info("task starting: task_id={s} vm_id={s}", .{
            &types.formatId(request.task_id),
            &types.formatId(vm_instance.id),
        });

        vm_instance.assignTask(request.task_id);

        const thread = std.Thread.spawn(.{}, runTask, .{ self, vm_instance, request }) catch |err| {
            log.err("failed to spawn task thread: task_id={s} err={}", .{
                &types.formatId(request.task_id),
                err,
            });
            self.vm_pool.release(vm_instance.id);
            return err;
        };
        thread.detach();
    }

    fn runTask(self: *TaskExecutor, vm_instance: *vm.Vm, request: protocol.ExecuteTaskRequest) void {
        defer self.vm_pool.release(vm_instance.id);

        var runner = vsock.TaskRunner.init(
            self.allocator,
            vm_instance.vsock_cid,
            9999,
            request.task_id,
        );
        defer runner.deinit();

        const vsock_payload = protocol.VsockStartPayload{
            .task_id = request.task_id,
            .repo_url = request.repo_url,
            .branch = request.branch,
            .prompt = request.prompt,
            .github_token = request.github_token,
            .anthropic_api_key = request.anthropic_api_key,
            .create_pr = request.create_pr,
            .pr_title = request.pr_title,
            .pr_body = request.pr_body,
            .max_iterations = null,
            .completion_promise = null,
        };

        const result = runner.run(vsock_payload) catch |err| {
            log.err("task execution failed: task_id={s} err={}", .{
                &types.formatId(request.task_id),
                err,
            });
            return;
        };

        log.info("task completed: task_id={s} success={} pr_url={s}", .{
            &types.formatId(request.task_id),
            result.success,
            result.pr_url orelse "none",
        });
    }
};

test "task executor init" {
    const allocator = std.testing.allocator;

    const snapshot_mgr = @import("../snapshot/manager.zig");
    var mgr = try snapshot_mgr.SnapshotManager.init(allocator, "/tmp/marathon-executor-test");
    defer mgr.deinit();

    var pool = vm.VmPool.init(allocator, &mgr, .{});
    defer pool.deinit();

    const executor = TaskExecutor.init(allocator, &pool);
    _ = executor;
}
