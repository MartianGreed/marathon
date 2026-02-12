const std = @import("std");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;
const vm = @import("../vm/firecracker.zig");
const vsock = @import("../vsock/handler.zig");
const OutputBuffer = @import("output_buffer.zig").OutputBuffer;

const log = std.log.scoped(.task_executor);

pub const TaskExecutor = struct {
    allocator: std.mem.Allocator,
    vm_pool: *vm.VmPool,
    mutex: std.Thread.Mutex = .{},
    completed_results: std.ArrayListUnmanaged(protocol.TaskResultReport) = .empty,
    output_buffer: OutputBuffer,

    pub fn init(allocator: std.mem.Allocator, vm_pool: *vm.VmPool) TaskExecutor {
        return .{
            .allocator = allocator,
            .vm_pool = vm_pool,
            .output_buffer = OutputBuffer.init(allocator),
        };
    }

    pub fn deinit(self: *TaskExecutor) void {
        self.completed_results.deinit(self.allocator);
        self.output_buffer.deinit();
    }

    pub fn drainResults(self: *TaskExecutor) []protocol.TaskResultReport {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.completed_results.toOwnedSlice(self.allocator) catch return &[_]protocol.TaskResultReport{};
    }

    pub fn drainOutput(self: *TaskExecutor) []protocol.TaskOutputEvent {
        return self.output_buffer.drain();
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
            vm_instance.vsock_uds_path,
            9999,
            request.task_id,
        );
        defer runner.deinit();

        // Wire up output forwarding to the shared output buffer.
        // The heartbeat drains this buffer and forwards events to the orchestrator.
        runner.output_buffer = &self.output_buffer;

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
            .max_iterations = request.max_iterations,
            .completion_promise = request.completion_promise,
            .env_vars = request.env_vars,
        };

        const report: protocol.TaskResultReport = if (runner.run(vsock_payload)) |result| .{
            .task_id = request.task_id,
            .success = result.success,
            .error_message = result.error_message,
            .metrics = result.metrics,
            .pr_url = result.pr_url,
        } else |err| blk: {
            log.err("task execution failed: task_id={s} err={}", .{
                &types.formatId(request.task_id),
                err,
            });
            break :blk .{
                .task_id = request.task_id,
                .success = false,
                .error_message = @errorName(err),
                .metrics = .{},
                .pr_url = null,
            };
        };

        log.info("task completed: task_id={s} success={} pr_url={s} error={s}", .{
            &types.formatId(request.task_id),
            report.success,
            report.pr_url orelse "none",
            report.error_message orelse "none",
        });

        self.mutex.lock();
        defer self.mutex.unlock();
        self.completed_results.append(self.allocator, report) catch |err| {
            log.err("failed to queue task result: task_id={s} err={}", .{
                &types.formatId(request.task_id),
                err,
            });
        };
    }
};

test "task executor init" {
    const allocator = std.testing.allocator;

    const snapshot_mgr = @import("../snapshot/manager.zig");
    var mgr = try snapshot_mgr.SnapshotManager.init(allocator, "/tmp/marathon-executor-test");
    defer mgr.deinit();

    var pool = vm.VmPool.init(allocator, &mgr, .{});
    defer pool.deinit();

    var executor = TaskExecutor.init(allocator, &pool);
    defer executor.deinit();
}
