//! Builtin backend: no external seat manager. We fork a child that runs an
//! embedded copy of the daemon over a socketpair, and the parent talks to it
//! with the ordinary seatd client backend. The compositor must already have
//! permission to open the seat's devices (and drmSetMaster) at open time.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const seat_mod = @import("../seat.zig");
const daemon = @import("../daemon.zig");
const vtmod = @import("../daemon/vt.zig");
const types = @import("../types.zig");

const Error = types.Error;

pub const Config = struct {
    /// Whether the embedded seat is VT-bound. Real use defaults to true. Tests
    /// pass false so no console is required.
    vt_bound: bool = true,
};

pub fn open(gpa: Allocator, listener: *const seat_mod.Listener, userdata: ?*anyopaque, config: Config) Error!*seat_mod.Seat {
    var sv: [2]i32 = undefined;
    if (posix.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0, &sv)) != .SUCCESS) {
        return Error.ConnectionFailed;
    }

    const pid = linux.fork();
    switch (posix.errno(pid)) {
        .SUCCESS => {},
        else => {
            _ = linux.close(sv[0]);
            _ = linux.close(sv[1]);
            return Error.ConnectionFailed;
        },
    }

    if (pid == 0) {
        // Child: serve exactly one client (us) until we disconnect, then exit.
        _ = linux.close(sv[1]);
        runEmbedded(gpa, sv[0], config);
    }

    // Parent: the forked server owns sv[0]. We speak to it over sv[1].
    _ = linux.close(sv[0]);
    return seat_mod.Seat.openFd(gpa, listener, userdata, sv[1]);
}

fn runEmbedded(gpa: Allocator, fd: i32, config: Config) noreturn {
    var linux_vt = vtmod.LinuxVt{};
    var server = daemon.Server.init(gpa, .{
        .vt_bound = config.vt_bound,
        .vt = linux_vt.interface(),
    }) catch linux.exit_group(1);
    _ = server.addClient(fd) catch linux.exit_group(1);
    server.run();
    linux.exit_group(0);
}

const testing = std.testing;

const TestCtx = struct { enabled: bool = false };
fn onEnable(_: *seat_mod.Seat, ud: ?*anyopaque) void {
    const ctx: *TestCtx = @ptrCast(@alignCast(ud.?));
    ctx.enabled = true;
}
fn onDisable(_: *seat_mod.Seat, _: ?*anyopaque) void {}
const test_listener = seat_mod.Listener{ .enable = onEnable, .disable = onDisable };

test "builtin backend forks an embedded server end to end" {
    const gpa = testing.allocator;
    var ctx = TestCtx{};
    // Non-VT-bound so the embedded server needs no real console.
    const seat = try open(gpa, &test_listener, &ctx, .{ .vt_bound = false });
    defer seat.close();

    try testing.expectEqualStrings("seat0", seat.name());
    _ = try seat.dispatch(1000);
    try testing.expect(ctx.enabled);

    const dev = try seat.openDevice("/dev/null");
    try testing.expect(dev.fd >= 0);
    try testing.expectEqual(@as(usize, 1), linux.write(dev.fd, "z", 1));
    try seat.closeDevice(dev);
}
