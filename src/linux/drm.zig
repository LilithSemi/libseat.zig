//! DRM ioctls needed for seat management: master set/drop, used to grant and
//! revoke a session's control of a GPU. Pure Zig, no libdrm.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const ioctl = @import("ioctl.zig");

const DRM_IOCTL_BASE = 'd';

pub const set_master = ioctl.IO(DRM_IOCTL_BASE, 0x1e);
pub const drop_master = ioctl.IO(DRM_IOCTL_BASE, 0x1f);

pub fn pathIsDrm(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/dev/dri/");
}

pub fn setMaster(fd: i32) bool {
    return posix.errno(linux.ioctl(fd, set_master, 0)) == .SUCCESS;
}

pub fn dropMaster(fd: i32) bool {
    return posix.errno(linux.ioctl(fd, drop_master, 0)) == .SUCCESS;
}

test "DRM master ioctl numbers" {
    try std.testing.expectEqual(@as(u32, 0x641e), set_master);
    try std.testing.expectEqual(@as(u32, 0x641f), drop_master);
}

test "DRM path detection" {
    try std.testing.expect(pathIsDrm("/dev/dri/card0"));
    try std.testing.expect(pathIsDrm("/dev/dri/renderD128"));
    try std.testing.expect(!pathIsDrm("/dev/input/event0"));
    try std.testing.expect(!pathIsDrm("/dev/null"));
}
