//! Buffered message transport for the seatd wire protocol: a stream unix socket
//! plus SCM_RIGHTS fd passing. `Connection` buffers outgoing bytes/fds until a
//! flush and buffers incoming bytes/fds until the consumer pulls them, so the
//! caller frames messages (header + body) without worrying about short reads.
//!
//! Raw Linux syscalls via std.os.linux, errno via std.posix.errno.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const Error = error{
    WouldBlock,
    Interrupted,
    ConnectionReset,
    BrokenPipe,
    TooManyFds,
    Unexpected,
};

/// Max fds carried in a single sendmsg/recvmsg. A device-open only ever carries
/// one, so this is generous headroom.
pub const max_fds = 16;

const MSG_CMSG_CLOEXEC: u32 = 0x40000000;
const MSG_CTRUNC: u32 = 0x0008;
const MSG_NOSIGNAL: u32 = 0x4000;

const cmsg_align_to = @sizeOf(usize);

fn cmsgAlign(n: usize) usize {
    return (n + cmsg_align_to - 1) & ~@as(usize, cmsg_align_to - 1);
}

const cmsg_hdr_space = cmsgAlign(@sizeOf(linux.cmsghdr));
const cmsg_buf_len = cmsg_hdr_space + cmsgAlign(max_fds * @sizeOf(i32));

fn check(rc: usize) Error!usize {
    return switch (posix.errno(rc)) {
        .SUCCESS => rc,
        .AGAIN => Error.WouldBlock,
        .INTR => Error.Interrupted,
        .CONNRESET => Error.ConnectionReset,
        .PIPE => Error.BrokenPipe,
        else => Error.Unexpected,
    };
}

const RecvResult = struct { bytes: usize, fds: usize };

/// Send `bytes` plus `fds` as SCM_RIGHTS ancillary data. Returns bytes accepted.
fn sendWithFds(fd: i32, bytes: []const u8, fds: []const i32) Error!usize {
    if (fds.len > max_fds) return Error.TooManyFds;
    var iov = [1]posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};

    var cmsg_buf: [cmsg_buf_len]u8 align(cmsg_align_to) = undefined;
    var controllen: usize = 0;
    var control_ptr: ?*const anyopaque = null;
    if (fds.len > 0) {
        const data_len = fds.len * @sizeOf(i32);
        controllen = cmsg_hdr_space + cmsgAlign(data_len);
        const hdr: *linux.cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
        hdr.* = .{
            .len = cmsg_hdr_space + data_len,
            .level = linux.SOL.SOCKET,
            .type = linux.SCM.RIGHTS,
        };
        @memcpy(cmsg_buf[cmsg_hdr_space .. cmsg_hdr_space + data_len], std.mem.sliceAsBytes(fds));
        control_ptr = &cmsg_buf;
    }

    var msg = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = control_ptr,
        .controllen = controllen,
        .flags = 0,
    };
    return check(linux.sendmsg(fd, &msg, MSG_NOSIGNAL));
}

/// Receive bytes into `buf` and any SCM_RIGHTS fds into `fd_out` (O_CLOEXEC set).
fn recvWithFds(fd: i32, buf: []u8, fd_out: []i32) Error!RecvResult {
    var iov = [1]posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var cmsg_buf: [cmsg_buf_len]u8 align(cmsg_align_to) = undefined;
    var msg = linux.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cmsg_buf,
        .controllen = cmsg_buf.len,
        .flags = 0,
    };
    const n = try check(linux.recvmsg(fd, &msg, MSG_CMSG_CLOEXEC));

    var nfds: usize = 0;
    if (msg.controllen >= cmsg_hdr_space) {
        const hdr: *const linux.cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
        if (hdr.level == linux.SOL.SOCKET and hdr.type == linux.SCM.RIGHTS) {
            const data_len = hdr.len - cmsg_hdr_space;
            const count = data_len / @sizeOf(i32);
            const fd_bytes = cmsg_buf[cmsg_hdr_space .. cmsg_hdr_space + count * @sizeOf(i32)];
            const take = @min(count, fd_out.len);
            @memcpy(std.mem.sliceAsBytes(fd_out[0..take]), fd_bytes[0 .. take * @sizeOf(i32)]);
            // Close any fds the kernel installed beyond our buffer, else leak.
            var k = take;
            while (k < count) : (k += 1) {
                var fdv: i32 = undefined;
                @memcpy(std.mem.asBytes(&fdv), fd_bytes[k * @sizeOf(i32) .. (k + 1) * @sizeOf(i32)]);
                _ = linux.close(fdv);
            }
            nfds = take;
        }
    }
    if (msg.flags & MSG_CTRUNC != 0) return Error.TooManyFds;
    return .{ .bytes = n, .fds = nfds };
}

/// Buffered, message-framed connection over a stream unix socket. Owns any fds
/// handed to `putFd` (closed after `flush`) and any fds pulled off the wire that
/// have not yet been claimed via `getFd` (closed on `deinit`).
pub const Connection = struct {
    gpa: Allocator,
    fd: i32,
    in: std.ArrayList(u8) = .empty,
    in_pos: usize = 0,
    out: std.ArrayList(u8) = .empty,
    fds_in: std.ArrayList(i32) = .empty,
    fds_in_pos: usize = 0,
    fds_out: std.ArrayList(i32) = .empty,

    pub fn init(gpa: Allocator, fd: i32) Connection {
        return .{ .gpa = gpa, .fd = fd };
    }

    pub fn deinit(self: *Connection) void {
        for (self.fds_in.items[self.fds_in_pos..]) |f| _ = linux.close(f);
        for (self.fds_out.items) |f| _ = linux.close(f);
        self.in.deinit(self.gpa);
        self.out.deinit(self.gpa);
        self.fds_in.deinit(self.gpa);
        self.fds_out.deinit(self.gpa);
        if (self.fd != -1) _ = linux.close(self.fd);
        self.fd = -1;
    }

    /// Bytes received but not yet consumed with `get`.
    pub fn pending(self: *const Connection) usize {
        return self.in.items.len - self.in_pos;
    }

    /// Queue bytes for the next flush.
    pub fn put(self: *Connection, data: []const u8) Allocator.Error!void {
        try self.out.appendSlice(self.gpa, data);
    }

    /// Queue a typed value (native memory layout) for the next flush.
    pub fn putValue(self: *Connection, value: anytype) Allocator.Error!void {
        try self.put(std.mem.asBytes(&value));
    }

    /// Queue an fd to travel with the next flush. Ownership transfers to the
    /// connection, which closes it once sent.
    pub fn putFd(self: *Connection, fd: i32) Allocator.Error!void {
        try self.fds_out.append(self.gpa, fd);
    }

    /// Send all queued bytes and fds. The fds ride along with the first chunk.
    pub fn flush(self: *Connection) Error!void {
        var sent: usize = 0;
        while (sent < self.out.items.len) {
            const chunk = self.out.items[sent..];
            const fds = if (sent == 0) self.fds_out.items else &[_]i32{};
            const n = sendWithFds(self.fd, chunk, fds) catch |err| switch (err) {
                Error.Interrupted => continue,
                else => return err,
            };
            sent += n;
        }
        for (self.fds_out.items) |f| _ = linux.close(f);
        self.fds_out.clearRetainingCapacity();
        self.out.clearRetainingCapacity();
    }

    /// Read one batch of bytes and fds from the socket into the buffers. Returns
    /// bytes read. A return of 0 means the peer closed the connection.
    pub fn read(self: *Connection) (Error || Allocator.Error)!usize {
        var buf: [512]u8 = undefined;
        var fds: [max_fds]i32 = undefined;
        const res = while (true) {
            break recvWithFds(self.fd, buf[0..], fds[0..]) catch |err| switch (err) {
                Error.Interrupted => continue,
                else => return err,
            };
        };
        try self.in.appendSlice(self.gpa, buf[0..res.bytes]);
        try self.fds_in.appendSlice(self.gpa, fds[0..res.fds]);
        self.compact();
        return res.bytes;
    }

    /// Copy the next `dst.len` buffered bytes out, consuming them. WouldBlock if
    /// fewer bytes are buffered.
    pub fn get(self: *Connection, dst: []u8) Error!void {
        if (self.pending() < dst.len) return Error.WouldBlock;
        @memcpy(dst, self.in.items[self.in_pos .. self.in_pos + dst.len]);
        self.in_pos += dst.len;
        self.compact();
    }

    /// Read a typed value (native memory layout) off the buffer.
    pub fn getValue(self: *Connection, comptime T: type) Error!T {
        var value: T = undefined;
        try self.get(std.mem.asBytes(&value));
        return value;
    }

    /// Copy the next `dst.len` buffered bytes without consuming them.
    pub fn peek(self: *Connection, dst: []u8) Error!void {
        if (self.pending() < dst.len) return Error.WouldBlock;
        @memcpy(dst, self.in.items[self.in_pos .. self.in_pos + dst.len]);
    }

    /// Peek a typed value (native memory layout) without consuming it.
    pub fn peekValue(self: *Connection, comptime T: type) Error!T {
        var value: T = undefined;
        try self.peek(std.mem.asBytes(&value));
        return value;
    }

    /// Discard `n` buffered bytes.
    pub fn skip(self: *Connection, n: usize) void {
        std.debug.assert(self.pending() >= n);
        self.in_pos += n;
        self.compact();
    }

    /// Claim the next received fd. WouldBlock if none is buffered. Ownership
    /// transfers to the caller.
    pub fn getFd(self: *Connection) Error!i32 {
        if (self.fds_in_pos >= self.fds_in.items.len) return Error.WouldBlock;
        const fd = self.fds_in.items[self.fds_in_pos];
        self.fds_in_pos += 1;
        if (self.fds_in_pos == self.fds_in.items.len) {
            self.fds_in.clearRetainingCapacity();
            self.fds_in_pos = 0;
        }
        return fd;
    }

    // Drop the consumed prefix once it dominates the buffer, keeping memory bounded.
    fn compact(self: *Connection) void {
        if (self.in_pos == 0) return;
        if (self.in_pos == self.in.items.len) {
            self.in.clearRetainingCapacity();
            self.in_pos = 0;
            return;
        }
        if (self.in_pos >= 256) {
            const remaining = self.in.items.len - self.in_pos;
            std.mem.copyForwards(u8, self.in.items[0..remaining], self.in.items[self.in_pos..]);
            self.in.shrinkRetainingCapacity(remaining);
            self.in_pos = 0;
        }
    }
};

const testing = std.testing;

test "connection round-trips a framed message" {
    var fds: [2]i32 = undefined;
    _ = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds);
    var a = Connection.init(testing.allocator, fds[0]);
    var b = Connection.init(testing.allocator, fds[1]);
    defer a.deinit();
    defer b.deinit();

    try a.put("hello");
    try a.flush();

    const n = try b.read();
    try testing.expectEqual(@as(usize, 5), n);
    var buf: [5]u8 = undefined;
    try b.get(buf[0..]);
    try testing.expectEqualStrings("hello", buf[0..]);
}

test "connection passes an fd with a message" {
    var fds: [2]i32 = undefined;
    _ = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds);
    var a = Connection.init(testing.allocator, fds[0]);
    var b = Connection.init(testing.allocator, fds[1]);
    defer a.deinit();
    defer b.deinit();

    // Pass one end of an auxiliary pipe and prove the received fd is live by
    // writing through the sender end and reading it back from the received fd.
    var aux: [2]i32 = undefined;
    _ = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &aux);
    defer _ = linux.close(aux[1]);

    try a.put("f");
    try a.putFd(aux[0]); // connection takes ownership, closes on flush
    try a.flush();

    _ = try b.read();
    var buf: [1]u8 = undefined;
    try b.get(buf[0..]);
    try testing.expectEqualStrings("f", buf[0..]);

    const got = try b.getFd();
    defer _ = linux.close(got);
    const wr = linux.write(aux[1], "z", 1);
    try testing.expectEqual(@as(usize, 1), wr);
    var rb: [1]u8 = undefined;
    const rn = linux.read(got, &rb, 1);
    try testing.expectEqual(@as(usize, 1), rn);
    try testing.expectEqualStrings("z", rb[0..]);
}

test "get past the buffered data reports WouldBlock" {
    var fds: [2]i32 = undefined;
    _ = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds);
    var a = Connection.init(testing.allocator, fds[0]);
    defer a.deinit();
    defer _ = linux.close(fds[1]);

    var buf: [4]u8 = undefined;
    try testing.expectError(error.WouldBlock, a.get(buf[0..]));
    try testing.expectError(error.WouldBlock, a.getFd());
}
