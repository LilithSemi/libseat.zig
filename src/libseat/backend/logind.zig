//! logind backend: talks to systemd-logind (or elogind) on the D-Bus system bus
//! via the pure-Zig dbus.zig client. No libsystemd. Devices are taken with
//! `TakeDevice`, whose fd arrives over SCM_RIGHTS (needs dbus.zig fd support and
//! is forwarded by the real system bus). Activation follows the session's
//! `Active` property and `PauseDevice` signals.
//!
//! D-Bus calls are issued synchronously here: send, then pump the event loop
//! until the reply lands. Asynchronous session events are delivered through
//! `dispatch`, which the compositor drives off `pollFd`.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const native_endian = builtin.cpu.arch.endian();

const dbus = @import("dbus");
const Bus = dbus.client.Bus;
const EventLoop = dbus.event_loop.EventLoop;
const Message = dbus.message.Message;
const Connection = dbus.connection.Connection;
const marshal = dbus.marshal;
const unmarshal = dbus.unmarshal;
const MatchRule = dbus.match.MatchRule;

const seat_mod = @import("../seat.zig");
const types = @import("../types.zig");
const env = @import("../env.zig");
const Error = types.Error;
const Device = types.Device;

const login1 = "org.freedesktop.login1";
const manager_iface = "org.freedesktop.login1.Manager";
const session_iface = "org.freedesktop.login1.Session";
const seat_iface = "org.freedesktop.login1.Seat";
const props_iface = "org.freedesktop.DBus.Properties";
const manager_path = "/org/freedesktop/login1";

pub const Backend = struct {
    gpa: Allocator,
    owner: *seat_mod.Seat,
    loop: EventLoop,
    bus: *Bus,
    session_id: []u8,
    seat_id: []u8,
    session_path: []u8,
    seat_path: []u8,
    active: bool = false,
    initial_setup: bool = true,

    pub fn open(gpa: Allocator, owner: *seat_mod.Seat) Error!*Backend {
        // A logind session is required. Without one this backend does not apply.
        var id_buf: [64]u8 = undefined;
        var seat_buf: [64]u8 = undefined;
        const session_id = env.get(&id_buf, "XDG_SESSION_ID") orelse return Error.NoBackend;
        const seat_id = env.get(&seat_buf, "XDG_SEAT") orelse "seat0";

        var bus_buf: [256]u8 = undefined;
        return openWith(gpa, owner, systemBusPath(&bus_buf), false, session_id, seat_id);
    }

    /// Connect to a specific bus with explicit session/seat ids. Used by `open`
    /// after reading the environment, and directly by tests against a mock bus.
    pub fn openWith(gpa: Allocator, owner: *seat_mod.Seat, bus_path: []const u8, abstract: bool, session_id: []const u8, seat_id: []const u8) Error!*Backend {
        const self = gpa.create(Backend) catch return Error.OutOfMemory;
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .owner = owner,
            .loop = undefined,
            .bus = undefined,
            .session_id = gpa.dupe(u8, session_id) catch return Error.OutOfMemory,
            .seat_id = gpa.dupe(u8, seat_id) catch return Error.OutOfMemory,
            .session_path = &.{},
            .seat_path = &.{},
        };
        errdefer gpa.free(self.session_id);
        errdefer gpa.free(self.seat_id);

        self.loop = EventLoop.init(gpa) catch return Error.ConnectionFailed;
        errdefer self.loop.deinit();

        self.bus = Bus.connectUnix(gpa, &self.loop, bus_path, abstract, linux.getuid()) catch
            return Error.ConnectionFailed;
        errdefer self.bus.deinit();

        try self.setup();
        return self;
    }

    fn setup(self: *Backend) Error!void {
        self.session_path = try self.managerLookup("GetSession", self.session_id);
        errdefer self.gpa.free(self.session_path);
        self.seat_path = try self.managerLookup("GetSeat", self.seat_id);
        errdefer self.gpa.free(self.seat_path);

        try self.addSignalMatches();

        self.active = self.sessionActive();
        try self.takeControl();

        var type_buf: [64]u8 = undefined;
        if (env.get(&type_buf, "XDG_SESSION_TYPE")) |t| self.setType(t);
    }

    pub fn destroy(self: *Backend) void {
        if (self.session_path.len > 0) self.gpa.free(self.session_path);
        if (self.seat_path.len > 0) self.gpa.free(self.seat_path);
        self.gpa.free(self.session_id);
        self.gpa.free(self.seat_id);
        self.bus.deinit();
        self.loop.deinit();
        self.gpa.destroy(self);
    }

    pub fn close(self: *Backend) void {
        self.releaseControl();
        self.destroy();
    }

    pub fn seatName(self: *Backend) []const u8 {
        return self.seat_id;
    }

    pub fn pollFd(self: *Backend) i32 {
        return self.bus.conn.transport.fd;
    }

    const Reply = struct {
        gpa: Allocator,
        done: bool = false,
        ok: bool = false,
        body: []u8 = &.{},
        endian: std.builtin.Endian = native_endian,
        fd: i32 = -1,

        fn onReply(ctx: ?*anyopaque, conn: *Connection, r: ?*const Message) void {
            _ = conn;
            const self: *Reply = @ptrCast(@alignCast(ctx.?));
            self.done = true;
            const msg = r orelse return;
            if (msg.msg_type != .method_return) return;
            self.ok = true;
            self.endian = msg.endian;
            if (msg.body.len > 0) {
                self.body = self.gpa.dupe(u8, msg.body) catch {
                    self.ok = false;
                    return;
                };
            }
            if (msg.fds.len > 0) {
                const rc = linux.fcntl(msg.fds[0], linux.F.DUPFD_CLOEXEC, 0);
                if (posix.errno(rc) == .SUCCESS) self.fd = @intCast(rc);
            }
        }

        fn free(self: *Reply) void {
            if (self.body.len > 0) self.gpa.free(self.body);
        }
    };

    fn callSync(self: *Backend, msg: Message) Reply {
        var reply = Reply{ .gpa = self.gpa };
        _ = self.bus.call(msg, Reply.onReply, &reply) catch {
            reply.done = true;
            return reply;
        };
        var i: usize = 0;
        while (!reply.done and i < 1000) : (i += 1) _ = self.loop.dispatch(20);
        return reply;
    }

    fn managerLookup(self: *Backend, member: []const u8, arg: []const u8) Error![]u8 {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var w = marshal.Writer.init(self.gpa, &body, self.bus.conn.endian);
        w.string(arg) catch return Error.OutOfMemory;

        var reply = self.callSync(.{
            .msg_type = .method_call,
            .serial = 0,
            .destination = login1,
            .path = manager_path,
            .interface = manager_iface,
            .member = member,
            .body_signature = "s",
            .body = body.items,
        });
        defer reply.free();
        if (!reply.ok) return Error.Denied;

        var r = unmarshal.Reader.init(reply.body, reply.endian);
        const path = r.objectPath() catch return Error.ProtocolError;
        return self.gpa.dupe(u8, path) catch Error.OutOfMemory;
    }

    fn takeControl(self: *Backend) Error!void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var w = marshal.Writer.init(self.gpa, &body, self.bus.conn.endian);
        w.boolean(false) catch return Error.OutOfMemory;

        var reply = self.callSync(sessionCall("TakeControl", "b", body.items, self.session_path));
        defer reply.free();
        if (!reply.ok) return Error.Denied;
    }

    fn releaseControl(self: *Backend) void {
        var reply = self.callSync(sessionCall("ReleaseControl", null, &.{}, self.session_path));
        reply.free();
    }

    fn setType(self: *Backend, session_type: []const u8) void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var w = marshal.Writer.init(self.gpa, &body, self.bus.conn.endian);
        w.string(session_type) catch return;
        var reply = self.callSync(sessionCall("SetType", "s", body.items, self.session_path));
        reply.free();
    }

    fn sessionActive(self: *Backend) bool {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var w = marshal.Writer.init(self.gpa, &body, self.bus.conn.endian);
        w.string(session_iface) catch return false;
        w.string("Active") catch return false;

        var reply = self.callSync(.{
            .msg_type = .method_call,
            .serial = 0,
            .destination = login1,
            .path = self.session_path,
            .interface = props_iface,
            .member = "Get",
            .body_signature = "ss",
            .body = body.items,
        });
        defer reply.free();
        if (!reply.ok) return false;

        var r = unmarshal.Reader.init(reply.body, reply.endian);
        const v = r.readValue(self.gpa, "v") catch return false;
        defer unmarshal.freeValue(self.gpa, v);
        return v == .variant and v.variant.* == .boolean and v.variant.*.boolean;
    }

    pub fn openDevice(self: *Backend, path: []const u8) Error!Device {
        const dev = statxRdev(path) catch return Error.Denied;

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var w = marshal.Writer.init(self.gpa, &body, self.bus.conn.endian);
        w.uint32(dev.major) catch return Error.OutOfMemory;
        w.uint32(dev.minor) catch return Error.OutOfMemory;

        var reply = self.callSync(sessionCall("TakeDevice", "uu", body.items, self.session_path));
        defer reply.free();
        if (!reply.ok) return Error.Denied;
        if (reply.fd < 0) return Error.ProtocolError;

        // libseat identifies a logind device by its fd.
        return .{ .id = reply.fd, .fd = reply.fd };
    }

    pub fn closeDevice(self: *Backend, device_id: i32) Error!void {
        if (device_id < 0) return Error.InvalidArgument;
        const dev = statxRdevFd(device_id) catch return Error.Denied;

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var w = marshal.Writer.init(self.gpa, &body, self.bus.conn.endian);
        w.uint32(dev.major) catch return Error.OutOfMemory;
        w.uint32(dev.minor) catch return Error.OutOfMemory;

        var reply = self.callSync(sessionCall("ReleaseDevice", "uu", body.items, self.session_path));
        reply.free();
    }

    pub fn switchSession(self: *Backend, session: i32) Error!void {
        if (session < 0) return Error.InvalidArgument;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var w = marshal.Writer.init(self.gpa, &body, self.bus.conn.endian);
        w.uint32(@intCast(session)) catch return Error.OutOfMemory;

        var reply = self.callSync(.{
            .msg_type = .method_call,
            .serial = 0,
            .destination = login1,
            .path = self.seat_path,
            .interface = seat_iface,
            .member = "SwitchTo",
            .body_signature = "u",
            .body = body.items,
        });
        reply.free();
    }

    pub fn disable(_: *Backend) Error!void {
        // logind manages activation, so there is nothing to acknowledge.
    }

    pub fn dispatch(self: *Backend, timeout_ms: i32) Error!usize {
        var n: usize = 0;
        if (self.initial_setup) {
            self.initial_setup = false;
            if (self.active) self.owner.emitEnable() else self.owner.emitDisable();
            n += 1;
        }
        const t = if (timeout_ms < 0) 100 else timeout_ms;
        n += self.loop.dispatch(t);
        return n;
    }

    fn addSignalMatches(self: *Backend) Error!void {
        self.bus.addSignalHandler(.{
            .msg_type = .signal,
            .sender = login1,
            .path = self.session_path,
            .interface = session_iface,
            .member = "PauseDevice",
        }, onPauseDevice, self) catch return Error.ConnectionFailed;

        self.bus.addSignalHandler(.{
            .msg_type = .signal,
            .sender = login1,
            .path = self.session_path,
            .interface = props_iface,
            .member = "PropertiesChanged",
        }, onPropertiesChanged, self) catch return Error.ConnectionFailed;
    }

    fn setActive(self: *Backend, active: bool) void {
        if (self.active == active) return;
        self.active = active;
        if (active) self.owner.emitEnable() else self.owner.emitDisable();
    }

    fn onPauseDevice(ctx: ?*anyopaque, bus: *Bus, signal: *const Message) void {
        _ = bus;
        const self: *Backend = @ptrCast(@alignCast(ctx.?));
        var r = unmarshal.Reader.init(signal.body, signal.endian);
        const major = r.uint32() catch return;
        const minor = r.uint32() catch return;
        const kind = r.string() catch return;

        if (std.mem.eql(u8, kind, "gone")) return;
        // "pause" asks us to give up access. "force" means it is already gone.
        if (std.mem.eql(u8, kind, "pause")) {
            self.setActive(false);
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(self.gpa);
            var w = marshal.Writer.init(self.gpa, &body, self.bus.conn.endian);
            w.uint32(major) catch return;
            w.uint32(minor) catch return;
            var reply = self.callSync(sessionCall("PauseDeviceComplete", "uu", body.items, self.session_path));
            reply.free();
        } else {
            self.setActive(false);
        }
    }

    fn onPropertiesChanged(ctx: ?*anyopaque, bus: *Bus, signal: *const Message) void {
        _ = bus;
        const self: *Backend = @ptrCast(@alignCast(ctx.?));
        var r = unmarshal.Reader.init(signal.body, signal.endian);

        const iface = r.string() catch return;
        if (!std.mem.eql(u8, iface, session_iface)) return;

        // Changed properties: a{sv}. Look for Active with a value.
        const changed = r.readValue(self.gpa, "a{sv}") catch return;
        defer unmarshal.freeValue(self.gpa, changed);
        if (changed == .array) {
            for (changed.array) |entry| {
                if (entry != .dict_entry) continue;
                const key = entry.dict_entry[0];
                const val = entry.dict_entry[1];
                if (key == .string and std.mem.eql(u8, key.string, "Active") and
                    val == .variant and val.variant.* == .boolean)
                {
                    self.setActive(val.variant.*.boolean);
                }
            }
        }

        // Invalidated properties: as. If Active is here, re-read it.
        const invalidated = r.readValue(self.gpa, "as") catch return;
        defer unmarshal.freeValue(self.gpa, invalidated);
        if (invalidated == .array) {
            for (invalidated.array) |item| {
                if (item == .string and std.mem.eql(u8, item.string, "Active")) {
                    self.setActive(self.sessionActive());
                }
            }
        }
    }
};

fn sessionCall(member: []const u8, sig: ?[]const u8, body: []const u8, path: []const u8) Message {
    return .{
        .msg_type = .method_call,
        .serial = 0,
        .destination = login1,
        .path = path,
        .interface = session_iface,
        .member = member,
        .body_signature = sig,
        .body = body,
    };
}

fn systemBusPath(buf: []u8) []const u8 {
    // DBUS_SYSTEM_BUS_ADDRESS looks like "unix:path=/some/socket". Extract the path.
    if (env.get(buf, "DBUS_SYSTEM_BUS_ADDRESS")) |addr| {
        const marker = "unix:path=";
        if (std.mem.indexOf(u8, addr, marker)) |i| {
            const rest = addr[i + marker.len ..];
            const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
            return rest[0..end];
        }
    }
    return "/var/run/dbus/system_bus_socket";
}

const DevNum = struct { major: u32, minor: u32 };

fn statxRdev(path: []const u8) !DevNum {
    var buf: [512]u8 = undefined;
    if (path.len + 1 > buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, @ptrCast(&buf), 0, linux.STATX.BASIC_STATS, &stx);
    if (posix.errno(rc) != .SUCCESS) return error.StatFailed;
    return .{ .major = stx.rdev_major, .minor = stx.rdev_minor };
}

fn statxRdevFd(fd: i32) !DevNum {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stx);
    if (posix.errno(rc) != .SUCCESS) return error.StatFailed;
    return .{ .major = stx.rdev_major, .minor = stx.rdev_minor };
}

const testing = std.testing;
const Daemon = dbus.daemon.bus.Daemon;
const object = dbus.object;

const mock_session_path = "/org/freedesktop/login1/session/self";
const mock_seat_path = "/org/freedesktop/login1/seat/seat0";

// A minimal login1 stand-in built from registered D-Bus objects, so the backend
// can be exercised over a real bus without a live logind.
const MockLogind = struct {
    switched_to: i32 = -1,

    fn getSession(_: ?*anyopaque, _: *const Message, w: *marshal.Writer) object.HandlerError![]const u8 {
        try w.objectPath(mock_session_path);
        return "o";
    }
    fn getSeat(_: ?*anyopaque, _: *const Message, w: *marshal.Writer) object.HandlerError![]const u8 {
        try w.objectPath(mock_seat_path);
        return "o";
    }
    fn empty(_: ?*anyopaque, _: *const Message, _: *marshal.Writer) object.HandlerError![]const u8 {
        return "";
    }
    fn switchTo(ctx: ?*anyopaque, call: *const Message, _: *marshal.Writer) object.HandlerError![]const u8 {
        const self: *MockLogind = @ptrCast(@alignCast(ctx.?));
        var r = unmarshal.Reader.init(call.body, call.endian);
        self.switched_to = @intCast(r.uint32() catch 0);
        return "";
    }
    fn activeProp(_: ?*anyopaque, w: *marshal.Writer) object.HandlerError!void {
        try w.boolean(true);
    }
};

const LogindCtx = struct { enabled: bool = false, disabled: bool = false };
fn logindEnable(_: *seat_mod.Seat, ud: ?*anyopaque) void {
    const c: *LogindCtx = @ptrCast(@alignCast(ud.?));
    c.enabled = true;
}
fn logindDisable(_: *seat_mod.Seat, ud: ?*anyopaque) void {
    const c: *LogindCtx = @ptrCast(@alignCast(ud.?));
    c.disabled = true;
}
const logind_listener = seat_mod.Listener{ .enable = logindEnable, .disable = logindDisable };

fn mockThread(loop: *EventLoop, stop: *const bool) void {
    while (!stop.*) _ = loop.dispatch(20);
}
fn daemonThread(d: *Daemon) void {
    d.run();
}

test "logind backend talks to a mock login1 over the bus" {
    const gpa = testing.allocator;

    // Daemon on its own thread.
    var dloop = try EventLoop.init(gpa);
    defer dloop.deinit();
    const d = try Daemon.init(gpa, &dloop);
    defer d.deinit();
    var name_buf: [64]u8 = undefined;
    const sock = try std.fmt.bufPrint(&name_buf, "libseat-logind-{d}", .{linux.getpid()});
    try d.listenUnix(sock, true);
    const dthread = try std.Thread.spawn(.{}, daemonThread, .{d});
    defer {
        d.stop();
        dthread.join();
    }

    // Mock connects and claims org.freedesktop.login1.
    var mloop = try EventLoop.init(gpa);
    defer mloop.deinit();
    var mock = MockLogind{};
    const mbus = connectRetry(gpa, &mloop, sock, linux.getuid()) catch return error.SkipZigTest;
    defer mbus.deinit();

    const manager_methods = [_]object.Method{
        .{ .name = "GetSession", .handler = MockLogind.getSession },
        .{ .name = "GetSeat", .handler = MockLogind.getSeat },
    };
    const session_methods = [_]object.Method{
        .{ .name = "TakeControl", .handler = MockLogind.empty },
        .{ .name = "ReleaseControl", .handler = MockLogind.empty },
        .{ .name = "SetType", .handler = MockLogind.empty },
    };
    const session_props = [_]object.Property{
        .{ .name = "Active", .sig = "b", .getter = MockLogind.activeProp },
    };
    const seat_methods = [_]object.Method{
        .{ .name = "SwitchTo", .handler = MockLogind.switchTo, .ctx = &mock },
    };
    try mbus.exportObject(manager_path, &.{.{ .name = manager_iface, .methods = &manager_methods }});
    try mbus.exportObject(mock_session_path, &.{.{ .name = session_iface, .methods = &session_methods, .properties = &session_props }});
    try mbus.exportObject(mock_seat_path, &.{.{ .name = seat_iface, .methods = &seat_methods }});
    {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        var w = marshal.Writer.init(gpa, &body, mbus.conn.endian);
        try w.string(login1);
        try w.uint32(0);
        var done = false;
        _ = try mbus.call(.{
            .msg_type = .method_call,
            .serial = 0,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "RequestName",
            .destination = "org.freedesktop.DBus",
            .body_signature = "su",
            .body = body.items,
        }, setDone, &done);
        var i: usize = 0;
        while (!done and i < 200) : (i += 1) _ = mloop.dispatch(10);
    }

    // From here the mock is serviced on its own thread.
    var stop = false;
    const mthread = try std.Thread.spawn(.{}, mockThread, .{ &mloop, &stop });

    var ctx = LogindCtx{};
    const seat = gpa.create(seat_mod.Seat) catch unreachable;
    seat.* = .{ .gpa = gpa, .listener = &logind_listener, .userdata = &ctx, .backend = undefined };
    const be = openWithRetry(gpa, seat, sock) catch {
        gpa.destroy(seat);
        stop = true;
        mthread.join();
        return error.SkipZigTest;
    };
    seat.backend = .{ .logind = be };

    try testing.expectEqualStrings("seat0", seat.name());

    // Active was true, so the first dispatch delivers enable.
    _ = try seat.dispatch(50);
    try testing.expect(ctx.enabled);

    try seat.switchSession(2);
    try testing.expectEqual(@as(i32, 2), mock.switched_to);

    seat.close(); // drives ReleaseControl, answered by the mock
    stop = true;
    mthread.join();
}

fn setDone(ctx: ?*anyopaque, conn: *Connection, reply: ?*const Message) void {
    _ = conn;
    _ = reply;
    const f: *bool = @ptrCast(@alignCast(ctx.?));
    f.* = true;
}

fn connectRetry(gpa: Allocator, loop: *EventLoop, sock: []const u8, uid: u32) !*Bus {
    var attempt: usize = 0;
    while (attempt < 20) : (attempt += 1) {
        if (Bus.connectUnix(gpa, loop, sock, true, uid)) |bus| return bus else |_| {}
    }
    return error.ConnectFailed;
}

fn openWithRetry(gpa: Allocator, seat: *seat_mod.Seat, sock: []const u8) !*Backend {
    var attempt: usize = 0;
    while (attempt < 20) : (attempt += 1) {
        if (Backend.openWith(gpa, seat, sock, true, "1", "seat0")) |be| return be else |_| {}
    }
    return error.ConnectFailed;
}

test "statxRdev reads device numbers (/dev/null is 1:3)" {
    const dev = statxRdev("/dev/null") catch return error.SkipZigTest;
    try testing.expectEqual(@as(u32, 1), dev.major);
    try testing.expectEqual(@as(u32, 3), dev.minor);
}

test "systemBusPath falls back to the well-known socket" {
    var buf: [256]u8 = undefined;
    // With no DBUS_SYSTEM_BUS_ADDRESS in the test env, we get the default path.
    if (!env.eql("DBUS_SYSTEM_BUS_ADDRESS", "")) {
        var probe: [256]u8 = undefined;
        if (env.get(&probe, "DBUS_SYSTEM_BUS_ADDRESS") == null) {
            try testing.expectEqualStrings("/var/run/dbus/system_bus_socket", systemBusPath(&buf));
        }
    }
}
