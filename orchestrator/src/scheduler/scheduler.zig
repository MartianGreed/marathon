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

    pub fn getTask(self: *Scheduler, task_id: types.TaskId) ?*TaskContext {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tasks.get(task_id);
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

pub const TaskResult = struct {
    state: types.TaskState,
    usage: types.UsageMetrics,
    error_message: ?[]const u8,
    pr_url: ?[]const u8,
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
    const ctx = sched.getTask(id);
    try std.testing.expect(ctx != null);
    try std.testing.expectEqual(types.TaskState.queued, ctx.?.task.state);
}
