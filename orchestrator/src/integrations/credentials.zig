const std = @import("std");
const crypto = std.crypto;

/// Manages encrypted storage of integration credentials with key rotation support
pub const CredentialsManager = struct {
    allocator: std.mem.Allocator,
    encryption_key: [32]u8,
    stored_credentials: std.StringHashMap(EncryptedCredentials),

    const EncryptedCredentials = struct {
        integration_id: []const u8,
        encrypted_data: []const u8,
        nonce: [12]u8,
        created_at: i64,
        updated_at: i64,
        rotation_count: u32,

        pub fn deinit(self: *EncryptedCredentials, allocator: std.mem.Allocator) void {
            allocator.free(self.integration_id);
            allocator.free(self.encrypted_data);
        }
    };

    pub const Credentials = struct {
        integration_id: []const u8,
        settings: std.StringHashMap([]const u8),

        pub fn deinit(self: *Credentials, allocator: std.mem.Allocator) void {
            allocator.free(self.integration_id);
            var iter = self.settings.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            self.settings.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator, master_key: []const u8) CredentialsManager {
        var encryption_key: [32]u8 = undefined;
        crypto.hash.blake3.hash(master_key, &encryption_key, .{});
        
        return .{
            .allocator = allocator,
            .encryption_key = encryption_key,
            .stored_credentials = std.StringHashMap(EncryptedCredentials).init(allocator),
        };
    }

    pub fn deinit(self: *CredentialsManager) void {
        var iter = self.stored_credentials.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.stored_credentials.deinit();
    }

    pub fn storeCredentials(self: *CredentialsManager, integration_id: []const u8, settings: std.StringHashMap([]const u8)) !void {
        // Serialize settings to JSON
        var json_buf = std.ArrayList(u8).init(self.allocator);
        defer json_buf.deinit();

        try json_buf.append('{');
        var iter = settings.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try json_buf.append(',');
            first = false;
            try std.fmt.format(json_buf.writer(), "\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try json_buf.append('}');

        // Generate random nonce
        var nonce: [12]u8 = undefined;
        crypto.random.bytes(&nonce);

        // Encrypt the JSON data
        const plaintext = json_buf.items;
        var ciphertext = try self.allocator.alloc(u8, plaintext.len);
        var tag: [16]u8 = undefined;

        crypto.aead.chacha_poly.ChaCha20Poly1305.encrypt(ciphertext, &tag, plaintext, "", nonce, self.encryption_key);

        // Combine ciphertext and tag
        var encrypted_data = try self.allocator.alloc(u8, ciphertext.len + tag.len);
        @memcpy(encrypted_data[0..ciphertext.len], ciphertext);
        @memcpy(encrypted_data[ciphertext.len..], &tag);
        
        self.allocator.free(ciphertext);

        const now = std.time.timestamp();
        const credentials = EncryptedCredentials{
            .integration_id = try self.allocator.dupe(u8, integration_id),
            .encrypted_data = encrypted_data,
            .nonce = nonce,
            .created_at = now,
            .updated_at = now,
            .rotation_count = 0,
        };

        // Remove existing credentials if any
        if (self.stored_credentials.fetchRemove(integration_id)) |entry| {
            entry.value.deinit(self.allocator);
        }

        try self.stored_credentials.put(try self.allocator.dupe(u8, integration_id), credentials);
    }

    pub fn getCredentials(self: *CredentialsManager, integration_id: []const u8) !Credentials {
        const encrypted = self.stored_credentials.get(integration_id) orelse return error.CredentialsNotFound;

        // Extract ciphertext and tag
        const tag_size = 16;
        if (encrypted.encrypted_data.len < tag_size) return error.InvalidCredentialData;
        
        const ciphertext = encrypted.encrypted_data[0..encrypted.encrypted_data.len - tag_size];
        const tag = encrypted.encrypted_data[encrypted.encrypted_data.len - tag_size..][0..tag_size].*;

        // Decrypt
        var plaintext = try self.allocator.alloc(u8, ciphertext.len);
        defer self.allocator.free(plaintext);

        crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(plaintext, ciphertext, tag, "", encrypted.nonce, self.encryption_key) catch return error.DecryptionFailed;

        // Parse JSON back to settings map
        var settings = std.StringHashMap([]const u8).init(self.allocator);
        
        var parser = std.json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();
        
        var tree = try parser.parse(plaintext);
        defer tree.deinit();

        if (tree.root != .object) return error.InvalidCredentialFormat;
        
        var obj_iter = tree.root.object.iterator();
        while (obj_iter.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            const value = try self.allocator.dupe(u8, entry.value_ptr.string);
            try settings.put(key, value);
        }

        return Credentials{
            .integration_id = try self.allocator.dupe(u8, integration_id),
            .settings = settings,
        };
    }

    pub fn deleteCredentials(self: *CredentialsManager, integration_id: []const u8) !void {
        if (self.stored_credentials.fetchRemove(integration_id)) |entry| {
            entry.value.deinit(self.allocator);
        }
    }

    pub fn rotateEncryptionKey(self: *CredentialsManager, new_master_key: []const u8) !void {
        var new_encryption_key: [32]u8 = undefined;
        crypto.hash.blake3.hash(new_master_key, &new_encryption_key, .{});

        // Re-encrypt all stored credentials with new key
        var temp_credentials = std.ArrayList(struct { id: []const u8, settings: std.StringHashMap([]const u8) }).init(self.allocator);
        defer {
            for (temp_credentials.items) |item| {
                self.allocator.free(item.id);
                var iter = item.settings.iterator();
                while (iter.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                item.settings.deinit();
            }
            temp_credentials.deinit();
        }

        // Decrypt all with old key
        var iter = self.stored_credentials.iterator();
        while (iter.next()) |entry| {
            var creds = try self.getCredentials(entry.key_ptr.*);
            defer creds.deinit(self.allocator);
            
            try temp_credentials.append(.{
                .id = try self.allocator.dupe(u8, entry.key_ptr.*),
                .settings = creds.settings,
            });
        }

        // Update encryption key
        self.encryption_key = new_encryption_key;

        // Clear old credentials
        iter = self.stored_credentials.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.stored_credentials.clearAndFree();

        // Re-encrypt with new key
        for (temp_credentials.items) |item| {
            try self.storeCredentials(item.id, item.settings);
        }
    }

    pub fn healthCheck(self: *CredentialsManager) bool {
        // Simple health check - verify we can decrypt a test credential
        const test_id = "__health_check__";
        var test_settings = std.StringHashMap([]const u8).init(self.allocator);
        defer test_settings.deinit();
        test_settings.put("test", "value") catch return false;

        self.storeCredentials(test_id, test_settings) catch return false;
        var retrieved = self.getCredentials(test_id) catch return false;
        defer retrieved.deinit(self.allocator);
        self.deleteCredentials(test_id) catch return false;

        return retrieved.settings.get("test") != null;
    }
};

test "credentials manager encrypt/decrypt" {
    const testing = std.testing;
    
    var manager = CredentialsManager.init(testing.allocator, "test-master-key-12345");
    defer manager.deinit();

    var settings = std.StringHashMap([]const u8).init(testing.allocator);
    defer settings.deinit();
    try settings.put("username", "testuser");
    try settings.put("password", "secret123");
    try settings.put("token", "ghp_abc123");

    try manager.storeCredentials("test-integration", settings);

    var retrieved = try manager.getCredentials("test-integration");
    defer retrieved.deinit(testing.allocator);

    try testing.expectEqualStrings("testuser", retrieved.settings.get("username").?);
    try testing.expectEqualStrings("secret123", retrieved.settings.get("password").?);
    try testing.expectEqualStrings("ghp_abc123", retrieved.settings.get("token").?);
}

test "credentials manager key rotation" {
    const testing = std.testing;
    
    var manager = CredentialsManager.init(testing.allocator, "old-key");
    defer manager.deinit();

    var settings = std.StringHashMap([]const u8).init(testing.allocator);
    defer settings.deinit();
    try settings.put("secret", "important-data");

    try manager.storeCredentials("test", settings);

    // Rotate key
    try manager.rotateEncryptionKey("new-key");

    // Should still be able to decrypt
    var retrieved = try manager.getCredentials("test");
    defer retrieved.deinit(testing.allocator);

    try testing.expectEqualStrings("important-data", retrieved.settings.get("secret").?);
}

test "health check" {
    const testing = std.testing;
    
    var manager = CredentialsManager.init(testing.allocator, "test-key");
    defer manager.deinit();

    try testing.expect(manager.healthCheck());
}