const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dbus_dep = b.dependency("dbus", .{ .target = target, .optimize = optimize });

    const libseat_mod = b.addModule("libseat", .{
        .root_source_file = b.path("src/libseat.zig"),
        .target = target,
        .optimize = optimize,
    });
    libseat_mod.addImport("dbus", dbus_dep.module("dbus"));

    const test_step = b.step("test", "Run tests");
    const libseat_tests = b.addTest(.{ .root_module = libseat_mod });
    test_step.dependOn(&b.addRunArtifact(libseat_tests).step);

    const seatd_exe = b.addExecutable(.{
        .name = "seatd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/seatd.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    seatd_exe.root_module.addImport("libseat", libseat_mod);
    b.installArtifact(seatd_exe);

    const launch_exe = b.addExecutable(.{
        .name = "seatd-launch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/seatd-launch.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(launch_exe);
}
