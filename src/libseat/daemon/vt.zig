//! VT control for VT-bound seats, behind an interface so the seat state machine
//! can be driven by a fake in tests (real VT ioctls need a console and root).
//!
//! `LinuxVt` is the production implementation: it opens /dev/ttyN and issues the
//! VT/KD ioctls exactly as upstream seatd's terminal.c does.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const vt_uapi = @import("../../linux/vt.zig");
const kd_uapi = @import("../../linux/kd.zig");

/// Interface used by the seat: a pointer plus a vtable, like std.mem.Allocator.
pub const Vt = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        currentVt: *const fn (*anyopaque) i32,
        openVt: *const fn (*anyopaque, vt: i32) void,
        closeVt: *const fn (*anyopaque, vt: i32) void,
        switchVt: *const fn (*anyopaque, cur: i32, target: i32) void,
        ackRelease: *const fn (*anyopaque, vt: i32) void,
        ackAcquire: *const fn (*anyopaque, vt: i32) void,
    };

    pub fn currentVt(self: Vt) i32 {
        return self.vtable.currentVt(self.ptr);
    }
    pub fn openVt(self: Vt, vt: i32) void {
        self.vtable.openVt(self.ptr, vt);
    }
    pub fn closeVt(self: Vt, vt: i32) void {
        self.vtable.closeVt(self.ptr, vt);
    }
    pub fn switchVt(self: Vt, cur: i32, target: i32) void {
        self.vtable.switchVt(self.ptr, cur, target);
    }
    pub fn ackRelease(self: Vt, vt: i32) void {
        self.vtable.ackRelease(self.ptr, vt);
    }
    pub fn ackAcquire(self: Vt, vt: i32) void {
        self.vtable.ackAcquire(self.ptr, vt);
    }
};

/// A do-nothing VT for non-VT-bound seats, where the interface is never really
/// exercised. Keeps `Seat.vt` always valid without an optional.
pub const noop = Vt{ .ptr = undefined, .vtable = &noop_vtable };

const noop_vtable = Vt.VTable{
    .currentVt = noopCurrentVt,
    .openVt = noopVt,
    .closeVt = noopVt,
    .switchVt = noopSwitch,
    .ackRelease = noopVt,
    .ackAcquire = noopVt,
};
fn noopCurrentVt(_: *anyopaque) i32 {
    return 0;
}
fn noopVt(_: *anyopaque, _: i32) void {}
fn noopSwitch(_: *anyopaque, _: i32, _: i32) void {}

pub const LinuxVt = struct {
    pub fn interface(self: *LinuxVt) Vt {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Vt.VTable{
        .currentVt = currentVt,
        .openVt = openVt,
        .closeVt = closeVt,
        .switchVt = switchVt,
        .ackRelease = ackRelease,
        .ackAcquire = ackAcquire,
    };

    fn openTty(n: i32) ?i32 {
        var buf: [16]u8 = undefined;
        const path = std.mem.printSentinel(&buf, "/dev/tty{d}", .{n}, 0) catch return null;
        const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        if (posix.errno(rc) != .SUCCESS) return null;
        return @intCast(rc);
    }

    fn setProcessSwitching(fd: i32, enable: bool) void {
        const mode = vt_uapi.Mode{
            .mode = if (enable) vt_uapi.PROCESS else vt_uapi.AUTO,
            .waitv = 0,
            .relsig = if (enable) vt_uapi.relsig else 0,
            .acqsig = if (enable) vt_uapi.acqsig else 0,
            .frsig = 0,
        };
        _ = linux.ioctl(fd, vt_uapi.SETMODE, @intFromPtr(&mode));
    }

    fn setKeyboard(fd: i32, enable: bool) void {
        _ = linux.ioctl(fd, kd_uapi.SKBMODE, if (enable) kd_uapi.K_UNICODE else kd_uapi.K_OFF);
    }

    fn setGraphics(fd: i32, enable: bool) void {
        _ = linux.ioctl(fd, kd_uapi.SETMODE, if (enable) kd_uapi.GRAPHICS else kd_uapi.TEXT);
    }

    fn currentVt(_: *anyopaque) i32 {
        const fd = openTty(0) orelse return -1;
        defer _ = linux.close(fd);
        var st: vt_uapi.Stat = undefined;
        if (posix.errno(linux.ioctl(fd, vt_uapi.GETSTATE, @intFromPtr(&st))) != .SUCCESS) return -1;
        return st.v_active;
    }

    fn openVt(_: *anyopaque, vt: i32) void {
        const fd = openTty(vt) orelse return;
        defer _ = linux.close(fd);
        setProcessSwitching(fd, true);
        setKeyboard(fd, false);
        setGraphics(fd, true);
    }

    fn closeVt(_: *anyopaque, vt: i32) void {
        const fd = openTty(vt) orelse return;
        defer _ = linux.close(fd);
        setProcessSwitching(fd, true);
        setKeyboard(fd, true);
        setGraphics(fd, false);
    }

    fn switchVt(_: *anyopaque, cur: i32, target: i32) void {
        const fd = openTty(cur) orelse return;
        defer _ = linux.close(fd);
        setProcessSwitching(fd, true);
        _ = linux.ioctl(fd, vt_uapi.ACTIVATE, @intCast(target));
    }

    fn ackRelease(_: *anyopaque, vt: i32) void {
        const fd = openTty(vt) orelse return;
        defer _ = linux.close(fd);
        _ = linux.ioctl(fd, vt_uapi.RELDISP, 1);
    }

    fn ackAcquire(_: *anyopaque, vt: i32) void {
        const fd = openTty(vt) orelse return;
        defer _ = linux.close(fd);
        _ = linux.ioctl(fd, vt_uapi.RELDISP, vt_uapi.ACKACQ);
    }
};
