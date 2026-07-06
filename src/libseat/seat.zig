//! The public seat handle. A compositor opens a seat, receives enable/disable
//! events through a `Listener`, and opens privileged devices through it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const backend_mod = @import("backend.zig");
const env = @import("env.zig");
const seatd = @import("backend/seatd.zig");
const logind = @import("backend/logind.zig");
const builtin = @import("backend/builtin.zig");

pub const Device = types.Device;
pub const Error = types.Error;

/// Seat event callbacks. Both are required.
///
/// `enable` fires when the seat becomes active: reopen all devices, existing
/// fds may have been revoked. `disable` fires when access is about to be lost
/// and must be acknowledged promptly with `Seat.disable`.
pub const Listener = struct {
    enable: *const fn (*Seat, ?*anyopaque) void,
    disable: *const fn (*Seat, ?*anyopaque) void,
};

pub const Seat = struct {
    gpa: Allocator,
    listener: *const Listener,
    userdata: ?*anyopaque,
    backend: backend_mod.Backend,
    /// Errno reported by the seat manager on the last `Error.Denied`.
    last_errno: i32 = 0,

    /// Open a seat, selecting a backend. `LIBSEAT_BACKEND` forces one. Otherwise
    /// the backends are tried in order and the first that connects wins.
    pub fn open(gpa: Allocator, listener: *const Listener, userdata: ?*anyopaque) Error!*Seat {
        var forced_buf: [32]u8 = undefined;
        const forced = env.get(&forced_buf, "LIBSEAT_BACKEND");
        const wants = struct {
            fn f(forced_: ?[]const u8, candidate: []const u8) bool {
                return forced_ == null or std.mem.eql(u8, forced_.?, candidate);
            }
        }.f;

        if (wants(forced, "seatd")) {
            if (openSeatd(gpa, listener, userdata)) |s| return s else |_| {}
            if (forced != null) return Error.NoBackend;
        }
        if (wants(forced, "logind")) {
            if (openLogind(gpa, listener, userdata)) |s| return s else |_| {}
            if (forced != null) return Error.NoBackend;
        }
        if (wants(forced, "builtin")) {
            const vt_bound = !env.eql("SEATD_VTBOUND", "0");
            if (builtin.open(gpa, listener, userdata, .{ .vt_bound = vt_bound })) |s| return s else |_| {}
        }
        return Error.NoBackend;
    }

    fn openSeatd(gpa: Allocator, listener: *const Listener, userdata: ?*anyopaque) Error!*Seat {
        var path_buf: [256]u8 = undefined;
        const path = env.get(&path_buf, "SEATD_SOCK") orelse "/run/seatd.sock";
        const fd = try seatd.connect(path);
        return openFd(gpa, listener, userdata, fd);
    }

    fn openLogind(gpa: Allocator, listener: *const Listener, userdata: ?*anyopaque) Error!*Seat {
        const self = gpa.create(Seat) catch return Error.OutOfMemory;
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .listener = listener, .userdata = userdata, .backend = undefined };

        const be = try logind.Backend.open(gpa, self);
        self.backend = .{ .logind = be };
        return self;
    }

    /// Build a seat over an already-connected seatd socket. Ownership of `fd`
    /// transfers to the seat. Used by the builtin backend and by tests.
    pub fn openFd(gpa: Allocator, listener: *const Listener, userdata: ?*anyopaque, fd: i32) Error!*Seat {
        const self = gpa.create(Seat) catch return Error.OutOfMemory;
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .listener = listener, .userdata = userdata, .backend = undefined };

        const be = try seatd.Backend.create(gpa, self, fd);
        self.backend = .{ .seatd = be };
        errdefer be.destroy();
        try be.handshake();
        return self;
    }

    pub fn close(self: *Seat) void {
        self.backend.close();
        self.gpa.destroy(self);
    }

    pub fn name(self: *Seat) []const u8 {
        return self.backend.seatName();
    }

    pub fn openDevice(self: *Seat, path: []const u8) Error!Device {
        return self.backend.openDevice(path);
    }

    pub fn closeDevice(self: *Seat, device: Device) Error!void {
        return self.backend.closeDevice(device.id);
    }

    pub fn switchSession(self: *Seat, session: i32) Error!void {
        return self.backend.switchSession(session);
    }

    pub fn disable(self: *Seat) Error!void {
        return self.backend.disable();
    }

    /// The pollable fd to watch in the compositor's event loop.
    pub fn pollFd(self: *Seat) i32 {
        return self.backend.pollFd();
    }

    pub fn dispatch(self: *Seat, timeout_ms: i32) Error!usize {
        return self.backend.dispatch(timeout_ms);
    }

    pub fn lastErrno(self: *Seat) i32 {
        return self.last_errno;
    }

    // Invoked by the active backend to deliver queued events.
    pub fn emitEnable(self: *Seat) void {
        self.listener.enable(self, self.userdata);
    }

    pub fn emitDisable(self: *Seat) void {
        self.listener.disable(self, self.userdata);
    }
};

test {
    // Compile-check the whole public surface (open/close/device/dispatch paths).
    std.testing.refAllDecls(@This());
}
