//! The Linux `_IOC` request-number macros, in pure Zig. Device backends build
//! their ioctl request numbers from these instead of hardcoding hex, so the
//! layout is checked at comptime and cross-compiles with no C headers.
//!
//! Layout (asm-generic, used by every arch libseat targets): nr in bits 0-7,
//! type in bits 8-15, size in bits 16-29, dir in bits 30-31.

const std = @import("std");

const nr_bits = 8;
const type_bits = 8;
const size_bits = 14;

const nr_shift = 0;
const type_shift = nr_shift + nr_bits;
const size_shift = type_shift + type_bits;
const dir_shift = size_shift + size_bits;

pub const Dir = enum(u2) {
    none = 0,
    write = 1,
    read = 2,
    read_write = 3,
};

pub fn IOC(dir: Dir, io_type: u8, nr: u8, size: usize) u32 {
    return (@as(u32, @backingInt(dir)) << dir_shift) |
        (@as(u32, io_type) << type_shift) |
        (@as(u32, nr) << nr_shift) |
        (@as(u32, @intCast(size)) << size_shift);
}

pub fn IO(io_type: u8, nr: u8) u32 {
    return IOC(.none, io_type, nr, 0);
}

pub fn IOR(io_type: u8, nr: u8, comptime T: type) u32 {
    return IOC(.read, io_type, nr, @sizeOf(T));
}

pub fn IOW(io_type: u8, nr: u8, comptime T: type) u32 {
    return IOC(.write, io_type, nr, @sizeOf(T));
}

pub fn IOWR(io_type: u8, nr: u8, comptime T: type) u32 {
    return IOC(.read_write, io_type, nr, @sizeOf(T));
}

test "IO matches DRM master ioctl numbers" {
    // DRM_IOCTL_SET_MASTER = _IO(DRM_IOCTL_BASE 'd'==0x64, 0x1e)
    try std.testing.expectEqual(@as(u32, 0x641e), IO(0x64, 0x1e));
    try std.testing.expectEqual(@as(u32, 0x641f), IO(0x64, 0x1f));
}

test "IOW matches EVIOCREVOKE" {
    // EVIOCREVOKE = _IOW('E'==0x45, 0x91, int)
    try std.testing.expectEqual(@as(u32, 0x40044591), IOW(0x45, 0x91, i32));
}
