const std = @import("std");
const mem = std.mem;
const os = std.os;
const heap = std.heap;
const log = std.log.scoped(.wayprompt);
const io = std.io;
const fmt = std.fmt;
const math = std.math;

const pixman = @import("pixman");

const ini = @import("ini.zig");
const pinentry = @import("pinentry.zig");
const cli = @import("cli.zig");

const Context = struct {
    loop: bool = true,
    gpa: heap.GeneralPurposeAllocator(.{}) = .{},

    background_colour: pixman.Color = pixmanColourFromRGB("0x666666") catch @compileError("Bad colour!"),
    border_colour: pixman.Color = pixmanColourFromRGB("0x333333") catch @compileError("Bad colour!"),
    text_colour: pixman.Color = pixmanColourFromRGB("0xffffff") catch @compileError("Bad colour!"),
    error_text_colour: pixman.Color = pixmanColourFromRGB("0xff0000") catch @compileError("Bad colour!"),
    pinarea_background_colour: pixman.Color = pixmanColourFromRGB("0x999999") catch @compileError("Bad colour!"),
    pinarea_border_colour: pixman.Color = pixmanColourFromRGB("0x7F7F7F") catch @compileError("Bad colour!"),
    pinarea_square_colour: pixman.Color = pixmanColourFromRGB("0xCCCCCC") catch @compileError("Bad colour!"),

    title: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    description: ?[]const u8 = null,
    errmessage: ?[]const u8 = null,

    // We may not have WAYLAND_DISPLAY in our env when we get started, or maybe
    // even a bad one. However the gpg-agent will likely send us its own.
    wayland_display: ?[:0]const u8 = null,

    /// Release all allocated objects.
    pub fn reset(self: *Context) void {
        const alloc = self.gpa.allocator();
        if (self.title) |t| {
            alloc.free(t);
            self.title = null;
        }
        if (self.prompt) |t| {
            alloc.free(t);
            self.prompt = null;
        }
        if (self.description) |t| {
            alloc.free(t);
            self.description = null;
        }
        if (self.errmessage) |t| {
            alloc.free(t);
            self.errmessage = null;
        }
        if (self.wayland_display) |t| {
            alloc.free(t);
            self.wayland_display = null;
        }
    }
};

pub var context: Context = .{};

pub fn main() !u8 {
    defer _ = context.gpa.deinit();
    defer context.reset();

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
        return try cli.main();
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

// Copied and adapted from https://git.sr.ht/~novakane/zelbar, same license.
fn pixmanColourFromRGB(descr: []const u8) !pixman.Color {
    if (descr.len != "0xRRGGBB".len) return error.BadColour;
    if (descr[0] != '0' or descr[1] != 'x') return error.BadColour;

    var color = try fmt.parseUnsigned(u32, descr[2..], 16);
    if (descr.len == 8) {
        color <<= 8;
        color |= 0xff;
    }

    const bytes = @bitCast([4]u8, color);

    const r: u16 = bytes[3];
    const g: u16 = bytes[2];
    const b: u16 = bytes[1];
    const a: u16 = bytes[0];

    return pixman.Color{
        .red = @as(u16, r << math.log2(0x101)) + r,
        .green = @as(u16, g << math.log2(0x101)) + g,
        .blue = @as(u16, b << math.log2(0x101)) + b,
        .alpha = @as(u16, a << math.log2(0x101)) + a,
    };
}
