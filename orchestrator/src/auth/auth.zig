const std = @import("std");
const common = @import("common");
const types = common.types;

const log = std.log.scoped(.auth);

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
        var it = self.api_keys.keyIterator();
        while (it.next()) |key| {
            const key_ptr: [*]u8 = @constCast(key.*.ptr);
            @memset(key_ptr[0..key.*.len], 0);
            self.allocator.free(key.*);
        }
        self.api_keys.deinit();
    }

    pub fn registerApiKey(self: *Authenticator, api_key: []const u8, client_id: types.ClientId) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key_copy = try self.allocator.dupe(u8, api_key);
        try self.api_keys.put(key_copy, client_id);

        log.info("api key registered: client_id={s}", .{&types.formatId(client_id)});
    }

    pub fn authenticate(self: *Authenticator, api_key: []const u8) ?types.ClientId {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.api_keys.get(api_key)) |client_id| {
            log.info("auth success: client_id={s}", .{&types.formatId(client_id)});
            return client_id;
        }

        log.warn("auth failed: invalid api key", .{});
        return null;
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

test "authenticator register and authenticate" {
    const allocator = std.testing.allocator;

    var auth = Authenticator.init(allocator, "test-anthropic-key");
    defer auth.deinit();

    var client_id: [16]u8 = undefined;
    @memset(&client_id, 0xAB);

    try auth.registerApiKey("test-api-key-12345", client_id);

    const result = auth.authenticate("test-api-key-12345");
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, &client_id, &result.?);

    const invalid = auth.authenticate("wrong-key");
    try std.testing.expect(invalid == null);
}

test "authenticator getAnthropicKey" {
    const allocator = std.testing.allocator;

    var auth = Authenticator.init(allocator, "sk-ant-test-key");
    defer auth.deinit();

    try std.testing.expectEqualStrings("sk-ant-test-key", auth.getAnthropicKey());
}

test "authenticator generateClientId produces unique ids" {
    const id1 = Authenticator.generateClientId();
    const id2 = Authenticator.generateClientId();

    try std.testing.expect(!std.mem.eql(u8, &id1, &id2));
}

test "client permissions" {
    var client_id: [16]u8 = undefined;
    @memset(&client_id, 0);

    const perms = ClientPermissions{
        .client_id = client_id,
        .permissions = ClientPermissions.defaultPermissions(),
    };

    try std.testing.expect(perms.hasPermission(.submit_task));
    try std.testing.expect(perms.hasPermission(.cancel_task));
    try std.testing.expect(perms.hasPermission(.view_usage));
    try std.testing.expect(!perms.hasPermission(.admin));
}
