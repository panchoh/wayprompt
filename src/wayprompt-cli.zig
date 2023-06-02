const std = @import("std");
const os = std.os;
const mem = std.mem;
const heap = std.heap;
const debug = std.debug;
const io = std.io;
const meta = std.meta;

pub const log = @import("log.zig").log;
const logger = std.log.scoped(.wayprompt);

const Frontend = @import("Frontend.zig");
const SecretBuffer = @import("SecretBuffer.zig");
const Config = @import("Config.zig");

var getpin: bool = false;
var json: bool = false;

var gpa: heap.GeneralPurposeAllocator(.{}) = .{};
var arena: heap.ArenaAllocator = undefined;

pub fn main() !u8 {
    arena = heap.ArenaAllocator.init(gpa.allocator());
    defer _ = gpa.deinit();
    defer arena.deinit();

    var cfg: Config = .{
        .secbuf = undefined,
        .alloc = gpa.allocator(),
    };

    parseCmdFlags(&cfg) catch |err| {
        switch (err) {
            error.DumpedUsage => return 0,
            error.UnknownFlag,
            error.MissingArgument,
            error.RedundantFlag,
            => return 1,
            else => return err,
        }
    };

    if (!getpin) {
        if (cfg.prompt != null) {
            logger.err("you may not set a prompt when not querying for a password.", .{});
            return 1;
        }

        if (cfg.title == null and cfg.description == null and cfg.errmessage == null) {
            logger.err("at least one of title, description or error need to be set when not querying for a password.", .{});
            return 1;
        }
    }

    cfg.parse(gpa.allocator()) catch return 1;

    var secret: SecretBuffer = undefined;
    if (getpin) {
        secret = try SecretBuffer.new(gpa.allocator());
        cfg.secbuf = &secret;
    }
    defer if (getpin) secret.deinit(gpa.allocator());

    var frontend: Frontend = undefined;
    var fds: [1]os.pollfd = .{.{
        .fd = try frontend.init(&cfg),
        .events = os.POLL.IN,
        .revents = undefined,
    }};
    defer frontend.deinit();

    try frontend.enterMode(if (getpin) .getpin else .message);

    while (true) {
        {
            const ev = try frontend.flush();
            if (ev != .none) {
                switch (ev) {
                    .user_abort => try writeOutput("cancel", null),
                    .user_notok => try writeOutput("not-ok", null),
                    .user_ok => try writeOutput("ok", if (getpin) secret.slice() else null),
                    else => unreachable,
                }
                break;
            }
        }

        _ = try os.poll(&fds, -1);

        if (fds[0].revents & os.POLL.IN != 0) {
            const ev = try frontend.handleEvent();
            switch (ev) {
                .none => continue,
                .user_abort => try writeOutput("cancel", null),
                .user_notok => try writeOutput("not-ok", null),
                .user_ok => try writeOutput("ok", if (getpin) secret.slice() else null),
            }
            break;
        } else {
            try frontend.noEvent();
        }
    }
    _ = try frontend.flush();

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

fn parseCmdFlags(cfg: *Config) !void {
    const alloc = arena.allocator();

    var it = FlagIt.new(&os.argv);
    while (it.next()) |flag| {
        if (mem.eql(u8, flag, "--title")) {
            try dupeArg(alloc, &it, &cfg.title, "--title");
        } else if (mem.eql(u8, flag, "--description")) {
            try dupeArg(alloc, &it, &cfg.description, "--description");
        } else if (mem.eql(u8, flag, "--prompt")) {
            try dupeArg(alloc, &it, &cfg.prompt, "--prompt");
        } else if (mem.eql(u8, flag, "--error")) {
            try dupeArg(alloc, &it, &cfg.errmessage, "--error");
        } else if (mem.eql(u8, flag, "--wayland-display")) {
            try dupeArg(alloc, &it, &cfg.wayland_display, "--wayland-display");
        } else if (mem.eql(u8, flag, "--button-ok")) {
            try dupeArg(alloc, &it, &cfg.ok, "--button-ok");
        } else if (mem.eql(u8, flag, "--button-not-ok")) {
            try dupeArg(alloc, &it, &cfg.notok, "--button-not-ok");
        } else if (mem.eql(u8, flag, "--button-cancel")) {
            try dupeArg(alloc, &it, &cfg.cancel, "--button-cancel");
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
            logger.err("unknown flag: '{s}'", .{flag});
            return error.UnknownFlag;
        }
    }
}

fn dupeArg(alloc: mem.Allocator, it: *FlagIt, dest: *?[]const u8, comptime flag: []const u8) !void {
    if (dest.* != null) {
        logger.err("redundant '{s}' flag.", .{flag});
        return error.RedundantFlag;
    }
    dest.* = try alloc.dupe(u8, it.next() orelse {
        logger.err("flag '{s}' needs an argument.", .{flag});
        return error.MissingArgument;
    });
}
