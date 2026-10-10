//! seatd-launch: start a private seatd, wait until it is listening, then run the
//! target command with SEATD_SOCK pointed at it, dropping privileges to the
//! invoking user. Meant to be installed setuid-root.
//!
//! Uses std.process.Init for args/env and std.process.spawn for the children.

const std = @import("std");
const linux = std.os.linux;

const default_sock = "/run/seatd.sock";

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const gpa = init.gpa;

    // The target command is our args after argv[0] and an optional "--".
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // skip argv[0]
    var past_sep = false;
    while (it.next()) |arg| {
        if (!past_sep and std.mem.eql(u8, arg, "--")) {
            past_sep = true;
            continue;
        }
        argv.append(gpa, arg) catch return fail(io, "seatd-launch: out of memory\n");
    }
    if (argv.items.len == 0) return fail(io, "seatd-launch: a command must be specified\n");

    const sock = init.environ_map.get("SEATD_SOCK") orelse default_sock;

    // Locate the co-installed seatd binary.
    const dir = std.process.executableDirPathAlloc(io, gpa) catch return fail(io, "seatd-launch: cannot find own path\n");
    defer gpa.free(dir);
    const seatd_path = std.fmt.allocPrint(gpa, "{s}/seatd", .{dir}) catch return fail(io, "seatd-launch: out of memory\n");
    defer gpa.free(seatd_path);

    // Both children see SEATD_SOCK.
    init.environ_map.put("SEATD_SOCK", sock) catch return fail(io, "seatd-launch: out of memory\n");

    // Start seatd and wait for its readiness newline on stdout.
    var seatd_child = std.process.spawn(io, .{
        .argv = &.{seatd_path},
        .environ_map = init.environ_map,
        .stdout = .pipe,
    }) catch return fail(io, "seatd-launch: could not start seatd\n");

    var rbuf: [8]u8 = undefined;
    var reader = seatd_child.stdout.?.readerStreaming(io, &rbuf);
    var one: [1]u8 = undefined;
    const n = reader.interface.readSliceShort(&one) catch 0;
    if (n == 0) {
        _ = seatd_child.wait(io) catch {};
        return fail(io, "seatd-launch: seatd exited before becoming ready\n");
    }

    const uid = linux.getuid();
    const gid = linux.getgid();

    // Restrict the socket to the invoking user. Best effort, matters when setuid.
    var sockz: [257]u8 = undefined;
    if (sock.len < sockz.len) {
        @memcpy(sockz[0..sock.len], sock);
        sockz[sock.len] = 0;
        _ = linux.fchownat(linux.AT.FDCWD, @ptrCast(&sockz), uid, gid, 0);
        _ = linux.fchmodat(linux.AT.FDCWD, @ptrCast(&sockz), 0o700);
    }

    // Run the target with privileges dropped to the invoking user.
    var target = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = init.environ_map,
        .uid = uid,
        .gid = gid,
    }) catch {
        seatd_child.kill(io);
        return fail(io, "seatd-launch: could not start target\n");
    };

    const term = target.wait(io) catch {
        seatd_child.kill(io);
        return fail(io, "seatd-launch: could not wait for target\n");
    };
    seatd_child.kill(io); // tear down our private seatd

    return switch (term) {
        .exited => |code| code,
        .signal => |s| 128 +% @as(u8, @truncate(@backingInt(s))),
        else => 1,
    };
}

fn fail(io: std.Io, msg: []const u8) u8 {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.writeAll(msg) catch return 1;
    w.interface.flush() catch return 1;
    return 1;
}
