const std = @import("std");
const net = std.net;
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

    pub fn init(allocator: std.mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .stream = null,
            .next_request_id = 1,
        };
    }

    pub fn connect(self: *Client, host: []const u8, port: u16) !void {
        const address = try net.Address.parseIp(host, port);
        self.stream = try net.tcpConnectToAddress(address);
    }

    pub fn close(self: *Client) void {
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
    }

    pub fn call(self: *Client, msg_type: protocol.MessageType, request: anytype, comptime ResponseType: type) !protocol.Message(ResponseType) {
        const stream = self.stream orelse return error.NotConnected;

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

        try stream.writeAll(data);

        var header_buf: [@sizeOf(protocol.Header)]u8 = undefined;
        var total: usize = 0;
        while (total < header_buf.len) {
            const n = try stream.read(header_buf[total..]);
            if (n == 0) return error.ConnectionClosed;
            total += n;
        }

        const header: *const protocol.Header = @ptrCast(@alignCast(&header_buf));
        if (!std.mem.eql(u8, &header.magic, &.{ 'M', 'R', 'T', 'N' })) {
            return error.InvalidMagic;
        }

        const payload_buf = try self.allocator.alloc(u8, header.payload_len);
        defer self.allocator.free(payload_buf);

        total = 0;
        while (total < payload_buf.len) {
            const n = try stream.read(payload_buf[total..]);
            if (n == 0) return error.ConnectionClosed;
            total += n;
        }

        var full_buf = try self.allocator.alloc(u8, @sizeOf(protocol.Header) + header.payload_len);
        defer self.allocator.free(full_buf);

        @memcpy(full_buf[0..@sizeOf(protocol.Header)], &header_buf);
        @memcpy(full_buf[@sizeOf(protocol.Header)..], payload_buf);

        return protocol.Message(ResponseType).decode(self.allocator, full_buf);
    }

    pub fn streamCall(
        self: *Client,
        msg_type: protocol.MessageType,
        request: anytype,
        comptime EventType: type,
        callback: *const fn (protocol.Message(EventType)) bool,
    ) !void {
        const stream = self.stream orelse return error.NotConnected;

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

        try stream.writeAll(data);

        while (true) {
            var header_buf: [@sizeOf(protocol.Header)]u8 = undefined;
            var total: usize = 0;
            while (total < header_buf.len) {
                const n = stream.read(header_buf[total..]) catch |err| {
                    if (err == error.ConnectionResetByPeer) return;
                    return err;
                };
                if (n == 0) return;
                total += n;
            }

            const header: *const protocol.Header = @ptrCast(@alignCast(&header_buf));
            if (!std.mem.eql(u8, &header.magic, &.{ 'M', 'R', 'T', 'N' })) {
                return error.InvalidMagic;
            }

            const payload_buf = try self.allocator.alloc(u8, header.payload_len);
            defer self.allocator.free(payload_buf);

            total = 0;
            while (total < payload_buf.len) {
                const n = try stream.read(payload_buf[total..]);
                if (n == 0) return;
                total += n;
            }

            var full_buf = try self.allocator.alloc(u8, @sizeOf(protocol.Header) + header.payload_len);
            defer self.allocator.free(full_buf);

            @memcpy(full_buf[0..@sizeOf(protocol.Header)], &header_buf);
            @memcpy(full_buf[@sizeOf(protocol.Header)..], payload_buf);

            const event = try protocol.Message(EventType).decode(self.allocator, full_buf);

            if (!callback(event)) break;
        }
    }
};
