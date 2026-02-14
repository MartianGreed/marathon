const std = @import("std");
const json = std.json;
const http = std.http;
const auth = @import("../auth/auth.zig");
const analytics = @import("../analytics/analytics.zig");
const handlers = @import("../analytics/handlers.zig");
const db = @import("../db/root.zig");
const grpc_server = @import("../grpc/server.zig");
const common = @import("common");
const types = common.types;
const protocol = common.protocol;

const log = std.log.scoped(.http);

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    grpc_server: *grpc_server.Server,
    analytics_service: *analytics.AnalyticsService,
    analytics_handlers: *handlers.AnalyticsHandlers,
    auth_service: *auth.Authenticator,
    db_pool: ?*db.Pool,
    server: ?http.Server,
    
    pub fn init(
        allocator: std.mem.Allocator,
        grpc_server_ref: *grpc_server.Server,
        db_pool: ?*db.Pool,
        auth_service: *auth.Authenticator,
    ) !HttpServer {
        const analytics_service = try allocator.create(analytics.AnalyticsService);
        analytics_service.* = analytics.AnalyticsService.init(allocator, db_pool orelse {
            return error.DatabaseRequired;
        });
        
        const analytics_handlers_ref = try allocator.create(handlers.AnalyticsHandlers);
        analytics_handlers_ref.* = handlers.AnalyticsHandlers.init(allocator, analytics_service);
        
        return HttpServer{
            .allocator = allocator,
            .grpc_server = grpc_server_ref,
            .analytics_service = analytics_service,
            .analytics_handlers = analytics_handlers_ref,
            .auth_service = auth_service,
            .db_pool = db_pool,
            .server = null,
        };
    }
    
    pub fn deinit(self: *HttpServer) void {
        if (self.server) |*server| {
            server.deinit();
        }
        self.analytics_service.deinit();
        self.allocator.destroy(self.analytics_service);
        self.allocator.destroy(self.analytics_handlers);
    }
    
    pub fn listen(self: *HttpServer, address: []const u8, port: u16) !void {
        const addr = try std.net.Address.parseIp(address, port);
        self.server = try http.Server.init(self.allocator, .{ .reuse_address = true });
        try self.server.?.listen(addr);
        log.info("HTTP server listening on {}:{}", .{ address, port });
    }
    
    pub fn run(self: *HttpServer) !void {
        var server = self.server orelse return error.NotListening;
        
        while (true) {
            var response = try server.accept();
            defer response.deinit();
            
            const thread = try std.Thread.spawn(.{}, handleRequest, .{ self, &response });
            thread.detach();
        }
    }
    
    fn handleRequest(self: *HttpServer, response: *http.Server.Response) void {
        self.handleRequestInternal(response) catch |err| {
            log.err("Failed to handle HTTP request: {}", .{err});
            response.status = .internal_server_error;
            response.writeAll("Internal Server Error") catch {};
        };
    }
    
    fn handleRequestInternal(self: *HttpServer, response: *http.Server.Response) !void {
        try response.wait();
        
        const uri = response.request.uri;
        const method = response.request.method;
        
        // Add CORS headers
        try response.headers.append("Access-Control-Allow-Origin", "*");
        try response.headers.append("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
        try response.headers.append("Access-Control-Allow-Headers", "Content-Type, Authorization");
        
        // Handle preflight requests
        if (method == .OPTIONS) {
            response.status = .ok;
            try response.writeAll("");
            return;
        }
        
        log.info("HTTP request: {} {s}", .{ method, uri });
        
        // Route to appropriate handler
        if (std.mem.startsWith(u8, uri, "/analytics/")) {
            try self.handleAnalyticsRoutes(response, uri, method);
        } else if (std.mem.startsWith(u8, uri, "/auth/")) {
            try self.handleAuthRoutes(response, uri, method);
        } else if (std.mem.startsWith(u8, uri, "/tasks")) {
            try self.handleTaskRoutes(response, uri, method);
        } else if (std.mem.startsWith(u8, uri, "/usage")) {
            try self.handleUsageRoutes(response, uri, method);
        } else {
            response.status = .not_found;
            try response.writeAll("Not Found");
        }
    }
    
    fn handleAnalyticsRoutes(self: *HttpServer, response: *http.Server.Response, uri: []const u8, method: http.Method) !void {
        if (method != .GET and method != .POST) {
            response.status = .method_not_allowed;
            try response.writeAll("Method Not Allowed");
            return;
        }
        
        if (std.mem.eql(u8, uri, "/analytics/dashboard")) {
            try self.analytics_handlers.handleDashboard(response, &response.request);
        } else if (std.mem.eql(u8, uri, "/analytics/tasks")) {
            try self.analytics_handlers.handleTaskMetrics(response, &response.request);
        } else if (std.mem.eql(u8, uri, "/analytics/resources")) {
            try self.analytics_handlers.handleResourceUsage(response, &response.request);
        } else if (std.mem.eql(u8, uri, "/analytics/users")) {
            try self.analytics_handlers.handleUserActivity(response, &response.request);
        } else if (std.mem.eql(u8, uri, "/analytics/health")) {
            try self.analytics_handlers.handleSystemHealth(response, &response.request);
        } else if (std.mem.eql(u8, uri, "/analytics/time-series/tasks")) {
            try self.analytics_handlers.handleTaskPerformanceTimeSeries(response, &response.request);
        } else if (std.mem.eql(u8, uri, "/analytics/time-series/resources")) {
            try self.analytics_handlers.handleResourceTimeSeriesData(response, &response.request);
        } else if (std.mem.eql(u8, uri, "/analytics/export")) {
            try self.analytics_handlers.handleExport(response, &response.request);
        } else if (std.mem.eql(u8, uri, "/analytics/ws")) {
            try self.analytics_handlers.handleWebSocket(response, &response.request);
        } else {
            response.status = .not_found;
            try response.writeAll("Analytics endpoint not found");
        }
    }
    
    fn handleAuthRoutes(self: *HttpServer, response: *http.Server.Response, uri: []const u8, method: http.Method) !void {
        if (method != .POST) {
            response.status = .method_not_allowed;
            try response.writeAll("Method Not Allowed");
            return;
        }
        
        if (std.mem.eql(u8, uri, "/auth/register")) {
            try self.handleAuthRegister(response);
        } else if (std.mem.eql(u8, uri, "/auth/login")) {
            try self.handleAuthLogin(response);
        } else {
            response.status = .not_found;
            try response.writeAll("Auth endpoint not found");
        }
    }
    
    fn handleTaskRoutes(self: *HttpServer, response: *http.Server.Response, uri: []const u8, method: http.Method) !void {
        if (method == .GET and std.mem.eql(u8, uri, "/tasks")) {
            try self.handleListTasks(response);
        } else if (method == .GET and std.mem.startsWith(u8, uri, "/tasks/")) {
            const task_id_str = uri[7..]; // Skip "/tasks/"
            try self.handleGetTask(response, task_id_str);
        } else {
            response.status = .not_found;
            try response.writeAll("Task endpoint not found");
        }
    }
    
    fn handleUsageRoutes(self: *HttpServer, response: *http.Server.Response, uri: []const u8, method: http.Method) !void {
        if (method == .GET and std.mem.eql(u8, uri, "/usage")) {
            try self.handleGetUsage(response);
        } else {
            response.status = .not_found;
            try response.writeAll("Usage endpoint not found");
        }
    }
    
    fn isAuthenticated(self: *HttpServer, request: *const http.Server.Request) bool {
        const auth_header = request.headers.get("Authorization") orelse return false;
        
        if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
            return false;
        }
        
        const token = auth_header[7..]; // Skip "Bearer "
        return self.auth_service.validateToken(token);
    }
    
    fn writeJsonResponse(response: *http.Server.Response, data: anytype) !void {
        const json_string = json.stringifyAlloc(response.allocator, data, .{}) catch |err| {
            log.err("Failed to serialize JSON response: {}", .{err});
            response.status = .internal_server_error;
            try response.writeAll("Internal server error");
            return;
        };
        defer response.allocator.free(json_string);
        
        try response.headers.append("Content-Type", "application/json");
        try response.writeAll(json_string);
    }
    
    fn readJsonBody(self: *HttpServer, response: *http.Server.Response, comptime T: type) !T {
        const body_size = response.request.content_length orelse 0;
        if (body_size == 0) {
            return error.EmptyBody;
        }
        
        const body = try self.allocator.alloc(u8, body_size);
        defer self.allocator.free(body);
        
        _ = try response.readAll(body);
        
        const parsed = json.parseFromSlice(T, self.allocator, body, .{}) catch |err| {
            log.err("Failed to parse JSON body: {}", .{err});
            return error.InvalidJson;
        };
        defer parsed.deinit();
        
        return parsed.value;
    }
    
    fn handleAuthRegister(self: *HttpServer, response: *http.Server.Response) !void {
        const RegisterRequest = struct {
            email: []const u8,
            password: []const u8,
        };
        
        const request_data = self.readJsonBody(response, RegisterRequest) catch {
            response.status = .bad_request;
            try response.writeAll("Invalid JSON request");
            return;
        };
        
        const user_repo = if (self.db_pool) |pool| 
            db.UserRepository.init(self.allocator, pool)
        else {
            response.status = .service_unavailable;
            try response.writeAll("Database not available");
            return;
        };
        
        // Check if user already exists
        if (try user_repo.findByEmail(request_data.email)) |existing_user| {
            existing_user.deinit(self.allocator);
            response.status = .conflict;
            try writeJsonResponse(response, .{
                .success = false,
                .token = null,
                .api_key = null,
                .message = "Email already registered",
            });
            return;
        }
        
        // Create new user
        const password_hash = try auth.PasswordHash.hash(self.allocator, request_data.password);
        defer self.allocator.free(password_hash);
        
        var user_id: [16]u8 = undefined;
        std.crypto.random.bytes(&user_id);
        
        const api_key = try auth.Authenticator.generateApiKey(self.allocator);
        defer self.allocator.free(api_key);
        
        const now = std.time.milliTimestamp();
        
        const new_user = db.UserRepository.User{
            .id = user_id,
            .email = request_data.email,
            .password_hash = password_hash,
            .github_id = null,
            .api_key = api_key,
            .created_at = now,
            .updated_at = now,
        };
        
        user_repo.create(&new_user) catch {
            response.status = .internal_server_error;
            try writeJsonResponse(response, .{
                .success = false,
                .token = null,
                .api_key = null,
                .message = "Failed to create user",
            });
            return;
        };
        
        try self.auth_service.registerApiKey(api_key, user_id);
        
        const token = try self.auth_service.createToken(self.allocator, user_id, request_data.email);
        defer self.allocator.free(token);
        
        log.info("User registered via HTTP: email={s}", .{request_data.email});
        
        try writeJsonResponse(response, .{
            .success = true,
            .token = token,
            .api_key = api_key,
            .message = "Registration successful",
        });
    }
    
    fn handleAuthLogin(self: *HttpServer, response: *http.Server.Response) !void {
        const LoginRequest = struct {
            email: []const u8,
            password: []const u8,
        };
        
        const request_data = self.readJsonBody(response, LoginRequest) catch {
            response.status = .bad_request;
            try response.writeAll("Invalid JSON request");
            return;
        };
        
        const user_repo = if (self.db_pool) |pool| 
            db.UserRepository.init(self.allocator, pool)
        else {
            response.status = .service_unavailable;
            try response.writeAll("Database not available");
            return;
        };
        
        var found_user = (try user_repo.findByEmail(request_data.email)) orelse {
            response.status = .unauthorized;
            try writeJsonResponse(response, .{
                .success = false,
                .token = null,
                .api_key = null,
                .message = "Invalid email or password",
            });
            return;
        };
        defer found_user.deinit(self.allocator);
        
        if (!auth.PasswordHash.verify(request_data.password, found_user.password_hash)) {
            response.status = .unauthorized;
            try writeJsonResponse(response, .{
                .success = false,
                .token = null,
                .api_key = null,
                .message = "Invalid email or password",
            });
            return;
        }
        
        const token = try self.auth_service.createToken(self.allocator, found_user.id, found_user.email);
        defer self.allocator.free(token);
        
        log.info("User logged in via HTTP: email={s}", .{request_data.email});
        
        try writeJsonResponse(response, .{
            .success = true,
            .token = token,
            .api_key = found_user.api_key,
            .message = "Login successful",
        });
    }
    
    fn handleListTasks(self: *HttpServer, response: *http.Server.Response) !void {
        if (!self.isAuthenticated(&response.request)) {
            response.status = .unauthorized;
            try response.writeAll("Unauthorized");
            return;
        }
        
        // For now, return mock data. In a real implementation, you'd get this from the database
        const mock_tasks = [_]struct {
            id: []const u8,
            state: []const u8,
            repo_url: []const u8,
            branch: []const u8,
            prompt: []const u8,
            created_at: i64,
            started_at: ?i64 = null,
            completed_at: ?i64 = null,
            error_message: ?[]const u8 = null,
            pr_url: ?[]const u8 = null,
            usage: ?struct {
                input_tokens: u32,
                output_tokens: u32,
                compute_time_ms: u64,
                tool_calls: u32,
            } = null,
        }{
            .{
                .id = "task_001",
                .state = "completed",
                .repo_url = "https://github.com/example/repo",
                .branch = "main",
                .prompt = "Fix the authentication bug",
                .created_at = std.time.timestamp() - 3600,
                .completed_at = std.time.timestamp() - 3000,
                .usage = .{
                    .input_tokens = 1000,
                    .output_tokens = 500,
                    .compute_time_ms = 45000,
                    .tool_calls = 3,
                },
            },
            .{
                .id = "task_002",
                .state = "running",
                .repo_url = "https://github.com/example/another-repo",
                .branch = "feature-branch",
                .prompt = "Add new analytics dashboard",
                .created_at = std.time.timestamp() - 1800,
                .started_at = std.time.timestamp() - 1200,
            },
        };
        
        try writeJsonResponse(response, mock_tasks);
    }
    
    fn handleGetTask(self: *HttpServer, response: *http.Server.Response, task_id: []const u8) !void {
        if (!self.isAuthenticated(&response.request)) {
            response.status = .unauthorized;
            try response.writeAll("Unauthorized");
            return;
        }
        
        _ = task_id; // For now, ignore the specific task ID
        
        // Mock task data
        const mock_task = .{
            .id = "task_001",
            .state = "completed",
            .repo_url = "https://github.com/example/repo",
            .branch = "main", 
            .prompt = "Fix the authentication bug",
            .created_at = std.time.timestamp() - 3600,
            .completed_at = std.time.timestamp() - 3000,
            .usage = .{
                .input_tokens = 1000,
                .output_tokens = 500,
                .compute_time_ms = 45000,
                .tool_calls = 3,
            },
        };
        
        try writeJsonResponse(response, mock_task);
    }
    
    fn handleGetUsage(self: *HttpServer, response: *http.Server.Response) !void {
        if (!self.isAuthenticated(&response.request)) {
            response.status = .unauthorized;
            try response.writeAll("Unauthorized");
            return;
        }
        
        // Mock usage data
        const mock_usage = .{
            .total_input_tokens = 5000,
            .total_output_tokens = 2500,
            .total_compute_time_ms = 180000,
            .total_tool_calls = 15,
            .task_count = 8,
        };
        
        try writeJsonResponse(response, mock_usage);
    }
};