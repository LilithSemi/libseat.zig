//! Environment lookup by reading /proc/self/environ directly. This Zig build
//! exposes the process environment only through an Io/thread abstraction, so we
//! read the kernel-provided file instead: pure Linux, no libc, works the same
//! when statically linked or cross-compiled.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

/// Copy the value of `key` into `buf` and return the slice, or null if the
/// variable is unset, the environment is unreadable, or the value exceeds `buf`.
pub fn get(buf: []u8, key: []const u8) ?[]const u8 {
    const fd_rc = linux.openat(linux.AT.FDCWD, "/proc/self/environ", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (posix.errno(fd_rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var total: [16384]u8 = undefined;
    var n: usize = 0;
    while (n < total.len) {
        const rn = posix.read(fd, total[n..]) catch return null;
        if (rn == 0) break;
        n += rn;
    }

    var it = std.mem.splitScalar(u8, total[0..n], 0);
    while (it.next()) |entry| {
        if (entry.len > key.len and entry[key.len] == '=' and std.mem.eql(u8, entry[0..key.len], key)) {
            const val = entry[key.len + 1 ..];
            if (val.len > buf.len) return null;
            @memcpy(buf[0..val.len], val);
            return buf[0..val.len];
        }
    }
    return null;
}

/// True if `key` is set to exactly `value`.
pub fn eql(key: []const u8, value: []const u8) bool {
    var buf: [256]u8 = undefined;
    const v = get(&buf, key) orelse return false;
    return std.mem.eql(u8, v, value);
}

test "env reads a variable that the test process inherits" {
    // PATH is present in almost every environment. If somehow absent, skip.
    var buf: [4096]u8 = undefined;
    const v = get(&buf, "PATH") orelse return error.SkipZigTest;
    try std.testing.expect(v.len > 0);
    try std.testing.expect(get(&buf, "LIBSEAT_DEFINITELY_UNSET_VAR_XYZ") == null);
}
