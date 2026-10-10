//! seatd wire protocol, byte-compatible with upstream seatd's `protocol.h`.
//! The wire format is the host-native memory layout of these structs (upstream
//! sends them with raw `memcpy`), so we rely on `extern struct` layout matching
//! the C definitions exactly. All fds travel out of band via SCM_RIGHTS.

const std = @import("std");

/// Upstream limits (protocol.h). Enforced by both client and server so a peer
/// cannot make us allocate unbounded buffers.
pub const max_path_len = 256;
pub const max_seat_len = 64;
pub const max_seat_devices = 128;
pub const max_session_len = 64;

/// Message opcodes. Client requests occupy 1..7. Server messages set the high
/// bit (upstream `SERVER_EVENT(x) == x + (1 << 15)`), so the two directions
/// never collide and a single enum can decode either side of the wire.
pub const Opcode = enum(u16) {
    client_open_seat = 1,
    client_close_seat = 2,
    client_open_device = 3,
    client_close_device = 4,
    client_disable_seat = 5,
    client_switch_session = 6,
    client_ping = 7,

    server_seat_opened = 0x8000 + 1,
    server_seat_closed = 0x8000 + 2,
    server_device_opened = 0x8000 + 3,
    server_device_closed = 0x8000 + 4,
    server_disable_seat = 0x8000 + 5,
    server_enable_seat = 0x8000 + 6,
    server_pong = 0x8000 + 7,
    server_session_switched = 0x8000 + 8,
    server_seat_disabled = 0x8000 + 9,
    server_error = 0x8000 + 0x7FFF,
    _,
};

/// Every message begins with this 4-byte header. `size` counts the body bytes
/// that follow (not the header, not any out-of-band fds).
pub const Header = extern struct {
    opcode: u16,
    size: u16,
};

// Bodies follow the header. `int` in upstream is a C `int`, which is 32-bit on
// every platform seatd targets, so we pin it to i32 to keep the layout fixed
// when cross-compiling.

pub const ClientOpenDevice = extern struct {
    path_len: u16,
    // A NUL-terminated path of `path_len` bytes follows.
};

pub const ClientCloseDevice = extern struct {
    device_id: i32,
};

pub const ClientSwitchSession = extern struct {
    session: i32,
};

pub const ServerSeatOpened = extern struct {
    seat_name_len: u16,
    // A NUL-terminated seat name of `seat_name_len` bytes follows.
};

pub const ServerDeviceOpened = extern struct {
    device_id: i32,
    // One fd travels in the ancillary data.
};

pub const ServerError = extern struct {
    error_code: i32,
};

test "opcode values match upstream protocol.h" {
    try std.testing.expectEqual(@as(u16, 1), @backingInt(Opcode.client_open_seat));
    try std.testing.expectEqual(@as(u16, 7), @backingInt(Opcode.client_ping));
    try std.testing.expectEqual(@as(u16, 0x8001), @backingInt(Opcode.server_seat_opened));
    try std.testing.expectEqual(@as(u16, 0x8008), @backingInt(Opcode.server_session_switched));
    try std.testing.expectEqual(@as(u16, 0xFFFF), @backingInt(Opcode.server_error));
}

test "struct sizes match the C wire layout" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(ClientOpenDevice));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ClientCloseDevice));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ClientSwitchSession));
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(ServerSeatOpened));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ServerDeviceOpened));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ServerError));
}
