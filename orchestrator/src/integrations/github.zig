const std = @import("std");
const http = std.http;
const json = std.json;
const mod = @import("mod.zig");
const IntegrationStatus = mod.IntegrationStatus;

pub const GitHubClient = struct {
    allocator: std.mem.Allocator,
    access_token: ?[]const u8,
    base_url: []const u8,
    rate_limiter: RateLimiter,

    const RateLimiter = struct {
        requests_remaining: u32,
        reset_time: i64,
        
        pub fn init() RateLimiter {
            return .{
                .requests_remaining = 5000, // GitHub default
                .reset_time = 0,
            };
        }
        
        pub fn canMakeRequest(self: *RateLimiter) bool {
            const now = std.time.timestamp();
            if (now > self.reset_time) {
                self.requests_remaining = 5000;
                self.reset_time = now + 3600; // Reset every hour
            }
            return self.requests_remaining > 0;
        }
        
        pub fn recordRequest(self: *RateLimiter, remaining: u32, reset_time: i64) void {
            self.requests_remaining = remaining;
            self.reset_time = reset_time;
        }
    };

    pub fn init(allocator: std.mem.Allocator) GitHubClient {
        return .{
            .allocator = allocator,
            .access_token = null,
            .base_url = "https://api.github.com",
            .rate_limiter = RateLimiter.init(),
        };
    }

    pub fn deinit(self: *GitHubClient) void {
        if (self.access_token) |token| {
            self.allocator.free(token);
        }
    }

    pub fn setCredentials(self: *GitHubClient, token: []const u8) !void {
        if (self.access_token) |old_token| {
            self.allocator.free(old_token);
        }
        self.access_token = try self.allocator.dupe(u8, token);
    }

    pub fn testConnection(self: *GitHubClient) IntegrationStatus {
        if (self.access_token == null) return .disconnected;
        
        if (!self.rate_limiter.canMakeRequest()) return .rate_limited;

        // Test by getting authenticated user info
        const response = self.makeRequest(.GET, "/user", null) catch return .error;
        defer self.allocator.free(response.body);

        return if (response.status_code == 200) .connected else .error;
    }

    /// Repository operations
    pub const Repository = struct {
        id: u64,
        name: []const u8,
        full_name: []const u8,
        private: bool,
        clone_url: []const u8,
        default_branch: []const u8,
        description: ?[]const u8,
        
        pub fn deinit(self: *Repository, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.full_name);
            allocator.free(self.clone_url);
            allocator.free(self.default_branch);
            if (self.description) |desc| allocator.free(desc);
        }
    };

    pub fn cloneRepository(self: *GitHubClient, repo_url: []const u8, branch: []const u8, destination: []const u8) !void {
        if (self.access_token == null) return error.NotAuthenticated;
        
        const git_cmd = try std.fmt.allocPrint(self.allocator, 
            "git clone --branch {s} --single-branch https://x-access-token:{s}@github.com/{s}.git {s}",
            .{ branch, self.access_token.?, repo_url, destination }
        );
        defer self.allocator.free(git_cmd);

        var process = std.process.Child.init(&.{ "sh", "-c", git_cmd }, self.allocator);
        const term = try process.spawnAndWait();
        
        if (term != .Exited or term.Exited != 0) {
            return error.CloneFailed;
        }
    }

    pub fn listRepositories(self: *GitHubClient, org: ?[]const u8) ![]Repository {
        if (self.access_token == null) return error.NotAuthenticated;
        if (!self.rate_limiter.canMakeRequest()) return error.RateLimited;

        const endpoint = if (org) |organization| 
            try std.fmt.allocPrint(self.allocator, "/orgs/{s}/repos", .{organization})
        else 
            try self.allocator.dupe(u8, "/user/repos");
        defer self.allocator.free(endpoint);

        const response = try self.makeRequest(.GET, endpoint, null);
        defer self.allocator.free(response.body);

        if (response.status_code != 200) return error.RequestFailed;

        var parser = json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();
        
        var tree = try parser.parse(response.body);
        defer tree.deinit();

        if (tree.root != .array) return error.InvalidResponse;

        var repos = std.ArrayList(Repository).init(self.allocator);
        for (tree.root.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            
            const repo = Repository{
                .id = if (obj.get("id")) |id| @intCast(id.integer) else continue,
                .name = if (obj.get("name")) |name| try self.allocator.dupe(u8, name.string) else continue,
                .full_name = if (obj.get("full_name")) |name| try self.allocator.dupe(u8, name.string) else continue,
                .private = if (obj.get("private")) |priv| priv.bool else false,
                .clone_url = if (obj.get("clone_url")) |url| try self.allocator.dupe(u8, url.string) else continue,
                .default_branch = if (obj.get("default_branch")) |branch| try self.allocator.dupe(u8, branch.string) else try self.allocator.dupe(u8, "main"),
                .description = if (obj.get("description")) |desc| 
                    if (desc == .string) try self.allocator.dupe(u8, desc.string) else null 
                else 
                    null,
            };
            try repos.append(repo);
        }

        return repos.toOwnedSlice();
    }

    /// Branch operations
    pub const Branch = struct {
        name: []const u8,
        sha: []const u8,
        protected: bool,
        
        pub fn deinit(self: *Branch, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.sha);
        }
    };

    pub fn listBranches(self: *GitHubClient, owner: []const u8, repo: []const u8) ![]Branch {
        if (self.access_token == null) return error.NotAuthenticated;
        if (!self.rate_limiter.canMakeRequest()) return error.RateLimited;

        const endpoint = try std.fmt.allocPrint(self.allocator, "/repos/{s}/{s}/branches", .{ owner, repo });
        defer self.allocator.free(endpoint);

        const response = try self.makeRequest(.GET, endpoint, null);
        defer self.allocator.free(response.body);

        if (response.status_code != 200) return error.RequestFailed;

        var parser = json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();
        
        var tree = try parser.parse(response.body);
        defer tree.deinit();

        var branches = std.ArrayList(Branch).init(self.allocator);
        for (tree.root.array.items) |item| {
            const obj = item.object;
            const branch = Branch{
                .name = try self.allocator.dupe(u8, obj.get("name").?.string),
                .sha = try self.allocator.dupe(u8, obj.get("commit").?.object.get("sha").?.string),
                .protected = obj.get("protected").?.bool,
            };
            try branches.append(branch);
        }

        return branches.toOwnedSlice();
    }

    pub fn createBranch(self: *GitHubClient, owner: []const u8, repo: []const u8, branch_name: []const u8, source_sha: []const u8) !void {
        if (self.access_token == null) return error.NotAuthenticated;
        if (!self.rate_limiter.canMakeRequest()) return error.RateLimited;

        const endpoint = try std.fmt.allocPrint(self.allocator, "/repos/{s}/{s}/git/refs", .{ owner, repo });
        defer self.allocator.free(endpoint);

        const payload = try std.fmt.allocPrint(self.allocator,
            "{{\"ref\":\"refs/heads/{s}\",\"sha\":\"{s}\"}}",
            .{ branch_name, source_sha }
        );
        defer self.allocator.free(payload);

        const response = try self.makeRequest(.POST, endpoint, payload);
        defer self.allocator.free(response.body);

        if (response.status_code != 201) return error.CreateBranchFailed;
    }

    /// Pull Request operations
    pub const PullRequest = struct {
        number: u32,
        title: []const u8,
        body: ?[]const u8,
        state: []const u8,
        html_url: []const u8,
        head_branch: []const u8,
        base_branch: []const u8,
        
        pub fn deinit(self: *PullRequest, allocator: std.mem.Allocator) void {
            allocator.free(self.title);
            if (self.body) |body| allocator.free(body);
            allocator.free(self.state);
            allocator.free(self.html_url);
            allocator.free(self.head_branch);
            allocator.free(self.base_branch);
        }
    };

    pub fn createPullRequest(self: *GitHubClient, owner: []const u8, repo: []const u8, title: []const u8, body: ?[]const u8, head_branch: []const u8, base_branch: []const u8) !PullRequest {
        if (self.access_token == null) return error.NotAuthenticated;
        if (!self.rate_limiter.canMakeRequest()) return error.RateLimited;

        const endpoint = try std.fmt.allocPrint(self.allocator, "/repos/{s}/{s}/pulls", .{ owner, repo });
        defer self.allocator.free(endpoint);

        const payload = if (body) |pr_body|
            try std.fmt.allocPrint(self.allocator,
                "{{\"title\":\"{s}\",\"body\":\"{s}\",\"head\":\"{s}\",\"base\":\"{s}\"}}",
                .{ title, pr_body, head_branch, base_branch }
            )
        else
            try std.fmt.allocPrint(self.allocator,
                "{{\"title\":\"{s}\",\"head\":\"{s}\",\"base\":\"{s}\"}}",
                .{ title, head_branch, base_branch }
            );
        defer self.allocator.free(payload);

        const response = try self.makeRequest(.POST, endpoint, payload);
        defer self.allocator.free(response.body);

        if (response.status_code != 201) return error.CreatePullRequestFailed;

        var parser = json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();
        
        var tree = try parser.parse(response.body);
        defer tree.deinit();

        const obj = tree.root.object;
        return PullRequest{
            .number = @intCast(obj.get("number").?.integer),
            .title = try self.allocator.dupe(u8, obj.get("title").?.string),
            .body = if (obj.get("body")) |pr_body| 
                if (pr_body == .string) try self.allocator.dupe(u8, pr_body.string) else null 
            else 
                null,
            .state = try self.allocator.dupe(u8, obj.get("state").?.string),
            .html_url = try self.allocator.dupe(u8, obj.get("html_url").?.string),
            .head_branch = try self.allocator.dupe(u8, obj.get("head").?.object.get("ref").?.string),
            .base_branch = try self.allocator.dupe(u8, obj.get("base").?.object.get("ref").?.string),
        };
    }

    pub fn mergePullRequest(self: *GitHubClient, owner: []const u8, repo: []const u8, pull_number: u32, merge_method: []const u8) !void {
        if (self.access_token == null) return error.NotAuthenticated;
        if (!self.rate_limiter.canMakeRequest()) return error.RateLimited;

        const endpoint = try std.fmt.allocPrint(self.allocator, "/repos/{s}/{s}/pulls/{d}/merge", .{ owner, repo, pull_number });
        defer self.allocator.free(endpoint);

        const payload = try std.fmt.allocPrint(self.allocator,
            "{{\"merge_method\":\"{s}\"}}",
            .{merge_method}
        );
        defer self.allocator.free(payload);

        const response = try self.makeRequest(.PUT, endpoint, payload);
        defer self.allocator.free(response.body);

        if (response.status_code != 200) return error.MergeFailed;
    }

    /// Webhook operations
    pub const WebhookEvent = enum {
        push,
        pull_request,
        issues,
        release,
        workflow_run,
    };

    pub fn createWebhook(self: *GitHubClient, owner: []const u8, repo: []const u8, webhook_url: []const u8, events: []const WebhookEvent, secret: []const u8) !void {
        if (self.access_token == null) return error.NotAuthenticated;
        if (!self.rate_limiter.canMakeRequest()) return error.RateLimited;

        const endpoint = try std.fmt.allocPrint(self.allocator, "/repos/{s}/{s}/hooks", .{ owner, repo });
        defer self.allocator.free(endpoint);

        var events_json = std.ArrayList(u8).init(self.allocator);
        defer events_json.deinit();
        
        try events_json.append('[');
        for (events, 0..) |event, i| {
            if (i > 0) try events_json.append(',');
            try std.fmt.format(events_json.writer(), "\"{s}\"", .{@tagName(event)});
        }
        try events_json.append(']');

        const payload = try std.fmt.allocPrint(self.allocator,
            "{{\"name\":\"web\",\"config\":{{\"url\":\"{s}\",\"content_type\":\"json\",\"secret\":\"{s}\"}},\"events\":{s},\"active\":true}}",
            .{ webhook_url, secret, events_json.items }
        );
        defer self.allocator.free(payload);

        const response = try self.makeRequest(.POST, endpoint, payload);
        defer self.allocator.free(response.body);

        if (response.status_code != 201) return error.CreateWebhookFailed;
    }

    /// HTTP client implementation
    const HttpResponse = struct {
        status_code: u16,
        body: []const u8,
    };

    fn makeRequest(self: *GitHubClient, method: http.Method, endpoint: []const u8, body: ?[]const u8) !HttpResponse {
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, endpoint });
        defer self.allocator.free(url);

        var headers = http.Headers.init(self.allocator);
        defer headers.deinit();

        try headers.append("Accept", "application/vnd.github+json");
        try headers.append("User-Agent", "Marathon/1.0");
        
        if (self.access_token) |token| {
            const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
            defer self.allocator.free(auth_header);
            try headers.append("Authorization", auth_header);
        }

        if (body != null) {
            try headers.append("Content-Type", "application/json");
        }

        var request = try client.open(method, try std.Uri.parse(url), headers);
        defer request.deinit();

        if (body) |request_body| {
            request.transfer_encoding = .{ .content_length = request_body.len };
        } else {
            request.transfer_encoding = .{ .content_length = 0 };
        }

        try request.send();

        if (body) |request_body| {
            try request.writeAll(request_body);
        }

        try request.finish();
        try request.wait();

        // Update rate limiting info from headers
        if (request.response.headers.getFirstValue("X-RateLimit-Remaining")) |remaining_str| {
            const remaining = std.fmt.parseInt(u32, remaining_str, 10) catch 0;
            const reset_time = if (request.response.headers.getFirstValue("X-RateLimit-Reset")) |reset_str|
                std.fmt.parseInt(i64, reset_str, 10) catch 0
            else
                0;
            self.rate_limiter.recordRequest(remaining, reset_time);
        }

        const response_body = try request.reader().readAllAlloc(self.allocator, 1024 * 1024);
        return HttpResponse{
            .status_code = request.response.status.phrase(),
            .body = response_body,
        };
    }
};

test "github client initialization" {
    const testing = std.testing;
    
    var client = GitHubClient.init(testing.allocator);
    defer client.deinit();

    try testing.expect(client.access_token == null);
    try testing.expectEqualStrings("https://api.github.com", client.base_url);
}

test "rate limiter" {
    const testing = std.testing;
    
    var rate_limiter = GitHubClient.RateLimiter.init();
    try testing.expect(rate_limiter.canMakeRequest());
    
    rate_limiter.recordRequest(0, std.time.timestamp() + 3600);
    try testing.expect(!rate_limiter.canMakeRequest());
}