const builtin = @import("builtin");
const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const os = std.os;
const io = std.io;
const fs = std.fs;
const fmt = std.fmt;
const debug = std.debug;

const wayland = @import("wayland.zig");

const context = &@import("wayprompt.zig").context;

pub fn main() !u8 {
    const stdout = io.getStdOut();
    const stdin = io.getStdIn();

    var fds: [1]os.pollfd = undefined;
    fds[0] = .{
        .fd = stdin.handle,
        .events = os.POLL.IN,
        .revents = undefined,
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

    while (context.loop) {
        _ = try os.poll(&fds, -1);
        const read = try stdin.read(&in_buffer);
        if (read == 0) break;
        // Behold: We also read '\n', so let's get rid of that here handily by
        // just not including it in the slice.
        try parseInput(out_buffer.writer(), in_buffer[0 .. read - 1]);
        try out_buffer.flush();
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
        if (context.title) |p| {
            context.title = null;
            alloc.free(p);
        }
        if (it.next()) |_| context.title = try pinentryDupe(line["settitle ".len..]);
        try writer.writeAll("OK\n");
    } else if (ascii.eqlIgnoreCase(command, "setprompt")) {
        if (context.prompt) |p| {
            context.prompt = null;
            alloc.free(p);
        }
        if (it.next()) |_| context.prompt = try pinentryDupe(line["setprompt ".len..]);
        try writer.writeAll("OK\n");
    } else if (ascii.eqlIgnoreCase(command, "setdesc")) {
        if (context.description) |d| {
            context.description = null;
            alloc.free(d);
        }
        if (it.next()) |_| context.description = try pinentryDupe(line["setdesc ".len..]);
        try writer.writeAll("OK\n");
    } else if (ascii.eqlIgnoreCase(command, "seterror")) {
        if (context.errmessage) |e| {
            context.errmessage = null;
            alloc.free(e);
        }
        if (it.next()) |_| context.errmessage = try pinentryDupe(line["seterror ".len..]);
        try writer.writeAll("OK\n");
    } else if (ascii.eqlIgnoreCase(command, "getpin")) {
        // TODO it's possible that the gpg-apgent requests us to ask for the
        //      pin twice (f.e. when the user creates a new one, I imagine).
        //      This needs support in the UI.
        const pin = wayland.run(.getpin) catch |err| {
            // The client will ignore all messages starting with #, however they
            // should still be logged by the gpg-agent, given that the right
            // debug options are enabled. This means we can use this to insert
            // arbitrary messages into the logs and therefore have proper error
            // logging.
            try writer.print("# Error: {s}\n", .{@errorName(err)});
            try writer.writeAll("ERR 83886179 Operation cancelled\n");
            return;
        };
        // TODO don't send OK when escape is pressed, instead send "ERR 83886179 cancelled"
        if (pin) |p| {
            defer alloc.free(p);
            try writer.print("D {s}\nEND\nOK\n", .{p});
        } else {
            // Sending no pin is also a valid response.
            try writer.writeAll("OK\n");
        }

        // The errormessage must automatically reset after every GETPIN or
        // CONFIRM action.
        if (context.errmessage) |e| {
            alloc.free(e);
            context.errmessage = null;
        }
    } else if (ascii.eqlIgnoreCase(command, "confirm")) {
        // TODO XXX Wayland widget
        // TODO this can optionally have the "--one-button" option, in which
        //      case it effectively functions like MESSAGE.
        try writer.writeAll("OK\n");

        // TODO Message when notok button is clicked: "ERR 83886194 not confirmed"
        // TODO Message when cancel button is clicked: "ERR 83886179 cancelled"

        // The errormessage must automatically reset after every GETPIN or
        // CONFIRM action.
        if (context.errmessage) |e| {
            alloc.free(e);
            context.errmessage = null;
        }
    } else if (ascii.eqlIgnoreCase(command, "message")) {
        if (context.title != null or
            context.description != null or
            context.errmessage != null)
        {
            if (wayland.run(.message)) |ret| {
                debug.assert(ret == null);
            } else |err| {
                try writer.print("# Error: {s}\n", .{@errorName(err)});
            }
        }
        try writer.writeAll("OK\n");
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
            const option_wayland = "putenv=WAYLAND_DISPLAY=";
            if (mem.startsWith(u8, option, option_wayland)) {
                if (context.wayland_display) |w| alloc.free(w);
                context.wayland_display = try alloc.dupeZ(u8, line["option ".len + option_wayland.len ..]);
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
    } else if (ascii.eqlIgnoreCase(command, "setok") or
        ascii.eqlIgnoreCase(command, "setnotok") or // TODO if this is set, a third button should be displayed, which returns a different error than cancel
        ascii.eqlIgnoreCase(command, "setcancel"))
    {
        // TODO implement?
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

/// Some characters are escaped in assuan messages.
fn pinentryDupe(str: []const u8) ![]const u8 {
    const alloc = context.gpa.allocator();

    var len: usize = str.len;
    for (str) |ch| {
        if (ch == '%') len -= 2;
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
        } else {
            dupe[j] = str[i];
            i += 1;
        }
        j += 1;
    }

    return dupe;
}
