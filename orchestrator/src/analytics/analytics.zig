const std = @import("std");
const db = @import("../db/root.zig");
const types = @import("../db/types.zig");

pub const TaskMetrics = struct {
    total_tasks: u32 = 0,
    completed_tasks: u32 = 0,
    failed_tasks: u32 = 0,
    running_tasks: u32 = 0,
    queued_tasks: u32 = 0,
    average_execution_time_ms: u64 = 0,
    success_rate: f64 = 0.0,
};

pub const ResourceUsage = struct {
    total_cpu_usage: f64 = 0.0,
    average_cpu_usage: f64 = 0.0,
    total_memory_usage: f64 = 0.0,
    average_memory_usage: f64 = 0.0,
    total_disk_usage: f64 = 0.0,
    active_nodes: u32 = 0,
    healthy_nodes: u32 = 0,
};

pub const UserActivity = struct {
    total_active_users: u32 = 0,
    daily_active_users: u32 = 0,
    weekly_active_users: u32 = 0,
    monthly_active_users: u32 = 0,
    new_registrations: u32 = 0,
    user_engagement_score: f64 = 0.0,
};

pub const SystemHealth = struct {
    uptime_percentage: f64 = 1.0,
    average_response_time_ms: u64 = 100,
    error_rate: f64 = 0.0,
    active_connections: u32 = 0,
    queue_length: u32 = 0,
    last_updated: i64,
};

pub const TimeSeriesPoint = struct {
    timestamp: i64,
    value: f64,
    label: ?[]const u8 = null,
};

pub const TaskPerformanceData = struct {
    execution_times: []TimeSeriesPoint,
    success_rates: []TimeSeriesPoint,
    failure_rates: []TimeSeriesPoint,
    throughput: []TimeSeriesPoint,
};

pub const ResourceTimeSeriesData = struct {
    cpu_usage: []TimeSeriesPoint,
    memory_usage: []TimeSeriesPoint,
    disk_usage: []TimeSeriesPoint,
    network_io: []TimeSeriesPoint,
};

pub const UserActivityData = struct {
    login_frequency: []TimeSeriesPoint,
    task_creation: []TimeSeriesPoint,
    workspace_usage: []TimeSeriesPoint,
};

pub const TeamProductivityData = struct {
    tasks_completed: []TimeSeriesPoint,
    collaboration_score: []TimeSeriesPoint,
    code_commits: []TimeSeriesPoint,
    pr_creation: []TimeSeriesPoint,
};

pub const AnalyticsDashboard = struct {
    overview: struct {
        task_metrics: TaskMetrics,
        resource_usage: ResourceUsage,
        user_activity: UserActivity,
        system_health: SystemHealth,
    },
    time_series: struct {
        task_performance: TaskPerformanceData,
        resource_usage: ResourceTimeSeriesData,
        user_activity: UserActivityData,
        team_productivity: TeamProductivityData,
    },
    last_updated: i64,
};

pub const AnalyticsService = struct {
    db_pool: *db.Pool,
    allocator: std.mem.Allocator,
    start_time: i64,
    
    pub fn init(allocator: std.mem.Allocator, db_pool: *db.Pool) AnalyticsService {
        return AnalyticsService{
            .db_pool = db_pool,
            .allocator = allocator,
            .start_time = std.time.timestamp(),
        };
    }
    
    pub fn getTaskMetrics(self: *AnalyticsService, start_time: ?i64, end_time: ?i64) !TaskMetrics {
        const conn = try self.db_pool.acquire();
        defer self.db_pool.release(conn);
        
        var query = std.ArrayList(u8).init(self.allocator);
        defer query.deinit();
        
        try query.appendSlice("SELECT state, COUNT(*) as count, AVG(compute_time_ms) as avg_time FROM tasks");
        
        if (start_time != null and end_time != null) {
            try query.writer().print(" WHERE created_at >= {} AND created_at <= {}", .{start_time.?, end_time.?});
        }
        
        try query.appendSlice(" GROUP BY state");
        
        const result = conn.query(query.items, .{}) catch |err| {
            std.log.err("Failed to query task metrics: {}", .{err});
            return TaskMetrics{};
        };
        defer result.deinit();
        
        var metrics = TaskMetrics{};
        var total_execution_time: u64 = 0;
        var completed_count: u32 = 0;
        
        while (result.next()) |row| {
            const state = row.get([]const u8, 0);
            const count = row.get(i32, 1);
            const avg_time_opt = row.get(?f64, 2);
            
            metrics.total_tasks += @intCast(count);
            
            if (std.mem.eql(u8, state, "completed")) {
                metrics.completed_tasks = @intCast(count);
                completed_count = @intCast(count);
                if (avg_time_opt) |avg_time| {
                    total_execution_time = @intFromFloat(avg_time * @as(f64, @floatFromInt(count)));
                }
            } else if (std.mem.eql(u8, state, "failed")) {
                metrics.failed_tasks = @intCast(count);
            } else if (std.mem.eql(u8, state, "running")) {
                metrics.running_tasks = @intCast(count);
            } else if (std.mem.eql(u8, state, "queued")) {
                metrics.queued_tasks = @intCast(count);
            }
        }
        
        if (completed_count > 0) {
            metrics.average_execution_time_ms = total_execution_time / completed_count;
        }
        
        if (metrics.total_tasks > 0) {
            metrics.success_rate = @as(f64, @floatFromInt(metrics.completed_tasks)) / @as(f64, @floatFromInt(metrics.total_tasks));
        }
        
        return metrics;
    }
    
    pub fn getResourceUsage(self: *AnalyticsService, start_time: ?i64, end_time: ?i64) !ResourceUsage {
        const conn = try self.db_pool.acquire();
        defer self.db_pool.release(conn);
        
        var query = std.ArrayList(u8).init(self.allocator);
        defer query.deinit();
        
        try query.appendSlice("SELECT AVG(cpu_usage), AVG(memory_usage), COUNT(*), COUNT(CASE WHEN healthy = true THEN 1 END) FROM nodes");
        
        if (start_time != null and end_time != null) {
            try query.writer().print(" WHERE updated_at >= {} AND updated_at <= {}", .{start_time.?, end_time.?});
        }
        
        const result = conn.query(query.items, .{}) catch |err| {
            std.log.err("Failed to query resource usage: {}", .{err});
            return ResourceUsage{};
        };
        defer result.deinit();
        
        var usage = ResourceUsage{};
        
        if (result.next()) |row| {
            usage.average_cpu_usage = row.get(?f64, 0) orelse 0.0;
            usage.average_memory_usage = row.get(?f64, 1) orelse 0.0;
            usage.active_nodes = @intCast(row.get(i32, 2));
            usage.healthy_nodes = @intCast(row.get(i32, 3));
            
            usage.total_cpu_usage = usage.average_cpu_usage * @as(f64, @floatFromInt(usage.active_nodes));
            usage.total_memory_usage = usage.average_memory_usage * @as(f64, @floatFromInt(usage.active_nodes));
        }
        
        return usage;
    }
    
    pub fn getUserActivity(self: *AnalyticsService, start_time: ?i64, end_time: ?i64) !UserActivity {
        const conn = try self.db_pool.acquire();
        defer self.db_pool.release(conn);
        
        var query = std.ArrayList(u8).init(self.allocator);
        defer query.deinit();
        
        try query.appendSlice("SELECT COUNT(*) as total_users, COUNT(CASE WHEN created_at >= ");
        try query.writer().print("{}", .{std.time.timestamp() - 86400}); // Last 24h
        try query.appendSlice(" THEN 1 END) as daily_users FROM users");
        
        if (start_time != null and end_time != null) {
            try query.writer().print(" WHERE created_at >= {} AND created_at <= {}", .{start_time.?, end_time.?});
        }
        
        const result = conn.query(query.items, .{}) catch |err| {
            std.log.err("Failed to query user activity: {}", .{err});
            return UserActivity{};
        };
        defer result.deinit();
        
        var activity = UserActivity{};
        
        if (result.next()) |row| {
            activity.total_active_users = @intCast(row.get(i32, 0));
            activity.daily_active_users = @intCast(row.get(i32, 1));
            
            // Calculate weekly and monthly users (simplified for now)
            activity.weekly_active_users = activity.daily_active_users * 5; // Rough estimate
            activity.monthly_active_users = activity.total_active_users;
        }
        
        return activity;
    }
    
    pub fn getSystemHealth(self: *AnalyticsService) SystemHealth {
        const current_time = std.time.timestamp();
        const uptime_seconds = current_time - self.start_time;
        
        return SystemHealth{
            .uptime_percentage = 0.999, // 99.9% uptime (mock)
            .average_response_time_ms = 150, // Mock average response time
            .error_rate = 0.001, // 0.1% error rate (mock)
            .active_connections = 42, // Mock active connections
            .queue_length = 5, // Mock queue length
            .last_updated = current_time,
        };
    }
    
    pub fn getTaskPerformanceTimeSeries(self: *AnalyticsService, start_time: ?i64, end_time: ?i64) !TaskPerformanceData {
        const conn = try self.db_pool.acquire();
        defer self.db_pool.release(conn);
        
        // Generate time series data (simplified implementation)
        var execution_times = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        var success_rates = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        var failure_rates = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        var throughput = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        
        const now = std.time.timestamp();
        const start = start_time orelse (now - 86400 * 7); // Last 7 days
        const end = end_time orelse now;
        const interval = (end - start) / 24; // 24 data points
        
        var i: i64 = start;
        while (i <= end) : (i += interval) {
            // Mock data generation - in real implementation, query database
            try execution_times.append(TimeSeriesPoint{
                .timestamp = i,
                .value = 120000 + @as(f64, @floatFromInt(@mod(i, 60000))), // Mock execution time
            });
            
            try success_rates.append(TimeSeriesPoint{
                .timestamp = i,
                .value = 0.95 + (@as(f64, @floatFromInt(@mod(i, 100))) / 1000), // Mock success rate
            });
            
            try failure_rates.append(TimeSeriesPoint{
                .timestamp = i,
                .value = 0.05 - (@as(f64, @floatFromInt(@mod(i, 100))) / 1000), // Mock failure rate
            });
            
            try throughput.append(TimeSeriesPoint{
                .timestamp = i,
                .value = 50 + @as(f64, @floatFromInt(@mod(i, 20))), // Mock throughput
            });
        }
        
        return TaskPerformanceData{
            .execution_times = try execution_times.toOwnedSlice(),
            .success_rates = try success_rates.toOwnedSlice(),
            .failure_rates = try failure_rates.toOwnedSlice(),
            .throughput = try throughput.toOwnedSlice(),
        };
    }
    
    pub fn getResourceTimeSeriesData(self: *AnalyticsService, start_time: ?i64, end_time: ?i64) !ResourceTimeSeriesData {
        // Generate mock time series data
        var cpu_usage = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        var memory_usage = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        var disk_usage = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        var network_io = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        
        const now = std.time.timestamp();
        const start = start_time orelse (now - 86400 * 7);
        const end = end_time orelse now;
        const interval = (end - start) / 24;
        
        var i: i64 = start;
        while (i <= end) : (i += interval) {
            try cpu_usage.append(TimeSeriesPoint{
                .timestamp = i,
                .value = 0.3 + (@as(f64, @floatFromInt(@mod(i, 1000))) / 10000),
            });
            
            try memory_usage.append(TimeSeriesPoint{
                .timestamp = i,
                .value = 0.6 + (@as(f64, @floatFromInt(@mod(i, 500))) / 5000),
            });
            
            try disk_usage.append(TimeSeriesPoint{
                .timestamp = i,
                .value = 0.4 + (@as(f64, @floatFromInt(@mod(i, 200))) / 2000),
            });
            
            try network_io.append(TimeSeriesPoint{
                .timestamp = i,
                .value = @as(f64, @floatFromInt(1024 * 1024 * (@mod(i, 100) + 10))), // Mock network I/O
            });
        }
        
        return ResourceTimeSeriesData{
            .cpu_usage = try cpu_usage.toOwnedSlice(),
            .memory_usage = try memory_usage.toOwnedSlice(),
            .disk_usage = try disk_usage.toOwnedSlice(),
            .network_io = try network_io.toOwnedSlice(),
        };
    }
    
    pub fn getUserActivityData(self: *AnalyticsService, start_time: ?i64, end_time: ?i64) !UserActivityData {
        // Generate mock time series data
        var login_frequency = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        var task_creation = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        var workspace_usage = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        
        const now = std.time.timestamp();
        const start = start_time orelse (now - 86400 * 7);
        const end = end_time orelse now;
        const interval = (end - start) / 24;
        
        var i: i64 = start;
        while (i <= end) : (i += interval) {
            try login_frequency.append(TimeSeriesPoint{
                .timestamp = i,
                .value = @as(f64, @floatFromInt(10 + @mod(i, 20))),
            });
            
            try task_creation.append(TimeSeriesPoint{
                .timestamp = i,
                .value = @as(f64, @floatFromInt(5 + @mod(i, 15))),
            });
            
            try workspace_usage.append(TimeSeriesPoint{
                .timestamp = i,
                .value = @as(f64, @floatFromInt(3 + @mod(i, 10))),
            });
        }
        
        return UserActivityData{
            .login_frequency = try login_frequency.toOwnedSlice(),
            .task_creation = try task_creation.toOwnedSlice(),
            .workspace_usage = try workspace_usage.toOwnedSlice(),
        };
    }
    
    pub fn getDashboardData(self: *AnalyticsService, start_time: ?i64, end_time: ?i64) !AnalyticsDashboard {
        const task_metrics = try self.getTaskMetrics(start_time, end_time);
        const resource_usage = try self.getResourceUsage(start_time, end_time);
        const user_activity = try self.getUserActivity(start_time, end_time);
        const system_health = self.getSystemHealth();
        
        const task_performance = try self.getTaskPerformanceTimeSeries(start_time, end_time);
        const resource_time_series = try self.getResourceTimeSeriesData(start_time, end_time);
        const user_activity_data = try self.getUserActivityData(start_time, end_time);
        
        // Mock team productivity data
        var tasks_completed = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        var collaboration_score = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        var code_commits = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        var pr_creation = std.ArrayList(TimeSeriesPoint).init(self.allocator);
        
        const now = std.time.timestamp();
        const start = start_time orelse (now - 86400 * 7);
        const end = end_time orelse now;
        const interval = (end - start) / 24;
        
        var i: i64 = start;
        while (i <= end) : (i += interval) {
            try tasks_completed.append(TimeSeriesPoint{
                .timestamp = i,
                .value = @as(f64, @floatFromInt(8 + @mod(i, 12))),
            });
            
            try collaboration_score.append(TimeSeriesPoint{
                .timestamp = i,
                .value = 0.7 + (@as(f64, @floatFromInt(@mod(i, 100))) / 500),
            });
            
            try code_commits.append(TimeSeriesPoint{
                .timestamp = i,
                .value = @as(f64, @floatFromInt(15 + @mod(i, 25))),
            });
            
            try pr_creation.append(TimeSeriesPoint{
                .timestamp = i,
                .value = @as(f64, @floatFromInt(3 + @mod(i, 8))),
            });
        }
        
        const team_productivity = TeamProductivityData{
            .tasks_completed = try tasks_completed.toOwnedSlice(),
            .collaboration_score = try collaboration_score.toOwnedSlice(),
            .code_commits = try code_commits.toOwnedSlice(),
            .pr_creation = try pr_creation.toOwnedSlice(),
        };
        
        return AnalyticsDashboard{
            .overview = .{
                .task_metrics = task_metrics,
                .resource_usage = resource_usage,
                .user_activity = user_activity,
                .system_health = system_health,
            },
            .time_series = .{
                .task_performance = task_performance,
                .resource_usage = resource_time_series,
                .user_activity = user_activity_data,
                .team_productivity = team_productivity,
            },
            .last_updated = std.time.timestamp(),
        };
    }
    
    pub fn deinit(self: *AnalyticsService) void {
        _ = self; // Analytics service doesn't need special cleanup
    }
};