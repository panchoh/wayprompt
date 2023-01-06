const std = @import("std");
const zbs = std.build;
const mem = std.mem;
const ascii = std.ascii;
const fmt = std.fmt;

const ScanProtocolsStep = @import("deps/zig-wayland/build.zig").ScanProtocolsStep;

pub fn build(b: *zbs.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const options = b.addOptions();

    const scanner = ScanProtocolsStep.create(b);
    scanner.addProtocolPath("protocol/wlr-layer-shell-unstable-v1.xml");
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.generate("wl_compositor", 5);
    scanner.generate("wl_shm", 1);
    scanner.generate("zwlr_layer_shell_v1", 3);
    scanner.generate("xdg_wm_base", 5); // Needed as a dependency of the layershell.
    scanner.generate("wl_seat", 8);
    scanner.generate("wl_output", 4);

    const wayprompt = b.addExecutable("wayprompt", "src/wayprompt.zig");
    wayprompt.setTarget(target);
    wayprompt.setBuildMode(mode);
    wayprompt.addOptions("build_options", options);

    wayprompt.addPackagePath("spoon", "deps/zig-spoon/import.zig");

    const pixman = std.build.Pkg{
        .name = "pixman",
        .path = .{ .path = "deps/zig-pixman/pixman.zig" },
    };
    wayprompt.addPackage(pixman);
    wayprompt.linkSystemLibrary("pixman-1");

    const fcft = std.build.Pkg{
        .name = "fcft",
        .path = .{ .path = "deps/zig-fcft/fcft.zig" },
        .dependencies = &[_]std.build.Pkg{pixman},
    };
    wayprompt.addPackage(fcft);
    wayprompt.linkSystemLibrary("fcft");

    wayprompt.addPackagePath("xkbcommon", "deps/zig-xkbcommon/src/xkbcommon.zig");
    wayprompt.linkSystemLibrary("xkbcommon");

    wayprompt.step.dependOn(&scanner.step);
    wayprompt.addPackage(.{
        .name = "wayland",
        .path = .{ .generated = &scanner.result },
    });
    wayprompt.linkLibC();
    wayprompt.linkSystemLibrary("wayland-client");
    wayprompt.linkSystemLibrary("wayland-cursor");

    scanner.addCSource(wayprompt);

    wayprompt.install();
}
