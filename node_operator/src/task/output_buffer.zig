const std = @import("std");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;

/// Thread-safe buffer for task output events.
/// The task runner pushes output here; the heartbeat drains it for forwarding to orchestrator.
pub const OutputBuffer = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    events: std.ArrayListUnmanaged(protocol.TaskOutputEvent) = .empty,

    pub fn init(allocator: std.mem.Allocator) OutputBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OutputBuffer) void {
        for (self.events.items) |event| {
            self.allocator.free(event.data);
        }
        self.events.deinit(self.allocator);
    }

    pub fn push(self: *OutputBuffer, task_id: types.TaskId, output_type: types.OutputType, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Cap at 200 events to prevent unbounded growth
        if (self.events.items.len >= 200) {
            const old = self.events.orderedRemove(0);
            self.allocator.free(old.data);
        }

        const duped = self.allocator.dupe(u8, data) catch return;
        self.events.append(self.allocator, .{
            .task_id = task_id,
            .output_type = output_type,
            .timestamp = std.time.milliTimestamp(),
            .data = duped,
        }) catch {
            self.allocator.free(duped);
        };
    }

    /// Drain all buffered events. Caller owns the returned slice.
    pub fn drain(self: *OutputBuffer) []protocol.TaskOutputEvent {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.events.toOwnedSlice(self.allocator) catch return &[_]protocol.TaskOutputEvent{};
    }
};
