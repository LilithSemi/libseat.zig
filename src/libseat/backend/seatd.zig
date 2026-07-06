//! Client backend speaking the seatd wire protocol to a seat manager (our
//! daemon, an upstream seatd, or an embedded server for the builtin backend).
//!
//! Requests are synchronous: send, then read until the matching reply, handling
//! any interleaved background events (enable/disable/pong) as they arrive. The
//! caller drives asynchronous events with `dispatch`.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const protocol = @import("../protocol.zig");
const transport = @import("../transport.zig");
const types = @import("../types.zig");
const seat_mod = @import("../seat.zig");

const Connection = transport.Connection;
const Header = protocol.Header;
const Opcode = protocol.Opcode;
const Error = types.Error;
const Device = types.Device;

pub const Backend = struct {
    gpa: Allocator,
    owner: *seat_mod.Seat,
    conn: Connection,
    pending: std.ArrayList(Opcode) = .empty,
    awaiting_pong: bool = false,
    failed: bool = false,
    seat_name_buf: [protocol.max_seat_len + 1]u8 = undefined,
    seat_name_len: usize = 0,

    /// Wrap an already-connected socket fd. Ownership of `fd` transfers here.
    pub fn create(gpa: Allocator, owner: *seat_mod.Seat, fd: i32) Error!*Backend {
        const self = gpa.create(Backend) catch return Error.OutOfMemory;
        self.* = .{ .gpa = gpa, .owner = owner, .conn = Connection.init(gpa, fd) };
        return self;
    }

    /// Free all resources without a protocol close. Used on setup failure.
    pub fn destroy(self: *Backend) void {
        self.conn.deinit();
        self.pending.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn fail(self: *Backend) Error {
        self.failed = true;
        return Error.Disconnected;
    }

    fn pollConn(self: *Backend, timeout_ms: i32) Error!void {
        var fds = [_]posix.pollfd{.{ .fd = self.conn.fd, .events = posix.POLL.IN, .revents = 0 }};
        const n = posix.poll(&fds, timeout_ms) catch return Error.Unexpected;
        if (n == 0) return;
        if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) return self.fail();
        if (fds[0].revents & posix.POLL.IN != 0) {
            const got = self.conn.read() catch |err| switch (err) {
                error.WouldBlock => return,
                else => return self.fail(),
            };
            if (got == 0) return self.fail();
        }
    }

    /// Drain leading background events (enable/disable/pong) already buffered.
    /// Returns how many were processed. In `strict` mode a non-background
    /// message is a protocol error. Otherwise it is left buffered for a reply
    /// parser and draining stops.
    fn queueBackground(self: *Backend, strict: bool) Error!usize {
        var n: usize = 0;
        while (true) {
            const header = self.conn.peekValue(Header) catch return n;
            switch (@as(Opcode, @enumFromInt(header.opcode))) {
                .server_pong => {
                    self.conn.skip(@sizeOf(Header));
                    self.awaiting_pong = false;
                    n += 1;
                },
                .server_enable_seat, .server_disable_seat => {
                    self.conn.skip(@sizeOf(Header));
                    self.pending.append(self.gpa, @enumFromInt(header.opcode)) catch return Error.OutOfMemory;
                    n += 1;
                },
                else => {
                    if (strict) return Error.ProtocolError;
                    return n;
                },
            }
        }
    }

    /// Flush queued requests, then block until a full non-background reply is
    /// buffered (its header left in place for `readReply`).
    fn awaitReply(self: *Backend) Error!void {
        self.conn.flush() catch return self.fail();
        while (true) {
            _ = try self.queueBackground(false);
            if (self.conn.peekValue(Header)) |header| {
                if (self.conn.pending() >= @sizeOf(Header) + header.size) return;
            } else |_| {}
            try self.pollConn(-1);
        }
    }

    /// Consume a reply header, validating its opcode and size. A SERVER_ERROR is
    /// decoded into `owner.last_errno` and surfaced as `Error.Denied`.
    fn readReply(self: *Backend, expected: Opcode, expected_size: u16, variable: bool) Error!u16 {
        const header = self.conn.getValue(Header) catch return self.fail();
        if (header.opcode != @intFromEnum(expected)) {
            if (@as(Opcode, @enumFromInt(header.opcode)) == .server_error and
                header.size == @sizeOf(protocol.ServerError))
            {
                const emsg = self.conn.getValue(protocol.ServerError) catch return self.fail();
                self.owner.last_errno = emsg.error_code;
                return Error.Denied;
            }
            return Error.ProtocolError;
        }
        if ((!variable and header.size != expected_size) or (variable and header.size < expected_size)) {
            return Error.ProtocolError;
        }
        return header.size;
    }

    /// Deliver queued enable/disable events to the listener. Returns the count.
    fn executeEvents(self: *Backend) usize {
        var n: usize = 0;
        // Take a snapshot: a listener callback may itself issue requests that
        // queue more events, which we intentionally leave for the next round.
        const events = self.pending.toOwnedSlice(self.gpa) catch return 0;
        defer self.gpa.free(events);
        for (events) |op| {
            switch (op) {
                .server_enable_seat => self.owner.emitEnable(),
                .server_disable_seat => self.owner.emitDisable(),
                else => {},
            }
            n += 1;
        }
        return n;
    }

    /// After a synchronous reply, peek for pending events and, if any need a
    /// dispatch to fire, ping so the caller's poll wakes.
    fn checkPendingEvents(self: *Backend) void {
        _ = self.queueBackground(false) catch return;
        if (self.pending.items.len == 0 or self.awaiting_pong) return;
        self.sendPing() catch return;
        self.awaiting_pong = true;
    }

    fn sendPing(self: *Backend) Error!void {
        self.conn.putValue(Header{ .opcode = @intFromEnum(Opcode.client_ping), .size = 0 }) catch return Error.OutOfMemory;
        self.conn.flush() catch return self.fail();
    }

    pub fn handshake(self: *Backend) Error!void {
        self.conn.putValue(Header{ .opcode = @intFromEnum(Opcode.client_open_seat), .size = 0 }) catch return Error.OutOfMemory;
        try self.awaitReply();

        const size = try self.readReply(.server_seat_opened, @sizeOf(protocol.ServerSeatOpened), true);
        const rmsg = self.conn.getValue(protocol.ServerSeatOpened) catch return self.fail();
        const name_len = rmsg.seat_name_len;
        if (name_len != size - @sizeOf(protocol.ServerSeatOpened)) return Error.ProtocolError;
        if (name_len > protocol.max_seat_len) return Error.ProtocolError;
        self.conn.get(self.seat_name_buf[0..name_len]) catch return self.fail();
        // Trim the trailing NUL the protocol includes in the name length.
        self.seat_name_len = if (name_len > 0 and self.seat_name_buf[name_len - 1] == 0) name_len - 1 else name_len;

        _ = self.executeEvents();
    }

    pub fn close(self: *Backend) void {
        if (!self.failed) {
            self.conn.putValue(Header{ .opcode = @intFromEnum(Opcode.client_close_seat), .size = 0 }) catch {};
            if (self.awaitReply()) |_| {
                _ = self.readReply(.server_seat_closed, 0, false) catch {};
            } else |_| {}
            _ = self.executeEvents();
        }
        self.destroy();
    }

    pub fn seatName(self: *Backend) []const u8 {
        return self.seat_name_buf[0..self.seat_name_len];
    }

    pub fn pollFd(self: *Backend) i32 {
        return self.conn.fd;
    }

    pub fn openDevice(self: *Backend, path: []const u8) Error!Device {
        if (self.failed) return Error.Disconnected;
        const path_len = path.len + 1; // includes trailing NUL
        if (path_len > protocol.max_path_len) return Error.InvalidArgument;

        const msg = protocol.ClientOpenDevice{ .path_len = @intCast(path_len) };
        self.conn.putValue(Header{
            .opcode = @intFromEnum(Opcode.client_open_device),
            .size = @intCast(@sizeOf(protocol.ClientOpenDevice) + path_len),
        }) catch return Error.OutOfMemory;
        self.conn.putValue(msg) catch return Error.OutOfMemory;
        self.conn.put(path) catch return Error.OutOfMemory;
        self.conn.put(&[_]u8{0}) catch return Error.OutOfMemory;
        try self.awaitReply();

        _ = try self.readReply(.server_device_opened, @sizeOf(protocol.ServerDeviceOpened), false);
        const rmsg = self.conn.getValue(protocol.ServerDeviceOpened) catch return self.fail();
        const fd = self.conn.getFd() catch return self.fail();
        self.checkPendingEvents();
        return .{ .id = rmsg.device_id, .fd = fd };
    }

    pub fn closeDevice(self: *Backend, device_id: i32) Error!void {
        if (self.failed) return Error.Disconnected;
        if (device_id < 0) return Error.InvalidArgument;

        self.conn.putValue(Header{
            .opcode = @intFromEnum(Opcode.client_close_device),
            .size = @sizeOf(protocol.ClientCloseDevice),
        }) catch return Error.OutOfMemory;
        self.conn.putValue(protocol.ClientCloseDevice{ .device_id = device_id }) catch return Error.OutOfMemory;
        try self.awaitReply();

        _ = try self.readReply(.server_device_closed, 0, false);
        self.checkPendingEvents();
    }

    pub fn switchSession(self: *Backend, session: i32) Error!void {
        if (self.failed) return Error.Disconnected;
        if (session < 0) return Error.InvalidArgument;

        self.conn.putValue(Header{
            .opcode = @intFromEnum(Opcode.client_switch_session),
            .size = @sizeOf(protocol.ClientSwitchSession),
        }) catch return Error.OutOfMemory;
        self.conn.putValue(protocol.ClientSwitchSession{ .session = session }) catch return Error.OutOfMemory;
        try self.awaitReply();

        _ = try self.readReply(.server_session_switched, 0, false);
        self.checkPendingEvents();
    }

    pub fn disable(self: *Backend) Error!void {
        if (self.failed) return Error.Disconnected;
        self.conn.putValue(Header{ .opcode = @intFromEnum(Opcode.client_disable_seat), .size = 0 }) catch return Error.OutOfMemory;
        try self.awaitReply();

        _ = try self.readReply(.server_seat_disabled, 0, false);
        self.checkPendingEvents();
    }

    pub fn dispatch(self: *Backend, timeout_ms: i32) Error!usize {
        if (self.failed) return Error.Disconnected;

        var count = try self.queueBackground(true);
        count += self.executeEvents();

        // Don't block if we already produced events. The caller may be waiting.
        if (count > 0 or timeout_ms == 0) {
            _ = self.conn.read() catch |err| switch (err) {
                error.WouldBlock => {},
                else => return self.fail(),
            };
        } else {
            try self.pollConn(timeout_ms);
        }

        count += try self.queueBackground(true);
        count += self.executeEvents();
        return count;
    }
};

/// Connect a stream unix socket to `path` (SEATD_SOCK / SEATD_DEFAULTPATH).
pub fn connect(path: []const u8) Error!i32 {
    const s = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (posix.errno(s) != .SUCCESS) return Error.ConnectionFailed;
    const fd: i32 = @intCast(s);
    errdefer _ = linux.close(fd);

    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    if (path.len + 1 > addr.path.len) return Error.InvalidArgument;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    const namelen = @offsetOf(linux.sockaddr.un, "path") + path.len + 1;
    if (posix.errno(linux.connect(fd, @ptrCast(&addr), @intCast(namelen))) != .SUCCESS) {
        return Error.ConnectionFailed;
    }
    return fd;
}
