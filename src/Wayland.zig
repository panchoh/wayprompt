const builtin = @import("builtin");
const std = @import("std");
const ascii = std.ascii;
const os = std.os;
const cstr = std.cstr;
const mem = std.mem;
const math = std.math;
const unicode = std.unicode;
const debug = std.debug;
const log = std.log.scoped(.backend_wayland);

const pixman = @import("pixman");
const fcft = @import("fcft");
const xkb = @import("xkbcommon");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Frontend = @import("Frontend.zig");
const Config = @import("Config.zig");

const Wayland = @This();

const HotSpot = struct {
    const Effect = enum { cancel, ok, notok };

    effect: Effect,
    x: u31,
    y: u31,
    width: u31,
    height: u31,

    pub fn containsPoint(self: HotSpot, x: u31, y: u31) bool {
        return x >= self.x and x <= self.x +| self.width and
            y >= self.y and y <= self.y +| self.height;
    }

    pub fn act(self: HotSpot, w: *Wayland) void {
        switch (self.effect) {
            .cancel => w.abort(error.UserAbort),
            .notok => w.abort(error.UserNotOk),
            .ok => w.abort(error.UserOk),
        }
    }
};

// Copied and adapted from https://git.sr.ht/~novakane/zelbar, same license.
const TextView = struct {
    const Mode = union(enum) {
        text_run: *const fcft.TextRun,
        glyphs: struct {
            glyphs: []*const fcft.Glyph,
            kerns: []c_long,
        },
    };
    mode: Mode,
    font: *fcft.Font,
    width: u31,
    height: u31,

    pub fn new(alloc: mem.Allocator, str: []const u8, font: *fcft.Font) !TextView {
        if (str.len == 0) return error.EmptyString;

        var height = @intCast(u31, font.height);

        const len = try unicode.utf8CountCodepoints(str);
        const codepoints = try alloc.alloc(u32, len);
        defer alloc.free(codepoints);
        {
            var i: usize = 0;
            var it = (try unicode.Utf8View.init(str)).iterator();
            while (it.nextCodepoint()) |cp| : (i += 1) {
                if (cp == '\n') height += @intCast(u31, font.height);
                codepoints[i] = cp;
            }
        }

        if ((fcft.capabilities() & fcft.Capabilities.text_run_shaping) != 0) {
            const text_run = try font.rasterizeTextRunUtf32(codepoints, .default);
            var i: usize = 0;
            var width: u31 = 0;
            var max_width: u31 = 0;
            while (i < text_run.count) : (i += 1) {
                if (text_run.glyphs[i].cp == '\n') {
                    if (width > max_width) {
                        max_width = width;
                    }
                    width = 0;
                } else {
                    width += @intCast(u31, text_run.glyphs[i].advance.x);
                }
            }
            if (width > max_width) {
                max_width = width;
            }

            return TextView{
                .mode = .{ .text_run = text_run },
                .font = font,
                .width = max_width,
                .height = height,
            };
        } else {
            const glyphs = try alloc.alloc(*const fcft.Glyph, codepoints.len);
            errdefer alloc.free(glyphs);
            const kerns = try alloc.alloc(c_long, codepoints.len);
            errdefer alloc.free(kerns);

            var i: usize = 0;
            var width: u31 = 0;
            var max_width: u31 = 0;
            while (i < codepoints.len) : (i += 1) {
                glyphs[i] = try font.rasterizeCharUtf32(codepoints[i], .default);
                kerns[i] = 0;
                if (i > 0) {
                    var x_kern: c_long = 0;
                    if (font.kerning(codepoints[i - 1], codepoints[i], &x_kern, null)) kerns[i] = x_kern;
                }
                if (glyphs[i].cp == '\n') {
                    if (width > max_width) {
                        max_width = width;
                    }
                    width = 0;
                } else {
                    width += @intCast(u31, kerns[i] + glyphs[i].advance.x);
                }
            }
            if (width > max_width) {
                max_width = width;
            }

            return TextView{
                .mode = .{ .glyphs = .{
                    .glyphs = glyphs,
                    .kerns = kerns,
                } },
                .font = font,
                .width = max_width,
                .height = height,
            };
        }
    }

    pub fn deinit(self: *const TextView, alloc: mem.Allocator) void {
        switch (self.*.mode) {
            .text_run => self.mode.text_run.destroy(),
            .glyphs => {
                alloc.free(self.mode.glyphs.glyphs);
                alloc.free(self.mode.glyphs.kerns);
            },
        }
    }

    pub fn draw(self: *const TextView, image: *pixman.Image, colour: *pixman.Color, x: u31, y: u31, c: *Config) !u31 {
        const glyphs = switch (self.mode) {
            .text_run => self.mode.text_run.glyphs[0..self.mode.text_run.count],
            .glyphs => self.mode.glyphs.glyphs,
        };

        var X: u31 = x;
        var Y: u31 = y;
        var i: usize = 0;
        while (i < glyphs.len) : (i += 1) {
            if (self.mode == .glyphs) X += @intCast(u31, self.mode.glyphs.kerns[i]);

            if (glyphs[i].cp == '\n') {
                X = x;
                Y += @intCast(u31, self.font.height);
                continue;
            }

            const solcol = pixman.Image.createSolidFill(colour).?;
            defer _ = solcol.unref();

            switch (pixman.Image.getFormat(glyphs[i].pix)) {
                // Pre-rendered Image.
                .a8r8g8b8 => pixman.Image.composite32(
                    .over,
                    glyphs[i].pix,
                    null,
                    image,
                    0,
                    0,
                    0,
                    0,
                    X + @intCast(u31, glyphs[i].x),
                    Y - @intCast(i32, glyphs[i].y) + self.font.ascent,
                    glyphs[i].width,
                    glyphs[i].height,
                ),

                // Alpha mask (i.e. regular character).
                else => {
                    pixman.Image.composite32(
                        .over,
                        solcol,
                        glyphs[i].pix,
                        image,
                        0,
                        0,
                        0,
                        0,
                        X + @intCast(i32, glyphs[i].x),
                        Y - @intCast(i32, glyphs[i].y) + self.font.ascent,
                        glyphs[i].width,
                        glyphs[i].height,
                    );
                },
            }

            X += @intCast(u31, glyphs[i].advance.x);
        }

        return self.height + c.vertical_padding;
    }
};

const Seat = struct {
    const CursorShape = enum { none, arrow, hand };

    w: *Wayland,

    wl_seat: *wl.Seat,

    // Keyboard related objects.
    wl_keyboard: ?*wl.Keyboard = null,
    xkb_state: ?*xkb.State = null,

    // Pointer related objects.
    wl_pointer: ?*wl.Pointer = null,
    pointer_x: u31 = 0,
    pointer_y: u31 = 0,
    cursor_shape: CursorShape = .none,
    cursor_theme: ?*wl.CursorTheme = null,
    cursor_surface: ?*wl.Surface = null,
    last_enter_serial: u32 = undefined,
    press_hotspot: ?*HotSpot = null,

    pub fn init(self: *Seat, w: *Wayland, wl_seat: *wl.Seat) !void {
        self.* = .{ .w = w, .wl_seat = wl_seat };
        self.wl_seat.setListener(*Seat, seatListener, self);
    }

    pub fn deinit(self: *Seat) void {
        self.releaseKeyboard();
        self.releasePointer();
        self.wl_seat.destroy();
    }

    fn seatListener(_: *wl.Seat, event: wl.Seat.Event, self: *Seat) void {
        switch (event) {
            .capabilities => |ev| {
                if (ev.capabilities.keyboard) {
                    self.bindKeyboard() catch {};
                } else {
                    self.releaseKeyboard();
                }

                if (ev.capabilities.pointer) {
                    self.bindPointer() catch {};
                } else {
                    self.releasePointer();
                }

                // TODO touch
            },
            .name => {}, // Do I look like I care?
        }
    }

    fn bindPointer(self: *Seat) !void {
        if (self.wl_pointer != null) return;
        self.wl_pointer = try self.wl_seat.getPointer();
        self.wl_pointer.?.setListener(*Seat, pointerListener, self);
    }

    fn releasePointer(self: *Seat) void {
        self.cursor_shape = .none;
        self.press_hotspot = null;
        if (self.cursor_theme) |t| {
            t.destroy();
            self.cursor_theme = null;
        }
        if (self.cursor_surface) |s| {
            s.destroy();
            self.cursor_surface = null;
        }
        if (self.wl_pointer) |p| {
            p.release();
            self.wl_pointer = null;
        }
    }

    fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, self: *Seat) void {
        // It is possible that the server sends us more move events before we
        // inform it of having closed the surface.
        if (self.w.surface == null) return;

        switch (event) {
            .enter => |ev| self.updatePointer(ev.surface_x, ev.surface_y, ev.serial),
            .motion => |ev| self.updatePointer(ev.surface_x, ev.surface_y, null),
            .button => |ev| {
                // Only activating a button on release is the better UX, IMO.
                switch (ev.state) {
                    .pressed => self.press_hotspot = self.w.surface.?.hotspotFromPoint(self.pointer_x, self.pointer_y),
                    .released => {
                        if (self.press_hotspot == null) return;
                        if (self.w.surface.?.hotspotFromPoint(self.pointer_x, self.pointer_y)) |hs| {
                            if (hs == self.press_hotspot.?) {
                                hs.act(self.w);
                            }
                        }
                        self.press_hotspot = null;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn updatePointer(self: *Seat, x: wl.Fixed, y: wl.Fixed, serial: ?u32) void {
        const X = x.toInt();
        self.pointer_x = if (X > 0) @intCast(u31, X) else 0;

        const Y = y.toInt();
        self.pointer_y = if (Y > 0) @intCast(u31, Y) else 0;

        if (serial) |s| self.last_enter_serial = s;

        // Sanity check.
        debug.assert(self.wl_pointer != null);

        // Cursor errors shall not be fatal. It's fairly expectable for
        // something to go wrong there and it's not exactly vital to our
        // operation here, so we can roll without setting the cursor.
        if (self.w.surface.?.hotspotFromPoint(self.pointer_x, self.pointer_y) != null) {
            self.setCursor(.hand) catch {};
        } else {
            self.setCursor(.arrow) catch {};
        }
    }

    fn setCursor(self: *Seat, shape: CursorShape) !void {
        if (self.cursor_shape == shape) return;

        const name = switch (shape) {
            .none => unreachable,
            .arrow => "default",
            .hand => "pointer",
        };

        const scale = 1; // TODO
        const cursor_size = 24 * scale;

        if (self.cursor_theme == null) {
            self.cursor_theme = try wl.CursorTheme.load(null, cursor_size, self.w.shm.?);
        }
        errdefer {
            self.cursor_theme.?.destroy();
            self.cursor_theme = null;
        }

        // These just point back to the CursorTheme, no need to keep them.
        const wl_cursor = self.cursor_theme.?.getCursor(name) orelse return error.NoCursor;
        const cursor_image = wl_cursor.images[0]; // TODO Is this nullable? Not in the bindings, but they may be wrong.
        const wl_buffer = try cursor_image.getBuffer();

        if (self.cursor_surface == null) {
            self.cursor_surface = try self.w.compositor.?.createSurface();
        }
        errdefer {
            self.cursor_surface.?.destroy();
            self.cursor_surface = null;
        }

        self.cursor_surface.?.setBufferScale(scale);
        self.cursor_surface.?.attach(wl_buffer, 0, 0);
        self.cursor_surface.?.damageBuffer(0, 0, math.maxInt(i31), math.maxInt(u31));
        self.cursor_surface.?.commit();

        self.wl_pointer.?.setCursor(
            self.last_enter_serial,
            self.cursor_surface.?,
            @intCast(i32, @divFloor(cursor_image.hotspot_x, scale)),
            @intCast(i32, @divFloor(cursor_image.hotspot_y, scale)),
        );
    }

    fn bindKeyboard(self: *Seat) !void {
        if (self.wl_keyboard != null) return;
        self.wl_keyboard = try self.wl_seat.getKeyboard();
        self.wl_keyboard.?.setListener(*Seat, keyboardListener, self);
        // TODO XKBcommon things (see snayk)
    }

    fn releaseKeyboard(self: *Seat) void {
        if (self.wl_keyboard) |kb| {
            kb.release();
            self.wl_keyboard = null;
            // TODO XKBcommon things (see snayk)
        }
        if (self.xkb_state) |xs| {
            xs.unref();
            self.xkb_state = null;
        }
    }

    fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Seat) void {
        switch (event) {
            .keymap => |ev| {
                defer os.close(ev.fd);
                if (ev.format != .xkb_v1) {
                    self.w.abort(error.UnsupportedKeyboardLayoutFormat);
                    return;
                }
                const keymap_str = os.mmap(null, ev.size, os.PROT.READ, os.MAP.PRIVATE, ev.fd, 0) catch {
                    self.w.abort(error.OutOfMemory);
                    return;
                };
                defer os.munmap(keymap_str);
                const keymap = xkb.Keymap.newFromBuffer(
                    self.w.xkb_context.?,
                    keymap_str.ptr,
                    keymap_str.len - 1,
                    .text_v1,
                    .no_flags,
                ) orelse {
                    self.w.abort(error.OutOfMemory);
                    return;
                };
                defer keymap.unref();
                const state = xkb.State.new(keymap) orelse {
                    self.w.abort(error.OutOfMemory);
                    return;
                };
                defer state.unref();
                if (self.xkb_state) |xs| xs.unref();
                self.xkb_state = state.ref();
            },
            .modifiers => |ev| {
                if (self.xkb_state) |xs| {
                    _ = xs.updateMask(ev.mods_depressed, ev.mods_latched, ev.mods_locked, 0, 0, ev.group);
                }
            },
            .key => |ev| {
                if (ev.state != .pressed) return;
                const keycode = ev.key + 8;
                const keysym = self.xkb_state.?.keyGetOneSym(keycode);
                if (keysym == .NoSymbol) return;
                switch (@enumToInt(keysym)) {
                    xkb.Keysym.Return => {
                        self.w.abort(error.UserOk);
                        return;
                    },
                    xkb.Keysym.BackSpace => {
                        self.w.config.secbuf.deleteBackwards();
                        self.w.surface.?.render() catch self.w.abort(error.OutOfMemory);
                        return;
                    },
                    xkb.Keysym.Delete => return,
                    xkb.Keysym.Escape => {
                        self.w.abort(error.UserAbort);
                        return;
                    },
                    else => {},
                }

                if (self.w.mode != .getpin) return;

                var buffer: [16]u8 = undefined;
                const used = self.xkb_state.?.keyGetUtf8(keycode, &buffer);
                self.w.config.secbuf.appendSlice(buffer[0..used]) catch {};

                // We only get keyboard input when a surface exists.
                self.w.surface.?.render() catch self.w.abort(error.OutOfMemory);
            },
            .enter => {},
            .leave => {},
            .repeat_info => {},
        }
    }
};

const Surface = struct {
    w: *Wayland = undefined,

    wl_surface: *wl.Surface = undefined,
    layer_surface: *zwlr.LayerSurfaceV1 = undefined,
    configured: bool = false,
    width: u31 = undefined,
    height: u31 = undefined,

    scale: u31 = 1, // TODO use buffer_scale events

    /// Cursor / Touch hotspots, populated on first render.
    hotspots: std.ArrayListUnmanaged(HotSpot) = .{},

    pub fn init(self: *Surface, w: *Wayland) !void {
        log.debug("creating surface.", .{});

        const wl_surface = try w.compositor.?.createSurface();
        errdefer wl_surface.destroy();

        const layer_surface = try w.layer_shell.?.getLayerSurface(wl_surface, null, .overlay, "wayprompt");
        errdefer layer_surface.destroy();

        self.* = .{
            .w = w,
            .wl_surface = wl_surface,
            .layer_surface = layer_surface,
        };
        try self.calculateSize();

        layer_surface.setListener(*Surface, layerSurfaceListener, self);
        layer_surface.setKeyboardInteractivity(.exclusive);
        layer_surface.setSize(self.width, self.height);
        wl_surface.commit();
    }

    fn calculateSize(self: *Surface) !void {
        self.height = self.w.config.vertical_padding;
        self.width = self.w.config.horizontal_padding;

        if (self.w.mode == .getpin) {
            if (self.w.prompt) |prompt| {
                self.width = math.max(prompt.width + 2 * self.w.config.horizontal_padding, self.width);
                self.height += prompt.height + self.w.config.vertical_padding;
            }

            const square_padding = @divFloor(self.w.config.pin_square_size, 2);
            const pinarea_height = self.w.config.pin_square_size + 2 * square_padding;
            const pinarea_width = self.w.config.pin_square_amount * (self.w.config.pin_square_size + square_padding) + square_padding;

            self.height += pinarea_height + self.w.config.vertical_padding;
            self.width = math.max(self.width, pinarea_width + 2 * self.w.config.horizontal_padding);
        }

        if (self.w.title) |title| {
            self.width = math.max(title.width + 2 * self.w.config.horizontal_padding, self.width);
            self.height += title.height + self.w.config.vertical_padding;
        }
        if (self.w.description) |description| {
            self.width = math.max(description.width + 2 * self.w.config.horizontal_padding, self.width);
            self.height += description.height + self.w.config.vertical_padding;
        }
        if (self.w.errmessage) |errmessage| {
            self.width = math.max(errmessage.width + 2 * self.w.config.horizontal_padding, self.width);
            self.height += errmessage.height + self.w.config.vertical_padding;
        }

        {
            var button_amount: u31 = 0;
            var combined_button_length: u31 = 0;
            var max_button_height: u31 = 0;

            if (self.w.ok) |ok| {
                button_amount += 1;
                combined_button_length += ok.width + self.w.config.horizontal_padding + 2 * self.w.config.button_inner_padding;
                max_button_height = math.max(max_button_height, ok.height + 2 * self.w.config.button_inner_padding);
            }
            if (self.w.notok) |notok| {
                button_amount += 1;
                combined_button_length += notok.width + self.w.config.horizontal_padding + 2 * self.w.config.button_inner_padding;
                max_button_height = math.max(max_button_height, notok.height + 2 * self.w.config.button_inner_padding);
            }
            if (self.w.cancel) |cancel| {
                button_amount += 1;
                combined_button_length += cancel.width + self.w.config.horizontal_padding + 2 * self.w.config.button_inner_padding;
                max_button_height = math.max(max_button_height, cancel.height + 2 * self.w.config.button_inner_padding);
            }

            self.width = math.max(combined_button_length + self.w.config.horizontal_padding, self.width);

            if (max_button_height > 0) self.height += max_button_height + self.w.config.vertical_padding;

            debug.assert(self.hotspots.items.len == 0);
            try self.hotspots.ensureTotalCapacity(self.w.config.alloc, max_button_height);
        }
    }

    pub fn deinit(self: *Surface) void {
        self.hotspots.deinit(self.w.config.alloc);
        self.layer_surface.destroy();
        self.wl_surface.destroy();
    }

    pub fn hotspotFromPoint(self: *Surface, x: u31, y: u31) ?*HotSpot {
        for (self.hotspots.items) |*hs| {
            if (hs.containsPoint(x, y)) {
                return hs;
            }
        }
        return null;
    }

    fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, self: *Surface) void {
        switch (event) {
            .configure => |ev| {
                log.debug("layer surface configure event.", .{});
                // We just ignore the requested sizes. Figuring out a good size
                // based on the text context is already complicated enough. If
                // this annoys you, patches are welcome.
                self.configured = true;
                layer_surface.ackConfigure(ev.serial);
                self.render() catch {
                    self.w.abort(error.OutOfMemory);
                    return;
                };
            },
            .closed => {
                log.debug("layer surface closed by server.", .{});
                self.w.abort(error.OutOfMemory);
            },
        }
    }

    fn render(self: *Surface) !void {
        if (!self.configured) return;

        log.debug("render.", .{});

        const buffer = (try self.w.buffer_pool.nextBuffer(self.w, self.width, self.height)) orelse return;
        const image = buffer.*.pixman_image.?;

        self.drawBackground(image, self.width, self.height);

        var Y: u31 = self.w.config.vertical_padding;
        if (self.w.title) |title| {
            const X = @divFloor(self.width, 2) -| @divFloor(title.width, 2);
            Y += try title.draw(image, &self.w.config.text_colour, X, Y, self.w.config);
        }
        if (self.w.description) |description| {
            const X = @divFloor(self.width, 2) -| @divFloor(description.width, 2);
            Y += try description.draw(image, &self.w.config.text_colour, X, Y, self.w.config);
        }

        if (self.w.mode == .getpin) {
            if (self.w.prompt) |prompt| {
                const X = @divFloor(self.width, 2) -| @divFloor(prompt.width, 2);
                Y += try prompt.draw(image, &self.w.config.text_colour, X, Y, self.w.config);
            }
            Y += self.drawPinArea(image, self.w.config.secbuf.len, Y);
        }

        if (self.w.errmessage) |errmessage| {
            const X = @divFloor(self.width, 2) -| @divFloor(errmessage.width, 2);
            Y += try errmessage.draw(image, &self.w.config.error_text_colour, X, Y, self.w.config);
        }

        // The hotspot list is populated on first render. We could technically
        // do it in calculateSize(), but we already have all the sizes here
        // already, so doing it here is more convenient for now.
        const populate_hotspots = self.hotspots.items.len == 0;

        // Buttons
        {
            const combined_button_length = blk: {
                var len: u31 = 0;
                if (self.w.ok) |ok| len += ok.width + self.w.config.horizontal_padding + 2 * self.w.config.button_inner_padding;
                if (self.w.notok) |notok| len += notok.width + self.w.config.horizontal_padding + 2 * self.w.config.button_inner_padding;
                if (self.w.cancel) |cancel| len += cancel.width + self.w.config.horizontal_padding + 2 * self.w.config.button_inner_padding;
                break :blk len;
            };
            var X: u31 = @divFloor(self.width + self.w.config.horizontal_padding, 2) -| @divFloor(combined_button_length, 2);
            if (self.w.cancel) |cancel| {
                if (populate_hotspots) {
                    self.hotspots.appendAssumeCapacity(.{
                        .effect = .cancel,
                        .x = X,
                        .y = Y,
                        .width = cancel.width + 2 * self.w.config.button_inner_padding,
                        .height = cancel.height + 2 * self.w.config.button_inner_padding,
                    });
                }

                borderedRectangle(
                    image,
                    X,
                    Y,
                    cancel.width + 2 * self.w.config.button_inner_padding,
                    cancel.height + 2 * self.w.config.button_inner_padding,
                    self.w.config.button_border,
                    self.scale,
                    &self.w.config.cancel_button_background_colour,
                    &self.w.config.border_colour,
                );
                _ = try cancel.draw(image, &self.w.config.text_colour, X + self.w.config.button_inner_padding, Y + self.w.config.button_inner_padding, self.w.config);
                X += cancel.width + 2 * self.w.config.button_inner_padding + self.w.config.horizontal_padding;
            }
            if (self.w.notok) |notok| {
                if (populate_hotspots) {
                    self.hotspots.appendAssumeCapacity(.{
                        .effect = .notok,
                        .x = X,
                        .y = Y,
                        .width = notok.width + 2 * self.w.config.button_inner_padding,
                        .height = notok.height + 2 * self.w.config.button_inner_padding,
                    });
                }

                borderedRectangle(
                    image,
                    X,
                    Y,
                    notok.width + 2 * self.w.config.button_inner_padding,
                    notok.height + 2 * self.w.config.button_inner_padding,
                    self.w.config.button_border,
                    self.scale,
                    &self.w.config.notok_button_background_colour,
                    &self.w.config.border_colour,
                );
                _ = try notok.draw(image, &self.w.config.text_colour, X + self.w.config.button_inner_padding, Y + self.w.config.button_inner_padding, self.w.config);
                X += notok.width + 2 * self.w.config.button_inner_padding + self.w.config.horizontal_padding;
            }
            if (self.w.ok) |ok| {
                if (populate_hotspots) {
                    self.hotspots.appendAssumeCapacity(.{
                        .effect = .ok,
                        .x = X,
                        .y = Y,
                        .width = ok.width + 2 * self.w.config.button_inner_padding,
                        .height = ok.height + 2 * self.w.config.button_inner_padding,
                    });
                }

                borderedRectangle(
                    image,
                    X,
                    Y,
                    ok.width + 2 * self.w.config.button_inner_padding,
                    ok.height + 2 * self.w.config.button_inner_padding,
                    self.w.config.button_border,
                    self.scale,
                    &self.w.config.ok_button_background_colour,
                    &self.w.config.border_colour,
                );
                _ = try ok.draw(image, &self.w.config.text_colour, X + self.w.config.button_inner_padding, Y + self.w.config.button_inner_padding, self.w.config);
            }
        }

        self.wl_surface.setBufferScale(self.scale);
        self.wl_surface.attach(buffer.*.wl_buffer.?, 0, 0);
        self.wl_surface.damageBuffer(0, 0, math.maxInt(i31), math.maxInt(u31));
        self.wl_surface.commit();
        buffer.*.busy = true;
    }

    fn drawBackground(self: *Surface, image: *pixman.Image, width: u31, height: u31) void {
        borderedRectangle(
            image,
            0,
            0,
            width,
            height,
            self.w.config.border,
            self.scale,
            &self.w.config.background_colour,
            &self.w.config.border_colour,
        );
    }

    fn drawPinArea(self: *Surface, image: *pixman.Image, len: usize, pinarea_y: u31) u31 {
        const square_padding = @divFloor(self.w.config.pin_square_size, 2);
        const pinarea_height = self.w.config.pin_square_size + 2 * square_padding;
        const pinarea_width = self.w.config.pin_square_amount * (self.w.config.pin_square_size + square_padding) + square_padding;
        const pinarea_x = @divFloor(self.width, 2) - @divFloor(pinarea_width, 2);

        borderedRectangle(
            image,
            pinarea_x,
            pinarea_y,
            pinarea_width,
            pinarea_height,
            self.w.config.border,
            self.scale,
            &self.w.config.pinarea_background_colour,
            &self.w.config.pinarea_border_colour,
        );

        var i: usize = 0;
        while (i < len and i < self.w.config.pin_square_amount) : (i += 1) {
            const x = @intCast(u31, pinarea_x + (i * self.w.config.pin_square_size) + ((i + 1) * square_padding));
            const y = pinarea_y + square_padding;
            borderedRectangle(
                image,
                x,
                y,
                self.w.config.pin_square_size,
                self.w.config.pin_square_size,
                self.w.config.pin_square_border,
                self.scale,
                &self.w.config.pinarea_square_colour,
                &self.w.config.pinarea_border_colour,
            );
        }

        return pinarea_height + self.w.config.vertical_padding;
    }

    fn borderedRectangle(
        image: *pixman.Image,
        _x: u31,
        _y: u31,
        _width: u31,
        _height: u31,
        _border: u31,
        scale: u31,
        background_colour: *const pixman.Color,
        border_colour: *const pixman.Color,
    ) void {
        const x = @intCast(i16, _x * scale);
        const y = @intCast(i16, _y * scale);
        const width = @intCast(u15, _width * scale);
        const height = @intCast(u15, _height * scale);
        const border = @intCast(u15, _border * scale);
        _ = pixman.Image.fillRectangles(.src, image, background_colour, 1, &[1]pixman.Rectangle16{
            .{ .x = x, .y = y, .width = width, .height = height },
        });
        _ = pixman.Image.fillRectangles(.src, image, border_colour, 4, &[4]pixman.Rectangle16{
            .{ .x = x, .y = y, .width = width, .height = border }, // Top
            .{ .x = x, .y = (y + height - border), .width = width, .height = border }, // Bottom
            .{ .x = x, .y = (y + border), .width = border, .height = (height - 2 * border) }, // Left
            .{ .x = (x + width - border), .y = (y + border), .width = border, .height = (height - 2 * border) }, // Right
        });
    }
};

const BufferPool = struct {
    a: Buffer = .{},
    b: Buffer = .{},

    pub fn reset(self: *BufferPool) void {
        self.a.deinit();
        self.b.deinit();
        self.* = .{};
    }

    pub fn nextBuffer(self: *BufferPool, w: *Wayland, width: u31, height: u31) !?*Buffer {
        var buffer: *Buffer = blk: {
            if (!self.a.busy) break :blk &self.a;
            if (!self.b.busy) break :blk &self.b;
            return null;
        };
        if (buffer.*.width != width or buffer.*.height != height or buffer.*.wl_buffer == null) {
            buffer.*.deinit();
            try buffer.*.init(w, width, height);
        }
        return buffer;
    }
};

// Copied and adapted from https://git.sr.ht/~novakane/zelbar, same license.
const Buffer = struct {
    wl_buffer: ?*wl.Buffer = null,
    pixman_image: ?*pixman.Image = null,
    data: ?[]align(std.mem.page_size) u8 = null,
    width: u31 = 0, // u31 can coerce to i32.
    height: u31 = 0,
    busy: bool = false,

    pub fn init(self: *Buffer, w: *Wayland, width: u31, height: u31) !void {
        const stride = width << 2;
        const size = stride * height;

        if (size == 0) return error.ZeroSizedBuffer;

        const fd = blk: {
            if (builtin.target.os.tag == .linux) {
                break :blk try os.memfd_createZ("/wayprompt", os.linux.MFD.CLOEXEC);
            }
            @compileError("patches welcome");
        };
        defer os.close(fd);
        try os.ftruncate(fd, size);

        const data = mem.bytesAsSlice(u8, try os.mmap(
            null,
            size,
            os.PROT.READ | os.PROT.WRITE,
            os.MAP.SHARED,
            fd,
            0,
        ));
        errdefer os.munmap(data);

        const shm_pool = try w.shm.?.createPool(fd, size);
        defer shm_pool.destroy();

        const wl_buffer = try shm_pool.createBuffer(0, width, height, stride, .argb8888);
        errdefer wl_buffer.destroy();
        wl_buffer.setListener(*Buffer, bufferListener, self);

        const pixman_image = pixman.Image.createBitsNoClear(
            .a8r8g8b8,
            @intCast(c_int, width),
            @intCast(c_int, height),
            @ptrCast([*c]u32, data),
            @intCast(c_int, stride),
        );
        errdefer _ = pixman_image.unref();

        self.* = .{
            .wl_buffer = wl_buffer,
            .pixman_image = pixman_image,
            .data = data,
            .width = width,
            .height = height,
        };
    }

    fn deinit(self: Buffer) void {
        if (self.pixman_image) |p| _ = p.unref();
        if (self.wl_buffer) |wb| wb.destroy();
        if (self.data) |d| os.munmap(d);
    }

    fn bufferListener(_: *wl.Buffer, event: wl.Buffer.Event, self: *Buffer) void {
        switch (event) {
            .release => self.busy = false,
        }
    }
};

config: *Config = undefined,
mode: Frontend.InterfaceMode = .none,

title: ?TextView = null,
description: ?TextView = null,
prompt: ?TextView = null,
errmessage: ?TextView = null,
ok: ?TextView = null,
notok: ?TextView = null,
cancel: ?TextView = null,
font_large: ?*fcft.Font = null,
font_regular: ?*fcft.Font = null,

display: *wl.Display = undefined,
registry: ?*wl.Registry = null,
layer_shell: ?*zwlr.LayerShellV1 = null,
compositor: ?*wl.Compositor = null,
shm: ?*wl.Shm = null,
seats: std.TailQueue(Seat) = .{},
buffer_pool: BufferPool = .{},
surface: ?Surface = null,

/// While this is not null, we have not reached the sync handler and as such
/// not bound all the globals we need. Because for some backends (like the CLI
/// one) it is more ergonomic to call enterMode() _before_ entering the event
/// loop and as such before dispatching Wayland messages. In those cases, the
/// mode gets delayed until the sync listener fires.
sync: ?*wl.Callback = null,
delayed_mode: ?Frontend.InterfaceMode = null,

xkb_context: ?*xkb.Context = undefined,

exit_reason: ?anyerror = null,

pub fn init(self: *Wayland, cfg: *Config) !os.fd_t {
    self.config = cfg;

    const wayland_display = blk: {
        if (cfg.wayland_display) |wd| break :blk wd;
        if (os.getenv("WAYLAND_DISPLAY")) |wd| break :blk wd;
        return error.NoWaylandDisplay;
    };
    log.debug("trying to connect to '{s}'.", .{wayland_display});

    self.display = try wl.Display.connect(@ptrCast([*:0]const u8, wayland_display.ptr));
    errdefer self.deinit();

    self.registry = try self.display.getRegistry();
    self.registry.?.setListener(*Wayland, registryListener, self);

    self.sync = try self.display.sync();
    self.sync.?.setListener(*Wayland, syncListener, self);

    self.xkb_context = xkb.Context.new(.no_flags) orelse return error.OutOfMemory;

    _ = fcft.init(.never, false, .none);
    var font_regular_names = [_][*:0]const u8{ "sans:size=14", "mono:size=14" };
    self.font_regular = try fcft.Font.fromName(font_regular_names[0..], null);
    var font_large_names = [_][*:0]const u8{ "sans:size=20", "mono:size=20" };
    self.font_large = try fcft.Font.fromName(font_large_names[0..], null);

    return self.display.getFd();
}

pub fn deinit(self: *Wayland) void {
    const alloc = self.config.alloc;

    // FCFT teardown.
    {
        self.deinitTextViews();
        if (self.font_large) |f| f.destroy();
        if (self.font_regular) |f| f.destroy();
        fcft.fini();
    }

    if (self.surface) |*s| s.deinit();

    self.buffer_pool.reset();
    if (self.layer_shell) |ls| ls.destroy();
    if (self.compositor) |cmp| cmp.destroy();
    if (self.shm) |sm| sm.destroy();

    var it = self.seats.first;
    while (it) |node| {
        it = node.next;
        node.data.deinit();
        alloc.destroy(node);
    }

    if (self.xkb_context) |x| x.unref();

    if (self.sync) |s| s.destroy();
    if (self.registry) |r| r.destroy();
    self.display.disconnect();
}

pub fn enterMode(self: *Wayland, mode: Frontend.InterfaceMode) !void {
    if (self.mode == mode) {
        debug.assert(self.mode == .none);
        return;
    }

    // See doc-comment for Wayland.sync.
    if (self.sync != null) {
        log.debug("trying to enter mode but haven't sync'd yet, delaying.", .{});
        self.delayed_mode = mode;
        return;
    }

    self.deinitTextViews();

    self.mode = mode;
    if (mode == .none) {
        debug.assert(self.surface != null);
        self.surface.?.deinit();
        self.surface = null;
    } else {
        try self.initTextViews();
        self.surface = Surface{};
        self.surface.?.init(self) catch |err| {
            log.err("failed to init surface: {s}", .{@errorName(err)});
            self.surface = null;
            self.abort(error.OutOfMemory);
        };
    }
}

fn initTextViews(self: *Wayland) !void {
    const alloc = self.config.alloc;
    if (self.config.title) |title| self.title = try TextView.new(alloc, mem.trim(u8, title, &ascii.spaces), self.font_large.?);
    if (self.config.description) |description| self.description = try TextView.new(alloc, mem.trim(u8, description, &ascii.spaces), self.font_regular.?);
    if (self.config.errmessage) |errmessage| self.errmessage = try TextView.new(alloc, mem.trim(u8, errmessage, &ascii.spaces), self.font_regular.?);
    if (self.config.prompt) |prompt| self.prompt = try TextView.new(alloc, mem.trim(u8, prompt, &ascii.spaces), self.font_large.?);
    if (self.config.ok) |ok| self.ok = try TextView.new(alloc, mem.trim(u8, ok, &ascii.spaces), self.font_regular.?);
    if (self.config.notok) |notok| self.notok = try TextView.new(alloc, mem.trim(u8, notok, &ascii.spaces), self.font_regular.?);
    if (self.config.cancel) |cancel| self.cancel = try TextView.new(alloc, mem.trim(u8, cancel, &ascii.spaces), self.font_regular.?);
}

fn deinitTextViews(self: *Wayland) void {
    const alloc = self.config.alloc;
    if (self.title) |title| {
        self.title = null;
        title.deinit(alloc);
    }
    if (self.description) |description| {
        self.description = null;
        description.deinit(alloc);
    }
    if (self.errmessage) |errmessage| {
        self.errmessage = null;
        errmessage.deinit(alloc);
    }
    if (self.prompt) |prompt| {
        self.prompt = null;
        prompt.deinit(alloc);
    }
    if (self.ok) |ok| {
        self.ok = null;
        ok.deinit(alloc);
    }
    if (self.notok) |notok| {
        self.notok = null;
        notok.deinit(alloc);
    }
    if (self.cancel) |cancel| {
        self.cancel = null;
        cancel.deinit(alloc);
    }
}

/// Flushes Wayland events and prepares read, needed for handleEvent().
pub fn flush(self: *Wayland) !Frontend.Event {
    while (!self.display.prepareRead()) {
        const errno = self.display.dispatchPending();
        if (errno != .SUCCESS) {
            log.err("failed to dispatch pending Wayland events: {s}", .{@tagName(errno)});
            self.abort(error.UnexpectedError);
        }
    }

    while (true) {
        const errno = self.display.flush();
        switch (errno) {
            .SUCCESS => break,
            .PIPE => _ = self.display.readEvents(), // Server closed connection.
            .AGAIN => {
                log.debug("EAGAIN during Wayland display flush.", .{});
                continue;
            },
            else => {
                log.err("flushing Wayland display failed: {s}", .{@tagName(errno)});
                self.abort(error.UnexpectedError);
                break;
            },
        }
    }

    if (self.exit_reason) |er| {
        return try self.exitReasonToReturnVal(er);
    } else {
        return .none;
    }
}

pub fn handleEvent(self: *Wayland) !Frontend.Event {
    {
        const errno = self.display.readEvents();
        if (errno != .SUCCESS) {
            log.err("reading Wayland display failed: {s}", .{@tagName(errno)});
            self.abort(error.UnexpectedError);
        }
    }

    {
        const errno = self.display.dispatchPending();
        if (errno != .SUCCESS) {
            log.err("failed to dispatch pending Wayland events: {s}", .{@tagName(errno)});
            self.abort(error.UnexpectedError);
        }
    }

    if (self.exit_reason) |er| {
        return try self.exitReasonToReturnVal(er);
    } else {
        return .none;
    }
}

pub fn noEvent(self: *Wayland) !void {
    self.display.cancelRead();
}

fn exitReasonToReturnVal(self: *Wayland, er: anyerror) !Frontend.Event {
    // The first three are not technically errors, but using errors for these
    // cases allows us to handle them a tad bit nicer.
    switch (er) {
        error.UserAbort, error.UserNotOk, error.UserOk => {
            self.exit_reason = null;
            try self.enterMode(.none);
            switch (er) {
                error.UserAbort => return .user_abort,
                error.UserNotOk => return .user_notok,
                error.UserOk => return .user_ok,
                else => unreachable,
            }
        },
        else => return er,
    }
}

fn abort(self: *Wayland, reason: anyerror) void {
    switch (reason) {
        error.UserAbort, error.UserNotOk, error.UserOk => {},
        else => log.err("aborting: {s}", .{@errorName(reason)}),
    }
    self.exit_reason = reason;
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, self: *Wayland) void {
    switch (event) {
        .global => |ev| {
            if (cstr.cmp(ev.interface, zwlr.LayerShellV1.getInterface().name) == 0) {
                self.layer_shell = registry.bind(ev.name, zwlr.LayerShellV1, 4) catch {
                    self.abort(error.OutOfMemory);
                    return;
                };
            } else if (cstr.cmp(ev.interface, wl.Compositor.getInterface().name) == 0) {
                self.compositor = registry.bind(ev.name, wl.Compositor, 4) catch {
                    self.abort(error.OutOfMemory);
                    return;
                };
            } else if (cstr.cmp(ev.interface, wl.Shm.getInterface().name) == 0) {
                self.shm = registry.bind(ev.name, wl.Shm, 1) catch {
                    self.abort(error.OutOfMemory);
                    return;
                };
            } else if (cstr.cmp(ev.interface, wl.Seat.getInterface().name) == 0) {
                const seat = registry.bind(ev.name, wl.Seat, 1) catch {
                    self.abort(error.OutOfMemory);
                    return;
                };
                self.addSeat(seat) catch {
                    seat.destroy();
                    self.abort(error.OutOfMemory);
                };
            }
        },
        .global_remove => {}, // We do not live long enough for this to become relevant.
    }
}

fn addSeat(self: *Wayland, wl_seat: *wl.Seat) !void {
    const node = try self.config.alloc.create(std.TailQueue(Seat).Node);
    try node.data.init(self, wl_seat);
    self.seats.append(node);
}

fn syncListener(_: *wl.Callback, _: wl.Callback.Event, self: *Wayland) void {
    log.debug("sync listener reached.", .{});

    if (self.layer_shell == null or self.compositor == null or self.shm == null) {
        self.abort(error.MissingWaylandInterfaces);
    }

    if (self.sync) |s| s.destroy();
    self.sync = null;

    // See doc-comment for Wayland.sync.
    if (self.delayed_mode) |mode| {
        log.debug("delayed mode found, entering.", .{});
        self.delayed_mode = null;
        self.enterMode(mode) catch |err| {
            self.abort(err);
        };
    }
}
