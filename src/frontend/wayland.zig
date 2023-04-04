const builtin = @import("builtin");
const std = @import("std");
const ascii = std.ascii;
const os = std.os;
const cstr = std.cstr;
const mem = std.mem;
const math = std.math;
const unicode = std.unicode;
const debug = std.debug;

const pixman = @import("pixman");
const fcft = @import("fcft");
const xkb = @import("xkbcommon");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const context = &@import("wayprompt.zig").context;

const SecretBuffer = @import("SecretBuffer.zig");

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

    pub fn act(self: HotSpot) void {
        switch (self.effect) {
            .cancel => wayland_context.abort(error.UserAbort),
            .notok => wayland_context.abort(error.UserNotOk),
            .ok => wayland_context.loop = false,
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

    pub fn new(str: []const u8, font: *fcft.Font) !TextView {
        if (str.len == 0) return error.EmptyString;

        var height = @intCast(u31, font.height);

        const alloc = context.gpa.allocator();
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

    pub fn deinit(self: *const TextView) void {
        switch (self.*.mode) {
            .text_run => self.mode.text_run.destroy(),
            .glyphs => {
                const alloc = context.gpa.allocator();
                alloc.free(self.mode.glyphs.glyphs);
                alloc.free(self.mode.glyphs.kerns);
            },
        }
    }

    pub fn draw(self: *const TextView, image: *pixman.Image, colour: *pixman.Color, x: u31, y: u31) !u31 {
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

            const c = pixman.Image.createSolidFill(colour).?;
            defer _ = c.unref();

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
                        c,
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

        return self.height + context.vertical_padding;
    }
};

const Seat = struct {
    const CursorShape = enum { none, arrow, hand };

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

    pub fn init(self: *Seat, wl_seat: *wl.Seat) !void {
        self.* = .{ .wl_seat = wl_seat };
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
        switch (event) {
            .enter => |ev| self.updatePointer(ev.surface_x, ev.surface_y, ev.serial),
            .motion => |ev| self.updatePointer(ev.surface_x, ev.surface_y, null),
            .button => |ev| {
                // Only activating a button on release is the better UX, IMO.
                switch (ev.state) {
                    .pressed => self.press_hotspot = wayland_context.surface.?.hotspotFromPoint(self.pointer_x, self.pointer_y),
                    .released => {
                        if (self.press_hotspot == null) return;
                        if (wayland_context.surface.?.hotspotFromPoint(self.pointer_x, self.pointer_y)) |hs| {
                            if (hs == self.press_hotspot.?) {
                                hs.act();
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
        debug.assert(wayland_context.surface != null);

        // Cursor errors shall not be fatal. It's fairly expectable for
        // something to go wrong there and it's not exactly vital to our
        // operation here, so we can roll without setting the cursor.
        if (wayland_context.surface.?.hotspotFromPoint(self.pointer_x, self.pointer_y) != null) {
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
            self.cursor_theme = try wl.CursorTheme.load(null, cursor_size, wayland_context.shm.?);
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
            self.cursor_surface = try wayland_context.compositor.?.createSurface();
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
                    wayland_context.abort(error.UnsupportedKeyboardLayoutFormat);
                    return;
                }
                const keymap_str = os.mmap(null, ev.size, os.PROT.READ, os.MAP.PRIVATE, ev.fd, 0) catch {
                    wayland_context.abort(error.OutOfMemory);
                    return;
                };
                defer os.munmap(keymap_str);
                const keymap = xkb.Keymap.newFromBuffer(wayland_context.xkb_context, keymap_str.ptr, keymap_str.len - 1, .text_v1, .no_flags) orelse {
                    wayland_context.abort(error.OutOfMemory);
                    return;
                };
                defer keymap.unref();
                const state = xkb.State.new(keymap) orelse {
                    wayland_context.abort(error.OutOfMemory);
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
                    xkb.Keysym.leftarrow, xkb.Keysym.leftarrow => {
                        // TODO select button with arrow keys
                    },
                    xkb.Keysym.Return => {
                        wayland_context.loop = false;
                        return;
                    },
                    xkb.Keysym.BackSpace => {
                        wayland_context.pin.deleteBackwards();
                        wayland_context.surface.?.render() catch wayland_context.abort(error.OutOfMemory);
                        return;
                    },
                    xkb.Keysym.Delete => return,
                    xkb.Keysym.Escape => {
                        wayland_context.abort(error.UserAbort);
                        return;
                    },
                    else => {},
                }

                if (!wayland_context.getpin) return;

                var buffer: [16]u8 = undefined;
                const used = self.xkb_state.?.keyGetUtf8(keycode, &buffer);
                wayland_context.pin.appendSlice(buffer[0..used]) catch {};

                // We only get keyboard input when a surface exists.
                wayland_context.surface.?.render() catch wayland_context.abort(error.OutOfMemory);
            },
            .enter => {},
            .leave => {},
            .repeat_info => {},
        }
    }
};

const Surface = struct {
    wl_surface: *wl.Surface = undefined,
    layer_surface: *zwlr.LayerSurfaceV1 = undefined,
    configured: bool = false,
    width: u31 = undefined,
    height: u31 = undefined,

    scale: u31 = 1, // TODO we need to bind outputs for this and have a wl_seat listener

    /// Cursor / Touch hotspots, populated on first render.
    hotspots: std.ArrayListUnmanaged(HotSpot) = .{},

    pub fn init(self: *Surface) !void {
        const wl_surface = try wayland_context.compositor.?.createSurface();
        errdefer wl_surface.destroy();
        const layer_surface = try wayland_context.layer_shell.?.getLayerSurface(wl_surface, null, .overlay, "wayprompt");
        errdefer layer_surface.destroy();

        self.* = .{
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
        self.height = context.vertical_padding;
        self.width = context.horizontal_padding;

        if (wayland_context.getpin) {
            if (wayland_context.prompt) |prompt| {
                self.width = math.max(prompt.width + 2 * context.horizontal_padding, self.width);
                self.height += prompt.height + context.vertical_padding;
            }

            const square_padding = @divFloor(context.pin_square_size, 2);
            const pinarea_height = context.pin_square_size + 2 * square_padding;
            const pinarea_width = context.pin_square_amount * (context.pin_square_size + square_padding) + square_padding;

            self.height += pinarea_height + context.vertical_padding;
            self.width = math.max(self.width, pinarea_width + 2 * context.horizontal_padding);
        }

        if (wayland_context.title) |title| {
            self.width = math.max(title.width + 2 * context.horizontal_padding, self.width);
            self.height += title.height + context.vertical_padding;
        }
        if (wayland_context.description) |description| {
            self.width = math.max(description.width + 2 * context.horizontal_padding, self.width);
            self.height += description.height + context.vertical_padding;
        }
        if (wayland_context.errmessage) |errmessage| {
            self.width = math.max(errmessage.width + 2 * context.horizontal_padding, self.width);
            self.height += errmessage.height + context.vertical_padding;
        }

        {
            var button_amount: u31 = 0;
            var combined_button_length: u31 = 0;
            var max_button_height: u31 = 0;

            if (wayland_context.ok) |ok| {
                button_amount += 1;
                combined_button_length += ok.width + context.horizontal_padding + 2 * context.button_inner_padding;
                max_button_height = math.max(max_button_height, ok.height + 2 * context.button_inner_padding);
            }
            if (wayland_context.notok) |notok| {
                button_amount += 1;
                combined_button_length += notok.width + context.horizontal_padding + 2 * context.button_inner_padding;
                max_button_height = math.max(max_button_height, notok.height + 2 * context.button_inner_padding);
            }
            if (wayland_context.cancel) |cancel| {
                button_amount += 1;
                combined_button_length += cancel.width + context.horizontal_padding + 2 * context.button_inner_padding;
                max_button_height = math.max(max_button_height, cancel.height + 2 * context.button_inner_padding);
            }

            self.width = math.max(combined_button_length + context.horizontal_padding, self.width);

            if (max_button_height > 0) self.height += max_button_height + context.vertical_padding;

            debug.assert(self.hotspots.items.len == 0);
            try self.hotspots.ensureTotalCapacity(context.gpa.allocator(), max_button_height);
        }
    }

    pub fn deinit(self: *Surface) void {
        self.hotspots.deinit(context.gpa.allocator());
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
                // We just ignore the requested sizes. Figuring out a good size
                // based on the text context is already complicated enough. If
                // this annoys you, patches are welcome.
                self.configured = true;
                layer_surface.ackConfigure(ev.serial);
                self.render() catch {
                    wayland_context.abort(error.OutOfMemory);
                    return;
                };
            },
            .closed => wayland_context.abort(error.OutOfMemory),
        }
    }

    fn render(self: *Surface) !void {
        if (!self.configured) return;

        const buffer = (try wayland_context.buffer_pool.nextBuffer(self.width, self.height)) orelse return;
        const image = buffer.*.pixman_image.?;

        self.drawBackground(image, self.width, self.height);

        var Y: u31 = context.vertical_padding;
        if (wayland_context.title) |title| {
            const X = @divFloor(self.width, 2) -| @divFloor(title.width, 2);
            Y += try title.draw(image, &context.text_colour, X, Y);
        }
        if (wayland_context.description) |description| {
            const X = @divFloor(self.width, 2) -| @divFloor(description.width, 2);
            Y += try description.draw(image, &context.text_colour, X, Y);
        }

        if (wayland_context.getpin) {
            if (wayland_context.prompt) |prompt| {
                const X = @divFloor(self.width, 2) -| @divFloor(prompt.width, 2);
                Y += try prompt.draw(image, &context.text_colour, X, Y);
            }
            Y += self.drawPinarea(image, wayland_context.pin.len, Y);
        }

        if (wayland_context.errmessage) |errmessage| {
            const X = @divFloor(self.width, 2) -| @divFloor(errmessage.width, 2);
            Y += try errmessage.draw(image, &context.error_text_colour, X, Y);
        }

        // The hotspot list is populated on first render. We could technically
        // do it in calculateSize(), but we already have all the sizes here
        // already, so doing it here is more convenient for now.
        const populate_hotspots = self.hotspots.items.len == 0;

        // Buttons
        {
            const combined_button_length = blk: {
                var len: u31 = 0;
                if (wayland_context.ok) |ok| len += ok.width + context.horizontal_padding + 2 * context.button_inner_padding;
                if (wayland_context.notok) |notok| len += notok.width + context.horizontal_padding + 2 * context.button_inner_padding;
                if (wayland_context.cancel) |cancel| len += cancel.width + context.horizontal_padding + 2 * context.button_inner_padding;
                break :blk len;
            };
            var X: u31 = @divFloor(self.width + context.horizontal_padding, 2) -| @divFloor(combined_button_length, 2);
            if (wayland_context.cancel) |cancel| {
                if (populate_hotspots) {
                    self.hotspots.appendAssumeCapacity(.{
                        .effect = .cancel,
                        .x = X,
                        .y = Y,
                        .width = cancel.width + 2 * context.button_inner_padding,
                        .height = cancel.height + 2 * context.button_inner_padding,
                    });
                }

                borderedRectangle(
                    image,
                    X,
                    Y,
                    cancel.width + 2 * context.button_inner_padding,
                    cancel.height + 2 * context.button_inner_padding,
                    context.button_border,
                    self.scale,
                    &context.cancel_button_background_colour,
                    &context.border_colour,
                );
                _ = try cancel.draw(image, &context.text_colour, X + context.button_inner_padding, Y + context.button_inner_padding);
                X += cancel.width + 2 * context.button_inner_padding + context.horizontal_padding;
            }
            if (wayland_context.notok) |notok| {
                if (populate_hotspots) {
                    self.hotspots.appendAssumeCapacity(.{
                        .effect = .notok,
                        .x = X,
                        .y = Y,
                        .width = notok.width + 2 * context.button_inner_padding,
                        .height = notok.height + 2 * context.button_inner_padding,
                    });
                }

                borderedRectangle(
                    image,
                    X,
                    Y,
                    notok.width + 2 * context.button_inner_padding,
                    notok.height + 2 * context.button_inner_padding,
                    context.button_border,
                    self.scale,
                    &context.notok_button_background_colour,
                    &context.border_colour,
                );
                _ = try notok.draw(image, &context.text_colour, X + context.button_inner_padding, Y + context.button_inner_padding);
                X += notok.width + 2 * context.button_inner_padding + context.horizontal_padding;
            }
            if (wayland_context.ok) |ok| {
                if (populate_hotspots) {
                    self.hotspots.appendAssumeCapacity(.{
                        .effect = .ok,
                        .x = X,
                        .y = Y,
                        .width = ok.width + 2 * context.button_inner_padding,
                        .height = ok.height + 2 * context.button_inner_padding,
                    });
                }

                borderedRectangle(
                    image,
                    X,
                    Y,
                    ok.width + 2 * context.button_inner_padding,
                    ok.height + 2 * context.button_inner_padding,
                    context.button_border,
                    self.scale,
                    &context.ok_button_background_colour,
                    &context.border_colour,
                );
                _ = try ok.draw(image, &context.text_colour, X + context.button_inner_padding, Y + context.button_inner_padding);
            }
        }

        self.wl_surface.setBufferScale(self.scale);
        self.wl_surface.attach(buffer.*.wl_buffer.?, 0, 0);
        self.wl_surface.damageBuffer(0, 0, math.maxInt(i31), math.maxInt(u31));
        self.wl_surface.commit();
        buffer.*.busy = true;
    }

    fn drawBackground(self: *Surface, image: *pixman.Image, width: u31, height: u31) void {
        borderedRectangle(image, 0, 0, width, height, context.border, self.scale, &context.background_colour, &context.border_colour);
    }

    fn drawPinarea(self: *Surface, image: *pixman.Image, len: usize, pinarea_y: u31) u31 {
        const square_padding = @divFloor(context.pin_square_size, 2);
        const pinarea_height = context.pin_square_size + 2 * square_padding;
        const pinarea_width = context.pin_square_amount * (context.pin_square_size + square_padding) + square_padding;
        const pinarea_x = @divFloor(self.width, 2) - @divFloor(pinarea_width, 2);

        borderedRectangle(
            image,
            pinarea_x,
            pinarea_y,
            pinarea_width,
            pinarea_height,
            context.border,
            self.scale,
            &context.pinarea_background_colour,
            &context.pinarea_border_colour,
        );

        var i: usize = 0;
        while (i < len and i < context.pin_square_amount) : (i += 1) {
            const x = @intCast(u31, pinarea_x + (i * context.pin_square_size) + ((i + 1) * square_padding));
            const y = pinarea_y + square_padding;
            borderedRectangle(
                image,
                x,
                y,
                context.pin_square_size,
                context.pin_square_size,
                context.pin_square_border,
                self.scale,
                &context.pinarea_square_colour,
                &context.pinarea_border_colour,
            );
        }

        return pinarea_height + context.vertical_padding;
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

    pub fn nextBuffer(self: *BufferPool, width: u31, height: u31) !?*Buffer {
        var buffer: *Buffer = blk: {
            if (!self.a.busy) break :blk &self.a;
            if (!self.b.busy) break :blk &self.b;
            return null;
        };
        if (buffer.*.width != width or buffer.*.height != height or buffer.*.wl_buffer == null) {
            buffer.*.deinit();
            try buffer.*.init(width, height);
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

    pub fn init(self: *Buffer, width: u31, height: u31) !void {
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

        const shm_pool = try wayland_context.shm.?.createPool(fd, size);
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

const WaylandContext = struct {
    title: ?TextView = null,
    description: ?TextView = null,
    prompt: ?TextView = null,
    errmessage: ?TextView = null,
    ok: ?TextView = null,
    notok: ?TextView = null,
    cancel: ?TextView = null,

    getpin: bool = false,

    layer_shell: ?*zwlr.LayerShellV1 = null,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    seats: std.TailQueue(Seat) = .{},
    buffer_pool: BufferPool = .{},
    surface: ?Surface = null,

    xkb_context: *xkb.Context = undefined,

    loop: bool = true,
    exit_reason: ?anyerror = null,

    pin: SecretBuffer = undefined,

    pub fn abort(self: *WaylandContext, reason: anyerror) void {
        self.loop = false;
        self.exit_reason = reason;
    }

    pub fn run(self: *WaylandContext, getpin: bool) !?[]const u8 {
        self.pin = try SecretBuffer.new();
        defer self.pin.deinit();

        self.getpin = getpin;

        const wayland_display = blk: {
            if (context.wayland_display) |wd| break :blk wd;
            if (os.getenv("WAYLAND_DISPLAY")) |wd| break :blk wd;
            return error.NoWaylandDisplay;
        };

        _ = fcft.init(.never, false, .none);
        defer fcft.fini();

        var font_regular_names = [_][*:0]const u8{ "sans:size=14", "mono:size=14" };
        const font_regular = try fcft.Font.fromName(font_regular_names[0..], null);
        defer font_regular.destroy();

        var font_large_names = [_][*:0]const u8{ "sans:size=20", "mono:size=20" };
        const font_large = try fcft.Font.fromName(font_large_names[0..], null);
        defer font_large.destroy();

        if (context.title) |title| self.title = try TextView.new(mem.trim(u8, title, &ascii.spaces), font_large);
        defer if (self.title) |title| title.deinit();
        if (context.description) |description| self.description = try TextView.new(mem.trim(u8, description, &ascii.spaces), font_regular);
        defer if (self.description) |description| description.deinit();
        if (context.errmessage) |errmessage| self.errmessage = try TextView.new(mem.trim(u8, errmessage, &ascii.spaces), font_regular);
        defer if (self.errmessage) |errmessage| errmessage.deinit();
        if (context.prompt) |prompt| self.prompt = try TextView.new(mem.trim(u8, prompt, &ascii.spaces), font_large);
        defer if (self.prompt) |prompt| prompt.deinit();
        if (context.ok) |ok| self.ok = try TextView.new(mem.trim(u8, ok, &ascii.spaces), font_regular);
        defer if (self.ok) |ok| ok.deinit();
        if (context.notok) |notok| self.notok = try TextView.new(mem.trim(u8, notok, &ascii.spaces), font_regular);
        defer if (self.notok) |notok| notok.deinit();
        if (context.cancel) |cancel| self.cancel = try TextView.new(mem.trim(u8, cancel, &ascii.spaces), font_regular);
        defer if (self.cancel) |cancel| cancel.deinit();

        const display = try wl.Display.connect(@ptrCast([*:0]const u8, wayland_display.ptr));
        defer display.disconnect();

        const registry = try display.getRegistry();
        defer registry.destroy();
        registry.setListener(*WaylandContext, registryListener, self);

        const sync = try display.sync();
        defer sync.destroy();
        sync.setListener(*WaylandContext, syncListener, self);

        self.xkb_context = xkb.Context.new(.no_flags) orelse return error.OutOfMemory;
        defer (self.xkb_context.unref());

        // Cleanup all things we may set up in response to Wayland events.
        defer {
            if (self.surface) |*s| s.deinit();
            self.buffer_pool.reset();
            if (self.layer_shell) |ls| ls.destroy();
            if (self.compositor) |cmp| cmp.destroy();
            if (self.shm) |sm| sm.destroy();

            var it = self.seats.first;
            while (it) |node| {
                it = node.next;
                node.data.deinit();
                const alloc = context.gpa.allocator();
                alloc.destroy(node);
            }
        }

        // Per pinentry protocol documentation, the client may not send us anything
        // while it is waiting for a data response. So it's fine to just jump into
        // a different event loop here for a short while.
        while (self.loop) {
            if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }

        if (self.exit_reason) |reason| {
            return reason;
        } else if (self.getpin) {
            return self.pin.copySlice();
        } else {
            debug.assert(self.pin.len == 0);
            return null;
        }
    }

    fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, self: *WaylandContext) void {
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

    fn addSeat(self: *WaylandContext, wl_seat: *wl.Seat) !void {
        const alloc = context.gpa.allocator();
        const node = try alloc.create(std.TailQueue(Seat).Node);
        try node.data.init(wl_seat);
        self.seats.append(node);
    }

    fn syncListener(_: *wl.Callback, _: wl.Callback.Event, self: *WaylandContext) void {
        if (self.layer_shell == null or self.compositor == null or self.shm == null) {
            self.abort(error.MissingWaylandInterfaces);
        }

        self.surface = Surface{};
        self.surface.?.init() catch {
            self.surface = null;
            self.abort(error.OutOfMemory);
            return;
        };
    }
};

var wayland_context: WaylandContext = undefined;

/// Returned pin is owned by context.gpa.
pub fn run(getpin: bool) !?[]const u8 {
    wayland_context = .{};
    return (try wayland_context.run(getpin));
}
