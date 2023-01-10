const std = @import("std");
const os = std.os;
const mem = std.mem;
const debug = std.debug;
const io = std.io;
const meta = std.meta;
const log = std.log.scoped(.wayprompt);

const wayland = @import("wayland.zig");
const context = &@import("wayprompt.zig").context;

var getpin: bool = false;
var json: bool = false;

pub fn main() !u8 {
    parseCmdFlags() catch |err| {
        switch (err) {
            error.DumpedUsage => return 0,
            error.UnknownFlag, error.MissingArgument => return 1,
            else => return err,
        }
    };

    if (!getpin) {
        if (context.prompt != null) {
            log.err("you may not set a prompt when not querying for a password.", .{});
            return 1;
        }

        if (context.title == null and context.description == null and context.errmessage == null) {
            log.err("at least one of title, description or error need to be set when not querying for a password.", .{});
            return 1;
        }
    }

    if (wayland.run(getpin)) |pin_maybe_null| {
        try writeOutput("ok", pin_maybe_null);
        if (pin_maybe_null) |pin| context.gpa.allocator().free(pin);
    } else |err| {
        switch (err) {
            error.UserAbort => try writeOutput("cancel", null),
            error.UserNotOk => try writeOutput("not-ok", null),
            else => {
                log.err("unexpected error: {}", .{err});
                return 1;
            },
        }
    }

    return 0;
}

fn writeOutput(comptime action: []const u8, pin: ?[]const u8) !void {
    const stdout = io.getStdOut();
    var out_buffer = io.bufferedWriter(stdout.writer());
    const writer = out_buffer.writer();

    if (json) {
        try writer.writeAll("{\n");
        try writer.writeAll("    \"user-action\": \"" ++ action ++ "\"");
        if (pin) |p| {
            debug.assert(getpin);
            try writer.print(",\n    \"pin\": \"{s}\"\n", .{p});
        } else if (getpin) {
            try writer.writeAll(",\n    \"pin\": null\n");
        } else {
            try writer.writeAll("\n");
        }
        try writer.writeAll("}\n");
    } else {
        try writer.writeAll("user-action: " ++ action ++ "\n");
        if (pin) |p| {
            debug.assert(getpin);
            try writer.print("pin: {s}\n", .{p});
        } else if (getpin) {
            try writer.writeAll("no pin\n");
        }
    }

    try out_buffer.flush();
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
        } else if (mem.eql(u8, flag, "--get-pin")) {
            getpin = true;
        } else if (mem.eql(u8, flag, "--json")) {
            json = true;
        } else if (mem.eql(u8, flag, "--help") or mem.eql(u8, flag, "-h")) {
            const stdout = io.getStdOut();
            var out_buffer = io.bufferedWriter(stdout.writer());
            try out_buffer.writer().print(
                \\Usage: {s} [options..]
                \\--title             Set the window title
                \\--description       Set the description text.
                \\--prompt            Set the prompt. Can only be used with '--get-pin'.
                \\--error             Set the error message.
                \\--button-ok         Display the ok button with the provided Text.
                \\--button-no-ok      Display the not-ok button with the provided Text.
                \\--button-cancel     Display the cancel button with the provided Text.
                \\--wayland-display   Set the WAYLAND_DISPLAY to be used.
                \\--get-pin           Query for a password.
                \\--json              Format output (except error messages) in JSON.
                \\--help, -h          Dump help text and exit.
                \\
                \\Run as 'pinentry-wayprompt' to use as pinentry replacement.
                \\Run as 'hiprompt-wayprompt' to use as himitsu prompter.
                \\
                \\See wayprompt.1 for more information.
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
