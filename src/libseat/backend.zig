//! Backend selection glue: a tagged union over the concrete backends, so the
//! public `Seat` can hold whichever one `open` picked and dispatch calls to it
//! without knowing which is active.

const types = @import("types.zig");
const seatd = @import("backend/seatd.zig");
const logind = @import("backend/logind.zig");

const Error = types.Error;
const Device = types.Device;

pub const Kind = enum { seatd, logind };

/// Whichever concrete backend `Seat.open` selected. The builtin backend produces
/// a `seatd` variant (it just talks to a forked embedded server).
pub const Backend = union(Kind) {
    seatd: *seatd.Backend,
    logind: *logind.Backend,

    pub fn close(self: Backend) void {
        switch (self) {
            .seatd => |b| b.close(),
            .logind => |b| b.close(),
        }
    }

    pub fn seatName(self: Backend) []const u8 {
        return switch (self) {
            .seatd => |b| b.seatName(),
            .logind => |b| b.seatName(),
        };
    }

    pub fn pollFd(self: Backend) i32 {
        return switch (self) {
            .seatd => |b| b.pollFd(),
            .logind => |b| b.pollFd(),
        };
    }

    pub fn openDevice(self: Backend, path: []const u8) Error!Device {
        return switch (self) {
            .seatd => |b| b.openDevice(path),
            .logind => |b| b.openDevice(path),
        };
    }

    pub fn closeDevice(self: Backend, device_id: i32) Error!void {
        return switch (self) {
            .seatd => |b| b.closeDevice(device_id),
            .logind => |b| b.closeDevice(device_id),
        };
    }

    pub fn switchSession(self: Backend, session: i32) Error!void {
        return switch (self) {
            .seatd => |b| b.switchSession(session),
            .logind => |b| b.switchSession(session),
        };
    }

    pub fn disable(self: Backend) Error!void {
        return switch (self) {
            .seatd => |b| b.disable(),
            .logind => |b| b.disable(),
        };
    }

    pub fn dispatch(self: Backend, timeout_ms: i32) Error!usize {
        return switch (self) {
            .seatd => |b| b.dispatch(timeout_ms),
            .logind => |b| b.dispatch(timeout_ms),
        };
    }
};
