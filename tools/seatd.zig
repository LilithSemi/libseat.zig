//! The standalone seatd daemon: binds a unix socket and serves the seatd wire
//! protocol to clients (compositors using the seatd backend).
//!
//! Configuration comes from the environment (via std.process.Init):
//!   SEATD_SOCK     socket path (default /run/seatd.sock)
//!   SEATD_VTBOUND  "0" for a non-VT-bound seat (default: VT-bound)
//!
//! Once listening it writes a newline to stdout as a readiness signal, which
//! seatd-launch waits for.

const std = @import("std");
const libseat = @import("libseat");
const daemon = libseat.daemon;

pub fn main(init: std.process.Init) u8 {
    const sock = init.environ_map.get("SEATD_SOCK") orelse "/run/seatd.sock";
    const vt_bound = if (init.environ_map.get("SEATD_VTBOUND")) |v| !std.mem.eql(u8, v, "0") else true;

    var linux_vt = daemon.LinuxVt{};
    var server = daemon.Server.init(init.gpa, .{ .vt_bound = vt_bound, .vt = linux_vt.interface() }) catch {
        return fail(init.io, "seatd: server init failed\n");
    };
    defer server.deinit();

    server.listenUnix(sock) catch {
        return fail(init.io, "seatd: could not listen on socket\n");
    };

    // Announce readiness now that the socket is accepting connections.
    writeAll(init.io, std.Io.File.stdout(), "\n");

    server.run();
    return 0;
}

fn writeAll(io: std.Io, file: std.Io.File, msg: []const u8) void {
    var buf: [256]u8 = undefined;
    var w = file.writer(io, &buf);
    w.interface.writeAll(msg) catch return;
    w.interface.flush() catch return;
}

fn fail(io: std.Io, msg: []const u8) u8 {
    writeAll(io, std.Io.File.stderr(), msg);
    return 1;
}
