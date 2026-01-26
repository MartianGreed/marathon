const std = @import("std");
const common = @import("common");
const types = common.types;
const registry = @import("../registry/registry.zig");

const log = std.log.scoped(.scheduler);

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    node_registry: *registry.NodeRegistry,
    task_queue: TaskQueue,
    tasks: std.AutoHashMap(types.TaskId, *TaskContext),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, node_registry: *registry.NodeRegistry) Scheduler {
        return .{
            .allocator = allocator,
            .node_registry = node_registry,
            .task_queue = TaskQueue.init(allocator),
            .tasks = std.AutoHashMap(types.TaskId, *TaskContext).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Scheduler) void {
        var it = self.tasks.valueIterator();
        while (it.next()) |ctx| {
            ctx.*.deinit(self.allocator);
            self.allocator.destroy(ctx.*);
        }
        self.tasks.deinit();
        self.task_queue.deinit();
    }

    pub fn submitTask(self: *Scheduler, task: types.Task) !types.TaskId {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ctx = try self.allocator.create(TaskContext);
        ctx.* = TaskContext.init(self.allocator, task);

        try self.tasks.put(task.id, ctx);
        try self.task_queue.enqueue(task.id);

        log.info("task submitted: task_id={s} client_id={s} repo={s}", .{
            &types.formatId(task.id),
            &types.formatId(task.client_id),
            task.repo_url,
        });

        return task.id;
    }

    pub fn getTask(self: *Scheduler, task_id: types.TaskId) ?TaskSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ctx = self.tasks.get(task_id) orelse return null;
        return TaskSnapshot{
            .task = ctx.*.task,
            .subscriber_count = ctx.*.subscribers.items.len,
        };
    }

    pub fn getTaskState(self: *Scheduler, task_id: types.TaskId) ?types.TaskState {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ctx = self.tasks.get(task_id) orelse return null;
        return ctx.*.task.state;
    }

    pub fn scheduleNext(self: *Scheduler) ?ScheduleResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const task_id = self.task_queue.dequeue() orelse return null;
        const ctx = self.tasks.get(task_id) orelse return null;

        const node = self.selectNode() orelse {
            self.task_queue.enqueue(task_id) catch {};
            log.warn("no available node, task requeued: task_id={s}", .{&types.formatId(task_id)});
            return null;
        };

        ctx.task.state = .starting;
        ctx.task.node_id = node.node_id;
        ctx.task.started_at = std.time.milliTimestamp();

        log.info("task scheduled: task_id={s} node_id={s}", .{
            &types.formatId(task_id),
            &types.formatId(node.node_id),
        });

        return .{
            .task = &ctx.task,
            .node_id = node.node_id,
        };
    }

    fn selectNode(self: *Scheduler) ?*const types.NodeStatus {
        var best_node: ?*const types.NodeStatus = null;
        var best_score: f64 = 0.0;

        var it = self.node_registry.nodes.valueIterator();
        while (it.next()) |status| {
            const score = status.score();
            if (score > best_score) {
                best_score = score;
                best_node = status;
            }
        }

        return best_node;
    }

    pub fn completeTask(self: *Scheduler, task_id: types.TaskId, result: TaskResult) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ctx = self.tasks.get(task_id) orelse return;
        ctx.task.state = result.state;
        ctx.task.completed_at = std.time.milliTimestamp();
        ctx.task.usage = result.usage;
        ctx.task.error_message = result.error_message;
        ctx.task.pr_url = result.pr_url;

        log.info("task completed: task_id={s} state={s}", .{ &types.formatId(task_id), @tagName(result.state) });
    }

    pub fn cancelTask(self: *Scheduler, task_id: types.TaskId) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ctx = self.tasks.get(task_id) orelse return false;
        if (ctx.task.state.isTerminal()) {
            log.warn("cancel failed, task already terminal: task_id={s}", .{&types.formatId(task_id)});
            return false;
        }

        ctx.task.state = .cancelled;
        ctx.task.completed_at = std.time.milliTimestamp();

        log.info("task cancelled: task_id={s}", .{&types.formatId(task_id)});
        return true;
    }

    pub fn listTasks(
        self: *Scheduler,
        allocator: std.mem.Allocator,
        client_id: types.ClientId,
        state_filter: ?types.TaskState,
        limit: u32,
        offset: u32,
    ) !ListTasksResult {
        const capped_limit = @min(limit, 1000);

        self.mutex.lock();
        defer self.mutex.unlock();

        var matching: std.ArrayListUnmanaged(types.Task) = .empty;
        defer matching.deinit(allocator);

        var it = self.tasks.valueIterator();
        while (it.next()) |ctx_ptr| {
            const ctx = ctx_ptr.*;
            if (!std.mem.eql(u8, &ctx.task.client_id, &client_id)) continue;
            if (state_filter) |filter| {
                if (ctx.task.state != filter) continue;
            }
            try matching.append(allocator, ctx.task);
        }

        const total_count: u32 = @intCast(matching.items.len);
        const start = @min(offset, total_count);
        const end = @min(start + capped_limit, total_count);
        const page = matching.items[start..end];

        const tasks = try allocator.alloc(types.Task, page.len);
        @memcpy(tasks, page);

        return .{
            .tasks = tasks,
            .total_count = total_count,
        };
    }
};

pub const TaskContext = struct {
    allocator: std.mem.Allocator,
    task: types.Task,
    subscribers: std.ArrayListUnmanaged(*EventSubscriber),

    pub fn init(allocator: std.mem.Allocator, task: types.Task) TaskContext {
        return .{
            .allocator = allocator,
            .task = task,
            .subscribers = .empty,
        };
    }

    pub fn deinit(self: *TaskContext, allocator: std.mem.Allocator) void {
        self.subscribers.deinit(allocator);
    }

    pub fn subscribe(self: *TaskContext, subscriber: *EventSubscriber) !void {
        try self.subscribers.append(self.allocator, subscriber);
    }

    pub fn notify(self: *TaskContext, event: common.protocol.TaskEvent) void {
        for (self.subscribers.items) |sub| {
            sub.onEvent(event);
        }
    }
};

pub const EventSubscriber = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, common.protocol.TaskEvent) void,

    pub fn onEvent(self: *EventSubscriber, event: common.protocol.TaskEvent) void {
        self.callback(self.context, event);
    }
};

pub const ScheduleResult = struct {
    task: *types.Task,
    node_id: types.NodeId,
};

pub const TaskSnapshot = struct {
    task: types.Task,
    subscriber_count: usize,
};

pub const TaskResult = struct {
    state: types.TaskState,
    usage: types.UsageMetrics,
    error_message: ?[]const u8,
    pr_url: ?[]const u8,
};

pub const ListTasksResult = struct {
    tasks: []types.Task,
    total_count: u32,
};

const TaskQueue = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(types.TaskId),

    fn init(allocator: std.mem.Allocator) TaskQueue {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    fn deinit(self: *TaskQueue) void {
        self.items.deinit(self.allocator);
    }

    fn enqueue(self: *TaskQueue, task_id: types.TaskId) !void {
        try self.items.append(self.allocator, task_id);
    }

    fn dequeue(self: *TaskQueue) ?types.TaskId {
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }
};

test "scheduler basic operations" {
    const allocator = std.testing.allocator;

    var node_reg = registry.NodeRegistry.init(allocator);
    defer node_reg.deinit();

    var sched = Scheduler.init(allocator, &node_reg);
    defer sched.deinit();

    var client_id: types.ClientId = undefined;
    @memset(&client_id, 0);

    var task = try types.Task.init(allocator, client_id, "https://github.com/test/repo", "main", "test prompt");
    defer task.deinit();

    const id = try sched.submitTask(task);
    const snapshot = sched.getTask(id);
    try std.testing.expect(snapshot != null);
    try std.testing.expectEqual(types.TaskState.queued, snapshot.?.task.state);
}

test "scheduler getTask returns copy not pointer" {
    const allocator = std.testing.allocator;

    var node_reg = registry.NodeRegistry.init(allocator);
    defer node_reg.deinit();

    var sched = Scheduler.init(allocator, &node_reg);
    defer sched.deinit();

    var client_id: types.ClientId = undefined;
    @memset(&client_id, 0);

    var task = try types.Task.init(allocator, client_id, "https://github.com/test/repo", "main", "test prompt");
    defer task.deinit();

    const id = try sched.submitTask(task);

    const snapshot1 = sched.getTask(id).?;
    const snapshot2 = sched.getTask(id).?;

    try std.testing.expectEqual(snapshot1.task.state, snapshot2.task.state);
    try std.testing.expectEqualSlices(u8, &snapshot1.task.id, &snapshot2.task.id);
}

test "scheduler getTaskState returns state only" {
    const allocator = std.testing.allocator;

    var node_reg = registry.NodeRegistry.init(allocator);
    defer node_reg.deinit();

    var sched = Scheduler.init(allocator, &node_reg);
    defer sched.deinit();

    var client_id: types.ClientId = undefined;
    @memset(&client_id, 0);

    var task = try types.Task.init(allocator, client_id, "https://github.com/test/repo", "main", "test prompt");
    defer task.deinit();

    const id = try sched.submitTask(task);

    const state = sched.getTaskState(id);
    try std.testing.expect(state != null);
    try std.testing.expectEqual(types.TaskState.queued, state.?);

    var unknown_id: types.TaskId = undefined;
    @memset(&unknown_id, 0xFF);
    try std.testing.expect(sched.getTaskState(unknown_id) == null);
}

test "scheduler cancelTask" {
    const allocator = std.testing.allocator;

    var node_reg = registry.NodeRegistry.init(allocator);
    defer node_reg.deinit();

    var sched = Scheduler.init(allocator, &node_reg);
    defer sched.deinit();

    var client_id: types.ClientId = undefined;
    @memset(&client_id, 0);

    var task = try types.Task.init(allocator, client_id, "https://github.com/test/repo", "main", "test prompt");
    defer task.deinit();

    const id = try sched.submitTask(task);

    const cancelled = sched.cancelTask(id);
    try std.testing.expect(cancelled);

    const state = sched.getTaskState(id);
    try std.testing.expectEqual(types.TaskState.cancelled, state.?);

    const cancelled_again = sched.cancelTask(id);
    try std.testing.expect(!cancelled_again);
}

test "scheduler listTasks filters by client" {
    const allocator = std.testing.allocator;

    var node_reg = registry.NodeRegistry.init(allocator);
    defer node_reg.deinit();

    var sched = Scheduler.init(allocator, &node_reg);
    defer sched.deinit();

    var client1: types.ClientId = undefined;
    @memset(&client1, 1);

    var client2: types.ClientId = undefined;
    @memset(&client2, 2);

    var task1 = try types.Task.init(allocator, client1, "https://github.com/test/repo1", "main", "prompt1");
    defer task1.deinit();
    _ = try sched.submitTask(task1);

    var task2 = try types.Task.init(allocator, client1, "https://github.com/test/repo2", "main", "prompt2");
    defer task2.deinit();
    _ = try sched.submitTask(task2);

    var task3 = try types.Task.init(allocator, client2, "https://github.com/test/repo3", "main", "prompt3");
    defer task3.deinit();
    _ = try sched.submitTask(task3);

    const result1 = try sched.listTasks(allocator, client1, null, 100, 0);
    defer allocator.free(result1.tasks);
    try std.testing.expectEqual(@as(u32, 2), result1.total_count);

    const result2 = try sched.listTasks(allocator, client2, null, 100, 0);
    defer allocator.free(result2.tasks);
    try std.testing.expectEqual(@as(u32, 1), result2.total_count);
}

test "scheduler listTasks respects limit" {
    const allocator = std.testing.allocator;

    var node_reg = registry.NodeRegistry.init(allocator);
    defer node_reg.deinit();

    var sched = Scheduler.init(allocator, &node_reg);
    defer sched.deinit();

    var client_id: types.ClientId = undefined;
    @memset(&client_id, 0);

    for (0..5) |_| {
        var task = try types.Task.init(allocator, client_id, "https://github.com/test/repo", "main", "prompt");
        defer task.deinit();
        _ = try sched.submitTask(task);
    }

    const result = try sched.listTasks(allocator, client_id, null, 2, 0);
    defer allocator.free(result.tasks);

    try std.testing.expectEqual(@as(usize, 2), result.tasks.len);
    try std.testing.expectEqual(@as(u32, 5), result.total_count);
}

test "scheduler listTasks filters by state" {
    const allocator = std.testing.allocator;

    var node_reg = registry.NodeRegistry.init(allocator);
    defer node_reg.deinit();

    var sched = Scheduler.init(allocator, &node_reg);
    defer sched.deinit();

    var client_id: types.ClientId = undefined;
    @memset(&client_id, 0);

    var task1 = try types.Task.init(allocator, client_id, "https://github.com/test/repo1", "main", "prompt1");
    defer task1.deinit();
    const id1 = try sched.submitTask(task1);

    var task2 = try types.Task.init(allocator, client_id, "https://github.com/test/repo2", "main", "prompt2");
    defer task2.deinit();
    _ = try sched.submitTask(task2);

    _ = sched.cancelTask(id1);

    const queued = try sched.listTasks(allocator, client_id, .queued, 100, 0);
    defer allocator.free(queued.tasks);
    try std.testing.expectEqual(@as(u32, 1), queued.total_count);

    const cancelled = try sched.listTasks(allocator, client_id, .cancelled, 100, 0);
    defer allocator.free(cancelled.tasks);
    try std.testing.expectEqual(@as(u32, 1), cancelled.total_count);
}

test "scheduler completeTask updates state and metrics" {
    const allocator = std.testing.allocator;

    var node_reg = registry.NodeRegistry.init(allocator);
    defer node_reg.deinit();

    var sched = Scheduler.init(allocator, &node_reg);
    defer sched.deinit();

    var client_id: types.ClientId = undefined;
    @memset(&client_id, 0);

    var task = try types.Task.init(allocator, client_id, "https://github.com/test/repo", "main", "test prompt");
    defer task.deinit();

    const id = try sched.submitTask(task);

    const result = TaskResult{
        .state = .completed,
        .usage = .{
            .compute_time_ms = 1000,
            .input_tokens = 100,
            .output_tokens = 50,
            .cache_read_tokens = 0,
            .cache_write_tokens = 0,
            .tool_calls = 5,
        },
        .error_message = null,
        .pr_url = "https://github.com/test/repo/pull/1",
    };

    sched.completeTask(id, result);

    const snapshot = sched.getTask(id).?;
    try std.testing.expectEqual(types.TaskState.completed, snapshot.task.state);
    try std.testing.expectEqual(@as(i64, 100), snapshot.task.usage.input_tokens);
    try std.testing.expectEqual(@as(i64, 50), snapshot.task.usage.output_tokens);
}
