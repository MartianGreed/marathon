const std = @import("std");
const net = std.net;
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;
const protocol = @import("protocol.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    listener: ?net.Server,
    running: std.atomic.Value(bool),
    handler: *const fn (*Connection) void,

    pub fn init(allocator: std.mem.Allocator, handler: *const fn (*Connection) void) Server {
        return .{
            .allocator = allocator,
            .listener = null,
            .running = std.atomic.Value(bool).init(false),
            .handler = handler,
        };
    }

    pub fn listen(self: *Server, address: []const u8, port: u16) !void {
        const addr = try net.Address.parseIp(address, port);
        self.listener = try addr.listen(.{
            .reuse_address = true,
        });
        self.running.store(true, .release);
    }

    pub fn run(self: *Server) !void {
        const listener = self.listener orelse return error.NotListening;

        while (self.running.load(.acquire)) {
            const conn = listener.accept() catch |err| {
                if (err == error.ConnectionAborted) continue;
                return err;
            };

            const thread = try std.Thread.spawn(.{}, handleConnection, .{ self, conn });
            thread.detach();
        }
    }

    fn handleConnection(self: *Server, stream: net.Server.Connection) void {
        var connection = Connection{
            .allocator = self.allocator,
            .stream = stream.stream,
            .address = stream.address,
        };
        defer connection.close();

        self.handler(&connection);
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    address: net.Address,

    pub fn close(self: *Connection) void {
        self.stream.close();
    }

    pub fn readHeader(self: *Connection) !protocol.Header {
        var header_buf: [@sizeOf(protocol.Header)]u8 = undefined;
        try self.readExact(&header_buf);

        const header: *const protocol.Header = @ptrCast(@alignCast(&header_buf));
        if (!std.mem.eql(u8, &header.magic, &.{ 'M', 'R', 'T', 'N' })) {
            return error.InvalidMagic;
        }

        return header.*;
    }

    pub fn readPayload(self: *Connection, comptime T: type, header: protocol.Header) !T {
        const payload_buf = try self.allocator.alloc(u8, header.payload_len);
        defer self.allocator.free(payload_buf);

        try self.readExact(payload_buf);

        var full_buf = try self.allocator.alloc(u8, @sizeOf(protocol.Header) + header.payload_len);
        defer self.allocator.free(full_buf);

        @memcpy(full_buf[0..@sizeOf(protocol.Header)], std.mem.asBytes(&header));
        @memcpy(full_buf[@sizeOf(protocol.Header)..], payload_buf);

        const msg = try protocol.Message(T).decode(self.allocator, full_buf);
        return msg.payload;
    }

    pub fn readMessage(self: *Connection, comptime T: type) !protocol.Message(T) {
        var header_buf: [@sizeOf(protocol.Header)]u8 = undefined;
        try self.readExact(&header_buf);

        const header: *const protocol.Header = @ptrCast(@alignCast(&header_buf));
        if (!std.mem.eql(u8, &header.magic, &.{ 'M', 'R', 'T', 'N' })) {
            return error.InvalidMagic;
        }

        const payload_buf = try self.allocator.alloc(u8, header.payload_len);
        defer self.allocator.free(payload_buf);

        try self.readExact(payload_buf);

        var full_buf = try self.allocator.alloc(u8, @sizeOf(protocol.Header) + header.payload_len);
        defer self.allocator.free(full_buf);

        @memcpy(full_buf[0..@sizeOf(protocol.Header)], &header_buf);
        @memcpy(full_buf[@sizeOf(protocol.Header)..], payload_buf);

        return protocol.Message(T).decode(self.allocator, full_buf);
    }

    pub fn writeMessage(self: *Connection, msg_type: protocol.MessageType, request_id: u32, payload: anytype) !void {
        const PayloadType = @TypeOf(payload);
        const msg = protocol.Message(PayloadType){
            .header = .{
                .msg_type = msg_type,
                .payload_len = 0,
                .request_id = request_id,
            },
            .payload = payload,
        };

        const data = try msg.encode(self.allocator);
        defer self.allocator.free(data);

        try self.stream.writeAll(data);
    }

    fn readExact(self: *Connection, buf: []u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try self.stream.read(buf[total..]);
            if (n == 0) return error.ConnectionClosed;
            total += n;
        }
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    stream: ?net.Stream,
    next_request_id: u32,
    tls_client: ?*tls.Client = null,
    stream_reader: ?net.Stream.Reader = null,
    stream_writer: ?net.Stream.Writer = null,
    read_buf: []u8 = &.{},
    write_buf: []u8 = &.{},
    tls_read_buf: []u8 = &.{},
    tls_write_buf: []u8 = &.{},
    ca_bundle: ?Certificate.Bundle = null,

    pub fn init(allocator: std.mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .stream = null,
            .next_request_id = 1,
        };
    }

    pub fn connect(self: *Client, host: []const u8, port: u16, tls_enabled: bool, ca_path: ?[]const u8) !void {
        const address = net.Address.parseIp(host, port) catch {
            const list = try net.getAddressList(self.allocator, host, port);
            defer list.deinit();
            if (list.addrs.len == 0) return error.UnknownHostName;
            self.stream = try net.tcpConnectToAddress(list.addrs[0]);
            errdefer {
                self.stream.?.close();
                self.stream = null;
            }
            std.debug.print("[grpc] TCP connected to {s}:{d} (resolved)\n", .{ host, port });
            if (tls_enabled) try self.initTls(host, ca_path);
            return;
        };
        self.stream = try net.tcpConnectToAddress(address);
        errdefer {
            self.stream.?.close();
            self.stream = null;
        }
        std.debug.print("[grpc] TCP connected to {s}:{d}\n", .{ host, port });
        if (tls_enabled) try self.initTls(host, ca_path);
    }

    fn initTls(self: *Client, host: []const u8, ca_path: ?[]const u8) !void {
        const s = self.stream orelse return error.NotConnected;

        std.debug.print("[grpc] Initializing TLS for host: {s}\n", .{host});
        var ca_bundle: Certificate.Bundle = .{};
        if (ca_path) |path| {
            try ca_bundle.addCertsFromFilePathAbsolute(self.allocator, path);
            std.debug.print("[grpc] CA bundle loaded from: {s}\n", .{path});
        } else {
            try ca_bundle.rescan(self.allocator);
            std.debug.print("[grpc] CA bundle loaded from system defaults\n", .{});
        }
        errdefer ca_bundle.deinit(self.allocator);

        const read_buf = try self.allocator.alloc(u8, tls.Client.min_buffer_len);
        errdefer self.allocator.free(read_buf);
        const write_buf = try self.allocator.alloc(u8, tls.Client.min_buffer_len);
        errdefer self.allocator.free(write_buf);
        const tls_read_buf = try self.allocator.alloc(u8, tls.Client.min_buffer_len);
        errdefer self.allocator.free(tls_read_buf);
        const tls_write_buf = try self.allocator.alloc(u8, tls.Client.min_buffer_len);
        errdefer self.allocator.free(tls_write_buf);

        var stream_reader = s.reader(read_buf);
        var stream_writer = s.writer(write_buf);

        const tc = try self.allocator.create(tls.Client);
        errdefer self.allocator.destroy(tc);

        std.debug.print("[grpc] TLS handshake starting...\n", .{});
        tc.* = tls.Client.init(stream_reader.interface(), &stream_writer.interface, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = ca_bundle },
            .read_buffer = tls_read_buf,
            .write_buffer = tls_write_buf,
        }) catch |err| {
            std.debug.print("[grpc] TLS handshake failed: {}\n", .{err});
            return err;
        };

        // Success - assign to self (errdefers won't trigger after this point)
        self.ca_bundle = ca_bundle;
        self.read_buf = read_buf;
        self.write_buf = write_buf;
        self.tls_read_buf = tls_read_buf;
        self.tls_write_buf = tls_write_buf;
        self.stream_reader = stream_reader;
        self.stream_writer = stream_writer;
        self.tls_client = tc;
        std.debug.print("[grpc] TLS handshake complete\n", .{});
    }

    pub fn close(self: *Client) void {
        // Clean up TLS first if present
        if (self.tls_client) |tc| {
            // Defensive: catch any errors during TLS cleanup
            tc.end() catch {};
            self.allocator.destroy(tc);
            self.tls_client = null;
        }
        // Close underlying stream BEFORE freeing buffers
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
        // Now safe to free buffers
        if (self.read_buf.len > 0) {
            self.allocator.free(self.read_buf);
            self.read_buf = &.{};
        }
        if (self.write_buf.len > 0) {
            self.allocator.free(self.write_buf);
            self.write_buf = &.{};
        }
        if (self.tls_read_buf.len > 0) {
            self.allocator.free(self.tls_read_buf);
            self.tls_read_buf = &.{};
        }
        if (self.tls_write_buf.len > 0) {
            self.allocator.free(self.tls_write_buf);
            self.tls_write_buf = &.{};
        }
        if (self.ca_bundle) |*cb| {
            cb.deinit(self.allocator);
            self.ca_bundle = null;
        }
        self.stream_reader = null;
        self.stream_writer = null;
    }

    fn writeAllBytes(self: *Client, data: []const u8) !void {
        const mode: []const u8 = if (self.tls_client != null) "TLS" else "plain";
        std.debug.print("[grpc] Writing {d} bytes ({s})\n", .{ data.len, mode });
        if (self.tls_client) |tc| {
            try tc.writer.writeAll(data);
            try tc.writer.flush();
        } else {
            const stream = self.stream orelse return error.NotConnected;
            try stream.writeAll(data);
        }
    }

    fn readExactBytes(self: *Client, buf: []u8) !void {
        const mode: []const u8 = if (self.tls_client != null) "TLS" else "plain";
        std.debug.print("[grpc] Reading {d} bytes ({s})...\n", .{ buf.len, mode });
        if (self.tls_client) |tc| {
            tc.reader.readSliceAll(buf) catch |err| switch (err) {
                error.EndOfStream => return error.ConnectionClosed,
                error.ReadFailed => return error.ConnectionClosed,
            };
        } else {
            const stream = self.stream orelse return error.NotConnected;
            var total: usize = 0;
            while (total < buf.len) {
                const n = try stream.read(buf[total..]);
                if (n == 0) return error.ConnectionClosed;
                total += n;
            }
        }
    }

    pub fn call(self: *Client, msg_type: protocol.MessageType, request: anytype, comptime ResponseType: type) !protocol.Message(ResponseType) {
        if (self.stream == null) return error.NotConnected;

        const request_id = self.next_request_id;
        self.next_request_id +%= 1;

        const RequestType = @TypeOf(request);
        const msg = protocol.Message(RequestType){
            .header = .{
                .msg_type = msg_type,
                .payload_len = 0,
                .request_id = request_id,
            },
            .payload = request,
        };

        const data = try msg.encode(self.allocator);
        defer self.allocator.free(data);

        try self.writeAllBytes(data);

        var header_buf: [@sizeOf(protocol.Header)]u8 = undefined;
        try self.readExactBytes(&header_buf);

        const header: *const protocol.Header = @ptrCast(@alignCast(&header_buf));
        if (!std.mem.eql(u8, &header.magic, &.{ 'M', 'R', 'T', 'N' })) {
            return error.InvalidMagic;
        }

        const payload_buf = try self.allocator.alloc(u8, header.payload_len);
        defer self.allocator.free(payload_buf);

        try self.readExactBytes(payload_buf);

        var full_buf = try self.allocator.alloc(u8, @sizeOf(protocol.Header) + header.payload_len);
        defer self.allocator.free(full_buf);

        @memcpy(full_buf[0..@sizeOf(protocol.Header)], &header_buf);
        @memcpy(full_buf[@sizeOf(protocol.Header)..], payload_buf);

        return protocol.Message(ResponseType).decode(self.allocator, full_buf);
    }

    pub const RawResponse = struct {
        header: protocol.Header,
        payload_data: []u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *RawResponse) void {
            self.allocator.free(self.payload_data);
        }

        pub fn decodeAs(self: *const RawResponse, comptime T: type) !T {
            var full_buf = try self.allocator.alloc(u8, @sizeOf(protocol.Header) + self.payload_data.len);
            defer self.allocator.free(full_buf);

            @memcpy(full_buf[0..@sizeOf(protocol.Header)], std.mem.asBytes(&self.header));
            @memcpy(full_buf[@sizeOf(protocol.Header)..], self.payload_data);

            const msg = try protocol.Message(T).decode(self.allocator, full_buf);
            return msg.payload;
        }
    };

    pub fn callWithHeader(self: *Client, msg_type: protocol.MessageType, request: anytype) !RawResponse {
        if (self.stream == null) return error.NotConnected;

        const request_id = self.next_request_id;
        self.next_request_id +%= 1;

        const RequestType = @TypeOf(request);
        const msg = protocol.Message(RequestType){
            .header = .{
                .msg_type = msg_type,
                .payload_len = 0,
                .request_id = request_id,
            },
            .payload = request,
        };

        const data = try msg.encode(self.allocator);
        defer self.allocator.free(data);

        try self.writeAllBytes(data);

        var header_buf: [@sizeOf(protocol.Header)]u8 = undefined;
        try self.readExactBytes(&header_buf);

        const header: *const protocol.Header = @ptrCast(@alignCast(&header_buf));
        if (!std.mem.eql(u8, &header.magic, &.{ 'M', 'R', 'T', 'N' })) {
            return error.InvalidMagic;
        }

        const payload_data = try self.allocator.alloc(u8, header.payload_len);
        errdefer self.allocator.free(payload_data);

        try self.readExactBytes(payload_data);

        return .{
            .header = header.*,
            .payload_data = payload_data,
            .allocator = self.allocator,
        };
    }

    pub fn streamCall(
        self: *Client,
        msg_type: protocol.MessageType,
        request: anytype,
        comptime EventType: type,
        callback: *const fn (protocol.Message(EventType)) bool,
    ) !void {
        if (self.stream == null) return error.NotConnected;

        const request_id = self.next_request_id;
        self.next_request_id +%= 1;

        const RequestType = @TypeOf(request);
        const msg = protocol.Message(RequestType){
            .header = .{
                .msg_type = msg_type,
                .payload_len = 0,
                .request_id = request_id,
            },
            .payload = request,
        };

        const data = try msg.encode(self.allocator);
        defer self.allocator.free(data);

        std.debug.print("[grpc] streamCall: sending request_id={d} msg_type={s}\n", .{ request_id, @tagName(msg_type) });
        try self.writeAllBytes(data);
        std.debug.print("[grpc] streamCall: request sent, waiting for events...\n", .{});

        while (true) {
            var header_buf: [@sizeOf(protocol.Header)]u8 = undefined;
            self.readExactBytes(&header_buf) catch |err| {
                if (err == error.ConnectionClosed) {
                    std.debug.print("[grpc] streamCall: connection closed by server\n", .{});
                    return;
                }
                return err;
            };

            const header: *const protocol.Header = @ptrCast(@alignCast(&header_buf));
            if (!std.mem.eql(u8, &header.magic, &.{ 'M', 'R', 'T', 'N' })) {
                std.debug.print("[grpc] streamCall: invalid magic in response header\n", .{});
                return error.InvalidMagic;
            }

            std.debug.print("[grpc] streamCall: received header msg_type={s} payload_len={d} request_id={d}\n", .{ @tagName(header.msg_type), header.payload_len, header.request_id });

            const payload_buf = try self.allocator.alloc(u8, header.payload_len);
            defer self.allocator.free(payload_buf);

            self.readExactBytes(payload_buf) catch |err| {
                if (err == error.ConnectionClosed) {
                    std.debug.print("[grpc] streamCall: connection closed while reading payload\n", .{});
                    return;
                }
                return err;
            };

            var full_buf = try self.allocator.alloc(u8, @sizeOf(protocol.Header) + header.payload_len);
            defer self.allocator.free(full_buf);

            @memcpy(full_buf[0..@sizeOf(protocol.Header)], &header_buf);
            @memcpy(full_buf[@sizeOf(protocol.Header)..], payload_buf);

            const event = try protocol.Message(EventType).decode(self.allocator, full_buf);
            std.debug.print("[grpc] streamCall: decoded event successfully\n", .{});

            if (!callback(event)) break;
        }
    }
};
