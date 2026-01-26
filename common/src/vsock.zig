const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const types = @import("types.zig");

pub const VMADDR_CID_ANY: u32 = 0xFFFFFFFF;
pub const VMADDR_CID_HYPERVISOR: u32 = 0;
pub const VMADDR_CID_LOCAL: u32 = 1;
pub const VMADDR_CID_HOST: u32 = 2;

pub const DEFAULT_PORT: u32 = 9999;

pub const SockaddrVm = extern struct {
    family: u16 = std.posix.AF.VSOCK,
    reserved1: u16 = 0,
    port: u32,
    cid: u32,
    flags: u8 = 0,
    zero: [3]u8 = .{ 0, 0, 0 },
};

pub const Connection = struct {
    fd: posix.fd_t,
    allocator: std.mem.Allocator,

    pub fn connect(allocator: std.mem.Allocator, cid: u32, port: u32) !Connection {
        const fd = try posix.socket(std.posix.AF.VSOCK, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        const addr = SockaddrVm{
            .cid = cid,
            .port = port,
        };

        try posix.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrVm));

        return .{
            .fd = fd,
            .allocator = allocator,
        };
    }

    pub fn close(self: *Connection) void {
        posix.close(self.fd);
    }

    pub fn send(self: *Connection, msg_type: protocol.MessageType, request_id: u32, payload: anytype) !void {
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

        var total_sent: usize = 0;
        while (total_sent < data.len) {
            const sent = try posix.send(self.fd, data[total_sent..], 0);
            if (sent == 0) return error.ConnectionClosed;
            total_sent += sent;
        }
    }

    pub fn receive(self: *Connection, comptime T: type) !protocol.Message(T) {
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

    fn readExact(self: *Connection, buf: []u8) !void {
        var total_read: usize = 0;
        while (total_read < buf.len) {
            const n = try posix.recv(self.fd, buf[total_read..], 0);
            if (n == 0) return error.ConnectionClosed;
            total_read += n;
        }
    }
};

pub const Listener = struct {
    fd: posix.fd_t,
    allocator: std.mem.Allocator,

    pub fn bind(allocator: std.mem.Allocator, port: u32) !Listener {
        const fd = try posix.socket(std.posix.AF.VSOCK, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        const addr = SockaddrVm{
            .cid = VMADDR_CID_ANY,
            .port = port,
        };

        try posix.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrVm));
        try posix.listen(fd, 128);

        return .{
            .fd = fd,
            .allocator = allocator,
        };
    }

    pub fn close(self: *Listener) void {
        posix.close(self.fd);
    }

    pub fn accept(self: *Listener) !Connection {
        var peer_addr: SockaddrVm = undefined;
        var addr_len: posix.socklen_t = @sizeOf(SockaddrVm);

        const client_fd = try posix.accept(self.fd, @ptrCast(&peer_addr), &addr_len, 0);

        return .{
            .fd = client_fd,
            .allocator = self.allocator,
        };
    }
};

pub fn getCid() !u32 {
    const fd = posix.open("/dev/vsock", .{ .ACCMODE = .RDONLY }, 0) catch |err| {
        if (err == error.FileNotFound) return error.VsockNotAvailable;
        return err;
    };
    defer posix.close(fd);

    const IOCTL_VM_SOCKETS_GET_LOCAL_CID = 0x7b9;
    var cid: u32 = undefined;

    const result = std.os.linux.ioctl(fd, IOCTL_VM_SOCKETS_GET_LOCAL_CID, @intFromPtr(&cid));
    if (result != 0) return error.IoctlFailed;

    return cid;
}

test "sockaddr_vm layout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(SockaddrVm));
}
