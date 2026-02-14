const std = @import("std");
const http = std.http;
const json = std.json;
const analytics = @import("analytics.zig");
const auth = @import("../auth/auth.zig");
const db = @import("../db/root.zig");

pub const AnalyticsHandlers = struct {
    analytics_service: *analytics.AnalyticsService,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, analytics_service: *analytics.AnalyticsService) AnalyticsHandlers {
        return AnalyticsHandlers{
            .analytics_service = analytics_service,
            .allocator = allocator,
        };
    }
    
    fn parseTimeParam(param: ?[]const u8) ?i64 {
        if (param) |p| {
            return std.fmt.parseInt(i64, p, 10) catch null;
        }
        return null;
    }
    
    fn writeJsonResponse(response: *http.Server.Response, data: anytype) !void {
        const json_string = json.stringifyAlloc(response.allocator, data, .{}) catch |err| {
            std.log.err("Failed to serialize JSON response: {}", .{err});
            response.status = .internal_server_error;
            try response.writeAll("Internal server error");
            return;
        };
        defer response.allocator.free(json_string);
        
        response.headers.append("Content-Type", "application/json") catch {};
        response.headers.append("Access-Control-Allow-Origin", "*") catch {};
        response.headers.append("Access-Control-Allow-Methods", "GET, POST, OPTIONS") catch {};
        response.headers.append("Access-Control-Allow-Headers", "Content-Type, Authorization") catch {};
        
        try response.writeAll(json_string);
    }
    
    pub fn handleDashboard(self: *AnalyticsHandlers, response: *http.Server.Response, request: *const http.Server.Request) !void {
        // Authentication check
        if (!auth.isAuthenticated(request)) {
            response.status = .unauthorized;
            try response.writeAll("Unauthorized");
            return;
        }
        
        // Parse query parameters for date range
        var start_time: ?i64 = null;
        var end_time: ?i64 = null;
        
        if (request.headers.get("query")) |query_string| {
            var it = std.mem.split(u8, query_string, "&");
            while (it.next()) |param| {
                if (std.mem.startsWith(u8, param, "start=")) {
                    start_time = parseTimeParam(param[6..]);
                } else if (std.mem.startsWith(u8, param, "end=")) {
                    end_time = parseTimeParam(param[4..]);
                }
            }
        }
        
        const dashboard_data = self.analytics_service.getDashboardData(start_time, end_time) catch |err| {
            std.log.err("Failed to get dashboard data: {}", .{err});
            response.status = .internal_server_error;
            try response.writeAll("Failed to retrieve dashboard data");
            return;
        };
        
        try writeJsonResponse(response, dashboard_data);
    }
    
    pub fn handleTaskMetrics(self: *AnalyticsHandlers, response: *http.Server.Response, request: *const http.Server.Request) !void {
        if (!auth.isAuthenticated(request)) {
            response.status = .unauthorized;
            try response.writeAll("Unauthorized");
            return;
        }
        
        var start_time: ?i64 = null;
        var end_time: ?i64 = null;
        
        if (request.headers.get("query")) |query_string| {
            var it = std.mem.split(u8, query_string, "&");
            while (it.next()) |param| {
                if (std.mem.startsWith(u8, param, "start=")) {
                    start_time = parseTimeParam(param[6..]);
                } else if (std.mem.startsWith(u8, param, "end=")) {
                    end_time = parseTimeParam(param[4..]);
                }
            }
        }
        
        const metrics = self.analytics_service.getTaskMetrics(start_time, end_time) catch |err| {
            std.log.err("Failed to get task metrics: {}", .{err});
            response.status = .internal_server_error;
            try response.writeAll("Failed to retrieve task metrics");
            return;
        };
        
        try writeJsonResponse(response, metrics);
    }
    
    pub fn handleResourceUsage(self: *AnalyticsHandlers, response: *http.Server.Response, request: *const http.Server.Request) !void {
        if (!auth.isAuthenticated(request)) {
            response.status = .unauthorized;
            try response.writeAll("Unauthorized");
            return;
        }
        
        var start_time: ?i64 = null;
        var end_time: ?i64 = null;
        
        if (request.headers.get("query")) |query_string| {
            var it = std.mem.split(u8, query_string, "&");
            while (it.next()) |param| {
                if (std.mem.startsWith(u8, param, "start=")) {
                    start_time = parseTimeParam(param[6..]);
                } else if (std.mem.startsWith(u8, param, "end=")) {
                    end_time = parseTimeParam(param[4..]);
                }
            }
        }
        
        const usage = self.analytics_service.getResourceUsage(start_time, end_time) catch |err| {
            std.log.err("Failed to get resource usage: {}", .{err});
            response.status = .internal_server_error;
            try response.writeAll("Failed to retrieve resource usage");
            return;
        };
        
        try writeJsonResponse(response, usage);
    }
    
    pub fn handleUserActivity(self: *AnalyticsHandlers, response: *http.Server.Response, request: *const http.Server.Request) !void {
        if (!auth.isAuthenticated(request)) {
            response.status = .unauthorized;
            try response.writeAll("Unauthorized");
            return;
        }
        
        var start_time: ?i64 = null;
        var end_time: ?i64 = null;
        
        if (request.headers.get("query")) |query_string| {
            var it = std.mem.split(u8, query_string, "&");
            while (it.next()) |param| {
                if (std.mem.startsWith(u8, param, "start=")) {
                    start_time = parseTimeParam(param[6..]);
                } else if (std.mem.startsWith(u8, param, "end=")) {
                    end_time = parseTimeParam(param[4..]);
                }
            }
        }
        
        const activity = self.analytics_service.getUserActivity(start_time, end_time) catch |err| {
            std.log.err("Failed to get user activity: {}", .{err});
            response.status = .internal_server_error;
            try response.writeAll("Failed to retrieve user activity");
            return;
        };
        
        try writeJsonResponse(response, activity);
    }
    
    pub fn handleSystemHealth(self: *AnalyticsHandlers, response: *http.Server.Response, request: *const http.Server.Request) !void {
        if (!auth.isAuthenticated(request)) {
            response.status = .unauthorized;
            try response.writeAll("Unauthorized");
            return;
        }
        
        const health = self.analytics_service.getSystemHealth();
        try writeJsonResponse(response, health);
    }
    
    pub fn handleTaskPerformanceTimeSeries(self: *AnalyticsHandlers, response: *http.Server.Response, request: *const http.Server.Request) !void {
        if (!auth.isAuthenticated(request)) {
            response.status = .unauthorized;
            try response.writeAll("Unauthorized");
            return;
        }
        
        var start_time: ?i64 = null;
        var end_time: ?i64 = null;
        
        if (request.headers.get("query")) |query_string| {
            var it = std.mem.split(u8, query_string, "&");
            while (it.next()) |param| {
                if (std.mem.startsWith(u8, param, "start=")) {
                    start_time = parseTimeParam(param[6..]);
                } else if (std.mem.startsWith(u8, param, "end=")) {
                    end_time = parseTimeParam(param[4..]);
                }
            }
        }
        
        const performance_data = self.analytics_service.getTaskPerformanceTimeSeries(start_time, end_time) catch |err| {
            std.log.err("Failed to get task performance time series: {}", .{err});
            response.status = .internal_server_error;
            try response.writeAll("Failed to retrieve task performance data");
            return;
        };
        
        try writeJsonResponse(response, performance_data);
    }
    
    pub fn handleResourceTimeSeriesData(self: *AnalyticsHandlers, response: *http.Server.Response, request: *const http.Server.Request) !void {
        if (!auth.isAuthenticated(request)) {
            response.status = .unauthorized;
            try response.writeAll("Unauthorized");
            return;
        }
        
        var start_time: ?i64 = null;
        var end_time: ?i64 = null;
        
        if (request.headers.get("query")) |query_string| {
            var it = std.mem.split(u8, query_string, "&");
            while (it.next()) |param| {
                if (std.mem.startsWith(u8, param, "start=")) {
                    start_time = parseTimeParam(param[6..]);
                } else if (std.mem.startsWith(u8, param, "end=")) {
                    end_time = parseTimeParam(param[4..]);
                }
            }
        }
        
        const resource_data = self.analytics_service.getResourceTimeSeriesData(start_time, end_time) catch |err| {
            std.log.err("Failed to get resource time series data: {}", .{err});
            response.status = .internal_server_error;
            try response.writeAll("Failed to retrieve resource time series data");
            return;
        };
        
        try writeJsonResponse(response, resource_data);
    }
    
    pub fn handleExport(self: *AnalyticsHandlers, response: *http.Server.Response, request: *const http.Server.Request) !void {
        if (!auth.isAuthenticated(request)) {
            response.status = .unauthorized;
            try response.writeAll("Unauthorized");
            return;
        }
        
        var format: []const u8 = "csv";
        var start_time: ?i64 = null;
        var end_time: ?i64 = null;
        
        if (request.headers.get("query")) |query_string| {
            var it = std.mem.split(u8, query_string, "&");
            while (it.next()) |param| {
                if (std.mem.startsWith(u8, param, "format=")) {
                    format = param[7..];
                } else if (std.mem.startsWith(u8, param, "start=")) {
                    start_time = parseTimeParam(param[6..]);
                } else if (std.mem.startsWith(u8, param, "end=")) {
                    end_time = parseTimeParam(param[4..]);
                }
            }
        }
        
        if (std.mem.eql(u8, format, "csv")) {
            try self.exportCSV(response, start_time, end_time);
        } else if (std.mem.eql(u8, format, "pdf")) {
            try self.exportPDF(response, start_time, end_time);
        } else {
            response.status = .bad_request;
            try response.writeAll("Invalid format. Supported formats: csv, pdf");
        }
    }
    
    fn exportCSV(self: *AnalyticsHandlers, response: *http.Server.Response, start_time: ?i64, end_time: ?i64) !void {
        const dashboard_data = self.analytics_service.getDashboardData(start_time, end_time) catch |err| {
            std.log.err("Failed to get dashboard data for export: {}", .{err});
            response.status = .internal_server_error;
            try response.writeAll("Failed to export data");
            return;
        };
        
        var csv_content = std.ArrayList(u8).init(self.allocator);
        defer csv_content.deinit();
        
        // CSV Header
        try csv_content.appendSlice("Metric,Value\n");
        
        // Task Metrics
        try csv_content.writer().print("Total Tasks,{}\n", .{dashboard_data.overview.task_metrics.total_tasks});
        try csv_content.writer().print("Completed Tasks,{}\n", .{dashboard_data.overview.task_metrics.completed_tasks});
        try csv_content.writer().print("Failed Tasks,{}\n", .{dashboard_data.overview.task_metrics.failed_tasks});
        try csv_content.writer().print("Success Rate,{d:.2}\n", .{dashboard_data.overview.task_metrics.success_rate});
        try csv_content.writer().print("Average Execution Time (ms),{}\n", .{dashboard_data.overview.task_metrics.average_execution_time_ms});
        
        // Resource Usage
        try csv_content.writer().print("Average CPU Usage,{d:.2}\n", .{dashboard_data.overview.resource_usage.average_cpu_usage});
        try csv_content.writer().print("Average Memory Usage,{d:.2}\n", .{dashboard_data.overview.resource_usage.average_memory_usage});
        try csv_content.writer().print("Active Nodes,{}\n", .{dashboard_data.overview.resource_usage.active_nodes});
        try csv_content.writer().print("Healthy Nodes,{}\n", .{dashboard_data.overview.resource_usage.healthy_nodes});
        
        // User Activity
        try csv_content.writer().print("Total Active Users,{}\n", .{dashboard_data.overview.user_activity.total_active_users});
        try csv_content.writer().print("Daily Active Users,{}\n", .{dashboard_data.overview.user_activity.daily_active_users});
        
        // System Health
        try csv_content.writer().print("System Uptime (%),{d:.2}\n", .{dashboard_data.overview.system_health.uptime_percentage * 100});
        try csv_content.writer().print("Average Response Time (ms),{}\n", .{dashboard_data.overview.system_health.average_response_time_ms});
        try csv_content.writer().print("Error Rate (%),{d:.3}\n", .{dashboard_data.overview.system_health.error_rate * 100});
        
        response.headers.append("Content-Type", "text/csv") catch {};
        response.headers.append("Content-Disposition", "attachment; filename=marathon-analytics.csv") catch {};
        response.headers.append("Access-Control-Allow-Origin", "*") catch {};
        
        try response.writeAll(csv_content.items);
    }
    
    fn exportPDF(self: *AnalyticsHandlers, response: *http.Server.Response, start_time: ?i64, end_time: ?i64) !void {
        // For now, return a simple text-based PDF placeholder
        // In a real implementation, you'd use a PDF library
        const pdf_content = 
            \\%PDF-1.4
            \\1 0 obj
            \\<<
            \\/Type /Catalog
            \\/Pages 2 0 R
            \\>>
            \\endobj
            \\2 0 obj
            \\<<
            \\/Type /Pages
            \\/Kids [3 0 R]
            \\/Count 1
            \\>>
            \\endobj
            \\3 0 obj
            \\<<
            \\/Type /Page
            \\/Parent 2 0 R
            \\/MediaBox [0 0 612 792]
            \\/Contents 4 0 R
            \\>>
            \\endobj
            \\4 0 obj
            \\<<
            \\/Length 44
            \\>>
            \\stream
            \\BT
            \\/F1 12 Tf
            \\100 700 Td
            \\(Marathon Analytics Report) Tj
            \\ET
            \\endstream
            \\endobj
            \\xref
            \\0 5
            \\0000000000 65535 f 
            \\0000000010 00000 n 
            \\0000000053 00000 n 
            \\0000000107 00000 n 
            \\0000000179 00000 n 
            \\trailer
            \\<<
            \\/Size 5
            \\/Root 1 0 R
            \\>>
            \\startxref
            \\274
            \\%%EOF
        ;
        
        response.headers.append("Content-Type", "application/pdf") catch {};
        response.headers.append("Content-Disposition", "attachment; filename=marathon-analytics.pdf") catch {};
        response.headers.append("Access-Control-Allow-Origin", "*") catch {};
        
        try response.writeAll(pdf_content);
    }
    
    pub fn handleWebSocket(self: *AnalyticsHandlers, response: *http.Server.Response, request: *const http.Server.Request) !void {
        // WebSocket upgrade handling - simplified implementation
        // In a real implementation, you'd use a proper WebSocket library
        
        if (!auth.isAuthenticated(request)) {
            response.status = .unauthorized;
            try response.writeAll("Unauthorized");
            return;
        }
        
        // Check for WebSocket upgrade headers
        const upgrade_header = request.headers.get("Upgrade");
        const connection_header = request.headers.get("Connection");
        
        if (upgrade_header == null or connection_header == null or 
            !std.mem.eql(u8, upgrade_header.?, "websocket") or
            !std.mem.containsAtLeast(u8, connection_header.?, 1, "Upgrade")) {
            response.status = .bad_request;
            try response.writeAll("Bad Request - Expected WebSocket upgrade");
            return;
        }
        
        // For now, just return a placeholder response
        response.status = .switching_protocols;
        response.headers.append("Upgrade", "websocket") catch {};
        response.headers.append("Connection", "Upgrade") catch {};
        
        // In a real implementation, you'd:
        // 1. Generate WebSocket accept key
        // 2. Upgrade the connection
        // 3. Handle WebSocket frames
        // 4. Send real-time analytics updates
        
        try response.writeAll("WebSocket connection established (mock)");
    }
};