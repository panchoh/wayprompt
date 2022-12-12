const std = @import("std");
const debug = std.debug;
const os = std.os;
const io = std.io;
const math = std.math;
const unicode = std.unicode;
const spoon = @import("spoon");

const context = &@import("wayprompt.zig").context;

const SecretBuffer = @import("SecretBuffer.zig");

const LineIterator = struct {
    in: ?[]const u8,

    pub fn from(input: []const u8) LineIterator {
        return .{ .in = input };
    }

    pub fn next(self: *LineIterator) ?[]const u8 {
        if (self.in == null) return null;
        if (self.in.?.len == 0) return null;
        if (self.in.?.len == 1 and self.in.?[0] == '\n') return null;
        var i: usize = 0;
        for (self.in.?) |byte| {
            if (byte == '\n') {
                defer self.in = self.in.?[i + 1 ..];
                return self.in.?[0..i];
            }
            i += 1;
        }
        defer self.in = null;
        return self.in.?;
    }
};

const TtyContext = struct {
    term: spoon.Term = undefined,
    loop: bool = true,
    getpin: bool = false,
    exit_reason: ?anyerror = null,

    pin: SecretBuffer = undefined,

    pub fn run(self: *TtyContext, getpin: bool) !?[]const u8 {
        self.pin = try SecretBuffer.new();
        defer self.pin.deinit();

        self.getpin = getpin;

        // Only try to fall back to TTY mode when a TTY is set.
        if (context.tty_name) |name| {
            try self.term.init(.{ .tty_name = name });
        } else {
            return error.NoTTYNameSet;
        }
        defer self.term.deinit();

        os.sigaction(os.SIG.WINCH, &os.Sigaction{
            .handler = .{ .handler = handleSigWinch },
            .mask = os.empty_sigset,
            .flags = 0,
        }, null);
        try self.term.uncook(.{});
        defer self.term.cook() catch {};

        try self.term.fetchSize();
        if (context.title) |t| {
            try self.term.setWindowTitle("wayprompt TTY fallback: {s}", .{t});
        } else {
            try self.term.setWindowTitle("wayprompt TTY fallback", .{});
        }
        try self.render();

        var fds: [1]os.pollfd = undefined;
        fds[0] = .{
            .fd = self.term.tty.handle,
            .events = os.POLL.IN,
            .revents = undefined,
        };

        var buf: [32]u8 = undefined;
        while (self.loop) {
            _ = try os.poll(&fds, -1);
            const read = try self.term.readInput(&buf);
            var it = spoon.inputParser(buf[0..read]);
            while (it.next()) |in| {
                if (in.eqlDescription("enter")) {
                    self.loop = false;
                } else if (in.eqlDescription("C-c")) {
                    if (context.notok == null) {
                        self.abort(error.UserAbort);
                    } else {
                        self.abort(error.UserNotOk);
                    }
                } else if (in.eqlDescription("backspace")) {
                    self.pin.deleteBackwards();
                    try self.render();
                } else if (in.eqlDescription("escape")) {
                    self.abort(error.UserAbort);
                } else if (self.getpin and in.content == .codepoint) {
                    if (in.mod_alt or in.mod_ctrl or in.mod_super) continue;
                    const cp = in.content.codepoint;

                    // We can safely reuse the buffer here.
                    const len = unicode.utf8Encode(cp, &buf) catch continue;
                    self.pin.appendSlice(buf[0..len]) catch {};

                    try self.render();
                }
            }
        }

        if (self.exit_reason) |reason| {
            return reason;
        } else if (self.getpin) {
            return try self.pin.copySlice();
        } else {
            debug.assert(self.pin.len == 0);
            return null;
        }
    }

    fn abort(self: *TtyContext, reason: anyerror) void {
        self.loop = false;
        self.exit_reason = reason;
    }

    fn render(self: *TtyContext) !void {
        var rc = try self.term.getRenderContext();
        defer rc.done() catch {};
        try rc.clear();

        if (self.term.width < 5 or self.term.height < 5) {
            try rc.setAttribute(.{ .fg = .red, .bold = true });
            try rc.writeAllWrapping("Terminal too small!");
            return;
        }

        var line: usize = 0;

        if (context.title) |title| try self.renderContent(&rc, title, .{ .bg = .green, .bold = true, .fg = .black }, &line);
        if (context.description) |description| try self.renderContent(&rc, description, .{}, &line);
        if (context.prompt) |prompt| try self.renderContent(&rc, prompt, .{ .bold = true }, &line);

        if (self.getpin) {
            try rc.setAttribute(.{ .bold = true });
            try rc.moveCursorTo(line, 0);
            var rpw = rc.restrictedPaddingWriter(self.term.width);
            const writer = rpw.writer();
            try writer.writeAll(" > ");
            try writer.writeByteNTimes('*', math.min(context.pin_square_amount, self.pin.len));
            try writer.writeByteNTimes('_', context.pin_square_amount -| self.pin.len);
            try rpw.finish();
            line += 2;
        }

        if (context.errmessage) |errmessage| try self.renderContent(&rc, errmessage, .{ .bold = true, .fg = .red }, &line);

        if (context.ok) |ok| try self.renderButton(&rc, "enter", ok, &line);
        if (context.notok) |notok| try self.renderButton(&rc, "C-c", notok, &line);
        if (context.cancel) |cancel| try self.renderButton(&rc, "escape", cancel, &line);
    }

    fn renderContent(self: *TtyContext, rc: *spoon.Term.RenderContext, str: []const u8, attr: spoon.Attribute, line: *usize) !void {
        try rc.setAttribute(attr);
        var it = LineIterator.from(str);
        while (it.next()) |l| {
            if (line.* >= self.term.height) return;
            try rc.moveCursorTo(line.*, 0);
            var rpw = rc.restrictedPaddingWriter(self.term.width);
            const writer = rpw.writer();
            try writer.writeByte(' ');
            try writer.writeAll(l);
            if (attr.bg != .none) {
                try rpw.pad();
            } else {
                try rpw.finish();
            }
            line.* += 1;
        }
        line.* += 1;
    }

    fn renderButton(self: *TtyContext, rc: *spoon.Term.RenderContext, comptime button: []const u8, str: []const u8, line: *usize) !void {
        var first = line.*;
        try rc.setAttribute(.{});
        try rc.moveCursorTo(line.*, 0);
        var it = LineIterator.from(str);
        while (it.next()) |l| {
            if (line.* >= self.term.height) return;
            try rc.moveCursorTo(line.*, 0);
            var rpw = rc.restrictedPaddingWriter(self.term.width);
            const writer = rpw.writer();
            try writer.writeByte(' ');
            if (line.* == first) {
                try writer.writeAll(button);
                try writer.writeAll(": ");
            } else {
                try writer.writeByteNTimes(' ', button.len + ": ".len);
            }
            try writer.writeAll(l);
            try rpw.finish();
            line.* += 1;
        }
    }

    fn handleSigWinch(_: c_int) callconv(.C) void {
        tty_context.term.fetchSize() catch {};
        tty_context.render() catch {};
    }
};

var tty_context: TtyContext = undefined;

/// Returned pin is owned by context.gpa.
pub fn run(getpin: bool) !?[]const u8 {
    tty_context = .{};
    return (try tty_context.run(getpin));
}
