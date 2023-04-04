const builtin = @import("builtin");
const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const os = std.os;
const io = std.io;
const fs = std.fs;
const fmt = std.fmt;
const debug = std.debug;
const log = std.log;

const Frontend = @import("../frontend.zig").Frontend;
const FrontendImpl = @import("../frontend.zig").FrontendImpl;

const context = &@import("wayprompt.zig").context;

var default_ok: ?[]const u8 = null;
var default_cancel: ?[]const u8 = null;
var default_yes: ?[]const u8 = null;
var default_no: ?[]const u8 = null;

var frontend: FrontendImpl = undefined;

pub fn main() !u8 {
    const stdout = io.getStdOut();
    const stdin = io.getStdIn();

    var _frontend = Frontend{};
    frontend = try _frontend.getInitFrontend();
    defer frontend.deinit();

    var fds: [2]os.pollfd = undefined;
    fds = .{
        .{
            .fd = stdin.handle,
            .events = os.POLL.IN,
            .revents = undefined,
        },
        .{
            .fd = frontend.getFd(),
            .events = os.POLL.IN,
            .revents = undefined,
        },
    };

    // Assuan messages are limited to 1000 bytes per spec. However,
    // documentation for the pinentry commands states that string can be up to
    // 2048 bytes long (it actually says "characters", but I assume bytes is
    // what they mean). Since realistically we are the ones sending long strings
    // (i.e. passwords with insane lengths), use a small buffer for input and a
    // default-sized (2048) buffer for outgoing messages.
    var in_buffer: [1024]u8 = undefined;
    var out_buffer = io.bufferedWriter(stdout.writer());

    try out_buffer.writer().writeAll("OK wayprompt is pleased to meet you\n");
    try out_buffer.flush();

    defer {
        const alloc = context.gpa.allocator();
        if (default_ok) |str| alloc.free(str);
        if (default_cancel) |str| alloc.free(str);
        if (default_yes) |str| alloc.free(str);
        if (default_no) |str| alloc.free(str);
    }

    while (context.loop) {
        _ = try os.poll(&fds, -1);
        if ((fds[0].revents & os.POLL.IN) > 0) {
            const read = try stdin.read(&in_buffer);
            if (read == 0) break;
            // Behold: We also read '\n', so let's get rid of that here handily by
            // just not including it in the slice.
            try parseInput(out_buffer.writer(), in_buffer[0 .. read - 1]);
            out_buffer.flush() catch |err| {
                // gpg-agent recently has become very eager to close the pipe after
                // sending "bye", so sending it an "OK" response will fail.
                if (context.loop == false and err == error.BrokenPipe) break;
                return err;
            };
        }
        if ((fds[1].revents & os.POLL.IN) > 0) {
            const ev = frontend.handleEvent catch return 1;
            switch (ev) {
                .none => {},
                else => {
                    // TODO XXX
                },
            }
        }
    }

    return 0;
}

fn parseInput(writer: io.BufferedWriter(4096, fs.File.Writer).Writer, line: []const u8) !void {
    // <rant>
    //   The protocol spoken between pinentry and the gpg-agent is a mess. It
    //   uses assuan as the wire protocol (who came up with that name?) which
    //   itself seems reasonable enough for something going through UNIX pipes,
    //   but for pinentry it got extended with additional commands. Nothing is
    //   consistent: Both direct requests as well as arguments to the OPTION
    //   request are used to set options. A server implementing this protocol
    //   is apparently not allowed to say it does not implement optional (!)
    //   requests, no it has to accept them even if it effectively just ignores
    //   them, despite there actually being a "no this is not implemented"
    //   response. Speaking of responses, there are just OK and errors. What?
    //   And errors use the gpg error format, which is ... weird and unwieldy.
    //   And when it comes to data responses, the pinentry program shipped with
    //   gpg just sends the "D string" events followed by OK. This actually goes
    //   against the assuan spec, which states that after the D event you have
    //   to send an END event before sending OK. And funnily enough, we actually
    //   have to do that, as the gpg-agent otherwise aborts. But apparently
    //   the default pinentry program gets away with it somehow? And the
    //   pinentry protocol documentation also says nothing about END? What?
    //   This protocol has clearly suffered severely from having only a single
    //   widely used implementation.
    // </rant>

    const alloc = context.gpa.allocator();
    var it = mem.tokenize(u8, line, &ascii.spaces);
    const command = it.next() orelse return;
    if (ascii.eqlIgnoreCase(command, "settitle")) {
        try setString(writer, "title", line["settitle".len..]);
    } else if (ascii.eqlIgnoreCase(command, "setprompt")) {
        try setString(writer, "prompt", line["setprompt".len..]);
    } else if (ascii.eqlIgnoreCase(command, "setdesc")) {
        try setString(writer, "description", line["setdesc".len..]);
    } else if (ascii.eqlIgnoreCase(command, "seterror")) {
        try setString(writer, "errmessage", line["seterror".len..]);
    } else if (ascii.eqlIgnoreCase(command, "setok")) {
        try setString(writer, "ok", line["setok ".len..]);
    } else if (ascii.eqlIgnoreCase(command, "setnotok")) {
        try setString(writer, "notok", line["setnotok ".len..]);
    } else if (ascii.eqlIgnoreCase(command, "setcancel")) {
        try setString(writer, "cancel", line["setcancel ".len..]);
    } else if (ascii.eqlIgnoreCase(command, "getpin")) {
        // TODO it's possible that the gpg-apgent requests us to ask for the
        //      pin twice (f.e. when the user creates a new one, I imagine).
        //      This needs support in the UI.
        try getPin(writer);
    } else if (ascii.eqlIgnoreCase(command, "confirm")) {
        // TODO this can optionally have the "--one-button" option, in which
        //      case it effectively functions like MESSAGE.
        try confirm(writer);
    } else if (ascii.eqlIgnoreCase(command, "message")) {
        try message(writer);
    } else if (ascii.eqlIgnoreCase(command, "getinfo")) {
        if (it.next()) |info| {
            if (ascii.eqlIgnoreCase(info, "flavor")) {
                try writer.writeAll("D wayprompt\nEND\n");
            } else if (ascii.eqlIgnoreCase(info, "version")) {
                try writer.writeAll("D 0.0.0\nEND\n");
            } else if (ascii.eqlIgnoreCase(info, "pid")) {
                if (builtin.os.tag == .linux) {
                    try writer.print("D {}\n", .{os.linux.getpid()});
                }
                // TODO Get pid on other systems. Do other systems even use GPG
                //      and pinentry programs?
            }
        }
        try writer.writeAll("OK\n");
    } else if (ascii.eqlIgnoreCase(command, "bye")) {
        context.loop = false;
        try writer.writeAll("OK\n");
    } else if (ascii.eqlIgnoreCase(command, "option")) {
        if (it.next()) |option| {
            if (getOption("putenv=WAYLAND_DISPLAY=", option, line)) |o| {
                if (context.wayland_display) |w| alloc.free(w);
                context.wayland_display = try alloc.dupeZ(u8, o);
            } else if (getOption("ttyname=", option, line)) |o| {
                if (context.tty_name) |w| alloc.free(w);
                context.tty_name = try alloc.dupeZ(u8, o);
            } else if (getOption("default-ok=", option, line)) |o| {
                if (default_ok) |w| alloc.free(w);
                default_ok = try pinentryDupe(o, true);
            } else if (getOption("default-cancel=", option, line)) |o| {
                if (default_cancel) |w| alloc.free(w);
                default_cancel = try pinentryDupe(o, true);
            } else if (getOption("default-yes=", option, line)) |o| {
                if (default_yes) |w| alloc.free(w);
                default_yes = try pinentryDupe(o, true);
            } else if (getOption("default-no=", option, line)) |o| {
                if (default_no) |w| alloc.free(w);
                default_no = try pinentryDupe(o, true);
            }
        }
        // Most options are internationalisation for features we don't offer.
        // Unfortunately we have to pretend to accept them. If we ever decide
        // to actually check the validity of the options, the error message for
        // unknown ones would be: "ERR 83886254 Unknown option".
        try writer.writeAll("OK\n");
    } else if (ascii.eqlIgnoreCase(command, "reset")) {
        context.reset();
        try writer.writeAll("OK\n");
    } else if (ascii.eqlIgnoreCase(command, "setkeyinfo")) {
        // This request sets a key identifier to be used for key-caching
        // mechanism (like for example the keyring daemons employed by some
        // desktop environments). We do not provide this feature (yet? would be
        // neat to have some himitsu integration here), however we unfortunately
        // can not simply respond with "ERR 536870981" (used for unimplemented
        // requests) because the gpg-agent will then abort. So let's just
        // pretend we accept this value and silently ignore it.
        try writer.writeAll("OK\n");
    } else if (ascii.eqlIgnoreCase(command, "cancel") or
        ascii.eqlIgnoreCase(command, "setgenpin") or // Undocumented, but present in "default" pinentry.
        ascii.eqlIgnoreCase(command, "setgenpin_tt") or // Undocumented, but present in "default" pinentry.
        ascii.eqlIgnoreCase(command, "settimeout") or // TODO timeout before aborting the prompt and returning an error.
        ascii.eqlIgnoreCase(command, "end") or
        ascii.eqlIgnoreCase(command, "quit") or // Specified as reserved for future use cases.
        ascii.eqlIgnoreCase(command, "auth") or // Specified as reserved for future use cases.
        ascii.eqlIgnoreCase(command, "cancel") or // Specified as reserved for future use cases.
        ascii.eqlIgnoreCase(command, "clearpassphrase") or // Undocumented, but present in "default" pinentry.
        ascii.eqlIgnoreCase(command, "setrepeat") or // TODO prompt twice for the password, compare them and only accept when equal.
        ascii.eqlIgnoreCase(command, "setrepeaterror") or
        // A qualitybar is technically easy to implement: The argument to the
        // command is the text next to the bar, which we'd probably ignore.
        // If set, we can send "INQUIRE QUALITY <pin>" after every keypress and
        // the client will respond with "<integer>\nEND\n". Would require doing
        // so in the wayland event loop though.
        ascii.eqlIgnoreCase(command, "setqualitybar") or
        ascii.eqlIgnoreCase(command, "setqualitybar_tt"))
    {
        try writer.writeAll("ERR 536870981 Not implemented\n");
    } else if (ascii.eqlIgnoreCase(command, "nop")) {
        try writer.writeAll("OK\n");
    } else if (ascii.eqlIgnoreCase(command, "help")) {
        try writer.writeAll(
            \\# NOP
            \\# SETTITLE
            \\# SETPROMPT
            \\# SETDESC
            \\# SETERROR
            \\# GETPIN
            \\# BYE
            \\# OPTION
            \\# RESET
            \\OK
            \\
        );
    } else {
        try writer.writeAll("ERR 536871187 Unknown IPC command\n");
    }
}

fn getPin(writer: anytype) !void {
    // If we don't have buttons defined, use the default ones. Note: This
    // transfers ownership of the string. This means they will be freed when
    // context is deinit'd.
    if (context.ok == null and default_ok != null) {
        context.ok = default_ok.?;
        default_ok = null;
    }
    if (context.cancel == null and default_cancel != null) {
        context.cancel = default_cancel.?;
        default_cancel = null;
    }

    const alloc = context.gpa.allocator();

    if (wayland.run(true)) |pin| {
        try dumpPin(writer, pin);
    } else |err| {
        // TODO error.UserNotOk should be handled here as well
        // The client will ignore all messages starting with #, however they
        // should still be logged by the gpg-agent, given that the right
        // debug options are enabled. This means we can use this to insert
        // arbitrary messages into the logs and therefore have proper error
        // logging.
        //
        // Technically there is a difference between pressing enter on an
        // empty prompt and the user aborting. However, gpg-agent apparently
        // treats both equally. We do it properly of course, because we're
        // pedantic. Anyway, that's why error.UserAbort exists and why we
        // don't print it because it's not /really/ an error.
        if (err == error.NoWaylandDisplay or err == error.ConnectFailed) {
            log.err("error while attempting to display wayland prompt: '{}'. Switching to TTY fallback.", .{err});
            if (tty.run(true)) |pin| {
                try dumpPin(writer, pin);
            } else |e| {
                if (e != error.UserAbort and e != error.UserNotOk) {
                    log.err("error while attempting to display TTY prompt: '{}'", .{e});
                }
                try errMessage(writer, e);
            }
        } else {
            if (err != error.UserAbort and err != error.UserNotOk) {
                log.err("error while attempting to display wayland prompt: '{}'", .{err});
            }
            try errMessage(writer, err);
        }
    }

    // The errormessage must automatically reset after every GETPIN or
    // CONFIRM action.
    if (context.errmessage) |e| {
        alloc.free(e);
        context.errmessage = null;
    }
}

fn dumpPin(writer: anytype, pin: ?[]const u8) !void {
    const alloc = context.gpa.allocator();
    if (pin) |p| {
        defer alloc.free(p);
        try writer.print("D {s}\nEND\nOK\n", .{p});
    } else {
        try writer.writeAll("OK\n");
    }
}

fn message(writer: anytype) !void {
    if (context.title == null and context.description == null and context.errmessage == null) {
        try writer.writeAll("OK\n");
        return;
    }

    if (wayland.run(false)) |ret| {
        debug.assert(ret == null);
        try writer.writeAll("OK\n");
    } else |err| {
        if (err == error.NoWaylandDisplay or err == error.ConnectFailed) {
            log.err("error while attempting to display wayland message: '{}'. Switching to TTY fallback.", .{err});
            if (tty.run(false)) |r| {
                debug.assert(r == null);
                try writer.writeAll("OK\n");
            } else |e| {
                if (e != error.UserAbort and e != error.UserNotOk) {
                    log.err("error while attempting to display TTY message: '{}'", .{e});
                }
                try errMessage(writer, e);
            }
        } else {
            if (err != error.UserAbort and err != error.UserNotOk) {
                log.err("error while attempting to display wayland message: '{}'", .{err});
            }
            try errMessage(writer, err);
        }
    }
}

fn confirm(writer: anytype) !void {
    // If we don't have buttons defined, use the default ones. Note: This
    // transfers ownership of the string. This means they will be freed when
    // context is deinit'd.
    if (context.ok == null and default_yes != null) {
        context.ok = default_yes.?;
        default_yes = null;
    }
    if (context.cancel == null and default_no != null) {
        context.cancel = default_no.?;
        default_no = null;
    }

    if (wayland.run(false)) |ret| {
        debug.assert(ret == null);
        try writer.writeAll("OK\n");
    } else |err| {
        if (err == error.NoWaylandDisplay or err == error.ConnectFailed) {
            log.err("error while attempting to display wayland confirm: '{}'. Switching to TTY fallback.", .{err});
            if (tty.run(false)) |r| {
                debug.assert(r == null);
                try writer.writeAll("OK\n");
            } else |e| {
                if (e != error.UserAbort and e != error.UserNotOk) {
                    log.err("error while attempting to display TTY confirm: '{}'", .{e});
                }
                try errMessage(writer, e);
            }
        } else {
            if (err != error.UserAbort and err != error.UserNotOk) {
                log.err("error while attempting to display wayland confirm: '{}'", .{err});
            }
            try errMessage(writer, err);
        }
    }

    // The errormessage must automatically reset after every GETPIN or
    // CONFIRM action.
    if (context.errmessage) |e| {
        const alloc = context.gpa.allocator();
        alloc.free(e);
        context.errmessage = null;
    }
}

// TODO the name of this function is confusing, find a better one
fn errMessage(writer: anytype, err: anyerror) !void {
    switch (err) {
        error.UserAbort => try writer.writeAll("ERR 83886179 Operation cancelled\n"),
        error.UserNotOk => try writer.writeAll("ERR 83886194 not confirmed\n"),
        else => {
            try writer.print("# Error: {s}\n", .{@errorName(err)});
            try writer.writeAll("ERR 83886179 Operation cancelled\n");
        },
    }
}

fn setString(writer: anytype, comptime name: []const u8, value: []const u8) !void {
    const alloc = context.gpa.allocator();
    if (@field(context.*, name)) |f| {
        @field(context.*, name) = null;
        alloc.free(f);
    }
    @field(context.*, name) = try pinentryDupe(value, false);
    try writer.writeAll("OK\n");
}

fn getOption(comptime opt: []const u8, arg: []const u8, line: []const u8) ?[]const u8 {
    if (mem.startsWith(u8, arg, opt)) {
        return line["option ".len + opt.len ..];
    }
    return null;
}

/// Some characters are escaped in assuan messages.
fn pinentryDupe(str: []const u8, button: bool) ![]const u8 {
    const alloc = context.gpa.allocator();

    var len: usize = str.len;
    for (str) |ch| {
        if (ch == '%') len -= 2;
        if (ch == '_' and button) len -= 1;
    }

    const dupe = try alloc.alloc(u8, len);
    errdefer alloc.free(dupe);

    var i: usize = 0;
    var j: usize = 0;
    while (i < str.len and j < dupe.len) {
        if (str[i] == '%') {
            if (str.len < i + 3) return error.BadInput;
            dupe[j] = try fmt.parseInt(u8, str[i + 1 .. i + 3], 16);
            i += 3;
            j += 1;
        } else if (str[i] == '_' and button) {
            i += 1;
        } else {
            dupe[j] = str[i];
            i += 1;
            j += 1;
        }
    }

    return dupe;
}
