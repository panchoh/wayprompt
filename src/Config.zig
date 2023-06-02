const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const os = std.os;
const fmt = std.fmt;
const meta = std.meta;
const math = std.math;
const log = std.log.scoped(.config);

const pixman = @import("pixman");

const ini = @import("ini.zig");
const SecretBuffer = @import("SecretBuffer.zig");

const Config = @This();

allow_tty_fallback: bool = false,
secbuf: *SecretBuffer,
alloc: mem.Allocator,

// General UI config.
title: ?[]const u8 = null,
description: ?[]const u8 = null,
prompt: ?[]const u8 = null,
errmessage: ?[]const u8 = null,
notok: ?[]const u8 = null,
ok: ?[]const u8 = null,
cancel: ?[]const u8 = null,
pin_square_amount: u31 = 16,

// TTY specific config.
tty_name: ?[:0]const u8 = null,

// Wayland specific config.
wayland_display: ?[:0]const u8 = null,
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
vertical_padding: u31 = 10,
horizontal_padding: u31 = 15,
button_inner_padding: u31 = 5,
pin_square_size: u31 = 18,
pin_square_border: u31 = 1,
button_border: u31 = 1,
border: u31 = 2,

/// Frees all memory using provided allocator.
pub fn reset(self: *Config, alloc: mem.Allocator) void {
    if (self.title) |str| {
        self.title = null;
        alloc.free(str);
    }
    if (self.description) |str| {
        self.description = null;
        alloc.free(str);
    }
    if (self.prompt) |str| {
        self.prompt = null;
        alloc.free(str);
    }
    if (self.errmessage) |str| {
        self.errmessage = null;
        alloc.free(str);
    }
    if (self.notok) |str| {
        self.notok = null;
        alloc.free(str);
    }
    if (self.ok) |str| {
        self.ok = null;
        alloc.free(str);
    }
    if (self.cancel) |str| {
        self.cancel = null;
        alloc.free(str);
    }
    if (self.tty_name) |str| {
        self.tty_name = null;
        alloc.free(str);
    }
    if (self.wayland_display) |str| {
        self.wayland_display = null;
        alloc.free(str);
    }
}

/// Note that the allocator is only needed for temporary allocations.
pub fn parse(self: *Config, alloc: mem.Allocator) !void {
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
            log.err("{s}:{}: Syntax error.", .{ path, line });
            return error.BadConfig;
        } else {
            return err;
        }
    }) |content| {
        switch (content) {
            .section => |sect| section = blk: {
                const sec = meta.stringToEnum(Section, sect);
                if (sec == null or sec.? == .none) {
                    log.err("{s}:{}: Unknown section '{s}'.", .{ path, line, sect });
                    return error.BadConfig;
                }
                break :blk sec.?;
            },
            .assign => |as| switch (section) {
                .none => {
                    log.err("{s}:{}: Assignments must be part of a section.", .{ path, line });
                    return error.BadConfig;
                },
                .general => self.assignGeneral(as.variable, as.value) catch |err| {
                    log.err("{s}:{}: Invalid unsigned integer: '{s}', {}", .{ path, line, as.value, err });
                    return error.BadConfig;
                },

                .colours => self.assignColour(as.variable, as.value) catch |err| {
                    switch (err) {
                        error.BadColour => log.err("{s}:{}: Bad colour: '{s}'", .{ path, line, as.value }),
                        error.UnknownColour => log.err("{s}:{}: Unknown colour: '{s}'", .{ path, line, as.variable }),
                        else => log.err("{s}:{}: Error while parsing colour: '{s}': {}", .{ path, line, as.variable, err }),
                    }
                    return error.BadConfig;
                },
            },
        }
    }
}

fn assignGeneral(self: *Config, variable: []const u8, value: []const u8) !void {
    if (mem.eql(u8, variable, "vertical-padding")) {
        self.vertical_padding = try fmt.parseInt(u31, value, 10);
    } else if (mem.eql(u8, variable, "horizontal-padding")) {
        self.horizontal_padding = try fmt.parseInt(u31, value, 10);
    } else if (mem.eql(u8, variable, "button-inner-padding")) {
        self.button_inner_padding = try fmt.parseInt(u31, value, 10);
    } else if (mem.eql(u8, variable, "pin-square-size")) {
        self.pin_square_size = try fmt.parseInt(u31, value, 10);
    } else if (mem.eql(u8, variable, "pin-square-amount")) {
        self.pin_square_amount = try fmt.parseInt(u31, value, 10);
    } else if (mem.eql(u8, variable, "pin-square-border")) {
        self.pin_square_border = try fmt.parseInt(u31, value, 10);
    } else if (mem.eql(u8, variable, "button-border")) {
        self.button_border = try fmt.parseInt(u31, value, 10);
    } else if (mem.eql(u8, variable, "border")) {
        self.border = try fmt.parseInt(u31, value, 10);
    }
}

fn assignColour(self: *Config, variable: []const u8, value: []const u8) !void {
    if (mem.eql(u8, variable, "background")) {
        self.background_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "border")) {
        self.border_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "text")) {
        self.text_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "error-text")) {
        self.error_text_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "pin-background")) {
        self.pinarea_background_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "pin-border")) {
        self.pinarea_border_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "pin-square")) {
        self.pinarea_square_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "ok-button")) {
        self.ok_button_background_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "notok-button")) {
        self.notok_button_background_colour = try pixmanColourFromRGB(value);
    } else if (mem.eql(u8, variable, "cancel-button")) {
        self.cancel_button_background_colour = try pixmanColourFromRGB(value);
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
