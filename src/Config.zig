const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const os = std.os;
const fmt = std.fmt;
const meta = std.meta;
const math = std.math;
const debug = std.debug;
const log = std.log.scoped(.config);

const pixman = @import("pixman");

const ini = @import("ini.zig");
const SecretBuffer = @import("SecretBuffer.zig");

const Config = @This();

/// Contents of labels.
/// Populated at runtime.
const Labels = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    err_message: ?[]const u8 = null,
    not_ok: ?[]const u8 = null,
    ok: ?[]const u8 = null,
    cancel: ?[]const u8 = null,
};

/// Colours used for Wayland frontend.
/// Populated by configuration file.
const WaylandColours = struct {
    background: pixman.Color = pixmanColourFromRGB("0xffffff") catch @compileError("Bad colour!"),
    border: pixman.Color = pixmanColourFromRGB("0x000000") catch @compileError("Bad colour!"),
    text: pixman.Color = pixmanColourFromRGB("0x000000") catch @compileError("Bad colour!"),
    error_text: pixman.Color = pixmanColourFromRGB("0xe0002b") catch @compileError("Bad colour!"),
    pin_background: pixman.Color = pixmanColourFromRGB("0xd0d0d0") catch @compileError("Bad colour!"),
    pin_border: pixman.Color = pixmanColourFromRGB("0x000000") catch @compileError("Bad colour!"),
    pin_square: pixman.Color = pixmanColourFromRGB("0x808080") catch @compileError("Bad colour!"),
    ok_button: pixman.Color = pixmanColourFromRGB("0xd5f200") catch @compileError("Bad colour!"),
    not_ok_button: pixman.Color = pixmanColourFromRGB("0xffe53e") catch @compileError("Bad colour!"),
    cancel_button: pixman.Color = pixmanColourFromRGB("0xff4647") catch @compileError("Bad colour!"),

    fn assign(self: *WaylandColours, path: []const u8, line: usize, variable: []const u8, value: []const u8) error{BadConfig}!bool {
        const info = @typeInfo(WaylandColours).Struct;
        inline for (info.fields) |field| {
            if (fieldEql(field.name, variable)) {
                debug.assert(@TypeOf(@field(self, field.name)) == pixman.Color);
                @field(self, field.name) = pixmanColourFromRGB(value) catch |err| {
                    switch (err) {
                        error.BadColour => log.err("{s}:{}: Bad colour: '{s}'", .{ path, line, value }),
                        else => log.err("{s}:{}: Error while parsing colour: '{s}': {}", .{ path, line, variable, err }),
                    }
                    return error.BadConfig;
                };
                return true;
            }
        }
        return false;
    }
};

/// UI dimensions for Wayland frontend.
/// Populated by configuration file.
const WaylandUi = struct {
    vertical_padding: u31 = 10,
    horizontal_padding: u31 = 15,
    button_inner_padding: u31 = 5,
    pin_square_size: u31 = 18,
    pin_square_border: u31 = 1,
    button_border: u31 = 1,
    border: u31 = 2,
    pin_square_amount: u31 = 16,

    font_regular: ?[:0]u8 = null,
    font_large: ?[:0]u8 = null,

    fn reset(self: *WaylandUi, alloc: mem.Allocator) void {
        if (self.font_regular) |p| {
            alloc.free(p);
            self.font_regular = null;
        }
        if (self.font_large) |p| {
            alloc.free(p);
            self.font_large = null;
        }
    }

    fn assign(self: *WaylandUi, alloc: mem.Allocator, path: []const u8, line: usize, variable: []const u8, value: []const u8) error{ BadConfig, OutOfMemory }!bool {
        const info = @typeInfo(WaylandUi).Struct;
        inline for (info.fields) |field| {
            if (fieldEql(field.name, variable)) {
                // TODO[zig]: inline switch
                switch (@TypeOf(@field(self, field.name))) {
                    u31 => {
                        @field(self, field.name) = fmt.parseInt(u31, value, 10) catch |err| {
                            log.err("{s}:{}: Invalid positive integer: '{s}', {}", .{ path, line, value, err });
                            return error.BadConfig;
                        };
                    },
                    ?[:0]u8 => {
                        if (@field(self, field.name)) |p| {
                            alloc.free(p);
                            @field(self, field.name) = null;
                        }
                        @field(self, field.name) = alloc.dupeZ(u8, value) catch {
                            log.err("{s}:{}: Parsing value for '{s}': Failed to allocate memory for string: '{s}'", .{ path, line, variable, value });
                            return error.OutOfMemory;
                        };
                    },
                    else => @compileError("You forgot to write parsing code for this :)"),
                }
                return true;
            }
        }
        return false;
    }
};

labels: Labels = .{},
wayland_colours: WaylandColours = .{},
wayland_ui: WaylandUi = .{},

/// General process configuration stuff. Note that that alloc may be different
/// from the allocator used for labels and other configuration things.
/// Populated at runtime.
allow_tty_fallback: bool = false,
secbuf: *SecretBuffer,
alloc: mem.Allocator,

/// Explicit names of TTY and wayland display socket to connect to. Used for
/// example in the pinentry version, where our process may not have these and
/// as such they are provided by the gpg-agent.
/// Populated at runtime.
tty_name: ?[:0]const u8 = null,
wayland_display: ?[:0]const u8 = null,

/// Frees all memory using provided allocator.
pub fn reset(self: *Config, alloc: mem.Allocator) void {
    self.wayland_ui.reset(alloc);
    const info = @typeInfo(@TypeOf(self.labels)).Struct;
    inline for (info.fields) |field| {
        if (@field(self.labels, field.name)) |str| {
            @field(self.labels, field.name) = null;
            alloc.free(str);
        }
    }
}

/// Note that the allocator is only needed for temporary allocations.
pub fn parse(self: *Config, alloc: mem.Allocator) !void {
    const path = try getConfigPath(alloc);
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
                .general => try self.assignGeneral(alloc, path, line, as.variable, as.value),
                .colours => try self.assignColour(path, line, as.variable, as.value),
            },
        }
    }
}

fn getConfigPath(alloc: mem.Allocator) ![]const u8 {
    if (os.getenv("XDG_CONFIG_HOME")) |xdg_config_home| {
        return try fs.path.join(alloc, &[_][]const u8{
            xdg_config_home,
            "wayprompt/config.ini",
        });
    } else if (os.getenv("HOME")) |home| {
        return try fs.path.join(alloc, &[_][]const u8{
            home,
            ".config/wayprompt/config.ini",
        });
    } else {
        return try alloc.dupe(u8, "/etc/wayprompt/config.ini");
    }
}

fn assignGeneral(self: *Config, alloc: mem.Allocator, path: []const u8, line: usize, variable: []const u8, value: []const u8) error{ BadConfig, OutOfMemory }!void {
    if (try self.wayland_ui.assign(alloc, path, line, variable, value)) return;
    log.err("Unknown variable in section 'general': '{s}'", .{variable});
    return error.BadConfig;
}

fn assignColour(self: *Config, path: []const u8, line: usize, variable: []const u8, value: []const u8) error{BadConfig}!void {
    if (try self.wayland_colours.assign(path, line, variable, value)) return;
    log.err("Unknown variable in section 'colours': '{s}'", .{variable});
    return error.BadConfig;
}

// TODO[zig]: multi for loop
fn fieldEql(field: []const u8, variable: []const u8) bool {
    if (field.len != variable.len) return false;
    if (field.ptr == variable.ptr) return true;
    for (field) |item, index| {
        if (item == '_') {
            if (variable[index] != '-') return false;
        } else if (variable[index] != item) {
            return false;
        }
    }
    return true;
}

test "fieldEql" {
    const testing = std.testing;
    try testing.expect(fieldEql("test_test", "test-test"));
    try testing.expect(!fieldEql("test_testA", "test-testB"));
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
