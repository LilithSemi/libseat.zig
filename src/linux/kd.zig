//! Linux KD (kernel display) ioctls for switching a VT between text and graphics
//! and toggling kernel keyboard processing. Values from <linux/kd.h>.

const std = @import("std");

pub const SETMODE = 0x4B3A;
pub const GKBMODE = 0x4B44;
pub const SKBMODE = 0x4B45;

/// KDSETMODE arguments.
pub const TEXT = 0x00;
pub const GRAPHICS = 0x01;

/// KDSKBMODE arguments: full unicode input vs input off.
pub const K_UNICODE = 0x03;
pub const K_OFF = 0x04;

test "kd constants" {
    try std.testing.expectEqual(@as(u32, 0x4B3A), SETMODE);
    try std.testing.expectEqual(@as(u32, 0x4B45), SKBMODE);
}
