const std = @import("std");
const common = @import("common");
const types = common.types;

const log = std.log.scoped(.auth);

/// JWT token with HS256 signing
pub const Jwt = struct {
    const header_b64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"; // {"alg":"HS256","typ":"JWT"}

    /// Create a signed JWT token
    pub fn create(allocator: std.mem.Allocator, user_id: [16]u8, email: []const u8, secret: []const u8, expires_in_s: i64) ![]u8 {
        const now = std.time.timestamp();
        const exp = now + expires_in_s;

        // Build payload JSON
        var payload_buf: [512]u8 = undefined;
        const user_id_hex = std.fmt.bytesToHex(user_id, .lower);
        const payload_json = try std.fmt.bufPrint(&payload_buf, "{{\"sub\":\"{s}\",\"email\":\"{s}\",\"iat\":{d},\"exp\":{d}}}", .{
            &user_id_hex,
            email,
            now,
            exp,
        });

        // Base64url encode payload
        const payload_b64_len = std.base64.url_safe_no_pad.Encoder.calcSize(payload_json.len);
        const payload_b64 = try allocator.alloc(u8, payload_b64_len);
        defer allocator.free(payload_b64);
        _ = std.base64.url_safe_no_pad.Encoder.encode(payload_b64, payload_json);

        // Sign: HMAC-SHA256(header.payload)
        const signing_input_len = header_b64.len + 1 + payload_b64_len;
        const signing_input = try allocator.alloc(u8, signing_input_len);
        defer allocator.free(signing_input);
        @memcpy(signing_input[0..header_b64.len], header_b64);
        signing_input[header_b64.len] = '.';
        @memcpy(signing_input[header_b64.len + 1 ..], payload_b64);

        var mac: [32]u8 = undefined;
        var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
        hmac.update(signing_input);
        hmac.final(&mac);

        const sig_b64_len = std.base64.url_safe_no_pad.Encoder.calcSize(32);
        const sig_b64 = try allocator.alloc(u8, sig_b64_len);
        defer allocator.free(sig_b64);
        _ = std.base64.url_safe_no_pad.Encoder.encode(sig_b64, &mac);

        // Assemble: header.payload.signature
        const total_len = signing_input_len + 1 + sig_b64_len;
        const token = try allocator.alloc(u8, total_len);
        @memcpy(token[0..signing_input_len], signing_input);
        token[signing_input_len] = '.';
        @memcpy(token[signing_input_len + 1 ..], sig_b64);

        return token;
    }

    /// Validate a JWT token and extract user_id. Returns null if invalid/expired.
    pub fn validate(allocator: std.mem.Allocator, token: []const u8, secret: []const u8) !?JwtClaims {
        // Split into 3 parts
        var parts_iter = std.mem.splitScalar(u8, token, '.');
        const header_part = parts_iter.next() orelse return null;
        const payload_part = parts_iter.next() orelse return null;
        const sig_part = parts_iter.next() orelse return null;
        if (parts_iter.next() != null) return null; // too many parts

        // Verify signature
        const signing_input_len = header_part.len + 1 + payload_part.len;
        const signing_input = try allocator.alloc(u8, signing_input_len);
        defer allocator.free(signing_input);
        @memcpy(signing_input[0..header_part.len], header_part);
        signing_input[header_part.len] = '.';
        @memcpy(signing_input[header_part.len + 1 ..], payload_part);

        var expected_mac: [32]u8 = undefined;
        var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
        hmac.update(signing_input);
        hmac.final(&expected_mac);

        const sig_decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(sig_part) catch return null;
        if (sig_decoded_len != 32) return null;
        var actual_mac: [32]u8 = undefined;
        std.base64.url_safe_no_pad.Decoder.decode(&actual_mac, sig_part) catch return null;

        if (!std.crypto.timing_safe.eql([32]u8, expected_mac, actual_mac)) {
            log.warn("jwt signature verification failed", .{});
            return null;
        }

        // Decode payload
        const payload_decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_part) catch return null;
        const payload_decoded = try allocator.alloc(u8, payload_decoded_len);
        defer allocator.free(payload_decoded);
        std.base64.url_safe_no_pad.Decoder.decode(payload_decoded, payload_part) catch return null;

        // Parse JSON to extract sub and exp
        return parseJwtPayload(payload_decoded);
    }

    fn parseJwtPayload(json: []const u8) ?JwtClaims {
        // Simple JSON parser for {"sub":"...","email":"...","iat":...,"exp":...}
        var claims = JwtClaims{
            .user_id = undefined,
            .email = "",
            .exp = 0,
        };

        // Extract "sub" field (hex-encoded user_id)
        if (findJsonString(json, "\"sub\":\"")) |sub_val| {
            if (sub_val.len != 32) return null; // 16 bytes = 32 hex chars
            _ = std.fmt.hexToBytes(&claims.user_id, sub_val) catch return null;
        } else return null;

        // Extract "exp" field
        if (findJsonInt(json, "\"exp\":")) |exp| {
            claims.exp = exp;
        } else return null;

        // Check expiry
        const now = std.time.timestamp();
        if (now > claims.exp) {
            log.warn("jwt expired: exp={d} now={d}", .{ claims.exp, now });
            return null;
        }

        return claims;
    }

    fn findJsonString(json: []const u8, key: []const u8) ?[]const u8 {
        const pos = std.mem.indexOf(u8, json, key) orelse return null;
        const start = pos + key.len;
        const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
        return json[start..end];
    }

    fn findJsonInt(json: []const u8, key: []const u8) ?i64 {
        const pos = std.mem.indexOf(u8, json, key) orelse return null;
        const start = pos + key.len;
        var end = start;
        while (end < json.len and (json[end] >= '0' and json[end] <= '9')) : (end += 1) {}
        if (end == start) return null;
        return std.fmt.parseInt(i64, json[start..end], 10) catch null;
    }
};

pub const JwtClaims = struct {
    user_id: [16]u8,
    email: []const u8,
    exp: i64,
};

/// Password hashing using PBKDF2-HMAC-SHA256
pub const PasswordHash = struct {
    const ITERATIONS: u32 = 100_000;
    const SALT_LEN: usize = 16;
    const HASH_LEN: usize = 32;

    /// Hash a password, returns "salt_hex:hash_hex" string
    pub fn hash(allocator: std.mem.Allocator, password: []const u8) ![]u8 {
        var salt: [SALT_LEN]u8 = undefined;
        std.crypto.random.bytes(&salt);

        var dk: [HASH_LEN]u8 = undefined;
        try std.crypto.pwhash.pbkdf2(&dk, password, &salt, ITERATIONS, std.crypto.auth.hmac.sha2.HmacSha256);

        // Format: hex(salt):hex(hash)
        const salt_hex = std.fmt.bytesToHex(salt, .lower);
        const hash_hex = std.fmt.bytesToHex(dk, .lower);
        const result = try allocator.alloc(u8, salt_hex.len + 1 + hash_hex.len);
        @memcpy(result[0..salt_hex.len], &salt_hex);
        result[salt_hex.len] = ':';
        @memcpy(result[salt_hex.len + 1 ..], &hash_hex);
        return result;
    }

    /// Verify a password against a stored hash string "salt_hex:hash_hex"
    pub fn verify(password: []const u8, stored: []const u8) bool {
        const sep = std.mem.indexOfScalar(u8, stored, ':') orelse return false;
        const salt_hex = stored[0..sep];
        const hash_hex = stored[sep + 1 ..];

        if (salt_hex.len != SALT_LEN * 2 or hash_hex.len != HASH_LEN * 2) return false;

        var salt: [SALT_LEN]u8 = undefined;
        _ = std.fmt.hexToBytes(&salt, salt_hex) catch return false;

        var expected: [HASH_LEN]u8 = undefined;
        _ = std.fmt.hexToBytes(&expected, hash_hex) catch return false;

        var actual: [HASH_LEN]u8 = undefined;
        std.crypto.pwhash.pbkdf2(&actual, password, &salt, ITERATIONS, std.crypto.auth.hmac.sha2.HmacSha256) catch return false;

        return std.crypto.timing_safe.eql([HASH_LEN]u8, expected, actual);
    }
};

pub const Authenticator = struct {
    allocator: std.mem.Allocator,
    anthropic_api_key: []const u8,
    api_keys: std.StringHashMap(types.ClientId),
    mutex: std.Thread.Mutex,
    jwt_secret: []const u8,

    pub fn init(allocator: std.mem.Allocator, anthropic_api_key: []const u8) Authenticator {
        // Generate a random JWT secret if not provided
        var secret: [32]u8 = undefined;
        std.crypto.random.bytes(&secret);
        const secret_hex = std.fmt.bytesToHex(secret, .lower);

        return .{
            .allocator = allocator,
            .anthropic_api_key = anthropic_api_key,
            .api_keys = std.StringHashMap(types.ClientId).init(allocator),
            .mutex = .{},
            .jwt_secret = &secret_hex,
        };
    }

    pub fn initWithSecret(allocator: std.mem.Allocator, anthropic_api_key: []const u8, jwt_secret: []const u8) Authenticator {
        return .{
            .allocator = allocator,
            .anthropic_api_key = anthropic_api_key,
            .api_keys = std.StringHashMap(types.ClientId).init(allocator),
            .mutex = .{},
            .jwt_secret = jwt_secret,
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

    /// Authenticate by API key (legacy) or JWT token
    pub fn authenticate(self: *Authenticator, api_key: []const u8) ?types.ClientId {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.api_keys.get(api_key)) |client_id| {
            log.info("auth success (api_key): client_id={s}", .{&types.formatId(client_id)});
            return client_id;
        }

        log.warn("auth failed: invalid api key", .{});
        return null;
    }

    /// Authenticate using a JWT token, returns user_id as ClientId
    pub fn authenticateJwt(self: *Authenticator, allocator: std.mem.Allocator, token: []const u8) !?types.ClientId {
        const claims = try Jwt.validate(allocator, token, self.jwt_secret) orelse return null;
        log.info("auth success (jwt): user_id={s}", .{&std.fmt.bytesToHex(claims.user_id, .lower)});
        return claims.user_id;
    }

    /// Create a JWT for a user
    pub fn createToken(self: *Authenticator, allocator: std.mem.Allocator, user_id: [16]u8, email: []const u8) ![]u8 {
        return Jwt.create(allocator, user_id, email, self.jwt_secret, 86400 * 7); // 7 days
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

    var auth_inst = Authenticator.initWithSecret(allocator, "test-anthropic-key", "test-jwt-secret-key-for-testing!");
    defer auth_inst.deinit();

    var client_id: [16]u8 = undefined;
    @memset(&client_id, 0xAB);

    try auth_inst.registerApiKey("test-api-key-12345", client_id);

    const result = auth_inst.authenticate("test-api-key-12345");
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, &client_id, &result.?);

    const invalid = auth_inst.authenticate("wrong-key");
    try std.testing.expect(invalid == null);
}

test "authenticator getAnthropicKey" {
    const allocator = std.testing.allocator;

    var auth_inst = Authenticator.initWithSecret(allocator, "sk-ant-test-key", "test-jwt-secret");
    defer auth_inst.deinit();

    try std.testing.expectEqualStrings("sk-ant-test-key", auth_inst.getAnthropicKey());
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

test "password hash and verify" {
    const allocator = std.testing.allocator;

    const hashed = try PasswordHash.hash(allocator, "my-secure-password");
    defer allocator.free(hashed);

    try std.testing.expect(PasswordHash.verify("my-secure-password", hashed));
    try std.testing.expect(!PasswordHash.verify("wrong-password", hashed));
}

test "jwt create and validate" {
    const allocator = std.testing.allocator;
    const secret = "test-jwt-secret-for-unit-tests!";

    var user_id: [16]u8 = undefined;
    @memset(&user_id, 0x42);

    const token = try Jwt.create(allocator, user_id, "test@example.com", secret, 3600);
    defer allocator.free(token);

    const claims = try Jwt.validate(allocator, token, secret);
    try std.testing.expect(claims != null);
    try std.testing.expectEqualSlices(u8, &user_id, &claims.?.user_id);
}

test "jwt rejects wrong secret" {
    const allocator = std.testing.allocator;

    var user_id: [16]u8 = undefined;
    @memset(&user_id, 0x42);

    const token = try Jwt.create(allocator, user_id, "test@example.com", "correct-secret-key-for-testing!", 3600);
    defer allocator.free(token);

    const claims = try Jwt.validate(allocator, token, "wrong-secret-key-for-testing!!");
    try std.testing.expect(claims == null);
}
