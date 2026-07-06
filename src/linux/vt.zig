//! Linux VT (virtual terminal) ioctls and structs for VT-bound seats. The
//! daemon uses these to learn the active VT, take process control of switching,
//! and ack the kernel's release/acquire signals. Values from <linux/vt.h>.

const std = @import("std");

pub const GETSTATE = 0x5603;
pub const SETMODE = 0x5602;
pub const RELDISP = 0x5605;
pub const ACTIVATE = 0x5606;
pub const WAITACTIVE = 0x5607;

/// vt_mode.mode values.
pub const AUTO = 0x00;
pub const PROCESS = 0x01;
/// Argument to RELDISP to ack an acquire.
pub const ACKACQ = 0x02;

/// Signals the kernel raises for process-controlled VT switching.
pub const relsig: i16 = @intFromEnum(std.os.linux.SIG.USR1);
pub const acqsig: i16 = @intFromEnum(std.os.linux.SIG.USR2);

/// struct vt_mode
pub const Mode = extern struct {
    mode: u8,
    waitv: u8,
    relsig: i16,
    acqsig: i16,
    frsig: i16,
};

/// struct vt_stat
pub const Stat = extern struct {
    v_active: u16,
    v_signal: u16,
    v_state: u16,
};

test "vt struct sizes match the kernel layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Mode));
    try std.testing.expectEqual(@as(usize, 6), @sizeOf(Stat));
}
