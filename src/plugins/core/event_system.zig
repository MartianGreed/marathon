const std = @import("std");
const plugin_api = @import("plugin_api.zig");

/// Event system for plugin hooks
pub const EventSystem = struct {
    allocator: std.mem.Allocator,
    /// Hook subscriptions (hook_type -> list of callback info)
    hook_subscriptions: std.EnumMap(plugin_api.HookType, std.ArrayList(HookSubscription)),
    /// Event history for debugging
    event_history: std.ArrayList(EventRecord),
    /// Maximum events to keep in history
    max_history: usize = 1000,
    
    /// Hook subscription information
    const HookSubscription = struct {
        plugin_name: []const u8,
        callback: plugin_api.PluginAPI.HookFn,
        context: *plugin_api.Context,
        priority: i32 = 0, // Higher priority hooks run first
    };
    
    /// Event record for history/debugging
    const EventRecord = struct {
        timestamp: i64,
        hook_type: plugin_api.HookType,
        plugin_name: ?[]const u8,
        data: ?[]const u8,
        success: bool,
        duration_ns: u64,
        result_message: ?[]const u8,
    };
    
    pub fn init(allocator: std.mem.Allocator) EventSystem {
        var system = EventSystem{
            .allocator = allocator,
            .hook_subscriptions = std.EnumMap(plugin_api.HookType, std.ArrayList(HookSubscription)){},
            .event_history = std.ArrayList(EventRecord).init(allocator),
        };
        
        // Initialize subscription lists for each hook type
        inline for (@typeInfo(plugin_api.HookType).Enum.fields) |field| {
            const hook_type = @field(plugin_api.HookType, field.name);
            system.hook_subscriptions.put(hook_type, std.ArrayList(HookSubscription).init(allocator));
        }
        
        return system;
    }
    
    pub fn deinit(self: *EventSystem) void {
        // Clean up subscriptions
        var iterator = self.hook_subscriptions.iterator();
        while (iterator.next()) |entry| {
            for (entry.value_ptr.items) |subscription| {
                self.allocator.free(subscription.plugin_name);
            }
            entry.value_ptr.deinit();
        }
        
        // Clean up event history
        for (self.event_history.items) |record| {
            if (record.plugin_name) |name| self.allocator.free(name);
            if (record.data) |data| self.allocator.free(data);
            if (record.result_message) |msg| self.allocator.free(msg);
        }
        self.event_history.deinit();
    }
    
    /// Subscribe to a hook
    pub fn subscribeHook(
        self: *EventSystem, 
        hook_type: plugin_api.HookType,
        plugin_name: []const u8,
        callback: plugin_api.PluginAPI.HookFn,
        context: *plugin_api.Context,
        priority: i32
    ) !void {
        const subscription = HookSubscription{
            .plugin_name = try self.allocator.dupe(u8, plugin_name),
            .callback = callback,
            .context = context,
            .priority = priority,
        };
        
        if (self.hook_subscriptions.getPtr(hook_type)) |subscriptions| {
            try subscriptions.append(subscription);
            
            // Sort by priority (descending)
            std.sort.insertion(HookSubscription, subscriptions.items, {}, struct {
                pub fn lessThan(_: void, a: HookSubscription, b: HookSubscription) bool {
                    return a.priority > b.priority;
                }
            }.lessThan);
        }
        
        std.log.debug("Plugin '{}' subscribed to hook {} with priority {}", .{ plugin_name, hook_type, priority });
    }
    
    /// Unsubscribe from a hook
    pub fn unsubscribeHook(self: *EventSystem, hook_type: plugin_api.HookType, plugin_name: []const u8) !void {
        if (self.hook_subscriptions.getPtr(hook_type)) |subscriptions| {
            var i: usize = 0;
            while (i < subscriptions.items.len) {
                if (std.mem.eql(u8, subscriptions.items[i].plugin_name, plugin_name)) {
                    self.allocator.free(subscriptions.items[i].plugin_name);
                    _ = subscriptions.swapRemove(i);
                    std.log.debug("Plugin '{}' unsubscribed from hook {}", .{ plugin_name, hook_type });
                    return;
                } else {
                    i += 1;
                }
            }
        }
        std.log.warn("Plugin '{}' was not subscribed to hook {}", .{ plugin_name, hook_type });
    }
    
    /// Fire a hook and execute all subscribed callbacks
    pub fn fireHook(self: *EventSystem, hook_type: plugin_api.HookType, trigger_plugin: ?[]const u8, data: ?[]const u8) !void {
        const start_time = std.time.nanoTimestamp();
        var success = true;
        var result_messages = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (result_messages.items) |msg| {
                self.allocator.free(msg);
            }
            result_messages.deinit();
        }
        
        if (self.hook_subscriptions.getPtr(hook_type)) |subscriptions| {
            std.log.debug("Firing hook {} with {} subscribers", .{ hook_type, subscriptions.items.len });
            
            for (subscriptions.items) |subscription| {
                const hook_start = std.time.nanoTimestamp();
                
                const result = subscription.callback(subscription.context, hook_type, data) catch |err| {
                    std.log.err("Hook {} failed in plugin '{}': {}", .{ hook_type, subscription.plugin_name, err });
                    success = false;
                    
                    const error_msg = std.fmt.allocPrint(self.allocator, "Error: {}", .{err}) catch "Unknown error";
                    try result_messages.append(error_msg);
                    
                    // Record failed hook execution
                    try self.recordEvent(.{
                        .timestamp = hook_start,
                        .hook_type = hook_type,
                        .plugin_name = try self.allocator.dupe(u8, subscription.plugin_name),
                        .data = if (data) |d| try self.allocator.dupe(u8, d) else null,
                        .success = false,
                        .duration_ns = @as(u64, @intCast(std.time.nanoTimestamp() - hook_start)),
                        .result_message = try self.allocator.dupe(u8, error_msg),
                    });
                    
                    continue;
                };
                
                // Record successful hook execution
                try self.recordEvent(.{
                    .timestamp = hook_start,
                    .hook_type = hook_type,
                    .plugin_name = try self.allocator.dupe(u8, subscription.plugin_name),
                    .data = if (data) |d| try self.allocator.dupe(u8, d) else null,
                    .success = result.success,
                    .duration_ns = @as(u64, @intCast(std.time.nanoTimestamp() - hook_start)),
                    .result_message = if (result.message) |msg| try self.allocator.dupe(u8, msg) else null,
                });
                
                if (result.message) |msg| {
                    try result_messages.append(try self.allocator.dupe(u8, msg));
                }
                
                if (!result.success) {
                    success = false;
                    std.log.warn("Hook {} returned failure in plugin '{}': {s}", .{ 
                        hook_type, 
                        subscription.plugin_name, 
                        result.message orelse "No message"
                    });
                }
                
                // Stop hook chain if requested
                if (!result.continue_chain) {
                    std.log.debug("Hook chain stopped by plugin '{}'", .{subscription.plugin_name});
                    break;
                }
            }
        }
        
        const total_duration = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
        std.log.debug("Hook {} completed in {}ns (success: {})", .{ hook_type, total_duration, success });
        
        // Record overall hook event
        try self.recordEvent(.{
            .timestamp = start_time,
            .hook_type = hook_type,
            .plugin_name = if (trigger_plugin) |tp| try self.allocator.dupe(u8, tp) else null,
            .data = if (data) |d| try self.allocator.dupe(u8, d) else null,
            .success = success,
            .duration_ns = total_duration,
            .result_message = if (result_messages.items.len > 0) try std.mem.join(self.allocator, "; ", result_messages.items) else null,
        });
    }
    
    /// Get hooks subscribed by a specific plugin
    pub fn getPluginHooks(self: *EventSystem, plugin_name: []const u8) ![]const plugin_api.HookType {
        var hooks = std.ArrayList(plugin_api.HookType).init(self.allocator);
        
        var iterator = self.hook_subscriptions.iterator();
        while (iterator.next()) |entry| {
            const hook_type = entry.key_ptr.*;
            const subscriptions = entry.value_ptr.*;
            
            for (subscriptions.items) |subscription| {
                if (std.mem.eql(u8, subscription.plugin_name, plugin_name)) {
                    try hooks.append(hook_type);
                    break;
                }
            }
        }
        
        return hooks.toOwnedSlice();
    }
    
    /// Get subscription statistics
    pub fn getStats(self: *EventSystem) HookStats {
        var stats = HookStats{};
        
        var iterator = self.hook_subscriptions.iterator();
        while (iterator.next()) |entry| {
            stats.total_subscriptions += entry.value_ptr.items.len;
        }
        
        stats.total_events = self.event_history.items.len;
        
        // Calculate success rate from recent events
        var recent_events: usize = 0;
        var successful_events: usize = 0;
        const now = std.time.timestamp();
        
        for (self.event_history.items) |record| {
            if (now - record.timestamp < 3600) { // Last hour
                recent_events += 1;
                if (record.success) successful_events += 1;
            }
        }
        
        stats.success_rate = if (recent_events > 0) 
            (@as(f32, @floatFromInt(successful_events)) / @as(f32, @floatFromInt(recent_events))) * 100.0 
        else 
            100.0;
        
        return stats;
    }
    
    /// Hook statistics
    pub const HookStats = struct {
        total_subscriptions: usize = 0,
        total_events: usize = 0,
        success_rate: f32 = 100.0,
    };
    
    /// Get recent event history
    pub fn getRecentEvents(self: *EventSystem, limit: usize) []const EventRecord {
        const start_index = if (self.event_history.items.len > limit) 
            self.event_history.items.len - limit 
        else 
            0;
        
        return self.event_history.items[start_index..];
    }
    
    /// Clear event history
    pub fn clearHistory(self: *EventSystem) void {
        for (self.event_history.items) |record| {
            if (record.plugin_name) |name| self.allocator.free(name);
            if (record.data) |data| self.allocator.free(data);
            if (record.result_message) |msg| self.allocator.free(msg);
        }
        self.event_history.clearRetainingCapacity();
    }
    
    // Private methods
    
    fn recordEvent(self: *EventSystem, record: EventRecord) !void {
        // Limit history size
        if (self.event_history.items.len >= self.max_history) {
            const old_record = self.event_history.orderedRemove(0);
            if (old_record.plugin_name) |name| self.allocator.free(name);
            if (old_record.data) |data| self.allocator.free(data);
            if (old_record.result_message) |msg| self.allocator.free(msg);
        }
        
        try self.event_history.append(record);
    }
};

test "event system basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var event_system = EventSystem.init(allocator);
    defer event_system.deinit();
    
    // Test stats
    const stats = event_system.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats.total_subscriptions);
    try std.testing.expectEqual(@as(usize, 0), stats.total_events);
    
    // Test recent events
    const events = event_system.getRecentEvents(10);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}