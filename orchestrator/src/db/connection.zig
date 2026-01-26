const std = @import("std");
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");

const DbError = errors.DbError;
const log = std.log.scoped(.db_connection);

const ScramState = struct {
    client_nonce: [24]u8,
    client_first_bare: [128]u8,
    client_first_bare_len: usize,
    server_first: [256]u8,
    server_first_len: usize,
    salted_password: [32]u8,
};

pub const ConnConfig = struct {
    host: []const u8 = "localhost",
    port: u16 = 5432,
    user: []const u8 = "postgres",
    password: []const u8 = "",
    database: []const u8 = "postgres",
    connect_timeout_ms: u32 = 10_000,

    pub fn fromUrl(url: []const u8, allocator: std.mem.Allocator) !ConnConfig {
        var config = ConnConfig{};
        errdefer {
            if (config.host.len > 0 and config.host.ptr != "localhost".ptr) allocator.free(config.host);
            if (config.user.len > 0 and config.user.ptr != "postgres".ptr) allocator.free(config.user);
            if (config.password.len > 0) allocator.free(config.password);
            if (config.database.len > 0 and config.database.ptr != "postgres".ptr) allocator.free(config.database);
        }

        var start: usize = 0;
        if (std.mem.startsWith(u8, url, "postgresql://")) {
            start = 13;
        } else if (std.mem.startsWith(u8, url, "postgres://")) {
            start = 11;
        }

        var remaining = url[start..];

        if (std.mem.indexOf(u8, remaining, "@")) |at_pos| {
            const auth = remaining[0..at_pos];
            remaining = remaining[at_pos + 1 ..];

            if (std.mem.indexOf(u8, auth, ":")) |colon| {
                config.user = try allocator.dupe(u8, auth[0..colon]);
                config.password = try allocator.dupe(u8, auth[colon + 1 ..]);
            } else {
                config.user = try allocator.dupe(u8, auth);
            }
        }

        const path_start = std.mem.indexOf(u8, remaining, "/") orelse remaining.len;
        const host_port = remaining[0..path_start];

        if (std.mem.indexOf(u8, host_port, ":")) |colon| {
            config.host = try allocator.dupe(u8, host_port[0..colon]);
            config.port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch 5432;
        } else if (host_port.len > 0) {
            config.host = try allocator.dupe(u8, host_port);
        }

        if (path_start < remaining.len) {
            var db = remaining[path_start + 1 ..];
            if (std.mem.indexOf(u8, db, "?")) |q| {
                db = db[0..q];
            }
            if (db.len > 0) {
                config.database = try allocator.dupe(u8, db);
            }
        }

        return config;
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    writer: protocol.MessageWriter,
    read_buf: [8192]u8,
    backend_pid: i32,
    secret_key: i32,
    tx_status: protocol.TransactionStatus,
    connected: bool,
    last_error: ?errors.ErrorInfo,
    prepared_statements: std.StringHashMap(void),

    pub fn connect(allocator: std.mem.Allocator, config: ConnConfig) !*Connection {
        const conn = try allocator.create(Connection);
        errdefer allocator.destroy(conn);

        conn.* = .{
            .allocator = allocator,
            .stream = undefined,
            .writer = protocol.MessageWriter.init(allocator),
            .read_buf = undefined,
            .backend_pid = 0,
            .secret_key = 0,
            .tx_status = .idle,
            .connected = false,
            .last_error = null,
            .prepared_statements = std.StringHashMap(void).init(allocator),
        };
        errdefer conn.writer.deinit();

        const address = std.net.Address.parseIp4(config.host, config.port) catch blk: {
            const list = try std.net.getAddressList(allocator, config.host, config.port);
            defer list.deinit();
            if (list.addrs.len == 0) return DbError.ConnectionFailed;
            break :blk list.addrs[0];
        };

        conn.stream = std.net.tcpConnectToAddress(address) catch {
            log.err("tcp connect failed: host={s} port={d}", .{ config.host, config.port });
            return DbError.ConnectionFailed;
        };
        errdefer conn.stream.close();

        try protocol.writeStartupMessage(&conn.writer, config.user, config.database);
        conn.stream.writeAll(conn.writer.data()) catch return DbError.ConnectionFailed;

        try conn.authenticate(config.user, config.password);
        conn.connected = true;

        log.info("connected: host={s} port={d} database={s} pid={d}", .{
            config.host,
            config.port,
            config.database,
            conn.backend_pid,
        });

        return conn;
    }

    pub fn close(self: *Connection) void {
        if (self.connected) {
            protocol.writeTerminate(&self.writer) catch {};
            self.stream.writeAll(self.writer.data()) catch {};
            self.stream.close();
            self.connected = false;
        }

        if (self.last_error) |*err| {
            err.deinit();
        }

        var key_it = self.prepared_statements.keyIterator();
        while (key_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.prepared_statements.deinit();

        self.writer.deinit();
        self.allocator.destroy(self);
    }

    fn authenticate(self: *Connection, user: []const u8, password: []const u8) !void {
        var scram_state: ScramState = undefined;

        while (true) {
            const msg = try protocol.Message.read(self.stream, &self.read_buf);

            switch (msg.msg_type) {
                .authentication => {
                    if (msg.payload.len < 4) return DbError.ProtocolError;
                    const auth_type: protocol.AuthType = @enumFromInt(std.mem.readInt(i32, msg.payload[0..4], .big));

                    switch (auth_type) {
                        .ok => {},
                        .cleartext_password => {
                            try protocol.writePasswordMessage(&self.writer, password);
                            self.stream.writeAll(self.writer.data()) catch return DbError.ConnectionFailed;
                        },
                        .md5_password => {
                            if (msg.payload.len < 8) return DbError.ProtocolError;
                            const salt = msg.payload[4..8];
                            try protocol.writeMd5PasswordMessage(&self.writer, user, password, salt[0..4].*);
                            self.stream.writeAll(self.writer.data()) catch return DbError.ConnectionFailed;
                        },
                        .sasl => {
                            try handleSaslInit(self, user, msg.payload[4..], &scram_state);
                        },
                        .sasl_continue => {
                            try handleSaslContinue(self, user, password, msg.payload[4..], &scram_state);
                        },
                        .sasl_final => {
                            try handleSaslFinal(msg.payload[4..], &scram_state);
                        },
                        else => {
                            log.err("unsupported auth type: {}", .{auth_type});
                            return DbError.AuthenticationFailed;
                        },
                    }
                },
                .error_response => {
                    self.last_error = try protocol.parseErrorResponse(msg.payload, self.allocator);
                    log.err("auth error: {any}", .{self.last_error.?});
                    return DbError.AuthenticationFailed;
                },
                .backend_key_data => {
                    if (msg.payload.len >= 8) {
                        self.backend_pid = std.mem.readInt(i32, msg.payload[0..4], .big);
                        self.secret_key = std.mem.readInt(i32, msg.payload[4..8], .big);
                    }
                },
                .parameter_status => {},
                .ready_for_query => {
                    if (msg.payload.len > 0) {
                        self.tx_status = @enumFromInt(msg.payload[0]);
                    }
                    return;
                },
                else => {},
            }
        }
    }

    fn handleSaslInit(self: *Connection, user: []const u8, payload: []const u8, state: *ScramState) !void {
        var found_scram256 = false;
        var pos: usize = 0;
        while (pos < payload.len) {
            const end = std.mem.indexOfScalarPos(u8, payload, pos, 0) orelse break;
            const mechanism = payload[pos..end];
            if (mechanism.len == 0) break;
            if (std.mem.eql(u8, mechanism, "SCRAM-SHA-256")) {
                found_scram256 = true;
                break;
            }
            pos = end + 1;
        }

        if (!found_scram256) {
            log.err("SCRAM-SHA-256 not offered by server", .{});
            return DbError.AuthenticationFailed;
        }

        std.crypto.random.bytes(&state.client_nonce);
        var nonce_b64: [32]u8 = undefined;
        const nonce_len = std.base64.standard.Encoder.encode(&nonce_b64, &state.client_nonce).len;

        var client_first_bare_stream = std.io.fixedBufferStream(&state.client_first_bare);
        const w = client_first_bare_stream.writer();
        w.print("n={s},r={s}", .{ user, nonce_b64[0..nonce_len] }) catch return DbError.ProtocolError;
        state.client_first_bare_len = client_first_bare_stream.pos;

        var client_first: [256]u8 = undefined;
        var client_first_stream = std.io.fixedBufferStream(&client_first);
        const cfw = client_first_stream.writer();
        cfw.print("n,,{s}", .{state.client_first_bare[0..state.client_first_bare_len]}) catch return DbError.ProtocolError;

        try protocol.writeSaslInitialResponse(&self.writer, "SCRAM-SHA-256", client_first[0..client_first_stream.pos]);
        self.stream.writeAll(self.writer.data()) catch return DbError.ConnectionFailed;
    }

    fn handleSaslContinue(self: *Connection, user: []const u8, password: []const u8, payload: []const u8, state: *ScramState) !void {
        @memcpy(state.server_first[0..payload.len], payload);
        state.server_first_len = payload.len;

        var server_nonce: []const u8 = "";
        var salt_b64: []const u8 = "";
        var iterations: u32 = 0;

        var iter = std.mem.splitScalar(u8, payload, ',');
        while (iter.next()) |part| {
            if (part.len < 2) continue;
            const key = part[0];
            const value = part[2..];
            switch (key) {
                'r' => server_nonce = value,
                's' => salt_b64 = value,
                'i' => iterations = std.fmt.parseInt(u32, value, 10) catch 4096,
                else => {},
            }
        }

        if (server_nonce.len == 0 or salt_b64.len == 0 or iterations == 0) {
            log.err("invalid server-first-message", .{});
            return DbError.AuthenticationFailed;
        }

        var salt: [128]u8 = undefined;
        const salt_len = std.base64.standard.Decoder.calcSizeForSlice(salt_b64) catch return DbError.AuthenticationFailed;
        std.base64.standard.Decoder.decode(salt[0..salt_len], salt_b64) catch return DbError.AuthenticationFailed;

        hi(password, salt[0..salt_len], iterations, &state.salted_password);

        var client_key: [32]u8 = undefined;
        var mac = std.crypto.auth.hmac.sha2.HmacSha256.init(&state.salted_password);
        mac.update("Client Key");
        mac.final(&client_key);

        var stored_key: [32]u8 = undefined;
        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        sha.update(&client_key);
        sha.final(&stored_key);

        const client_first_bare = state.client_first_bare[0..state.client_first_bare_len];
        const server_first = state.server_first[0..state.server_first_len];

        var client_final_without_proof: [256]u8 = undefined;
        var cfwp_stream = std.io.fixedBufferStream(&client_final_without_proof);
        const cfwp_w = cfwp_stream.writer();
        cfwp_w.print("c=biws,r={s}", .{server_nonce}) catch return DbError.ProtocolError;
        const cfwp_len = cfwp_stream.pos;

        var auth_message: [512]u8 = undefined;
        var am_stream = std.io.fixedBufferStream(&auth_message);
        const am_w = am_stream.writer();
        am_w.print("{s},{s},{s}", .{ client_first_bare, server_first, client_final_without_proof[0..cfwp_len] }) catch return DbError.ProtocolError;
        const am_len = am_stream.pos;

        var client_sig: [32]u8 = undefined;
        mac = std.crypto.auth.hmac.sha2.HmacSha256.init(&stored_key);
        mac.update(auth_message[0..am_len]);
        mac.final(&client_sig);

        var client_proof: [32]u8 = undefined;
        for (0..32) |i| {
            client_proof[i] = client_key[i] ^ client_sig[i];
        }

        var proof_b64: [44]u8 = undefined;
        const proof_b64_slice = std.base64.standard.Encoder.encode(&proof_b64, &client_proof);

        var client_final: [256]u8 = undefined;
        var cf_stream = std.io.fixedBufferStream(&client_final);
        const cf_w = cf_stream.writer();
        cf_w.print("{s},p={s}", .{ client_final_without_proof[0..cfwp_len], proof_b64_slice }) catch return DbError.ProtocolError;

        try protocol.writeSaslResponse(&self.writer, client_final[0..cf_stream.pos]);
        self.stream.writeAll(self.writer.data()) catch return DbError.ConnectionFailed;

        _ = user;
    }

    fn handleSaslFinal(payload: []const u8, state: *ScramState) !void {
        _ = state;
        if (payload.len < 2 or payload[0] != 'v' or payload[1] != '=') {
            log.err("invalid server-final-message", .{});
            return DbError.AuthenticationFailed;
        }
    }

    fn hi(password: []const u8, salt: []const u8, iterations: u32, out: *[32]u8) void {
        var u: [32]u8 = undefined;
        var mac = std.crypto.auth.hmac.sha2.HmacSha256.init(password);
        mac.update(salt);
        mac.update(&[_]u8{ 0, 0, 0, 1 });
        mac.final(&u);

        @memcpy(out, &u);

        var i: u32 = 1;
        while (i < iterations) : (i += 1) {
            mac = std.crypto.auth.hmac.sha2.HmacSha256.init(password);
            mac.update(&u);
            mac.final(&u);

            for (0..32) |j| {
                out[j] ^= u[j];
            }
        }
    }

    pub fn query(self: *Connection, sql: []const u8) !types.QueryResult {
        return self.queryParams(sql, &.{});
    }

    pub fn queryParams(self: *Connection, sql: []const u8, params: []const types.Param) !types.QueryResult {
        if (!self.connected) return DbError.ConnectionClosed;

        if (params.len == 0) {
            try protocol.writeQuery(&self.writer, sql);
            self.stream.writeAll(self.writer.data()) catch return DbError.ConnectionFailed;
        } else {
            try self.execPrepared("", sql, params);
        }

        return self.readQueryResult();
    }

    pub fn exec(self: *Connection, sql: []const u8) !u64 {
        var result = try self.query(sql);
        defer result.deinit();
        return result.rows_affected;
    }

    pub fn execParams(self: *Connection, sql: []const u8, params: []const types.Param) !u64 {
        var result = try self.queryParams(sql, params);
        defer result.deinit();
        return result.rows_affected;
    }

    pub fn prepare(self: *Connection, name: []const u8, sql: []const u8) !void {
        if (!self.connected) return DbError.ConnectionClosed;

        var oids: [0]types.Oid = .{};
        try protocol.writeParse(&self.writer, name, sql, &oids);
        self.stream.writeAll(self.writer.data()) catch return DbError.ConnectionFailed;

        try protocol.writeSync(&self.writer);
        self.stream.writeAll(self.writer.data()) catch return DbError.ConnectionFailed;

        while (true) {
            const msg = try protocol.Message.read(self.stream, &self.read_buf);

            switch (msg.msg_type) {
                .parse_complete => {},
                .error_response => {
                    if (self.last_error) |*e| e.deinit();
                    self.last_error = try protocol.parseErrorResponse(msg.payload, self.allocator);
                    log.err("prepare error: {any}", .{self.last_error.?});
                },
                .ready_for_query => {
                    if (msg.payload.len > 0) {
                        self.tx_status = @enumFromInt(msg.payload[0]);
                    }
                    if (self.last_error != null) return DbError.QueryFailed;

                    const owned_name = try self.allocator.dupe(u8, name);
                    try self.prepared_statements.put(owned_name, {});
                    return;
                },
                else => {},
            }
        }
    }

    pub fn execPrepared(self: *Connection, name: []const u8, sql: []const u8, params: []const types.Param) !void {
        if (!self.prepared_statements.contains(name)) {
            try self.prepare(name, sql);
        }

        try protocol.writeBind(&self.writer, "", name, params);
        self.stream.writeAll(self.writer.data()) catch return DbError.ConnectionFailed;

        try protocol.writeDescribe(&self.writer, 'P', "");
        self.stream.writeAll(self.writer.data()) catch return DbError.ConnectionFailed;

        try protocol.writeExecute(&self.writer, "", 0);
        self.stream.writeAll(self.writer.data()) catch return DbError.ConnectionFailed;

        try protocol.writeSync(&self.writer);
        self.stream.writeAll(self.writer.data()) catch return DbError.ConnectionFailed;
    }

    fn readQueryResult(self: *Connection) !types.QueryResult {
        var rows: std.ArrayListUnmanaged(types.Row) = .empty;
        errdefer {
            for (rows.items) |*row| row.deinit();
            rows.deinit(self.allocator);
        }

        var fields: ?[]types.FieldDesc = null;
        errdefer if (fields) |f| {
            for (f) |field| self.allocator.free(field.name);
            self.allocator.free(f);
        };

        var rows_affected: u64 = 0;

        while (true) {
            const msg = try protocol.Message.read(self.stream, &self.read_buf);

            switch (msg.msg_type) {
                .row_description => {
                    if (fields) |f| {
                        for (f) |field| self.allocator.free(field.name);
                        self.allocator.free(f);
                    }
                    fields = try protocol.parseRowDescription(msg.payload, self.allocator);
                },
                .data_row => {
                    if (fields) |f| {
                        const row = try protocol.parseDataRow(msg.payload, f, self.allocator);
                        try rows.append(self.allocator, row);
                    }
                },
                .command_complete => {
                    rows_affected = protocol.parseCommandComplete(msg.payload);
                },
                .empty_query_response => {},
                .error_response => {
                    if (self.last_error) |*e| e.deinit();
                    self.last_error = try protocol.parseErrorResponse(msg.payload, self.allocator);
                    log.err("query error: {any}", .{self.last_error.?});
                },
                .notice_response => {},
                .ready_for_query => {
                    if (msg.payload.len > 0) {
                        self.tx_status = @enumFromInt(msg.payload[0]);
                    }

                    if (self.last_error) |*err| {
                        const db_err = errors.mapSqlState(err.code);
                        err.deinit();
                        self.last_error = null;
                        return db_err;
                    }

                    return .{
                        .rows = try rows.toOwnedSlice(self.allocator),
                        .fields = fields orelse &.{},
                        .rows_affected = rows_affected,
                        .allocator = self.allocator,
                    };
                },
                .bind_complete, .parse_complete, .no_data => {},
                else => {},
            }
        }
    }

    pub fn begin(self: *Connection) !void {
        _ = try self.exec("BEGIN");
    }

    pub fn commit(self: *Connection) !void {
        _ = try self.exec("COMMIT");
    }

    pub fn rollback(self: *Connection) !void {
        _ = try self.exec("ROLLBACK");
    }

    pub fn isHealthy(self: *Connection) bool {
        if (!self.connected) return false;
        if (self.tx_status == .failed) return false;

        var result = self.query("SELECT 1") catch return false;
        defer result.deinit();
        return result.rowCount() == 1;
    }
};

test "connection config from url" {
    const allocator = std.testing.allocator;

    const config = try ConnConfig.fromUrl("postgresql://user:pass@localhost:5432/mydb", allocator);
    defer {
        allocator.free(config.host);
        allocator.free(config.user);
        allocator.free(config.password);
        allocator.free(config.database);
    }

    try std.testing.expectEqualStrings("localhost", config.host);
    try std.testing.expectEqual(@as(u16, 5432), config.port);
    try std.testing.expectEqualStrings("user", config.user);
    try std.testing.expectEqualStrings("pass", config.password);
    try std.testing.expectEqualStrings("mydb", config.database);
}

test "connection config from url without port" {
    const allocator = std.testing.allocator;

    const config = try ConnConfig.fromUrl("postgres://admin@dbhost/testdb", allocator);
    defer {
        allocator.free(config.host);
        allocator.free(config.user);
        allocator.free(config.database);
    }

    try std.testing.expectEqualStrings("dbhost", config.host);
    try std.testing.expectEqual(@as(u16, 5432), config.port);
    try std.testing.expectEqualStrings("admin", config.user);
    try std.testing.expectEqualStrings("testdb", config.database);
}
