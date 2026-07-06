//! evdev input-device revocation. `EVIOCREVOKE` makes an input fd permanently
//! inert, so a suspended session cannot read input. Pure Zig, no libevdev.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const ioctl = @import("ioctl.zig");

pub const revoke = ioctl.IOW('E', 0x91, i32);

pub fn pathIsEvdev(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/dev/input/event");
}

pub fn revokeFd(fd: i32) bool {
    return posix.errno(linux.ioctl(fd, revoke, 0)) == .SUCCESS;
}

test "EVIOCREVOKE number" {
    try std.testing.expectEqual(@as(u32, 0x40044591), revoke);
}

test "evdev path detection" {
    try std.testing.expect(pathIsEvdev("/dev/input/event0"));
    try std.testing.expect(pathIsEvdev("/dev/input/event12"));
    try std.testing.expect(!pathIsEvdev("/dev/input/mouse0"));
    try std.testing.expect(!pathIsEvdev("/dev/dri/card0"));
}
