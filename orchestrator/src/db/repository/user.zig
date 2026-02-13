const std = @import("std");
const pool = @import("../pool.zig");
const errors = @import("../errors.zig");

const DbError = errors.DbError;
const log = std.log.scoped(.user_repo);

pub const User = struct {
    id: [16]u8,
    email: []const u8,
    password_hash: []const u8,
    github_id: ?[]const u8,
    api_key: []const u8,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *User, allocator: std.mem.Allocator) void {
        allocator.free(self.email);
        allocator.free(self.password_hash);
        if (self.github_id) |gid| allocator.free(gid);
        allocator.free(self.api_key);
    }
};

pub const UserRepository = struct {
    allocator: std.mem.Allocator,
    db_pool: *pool.Pool,

    pub fn init(allocator: std.mem.Allocator, db_pool: *pool.Pool) UserRepository {
        return .{
            .allocator = allocator,
            .db_pool = db_pool,
        };
    }

    pub fn create(self: *UserRepository, user: *const User) !void {
        _ = self;
        _ = user;
        // TODO: implement when DB protocol supports parameterized queries
        log.info("user create: stub", .{});
    }

    pub fn findByEmail(self: *UserRepository, email: []const u8) !?User {
        _ = self;
        _ = email;
        // TODO: implement when DB protocol supports parameterized queries
        return null;
    }

    pub fn findByApiKey(self: *UserRepository, api_key: []const u8) !?User {
        _ = self;
        _ = api_key;
        return null;
    }

    pub fn findById(self: *UserRepository, user_id: [16]u8) !?User {
        _ = self;
        _ = user_id;
        return null;
    }
};
