//! Root of the pure-Zig libseat library (one `libseat` module). Consumers reach
//! the pieces as namespaces: `libseat.protocol`, `libseat.transport`, ...
//!
//! libseat lets a compositor open privileged devices (DRM, evdev) and switch
//! sessions/VTs without running as root, by delegating to a seat manager. This
//! is a from-scratch reimplementation with zero C dependencies.

const std = @import("std");

pub const protocol = @import("libseat/protocol.zig");
pub const transport = @import("libseat/transport.zig");
pub const backend = @import("libseat/backend.zig");
pub const seat = @import("libseat/seat.zig");
pub const daemon = @import("libseat/daemon.zig");

/// Pure-Zig Linux uapi (ioctl request-number macros, device constants).
pub const linux_uapi = @import("linux.zig");

pub const types = @import("libseat/types.zig");
pub const env = @import("libseat/env.zig");

/// The public seat handle and its event listener.
pub const Seat = seat.Seat;
pub const Listener = seat.Listener;
pub const Device = types.Device;
pub const Error = types.Error;

test {
    std.testing.refAllDecls(@This());
    // Pull in tests from files reached only through private imports.
    _ = @import("libseat/env.zig");
    _ = @import("libseat/backend/seatd.zig");
    _ = @import("libseat/backend/builtin.zig");
    _ = @import("libseat/backend/logind.zig");
    _ = @import("libseat/daemon/vt.zig");
}
