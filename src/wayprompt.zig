const std = @import("std");
const mem = std.mem;
const os = std.os;
const heap = std.heap;
const logger = std.log;
const io = std.io;
const fmt = std.fmt;
const math = std.math;
const fs = std.fs;
const meta = std.meta;
const c = @cImport({
    @cInclude("syslog.h");
});

const pixman = @import("pixman");

const ini = @import("ini.zig");
const pinentry = @import("pinentry.zig");
const cli = @import("cli.zig");

const Context = struct {
    syslog: bool = false,
    loop: bool = true,
    gpa: heap.GeneralPurposeAllocator(.{}) = .{},

    background_colour: pixman.Color = pixmanColourFromRGB("0xffffff") catch @compileError("Bad colour!"),
    border_colour: pixman.Color = pixmanColourFromRGB("0x000000") catch @compileError("Bad colour!"),
    text_colour: pixman.Color = pixmanColourFromRGB("0x000000") catch @compileError("Bad colour!"),
    error_text_colour: pixman.Color = pixmanColourFromRGB("0xe0002b") catch @compileError("Bad colour!"),
    pinarea_background_colour: pixman.Color = pixmanColourFromRGB("0xd0d0d0") catch @compileError("Bad colour!"),
    pinarea_border_colour: pixman.Color = pixmanColourFromRGB("0x000000") catch @compileError("Bad colour!"),
    pinarea_square_colour: pixman.Color = pixmanColourFromRGB("0x808080") catch @compileError("Bad colour!"),
    ok_button_background_colour: pixman.Color = pixmanColourFromRGB("0xd5f200") catch @compileError("Bad colour!"),
    notok_button_background_colour: pixman.Color = pixmanColourFromRGB("0xffe53e") catch @compileError("Bad colour!"),
    cancel_button_background_colour: pixman.Color = pixmanColourFromRGB("0xff4647") catch @compileError("Bad colour!"),

    title: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    description: ?[]const u8 = null,
    errmessage: ?[]const u8 = null,
    ok: ?[]const u8 = null,
    notok: ?[]const u8 = null,
    cancel: ?[]const u8 = null,

    vertical_padding: u31 = 10,
    horizontal_padding: u31 = 15,
    button_inner_padding: u31 = 5,
    pin_square_size: u31 = 18,
    pin_square_amount: u31 = 16,
    pin_square_border: u31 = 1,
    button_border: u31 = 1,
    border: u31 = 2,

    // We may not have WAYLAND_DISPLAY in our env when we get started, or maybe
    // even a bad one. However the gpg-agent will likely send us its own.
    wayland_display: ?[:0]const u8 = null,
    tty_name: ?[:0]const u8 = null,

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
        if (self.ok) |t| {
            alloc.free(t);
            self.ok = null;
        }
        if (self.notok) |t| {
            alloc.free(t);
            self.notok = null;
        }
        if (self.cancel) |t| {
            alloc.free(t);
            self.cancel = null;
        }
        if (self.wayland_display) |t| {
            alloc.free(t);
            self.wayland_display = null;
        }
        if (self.tty_name) |t| {
            alloc.free(t);
            self.tty_name = null;
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
        context.syslog = true;
        parseConfig() catch return 1;
        return pinentry.main() catch |err| {
            logger.err("unexpected error: '{}'", .{err});
            return 1;
        };
    } else if (mem.startsWith(u8, exec_name, "hiprompt")) {
        @panic("TODO");
    } else {
        context.syslog = false;
        parseConfig() catch return 1;
        return try cli.main();
    }

    return 0;
}

fn parseConfig() !void {
    const alloc = context.gpa.allocator();
    const path = blk: {
        if (os.getenv("XDG_CONFIG_HOME")) |xdg_config_home| {
            break :blk try fs.path.join(alloc, &[_][]const u8{
                xdg_config_home,
                "wayprompt/config.ini",
            });
        } else if (os.getenv("HOME")) |home| {
            break :blk try fs.path.join(alloc, &[_][]const u8{
                home,
                ".config/wayprompt/config.ini",
            });
        } else {
            break :blk try alloc.dupe(u8, "/etc/wayprompt/config.ini");
        }
    };
    defer alloc.free(path);
    os.access(path, os.R_OK) catch return;
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    const Section = enum { none, general, colours };
    var section: Section = .none;

    var buffer = std.io.bufferedReader(file.reader());
    var it = ini.tokenize(buffer.reader());
    var line: usize = 0;
    while (it.next(&line) catch |err| {
        if (err == error.InvalidLine) {
            logger.err("{s}:{}: Syntax error.", .{ path, line });
            return error.BadConfig;
        } else {
            return err;
        }
    }) |content| {
        switch (content) {
            .section => |sect| section = blk: {
                const sec = meta.stringToEnum(Section, sect);
                if (sec == null or sec.? == .none) {
                    logger.err("{s}:{}: Unknown section '{}'.", .{ path, line, sec.? });
                    return error.BadConfig;
                }
                break :blk sec.?;
            },
            .assign => |as| switch (section) {
                .none => {
                    logger.err("{s}:{}: Assignments must be part of a section.", .{ path, line });
                    return error.BadConfig;
                },
                .general => assignGeneral(as.variable, as.value) catch |err| {
                    logger.err("{s}:{}: Invalid unsigned integer: '{s}', {}", .{ path, line, as.value, err });
                    return error.BadConfig;
                },

                .colours => assignColour(as.variable, as.value) catch |err| {
                    switch (err) {
                        error.BadColour => logger.err("{s}:{}: Bad colour: '{s}'", .{ path, line, as.value }),
                        error.UnknownColour => logger.err("{s}:{}: Unknown colour: '{s}'", .{ path, line, as.variable }),
                        else => logger.err("{s}:{}: Error while parsing colour: '{s}': {}", .{ path, line, as.variable, err }),
                    }
                    return error.BadConfig;
                },
            },
        }
    }
}

fn assignGeneral(variable: []const u8, value: []const u8) !void {
    if (mem.eql(u8, variable, "vertical-padding")) {
        context.vertical_padding = try fmt.parseInt(u31, value, 10);
    } else if (mem.eql(u8, variable, "horizontal-padding")) {
        context.horizontal_padding = try fmt.parseInt(u31, value, 10);
    } else if (mem.eql(u8, variable, "button-inner-padding")) {
        context.button_inner_padding = try fmt.parseInt(u31, value, 10);
    } else if (mem.eql(u8, variable, "pin-square-size")) {
        context.pin_square_size = try fmt.parseInt(u31, value, 10);
    } else if (mem.eql(u8, variable, "pin-square-amount")) {
        context.pin_square_amount = try fmt.parseInt(u31, value, 10);
    } else if (mem.eql(u8, variable, "pin-square-border")) {
        context.pin_square_border = try fmt.parseInt(u31, value, 10);
    } else if (mem.eql(u8, variable, "button-border")) {
        context.button_border = try fmt.parseInt(u31, value, 10);
    } else if (mem.eql(u8, variable, "border")) {
        context.border = try fmt.parseInt(u31, value, 10);
    }
}

fn assignColour(variable: []const u8, value: []const u8) !void {
    if (mem.eql(u8, variable, "background")) {
        context.background_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "border")) {
        context.border_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "text")) {
        context.text_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "error-text")) {
        context.error_text_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "pin-background")) {
        context.pinarea_background_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "pin-border")) {
        context.pinarea_border_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "pin-square")) {
        context.pinarea_square_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "ok-button")) {
        context.ok_button_background_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "notok-button")) {
        context.notok_button_background_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "cancel-button")) {
        context.cancel_button_background_colour = try pixmanColourFromRGB(value);
    } else {
        return error.UnknownColour;
    }
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

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime level.asText();
    const prefix = if (scope == .default) "[wayprompt] " else "[wayprompt, " ++ @tagName(scope) ++ "] ";
    const format_full = prefix ++ level_txt ++ ": " ++ format ++ "\n";

    if (context.syslog) {
        nosuspend syslog(level, format_full, args) catch return;
    } else {
        const stderr = std.io.getStdErr().writer();
        nosuspend stderr.print(format_full, args) catch return;
    }
}

fn syslog(
    level: logger.Level,
    comptime format: []const u8,
    args: anytype,
) !void {
    const priority = switch (level) {
        .debug => c.LOG_DEBUG,
        .err => c.LOG_ERR,
        .warn => c.LOG_WARNING,
        .info => c.LOG_INFO,
    };
    var buf: [1024]u8 = undefined;
    const str = try fmt.bufPrintZ(&buf, format, args);
    c.syslog(priority, str.ptr);
}
