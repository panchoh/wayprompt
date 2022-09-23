const std = @import("std");
const os = std.os;
const mem = std.mem;
const debug = std.debug;
const io = std.io;
const meta = std.meta;
const log = std.log.scoped(.wayprompt);

const wayland = @import("wayland.zig");
const context = &@import("wayprompt.zig").context;

var mode: wayland.WaylandContext.Mode = .getpin;

pub fn main() !u8 {
    parseCmdFlags() catch |err| {
        switch (err) {
            error.DumpedUsage => return 0,
            error.UnknownFlag, error.MissingArgument, error.BadArgument => return 1,
            else => return err,
        }
    };

    if (mode == .message or mode == .confirm) {
        if (context.prompt != null) {
            log.err("you can not set a prompt for message and confirm modes.'", .{});
            return 1;
        }
        if (context.title == null and context.description == null and context.errmessage == null) {
            log.err("at least one of title, description or error need to be set for message and confirm modes.", .{});
            return 1;
        }
    }

    const pin = wayland.run(mode) catch |err| {
        if (err == error.UserAbort) return 2; // TODO document exit codes?
        log.err("failed to run: {}", .{err});
        return 1;
    };

    if (pin) |p| {
        debug.assert(mode == .getpin);
        const alloc = context.gpa.allocator();
        defer alloc.free(p);

        // TODO maybe optional JSON output? Can be better parsed and the no-pin
        //      state would be less ambigous.

        const stdout = io.getStdOut();
        var out_buffer = io.bufferedWriter(stdout.writer());
        try out_buffer.writer().print("{s}\n", .{p});
        try out_buffer.flush();
    }

    return 0;
}

fn parseCmdFlags() !void {
    const FlagIt = struct {
        const Self = @This();

        argv: *[][*:0]u8,
        index: usize = 1,

        pub fn new(argv: *[][*:0]u8) Self {
            return Self{ .argv = argv };
        }

        pub fn next(self: *Self) ?[]const u8 {
            if (self.index >= self.argv.len) return null;
            defer self.index += 1;
            return mem.span(self.argv.*[self.index]);
        }
    };

    const alloc = context.gpa.allocator();

    var it = FlagIt.new(&os.argv);
    while (it.next()) |flag| {
        if (mem.eql(u8, flag, "--title")) {
            if (context.title) |title| alloc.free(title);
            context.title = try alloc.dupe(u8, it.next() orelse {
                log.err("flag '--title' needs an argument.", .{});
                return error.MissingArgument;
            });
        } else if (mem.eql(u8, flag, "--description")) {
            if (context.description) |description| alloc.free(description);
            context.description = try alloc.dupe(u8, it.next() orelse {
                log.err("flag '--description' needs an argument.", .{});
                return error.MissingArgument;
            });
        } else if (mem.eql(u8, flag, "--prompt")) {
            if (context.prompt) |prompt| alloc.free(prompt);
            context.prompt = try alloc.dupe(u8, it.next() orelse {
                log.err("flag '--prompt' needs an argument.", .{});
                return error.MissingArgument;
            });
        } else if (mem.eql(u8, flag, "--error")) {
            if (context.errmessage) |errmessage| alloc.free(errmessage);
            context.errmessage = try alloc.dupe(u8, it.next() orelse {
                log.err("flag '--error' needs an argument.", .{});
                return error.MissingArgument;
            });
        } else if (mem.eql(u8, flag, "--wayland-display")) {
            if (context.wayland_display) |wayland_display| alloc.free(wayland_display);
            context.wayland_display = try alloc.dupeZ(u8, it.next() orelse {
                log.err("flag '--wayland-display' needs an argument.", .{});
                return error.MissingArgument;
            });
        } else if (mem.eql(u8, flag, "--button-ok")) {
            if (context.ok) |ok| alloc.free(ok);
            context.ok = try alloc.dupeZ(u8, it.next() orelse {
                log.err("flag '--button-ok' needs an argument.", .{});
                return error.MissingArgument;
            });
        } else if (mem.eql(u8, flag, "--button-not-ok")) {
            if (context.notok) |notok| alloc.free(notok);
            context.notok = try alloc.dupeZ(u8, it.next() orelse {
                log.err("flag '--button-not-ok' needs an argument.", .{});
                return error.MissingArgument;
            });
        } else if (mem.eql(u8, flag, "--button-cancel")) {
            if (context.cancel) |cancel| alloc.free(cancel);
            context.cancel = try alloc.dupeZ(u8, it.next() orelse {
                log.err("flag '--button-cancel' needs an argument.", .{});
                return error.MissingArgument;
            });
        } else if (mem.eql(u8, flag, "--mode")) {
            const m = it.next() orelse {
                log.err("flag '--mode' needs an argument.", .{});
                return error.MissingArgument;
            };
            mode = meta.stringToEnum(wayland.WaylandContext.Mode, m) orelse {
                log.err("unknown mode '{s}', valid modes are 'getpin', 'message' and 'confirm' .", .{m});
                return error.BadArgument;
            };
        } else if (mem.eql(u8, flag, "--help") or mem.eql(u8, flag, "-h")) {
            const stdout = io.getStdOut();
            var out_buffer = io.bufferedWriter(stdout.writer());
            try out_buffer.writer().print(
                \\Usage: {s} [options..]
                \\--title             Set the window title
                \\--prompt            Set the prompt.
                \\--error             Set the error message.
                \\--wayland-display   Set the WAYLAND_DISPLAY to be used.
                \\--mode              Set the mode. May be 'getpin', 'message' or 'confirm'.
                \\--button-ok         Text of the ok button.
                \\--button-no-ok      Text of the not ok button.
                \\--button-cancel     Text of the cancel button.
                \\--help, -h          Dump help text and exit.
                \\
            , .{os.argv[0]});
            try out_buffer.flush();
            return error.DumpedUsage;
        } else {
            log.err("unknown flag: '{s}'", .{flag});
            return error.UnknownFlag;
        }
    }
}
