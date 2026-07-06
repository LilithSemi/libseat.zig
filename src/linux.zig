//! Pure-Zig Linux uapi used by the device backends: ioctl request-number macros
//! and the per-subsystem constants. No C headers, so it cross-compiles cleanly.

const std = @import("std");

pub const ioctl = @import("linux/ioctl.zig");
pub const vt = @import("linux/vt.zig");
pub const kd = @import("linux/kd.zig");
pub const drm = @import("linux/drm.zig");
pub const evdev = @import("linux/evdev.zig");

test {
    std.testing.refAllDecls(@This());
}
