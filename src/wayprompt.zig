const std = @import("std");
const mem = std.mem;
const os = std.os;
const heap = std.heap;
const log = std.log.scoped(.wayprompt);
const io = std.io;

const ini = @import("ini.zig");
const pinentry = @import("pinentry.zig");

const Context = struct {
    loop: bool = true,
    gpa: heap.GeneralPurposeAllocator(.{}) = .{},
};

pub var context: Context = .{};

pub fn main() !u8 {
    defer _ = context.gpa.deinit();

    const exec_name = blk: {
        const full_command_name = mem.span(os.argv[0]);
        var i: usize = full_command_name.len - 1;
        while (i > 0) : (i -= 1) {
            if (full_command_name[i] == '/') {
                break :blk full_command_name[i + 1 ..];
            }
        }
        break :blk full_command_name;
    };

    if (mem.startsWith(u8, exec_name, "pinentry")) {
        return try pinentry.main();
    } else if (mem.startsWith(u8, exec_name, "hiprompt")) {
        @panic("TODO");
    } else if (mem.eql(u8, exec_name, "wayprompt-cli")) {
        @panic("TODO");
    } else {
        const stdout = io.getStdOut();
        var out_buffer = io.bufferedWriter(stdout.writer());
        const writer = out_buffer.writer();
        try writer.writeAll(
            \\wayprompt - multi-purpose prompter for Wayland
            \\
            \\To use as a pinentry replacement, run as 'pinentry-wayprompt'.
            \\To use as a himitsu prompter, run as 'hiprompt-wayprompt'.
            \\To use as a generic prompter for scripts, run as 'wayprompt-cli'.
            \\
            \\Read wayprompt(1) for further information.
            \\
        );
        try out_buffer.flush();
    }

    return 0;
}
