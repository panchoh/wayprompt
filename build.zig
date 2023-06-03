const std = @import("std");
const zbs = std.build;
const mem = std.mem;
const ascii = std.ascii;
const fmt = std.fmt;

const ScanProtocolsStep = @import("deps/zig-wayland/build.zig").ScanProtocolsStep;

pub fn build(b: *zbs.Builder) !void {
    const mode = b.standardReleaseOptions();
    const options = b.addOptions();
    const target = b.standardTargetOptions(.{});

    const scanner = ScanProtocolsStep.create(b);
    scanner.addProtocolPath("protocol/wlr-layer-shell-unstable-v1.xml");
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.generate("wl_compositor", 5);
    scanner.generate("wl_shm", 1);
    scanner.generate("zwlr_layer_shell_v1", 3);
    scanner.generate("xdg_wm_base", 5); // Needed as a dependency of the layershell.
    scanner.generate("wl_seat", 8);
    scanner.generate("wl_output", 4);

    const wayprompt_cli = b.addExecutable("wayprompt", "src/wayprompt-cli.zig");
    wayprompt_cli.setTarget(target);
    wayprompt_cli.setBuildMode(mode);
    wayprompt_cli.addOptions("build_options", options);
    try exeSetup(scanner, wayprompt_cli);

    const wayprompt_pinentry = b.addExecutable("pinentry-wayprompt", "src/wayprompt-pinentry.zig");
    wayprompt_pinentry.setTarget(target);
    wayprompt_pinentry.setBuildMode(mode);
    wayprompt_pinentry.addOptions("build_options", options);
    try exeSetup(scanner, wayprompt_pinentry);

    b.installFile("doc/wayprompt.1", "share/man/man1/wayprompt.1");
    b.installFile("doc/pinentry-wayprompt.1", "share/man/man1/pinentry-wayprompt.1");
    b.installFile("doc/wayprompt.5", "share/man/man5/wayprompt.5");
}

fn exeSetup(scanner: *ScanProtocolsStep, exe: *zbs.LibExeObjStep) !void {
    exe.addPackagePath("spoon", "deps/zig-spoon/import.zig");

    const pixman = std.build.Pkg{
        .name = "pixman",
        .source = .{ .path = "deps/zig-pixman/pixman.zig" },
    };
    exe.addPackage(pixman);
    exe.linkSystemLibrary("pixman-1");

    const fcft = std.build.Pkg{
        .name = "fcft",
        .source = .{ .path = "deps/zig-fcft/fcft.zig" },
        .dependencies = &[_]std.build.Pkg{pixman},
    };
    exe.addPackage(fcft);
    exe.linkSystemLibrary("fcft");

    exe.addPackagePath("xkbcommon", "deps/zig-xkbcommon/src/xkbcommon.zig");
    exe.linkSystemLibrary("xkbcommon");

    exe.step.dependOn(&scanner.step);
    exe.addPackage(.{
        .name = "wayland",
        .source = .{ .generated = &scanner.result },
    });
    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("wayland-cursor");

    scanner.addCSource(exe);

    exe.install();
}
