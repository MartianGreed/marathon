const std = @import("std");
const common = @import("common");
const types = common.types;

pub const Authenticator = struct {
    allocator: std.mem.Allocator,
    anthropic_api_key: []const u8,
    api_keys: std.StringHashMap(types.ClientId),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, anthropic_api_key: []const u8) Authenticator {
        return .{
            .allocator = allocator,
            .anthropic_api_key = anthropic_api_key,
            .api_keys = std.StringHashMap(types.ClientId).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Authenticator) void {
        self.api_keys.deinit();
    }

    pub fn registerApiKey(self: *Authenticator, api_key: []const u8, client_id: types.ClientId) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key_copy = try self.allocator.dupe(u8, api_key);
        try self.api_keys.put(key_copy, client_id);
    }

    pub fn authenticate(self: *Authenticator, api_key: []const u8) ?types.ClientId {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.api_keys.get(api_key);
    }

    pub fn getAnthropicKey(self: *Authenticator) []const u8 {
        return self.anthropic_api_key;
    }

    pub fn validateGitHubToken(token: []const u8) bool {
        if (token.len < 10) return false;
        if (std.mem.startsWith(u8, token, "ghp_")) return true;
        if (std.mem.startsWith(u8, token, "gho_")) return true;
        if (std.mem.startsWith(u8, token, "ghu_")) return true;
        if (std.mem.startsWith(u8, token, "ghs_")) return true;
        if (std.mem.startsWith(u8, token, "ghr_")) return true;
        if (std.mem.startsWith(u8, token, "github_pat_")) return true;
        return false;
    }

    pub fn generateClientId() types.ClientId {
        var id: types.ClientId = undefined;
        std.crypto.random.bytes(&id);
        return id;
    }

    pub fn generateApiKey(allocator: std.mem.Allocator) ![]u8 {
        var random_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);

        const key = try allocator.alloc(u8, 44);
        _ = std.base64.standard.Encoder.encode(key, &random_bytes);
        return key;
    }
};

pub const Permission = enum {
    submit_task,
    cancel_task,
    view_usage,
    admin,
};

pub const ClientPermissions = struct {
    client_id: types.ClientId,
    permissions: std.EnumSet(Permission),

    pub fn hasPermission(self: ClientPermissions, perm: Permission) bool {
        return self.permissions.contains(perm);
    }

    pub fn defaultPermissions() std.EnumSet(Permission) {
        var set = std.EnumSet(Permission).initEmpty();
        set.insert(.submit_task);
        set.insert(.cancel_task);
        set.insert(.view_usage);
        return set;
    }
};

test "github token validation" {
    try std.testing.expect(Authenticator.validateGitHubToken("ghp_1234567890abcdefghijklmnop"));
    try std.testing.expect(Authenticator.validateGitHubToken("github_pat_1234567890"));
    try std.testing.expect(!Authenticator.validateGitHubToken("invalid"));
    try std.testing.expect(!Authenticator.validateGitHubToken("short"));
}

test "api key generation" {
    const allocator = std.testing.allocator;
    const key = try Authenticator.generateApiKey(allocator);
    defer allocator.free(key);

    try std.testing.expectEqual(@as(usize, 44), key.len);
}
