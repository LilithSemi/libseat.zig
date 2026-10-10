//! The seat manager daemon: accepts client connections speaking the seatd wire
//! protocol, tracks seats and their clients, and hands out device fds.
//!
//! Seats may be VT-bound: one session per VT, switched by the kernel's VT
//! machinery, with DRM/evdev access granted on activation and revoked on
//! release. VT operations go through an injectable `Vt` interface so the state
//! machine is testable without a real console. One seat ("seat0") is served.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
const vtmod = @import("daemon/vt.zig");
const drm = @import("../linux/drm.zig");
const evdev = @import("../linux/evdev.zig");

const Connection = transport.Connection;
const Header = protocol.Header;
const Opcode = protocol.Opcode;

const OpenError = error{ Disconnected, Protocol, OutOfMemory };

/// Re-exports so the standalone daemon tool can build a real VT controller.
pub const Vt = vtmod.Vt;
pub const LinuxVt = vtmod.LinuxVt;

pub const ClientState = enum { new, active, pending_disable, disabled, closed };

pub const DeviceKind = enum { drm, evdev, other };

pub const DeviceEntry = struct {
    id: i32,
    fd: i32,
    path: []u8,
    ref_cnt: u32,
    active: bool,
    kind: DeviceKind,
};

pub const Client = struct {
    server: *Server,
    conn: Connection,
    seat: ?*Seat = null,
    state: ClientState = .new,
    session: i32 = -1,
    devices: std.ArrayList(*DeviceEntry) = .empty,
    dead: bool = false,

    fn findDevice(self: *Client, id: i32) ?*DeviceEntry {
        if (id == 0) return null;
        for (self.devices.items) |d| {
            if (d.id == id) return d;
        }
        return null;
    }
};

/// A seat and its clients. A VT-bound seat ties each session to a VT and defers
/// switching to the kernel. A non-VT-bound seat switches sessions virtually.
pub const Seat = struct {
    gpa: Allocator,
    name: []const u8,
    vt_bound: bool,
    vt: vtmod.Vt,
    clients: std.ArrayList(*Client) = .empty,
    active_client: ?*Client = null,
    next_client: ?*Client = null,
    cur_vt: i32 = 0,

    fn deinit(self: *Seat) void {
        self.clients.deinit(self.gpa);
    }

    fn updateVt(self: *Seat) void {
        if (self.vt_bound) self.cur_vt = self.vt.currentVt();
    }

    fn assignSession(self: *Seat) i32 {
        // Lowest positive session id not already taken by a member.
        var candidate: i32 = 1;
        var bumped = true;
        while (bumped) {
            bumped = false;
            for (self.clients.items) |c| {
                if (c.session == candidate) {
                    candidate += 1;
                    bumped = true;
                    break;
                }
            }
        }
        return candidate;
    }

    fn addClient(self: *Seat, client: *Client) OpenError!void {
        if (client.seat != null) return error.Protocol;
        if (self.vt_bound) {
            // A VT-bound seat allows at most one client per VT, bound to the
            // VT that is current when the client connects.
            if (self.active_client != null and self.active_client.?.state != .pending_disable) {
                return error.Protocol;
            }
            self.updateVt();
            if (self.cur_vt < 0) return error.Protocol;
            client.session = self.cur_vt;
        } else {
            client.session = self.assignSession();
        }
        try self.clients.append(self.gpa, client);
        client.seat = self;
    }

    fn removeClient(self: *Seat, client: *Client) void {
        if (self.next_client == client) self.next_client = null;
        for (client.devices.items) |d| closeDevice(client, d);
        client.devices.clearRetainingCapacity();

        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.orderedRemove(i);
                break;
            }
        }

        const was_active = self.active_client == client;
        if (was_active) {
            self.active_client = null;
            self.activate();
        }

        if (self.vt_bound) {
            if (was_active and self.active_client == null) {
                self.vt.closeVt(self.cur_vt);
            } else if (!was_active and client.state != .closed) {
                self.vt.closeVt(client.session);
            }
        }

        client.state = .closed;
        client.seat = null;
    }

    // Pick and enable a client when none is active.
    fn activate(self: *Seat) void {
        if (self.active_client != null) return;
        var target: ?*Client = null;
        if (self.next_client) |n| {
            target = n;
            self.next_client = null;
        } else if (self.clients.items.len == 0) {
            return;
        } else if (self.vt_bound) {
            if (self.cur_vt < 0) return;
            for (self.clients.items) |c| {
                if (c.session == self.cur_vt) {
                    target = c;
                    break;
                }
            }
            if (target == null) return; // no client for this VT
        } else {
            target = self.clients.items[0];
        }
        if (target) |t| self.openClient(t);
    }

    fn openClient(self: *Seat, client: *Client) void {
        if (client.state != .new and client.state != .disabled) return;
        if (self.active_client != null) return;
        if (self.vt_bound) self.vt.openVt(client.session);
        for (client.devices.items) |d| activateDevice(d);
        sendHeader(client, .server_enable_seat, 0) catch return;
        client.conn.flush() catch {};
        client.state = .active;
        self.active_client = client;
    }

    /// Kernel VT acquire signal (SIGUSR2): ack and open a client for the new VT.
    pub fn vtActivate(self: *Seat) void {
        if (!self.vt_bound) return;
        self.updateVt();
        self.vt.ackAcquire(self.cur_vt);
        if (self.active_client == null) self.activate();
    }

    /// Kernel VT release signal (SIGUSR1): disable the current client, then ack
    /// so the kernel proceeds with the switch.
    pub fn vtRelease(self: *Seat) void {
        if (!self.vt_bound) return;
        self.updateVt();
        if (self.active_client) |c| disableClient(c);
        self.vt.ackRelease(self.cur_vt);
        self.cur_vt = -1;
    }
};

fn disableClient(client: *Client) void {
    if (client.state != .active) return;
    for (client.devices.items) |d| deactivateDevice(d);
    client.state = .pending_disable;
    sendHeader(client, .server_disable_seat, 0) catch return;
    client.conn.flush() catch {};
}

pub const Options = struct {
    vt_bound: bool = false,
    seat_name: []const u8 = "seat0",
    /// VT control implementation. Production passes a `LinuxVt` and tests pass a
    /// fake. When null, a non-VT-bound seat uses a noop.
    vt: ?vtmod.Vt = null,
};

pub const Server = struct {
    gpa: Allocator,
    opts: Options,
    seat: Seat,
    clients: std.ArrayList(*Client) = .empty,
    running: bool = true,
    stop_pipe: [2]i32,
    signal_fd: i32 = -1,
    listen_fd: i32 = -1,
    listen_path: ?[]u8 = null,

    pub fn init(gpa: Allocator, opts: Options) !Server {
        var pipe: [2]i32 = undefined;
        const rc = linux.pipe2(&pipe, .{ .CLOEXEC = true, .NONBLOCK = true });
        if (posix.errno(rc) != .SUCCESS) return error.PipeFailed;
        return .{
            .gpa = gpa,
            .opts = opts,
            .seat = .{
                .gpa = gpa,
                .name = opts.seat_name,
                .vt_bound = opts.vt_bound,
                .vt = opts.vt orelse vtmod.noop,
            },
            .stop_pipe = pipe,
        };
    }

    pub fn deinit(self: *Server) void {
        for (self.clients.items) |c| destroyClient(c);
        self.clients.deinit(self.gpa);
        self.seat.deinit();
        _ = linux.close(self.stop_pipe[0]);
        _ = linux.close(self.stop_pipe[1]);
        if (self.signal_fd != -1) _ = linux.close(self.signal_fd);
        if (self.listen_fd != -1) _ = linux.close(self.listen_fd);
        if (self.listen_path) |p| {
            var buf: [108]u8 = undefined;
            if (p.len < buf.len) {
                @memcpy(buf[0..p.len], p);
                buf[p.len] = 0;
                _ = linux.unlink(@ptrCast(&buf));
            }
            self.gpa.free(p);
        }
    }

    /// Bind and listen on a unix socket so external clients can connect. Used by
    /// the standalone daemon (the embedded builtin server uses `addClient`).
    pub fn listenUnix(self: *Server, path: []const u8) !void {
        const s = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (posix.errno(s) != .SUCCESS) return error.SocketFailed;
        const fd: i32 = @intCast(s);
        errdefer _ = linux.close(fd);

        var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
        if (path.len + 1 > addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;
        const namelen = @offsetOf(linux.sockaddr.un, "path") + path.len + 1;
        if (posix.errno(linux.bind(fd, @ptrCast(&addr), @intCast(namelen))) != .SUCCESS) return error.BindFailed;
        if (posix.errno(linux.listen(fd, 16)) != .SUCCESS) return error.ListenFailed;

        self.listen_fd = fd;
        self.listen_path = try self.gpa.dupe(u8, path);
    }

    fn acceptClients(self: *Server) void {
        while (true) {
            const c = linux.accept4(self.listen_fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            if (posix.errno(c) != .SUCCESS) return;
            _ = self.addClient(@intCast(c)) catch {
                _ = linux.close(@intCast(c));
                return;
            };
        }
    }

    /// Register a connected client socket. Ownership of `fd` transfers here.
    pub fn addClient(self: *Server, fd: i32) !*Client {
        const client = try self.gpa.create(Client);
        client.* = .{ .server = self, .conn = Connection.init(self.gpa, fd) };
        try self.clients.append(self.gpa, client);
        return client;
    }

    pub fn stop(self: *Server) void {
        _ = linux.write(self.stop_pipe[1], "x", 1);
    }

    /// Poll and serve clients until `stop` is called or all clients leave when
    /// running as an embedded (builtin) server. A VT-bound seat also listens for
    /// the kernel's VT release/acquire signals via signalfd.
    pub fn run(self: *Server) void {
        if ((self.seat.vt_bound or self.listen_fd != -1) and self.signal_fd == -1) self.setupSignals();

        var pollfds: std.ArrayList(posix.pollfd) = .empty;
        defer pollfds.deinit(self.gpa);

        while (self.running) {
            pollfds.clearRetainingCapacity();
            pollfds.append(self.gpa, .{ .fd = self.stop_pipe[0], .events = posix.POLL.IN, .revents = 0 }) catch return;
            if (self.signal_fd != -1) {
                pollfds.append(self.gpa, .{ .fd = self.signal_fd, .events = posix.POLL.IN, .revents = 0 }) catch return;
            }
            if (self.listen_fd != -1) {
                pollfds.append(self.gpa, .{ .fd = self.listen_fd, .events = posix.POLL.IN, .revents = 0 }) catch return;
            }
            for (self.clients.items) |c| {
                pollfds.append(self.gpa, .{ .fd = c.conn.fd, .events = posix.POLL.IN, .revents = 0 }) catch return;
            }

            _ = posix.poll(pollfds.items, -1) catch return;

            for (pollfds.items) |pfd| {
                if (pfd.revents == 0) continue;
                if (pfd.fd == self.stop_pipe[0]) return; // stop requested
                if (pfd.fd == self.signal_fd) {
                    self.handleSignals();
                    continue;
                }
                if (self.listen_fd != -1 and pfd.fd == self.listen_fd) {
                    self.acceptClients();
                    continue;
                }
                const client = self.findClient(pfd.fd) orelse continue;
                if (pfd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
                    self.dispatchClient(client) catch {
                        client.dead = true;
                    };
                }
            }
            self.sweepDead();
        }
    }

    fn setupSignals(self: *Server) void {
        var mask = linux.sigemptyset();
        if (self.seat.vt_bound) {
            linux.sigaddset(&mask, .USR1);
            linux.sigaddset(&mask, .USR2);
        }
        // Only a standalone daemon owns process lifetime. The embedded builtin
        // server must not steal TERM/INT from its host compositor.
        if (self.listen_fd != -1) {
            linux.sigaddset(&mask, .TERM);
            linux.sigaddset(&mask, .INT);
        }
        _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
        const rc = linux.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
        if (posix.errno(rc) == .SUCCESS) self.signal_fd = @intCast(rc);
    }

    fn handleSignals(self: *Server) void {
        var si: linux.signalfd_siginfo = undefined;
        while (true) {
            const n = linux.read(self.signal_fd, std.mem.asBytes(&si), @sizeOf(@TypeOf(si)));
            if (posix.errno(n) != .SUCCESS or n != @sizeOf(@TypeOf(si))) return;
            if (si.signo == @backingInt(linux.SIG.USR1)) {
                self.seat.vtRelease();
            } else if (si.signo == @backingInt(linux.SIG.USR2)) {
                self.seat.vtActivate();
            } else if (si.signo == @backingInt(linux.SIG.TERM) or si.signo == @backingInt(linux.SIG.INT)) {
                self.running = false;
            }
        }
    }

    fn findClient(self: *Server, fd: i32) ?*Client {
        for (self.clients.items) |c| {
            if (c.conn.fd == fd and !c.dead) return c;
        }
        return null;
    }

    fn sweepDead(self: *Server) void {
        var i: usize = 0;
        while (i < self.clients.items.len) {
            const c = self.clients.items[i];
            if (c.dead) {
                _ = self.clients.orderedRemove(i);
                if (c.seat) |s| s.removeClient(c);
                destroyClient(c);
                // The embedded (builtin) server has no listen socket: once its one
                // client leaves there is nothing more to serve, so it exits. A
                // standalone daemon keeps listening for new clients.
                if (self.listen_fd == -1 and self.clients.items.len == 0) self.running = false;
            } else {
                i += 1;
            }
        }
    }

    fn dispatchClient(self: *Server, client: *Client) OpenError!void {
        const n = client.conn.read() catch |err| switch (err) {
            error.WouldBlock => return,
            else => return error.Disconnected,
        };
        if (n == 0) return error.Disconnected;

        while (true) {
            const header = client.conn.peekValue(Header) catch break;
            if (client.conn.pending() < @sizeOf(Header) + header.size) break;
            client.conn.skip(@sizeOf(Header));
            try self.handleOpcode(client, header.opcode, header.size);
        }
        client.conn.flush() catch {};
    }

    fn handleOpcode(self: *Server, client: *Client, opcode: u16, size: u16) OpenError!void {
        switch (@as(Opcode, @fromBackingInt(@intCast(opcode)))) {
            .client_open_seat => {
                if (size != 0) return error.Protocol;
                try self.handleOpenSeat(client);
            },
            .client_close_seat => {
                if (size != 0) return error.Protocol;
                try handleCloseSeat(client);
            },
            .client_open_device => {
                if (@sizeOf(protocol.ClientOpenDevice) > size) return error.Protocol;
                const msg = client.conn.getValue(protocol.ClientOpenDevice) catch return error.Protocol;
                if (msg.path_len != size - @sizeOf(protocol.ClientOpenDevice)) return error.Protocol;
                if (msg.path_len > protocol.max_path_len) return error.Protocol;
                var pathbuf: [protocol.max_path_len]u8 = undefined;
                client.conn.get(pathbuf[0..msg.path_len]) catch return error.Protocol;
                if (msg.path_len == 0 or pathbuf[msg.path_len - 1] != 0) return error.Protocol;
                try handleOpenDevice(client, pathbuf[0 .. msg.path_len - 1]);
            },
            .client_close_device => {
                if (size != @sizeOf(protocol.ClientCloseDevice)) return error.Protocol;
                const msg = client.conn.getValue(protocol.ClientCloseDevice) catch return error.Protocol;
                try handleCloseDevice(client, msg.device_id);
            },
            .client_switch_session => {
                if (size != @sizeOf(protocol.ClientSwitchSession)) return error.Protocol;
                const msg = client.conn.getValue(protocol.ClientSwitchSession) catch return error.Protocol;
                try handleSwitchSession(client, msg.session);
            },
            .client_disable_seat => {
                if (size != 0) return error.Protocol;
                try handleDisableSeat(client);
            },
            .client_ping => {
                if (size != 0) return error.Protocol;
                try sendHeader(client, .server_pong, 0);
            },
            else => return error.Protocol,
        }
    }

    fn handleOpenSeat(self: *Server, client: *Client) OpenError!void {
        const seat = &self.seat;
        try seat.addClient(client);

        const name = seat.name;
        const name_len: u16 = @intCast(name.len + 1);
        try sendHeader(client, .server_seat_opened, @sizeOf(protocol.ServerSeatOpened) + name_len);
        client.conn.putValue(protocol.ServerSeatOpened{ .seat_name_len = name_len }) catch return error.OutOfMemory;
        client.conn.put(name) catch return error.OutOfMemory;
        client.conn.put(&[_]u8{0}) catch return error.OutOfMemory;

        seat.openClient(client);
    }
};

fn handleCloseSeat(client: *Client) OpenError!void {
    const seat = client.seat orelse return error.Protocol;
    seat.removeClient(client);
    try sendHeader(client, .server_seat_closed, 0);
}

fn handleOpenDevice(client: *Client, path: []const u8) OpenError!void {
    if (client.seat == null) return error.Protocol;
    if (client.state != .active) return sendError(client, @backingInt(linux.E.PERM));

    const device = openDevice(client, path) catch |err| {
        return sendError(client, errnoFor(err));
    };

    const dup_rc = linux.dup(device.fd);
    if (posix.errno(dup_rc) != .SUCCESS) {
        return sendError(client, @backingInt(linux.E.BADF));
    }
    const dupfd: i32 = @intCast(dup_rc);
    client.conn.putFd(dupfd) catch return error.OutOfMemory;
    try sendHeader(client, .server_device_opened, @sizeOf(protocol.ServerDeviceOpened));
    client.conn.putValue(protocol.ServerDeviceOpened{ .device_id = device.id }) catch return error.OutOfMemory;
}

fn handleCloseDevice(client: *Client, device_id: i32) OpenError!void {
    if (client.seat == null) return error.Protocol;
    const device = client.findDevice(device_id) orelse return sendError(client, @backingInt(linux.E.BADF));
    closeDevice(client, device);
    try sendHeader(client, .server_device_closed, 0);
}

fn handleSwitchSession(client: *Client, session: i32) OpenError!void {
    const seat = client.seat orelse return error.Protocol;
    seatSetNextSession(seat, client, session) catch |err| {
        return sendError(client, errnoFor(err));
    };
    try sendHeader(client, .server_session_switched, 0);
}

fn handleDisableSeat(client: *Client) OpenError!void {
    const seat = client.seat orelse return error.Protocol;
    seatAckDisable(seat, client) catch |err| {
        return sendError(client, errnoFor(err));
    };
    try sendHeader(client, .server_seat_disabled, 0);
}

const SwitchError = error{ Perm, Invalid };

fn seatSetNextSession(seat: *Seat, client: *Client, session: i32) SwitchError!void {
    if (client.state != .active) return error.Perm;
    if (session <= 0) return error.Invalid;
    if (session == client.session) return; // already active, no-op
    if (seat.next_client != null) return; // switch already queued

    if (seat.vt_bound) {
        // Hand off to the kernel. The release/acquire ack cycle does the rest.
        seat.vt.switchVt(seat.cur_vt, session);
        return;
    }

    // Non-VT-bound: find the target client by session id and switch virtually.
    var target: ?*Client = null;
    for (seat.clients.items) |c| {
        if (c.session == session) {
            target = c;
            break;
        }
    }
    const t = target orelse return error.Invalid;
    seat.next_client = t;
    disableClient(seat.active_client.?);
}

fn seatAckDisable(seat: *Seat, client: *Client) SwitchError!void {
    if (client.state != .pending_disable) return error.Perm;
    client.state = .disabled;
    if (seat.active_client != client) return;
    seat.active_client = null;
    seat.activate();
}

fn openDevice(client: *Client, path: []const u8) !*DeviceEntry {
    // Reuse an already-open device by path, bumping its refcount.
    var next_id: i32 = 1;
    for (client.devices.items) |d| {
        if (std.mem.eql(u8, d.path, path)) {
            d.ref_cnt += 1;
            return d;
        }
        if (d.id >= next_id) next_id = d.id + 1;
    }
    if (client.devices.items.len >= protocol.max_seat_devices) return error.TooMany;

    const fd = try openDeviceFd(path);
    errdefer _ = linux.close(fd);

    const kind: DeviceKind = if (drm.pathIsDrm(path))
        .drm
    else if (evdev.pathIsEvdev(path))
        .evdev
    else
        .other;

    // A DRM device is only useful to the client if it becomes master.
    if (kind == .drm) _ = drm.setMaster(fd);

    const path_copy = try client.server.gpa.dupe(u8, path);
    errdefer client.server.gpa.free(path_copy);
    const device = try client.server.gpa.create(DeviceEntry);
    device.* = .{ .id = next_id, .fd = fd, .path = path_copy, .ref_cnt = 1, .active = true, .kind = kind };
    try client.devices.append(client.server.gpa, device);
    return device;
}

fn closeDevice(client: *Client, device: *DeviceEntry) void {
    device.ref_cnt -= 1;
    if (device.ref_cnt > 0) return;
    for (client.devices.items, 0..) |d, i| {
        if (d == device) {
            _ = client.devices.orderedRemove(i);
            break;
        }
    }
    if (device.fd != -1) _ = linux.close(device.fd);
    client.server.gpa.free(device.path);
    client.server.gpa.destroy(device);
}

/// Open a device node for passthrough. Type detection, DRM master and revocation
/// are layered on in the VT management stage.
fn openDeviceFd(path: []const u8) !i32 {
    var buf: [protocol.max_path_len]u8 = undefined;
    if (path.len + 1 > buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    const rc = linux.openat(linux.AT.FDCWD, @ptrCast(&buf), .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
        .NONBLOCK = true,
    }, 0);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.FileNotFound,
        else => error.OpenFailed,
    };
}

// On (re)activation a DRM device retakes master. On deactivation DRM drops
// master and evdev is revoked so a suspended session cannot touch the hardware.
// Non-device fds ("other", used in tests) have nothing to toggle.
fn activateDevice(device: *DeviceEntry) void {
    if (device.active) return;
    switch (device.kind) {
        .drm => _ = drm.setMaster(device.fd),
        .evdev, .other => {},
    }
    device.active = true;
}
fn deactivateDevice(device: *DeviceEntry) void {
    if (!device.active) return;
    switch (device.kind) {
        .drm => _ = drm.dropMaster(device.fd),
        .evdev => _ = evdev.revokeFd(device.fd),
        .other => {},
    }
    device.active = false;
}

fn sendHeader(client: *Client, opcode: Opcode, size: u16) OpenError!void {
    client.conn.putValue(Header{ .opcode = @backingInt(opcode), .size = size }) catch return error.OutOfMemory;
}

fn sendError(client: *Client, error_code: i32) OpenError!void {
    try sendHeader(client, .server_error, @sizeOf(protocol.ServerError));
    client.conn.putValue(protocol.ServerError{ .error_code = error_code }) catch return error.OutOfMemory;
}

fn errnoFor(err: anyerror) i32 {
    return switch (err) {
        error.Perm => @backingInt(linux.E.PERM),
        error.Invalid => @backingInt(linux.E.INVAL),
        error.TooMany => @backingInt(linux.E.MFILE),
        error.AccessDenied => @backingInt(linux.E.ACCES),
        error.FileNotFound => @backingInt(linux.E.NOENT),
        error.NameTooLong => @backingInt(linux.E.NAMETOOLONG),
        error.OpenFailed => @backingInt(linux.E.IO),
        else => @backingInt(linux.E.IO),
    };
}

fn destroyClient(client: *Client) void {
    for (client.devices.items) |d| {
        if (d.fd != -1) _ = linux.close(d.fd);
        client.server.gpa.free(d.path);
        client.server.gpa.destroy(d);
    }
    client.devices.deinit(client.server.gpa);
    client.conn.deinit();
    client.server.gpa.destroy(client);
}

const testing = std.testing;
const PublicSeat = @import("seat.zig").Seat;
const Listener = @import("seat.zig").Listener;

const TestCtx = struct { enabled: bool = false, disabled: bool = false };

fn onEnable(_: *PublicSeat, ud: ?*anyopaque) void {
    const ctx: *TestCtx = @ptrCast(@alignCast(ud.?));
    ctx.enabled = true;
}
fn onDisable(_: *PublicSeat, ud: ?*anyopaque) void {
    const ctx: *TestCtx = @ptrCast(@alignCast(ud.?));
    ctx.disabled = true;
}
const test_listener = Listener{ .enable = onEnable, .disable = onDisable };

test "client opens a seat and a device through the daemon" {
    const gpa = testing.allocator;

    var sp: [2]i32 = undefined;
    try testing.expect(posix.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0, &sp)) == .SUCCESS);

    var server = try Server.init(gpa, .{ .vt_bound = false });
    _ = try server.addClient(sp[1]);
    const thread = try std.Thread.spawn(.{}, Server.run, .{&server});

    defer server.deinit();
    defer thread.join();
    defer server.stop();

    var ctx = TestCtx{};
    const seat = try PublicSeat.openFd(gpa, &test_listener, &ctx, sp[0]);
    defer seat.close();

    try testing.expectEqualStrings("seat0", seat.name());

    // The enable event is delivered on the first dispatch after open.
    _ = try seat.dispatch(1000);
    try testing.expect(ctx.enabled);

    // Open a device and prove the fd is live.
    const dev = try seat.openDevice("/dev/null");
    try testing.expect(dev.fd >= 0);
    try testing.expectEqual(@as(usize, 1), linux.write(dev.fd, "x", 1));

    try seat.closeDevice(dev);
}

test "standalone daemon accepts a client over a listening socket" {
    const gpa = testing.allocator;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/libseat-daemon-{d}.sock", .{linux.getpid()});

    var server = try Server.init(gpa, .{ .vt_bound = false });
    try server.listenUnix(path);
    const thread = try std.Thread.spawn(.{}, Server.run, .{&server});

    defer server.deinit();
    defer thread.join();
    defer server.stop();

    const fd = try @import("backend/seatd.zig").connect(path);
    var ctx = TestCtx{};
    const seat = try PublicSeat.openFd(gpa, &test_listener, &ctx, fd);
    defer seat.close();

    try testing.expectEqualStrings("seat0", seat.name());
    _ = try seat.dispatch(1000);
    try testing.expect(ctx.enabled);
    const dev = try seat.openDevice("/dev/null");
    try testing.expect(dev.fd >= 0);
    try seat.closeDevice(dev);
}

// A fake VT that records calls, so the VT-bound state machine can be driven
// without a real console.
const FakeVt = struct {
    current: i32 = 1,
    opened: i32 = -1,
    closed: i32 = -1,
    switched: bool = false,
    switch_from: i32 = 0,
    switch_target: i32 = 0,
    ack_release: bool = false,
    ack_acquire: bool = false,

    fn interface(self: *FakeVt) vtmod.Vt {
        return .{ .ptr = self, .vtable = &fake_vtable };
    }
    const fake_vtable = vtmod.Vt.VTable{
        .currentVt = curr,
        .openVt = open,
        .closeVt = close,
        .switchVt = switchTo,
        .ackRelease = ackRel,
        .ackAcquire = ackAcq,
    };
    fn cast(p: *anyopaque) *FakeVt {
        return @ptrCast(@alignCast(p));
    }
    fn curr(p: *anyopaque) i32 {
        return cast(p).current;
    }
    fn open(p: *anyopaque, n: i32) void {
        cast(p).opened = n;
    }
    fn close(p: *anyopaque, n: i32) void {
        cast(p).closed = n;
    }
    fn switchTo(p: *anyopaque, from: i32, target: i32) void {
        const s = cast(p);
        s.switched = true;
        s.switch_from = from;
        s.switch_target = target;
    }
    fn ackRel(p: *anyopaque, _: i32) void {
        cast(p).ack_release = true;
    }
    fn ackAcq(p: *anyopaque, _: i32) void {
        cast(p).ack_acquire = true;
    }
};

fn expectHeader(conn: *Connection, opcode: Opcode) !void {
    const h = try conn.getValue(Header);
    try testing.expectEqual(@backingInt(opcode), h.opcode);
    if (opcode == .server_seat_opened) {
        const so = try conn.getValue(protocol.ServerSeatOpened);
        conn.skip(so.seat_name_len);
    }
}

test "VT-bound seat drives switching through the kernel" {
    const gpa = testing.allocator;

    var fake = FakeVt{ .current = 1 };
    var server = try Server.init(gpa, .{ .vt_bound = true, .vt = fake.interface() });
    defer server.deinit();

    var sp: [2]i32 = undefined;
    try testing.expect(posix.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0, &sp)) == .SUCCESS);
    const client = try server.addClient(sp[1]);
    var peer = Connection.init(gpa, sp[0]);
    defer peer.deinit();

    // Open the seat: client binds to the current VT (1) and is enabled.
    try server.handleOpenSeat(client);
    client.conn.flush() catch {};
    try testing.expectEqual(ClientState.active, client.state);
    try testing.expectEqual(@as(i32, 1), client.session);
    try testing.expectEqual(@as(i32, 1), fake.opened);

    _ = try peer.read();
    try expectHeader(&peer, .server_seat_opened);
    try expectHeader(&peer, .server_enable_seat);

    // Request a switch to VT 2: handed to the kernel, no client change yet.
    try seatSetNextSession(&server.seat, client, 2);
    try testing.expect(fake.switched);
    try testing.expectEqual(@as(i32, 1), fake.switch_from);
    try testing.expectEqual(@as(i32, 2), fake.switch_target);
    try testing.expectEqual(ClientState.active, client.state);

    // Kernel release signal: current client is disabled and release is acked.
    server.seat.vtRelease();
    client.conn.flush() catch {};
    try testing.expectEqual(ClientState.pending_disable, client.state);
    try testing.expect(fake.ack_release);
    try testing.expectEqual(@as(i32, -1), server.seat.cur_vt);

    _ = try peer.read();
    try expectHeader(&peer, .server_disable_seat);

    // Client acks the disable. With no client bound to the new VT, none reopens.
    try seatAckDisable(&server.seat, client);
    try testing.expectEqual(ClientState.disabled, client.state);
    try testing.expect(server.seat.active_client == null);
}
