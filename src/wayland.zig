const builtin = @import("builtin");
const std = @import("std");
const os = std.os;
const cstr = std.cstr;
const mem = std.mem;
const fmt = std.fmt;
const math = std.math;
const unicode = std.unicode;
const debug = std.debug;

const pixman = @import("pixman");
const fcft = @import("fcft");
const xkb = @import("xkbcommon");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const util = @import("util.zig");

const context = &@import("wayprompt.zig").context;
const pinentry_context = &@import("pinentry.zig").pinentry_context;

const widget_padding = 10;

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
    len: usize,

    pub fn new(str: []const u8, font: *fcft.Font) !TextView {
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
            const text_run = try font.rasterizeTextRunUtf32(codepoints, .none);
            var width: u31 = 0;
            var i: usize = 0;
            while (i < text_run.count) : (i += 1) {
                width += @intCast(u31, text_run.glyphs[i].advance.x);
            }

            return TextView{
                .mode = .{ .text_run = text_run },
                .font = font,
                .width = width,
                .height = height,
                .len = codepoints.len,
            };
        } else {
            const glyphs = try alloc.alloc(*const fcft.Glyph, codepoints.len);
            errdefer alloc.free(glyphs);
            const kerns = try alloc.alloc(c_long, codepoints.len);
            errdefer alloc.free(kerns);

            var i: usize = 0;
            var width: u31 = 0;
            while (i < codepoints.len) : (i += 1) {
                glyphs[i] = try font.rasterizeCharUtf32(codepoints[i], .none);
                kerns[i] = 0;
                if (i > 0) {
                    var x_kern: c_long = 0;
                    if (font.kerning(codepoints[i - 1], codepoints[i], &x_kern, null)) kerns[i] = x_kern;
                }
                width += @intCast(u31, kerns[i] + glyphs[i].advance.x);
            }

            return TextView{
                .mode = .{ .glyphs = .{
                    .glyphs = glyphs,
                    .kerns = kerns,
                } },
                .font = font,
                .width = width,
                .height = height,
                .len = codepoints.len,
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

    pub fn draw(self: *const TextView, image: *pixman.Image, x: u31, y: u31) !u31 {
        const text_colour = comptime pixmanColourFromRGB("0xffffff") catch @compileError("bad colour");

        const glyphs = switch (self.mode) {
            .text_run => self.mode.text_run.glyphs[0..self.len],
            .glyphs => self.mode.glyphs.glyphs,
        };
        debug.assert(glyphs.len == self.len);

        var X: u31 = x;
        var Y: u31 = y;
        var i: usize = 0;
        while (i < glyphs.len) : (i += 1) {
            if (self.mode == .glyphs) X += @intCast(u31, self.mode.glyphs.kerns[i]);

            debug.print(">> i = {}\n", .{i});
            if (glyphs[i].cp == '\n') {
                X = x;
                Y += @intCast(u31, self.font.height);
                continue;
            }

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
                    // TODO: this probably allocs memory, so investigate replacement.
                    // TODO: do we need to recreate this for every char?
                    const c = pixman.Image.createSolidFill(&text_colour).?;
                    defer _ = c.unref();

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

        return self.height + widget_padding;
    }
};

const Seat = struct {
    wl_seat: *wl.Seat,

    // Keyboard related objects.
    wl_keyboard: ?*wl.Keyboard = null,
    xkb_state: ?*xkb.State = null,

    pub fn init(self: *Seat, wl_seat: *wl.Seat) !void {
        self.* = .{ .wl_seat = wl_seat };
        self.wl_seat.setListener(*Seat, seatListener, self);
    }

    pub fn deinit(self: *Seat) void {
        self.releaseKeyboard();
        self.wl_seat.destroy();
    }

    fn seatListener(_: *wl.Seat, event: wl.Seat.Event, self: *Seat) void {
        switch (event) {
            .capabilities => |ev| {
                // TODO eventually also do pointer things, I guess.
                if (ev.capabilities.keyboard) {
                    self.bindKeyboard() catch {};
                } else {
                    self.releaseKeyboard();
                }
            },
            .name => {}, // Do I look like I care?
        }
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
                    wayland_context.abort();
                    return;
                }
                const keymap_str = os.mmap(null, ev.size, os.PROT.READ, os.MAP.PRIVATE, ev.fd, 0) catch {
                    wayland_context.abort();
                    return;
                };
                defer os.munmap(keymap_str);
                const keymap = xkb.Keymap.newFromBuffer(wayland_context.xkb_context, keymap_str.ptr, keymap_str.len - 1, .text_v1, .no_flags) orelse {
                    wayland_context.abort();
                    return;
                };
                defer keymap.unref();
                const state = xkb.State.new(keymap) orelse {
                    wayland_context.abort();
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
                        wayland_context.loop = false;
                        return;
                    },
                    xkb.Keysym.BackSpace => {
                        if (!wayland_context.readingInput()) return;
                        // TODO to properly delete inputs, we need a codepoint
                        //      buffer (u21). Probably just copy the one from
                        //      nfm.
                        wayland_context.surface.?.render() catch wayland_context.abort();
                        return;
                    },
                    xkb.Keysym.Delete => {
                        if (!wayland_context.readingInput()) return;
                        wayland_context.pin = .{ .buffer = undefined, .len = 0 };
                        wayland_context.surface.?.render() catch wayland_context.abort();
                        return;
                    },
                    xkb.Keysym.Escape => {
                        wayland_context.abort();
                        return;
                    },
                    else => {},
                }
                if (!wayland_context.readingInput()) return;
                {
                    @setRuntimeSafety(true);
                    const used = self.xkb_state.?.keyGetUtf8(keycode, wayland_context.pin.unusedCapacitySlice());
                    wayland_context.pin.resize(wayland_context.pin.len + used) catch wayland_context.abort();
                }

                // We only get keyboard input when a surface exists.
                wayland_context.surface.?.render() catch wayland_context.abort();
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

    pub fn init(self: *Surface) !void {
        const wl_surface = try wayland_context.compositor.?.createSurface();
        errdefer wl_surface.destroy();
        const layer_surface = try wayland_context.layer_shell.?.getLayerSurface(wl_surface, null, .overlay, "wayprompt");
        errdefer layer_surface.destroy();

        self.* = .{
            .wl_surface = wl_surface,
            .layer_surface = layer_surface,
        };
        self.calculateSize();

        layer_surface.setListener(*Surface, layerSurfaceListener, self);
        layer_surface.setKeyboardInteractivity(.exclusive);
        layer_surface.setSize(self.width, self.height);
        wl_surface.commit();
    }

    fn calculateSize(self: *Surface) void {
        self.width = 600;
        self.height = widget_padding;
        if (wayland_context.readingInput()) {
            if (wayland_context.prompt) |prompt| self.height += prompt.height + widget_padding;
            self.height += 40 + widget_padding; // TODO don't hardcode pinarea height
        }
        if (wayland_context.title) |title| self.height += title.height + widget_padding;
        if (wayland_context.description) |description| self.height += description.height + widget_padding;
        if (wayland_context.errmessage) |errmessage| self.height += errmessage.height + widget_padding;
    }

    pub fn deinit(self: *const Surface) void {
        self.layer_surface.destroy();
        self.wl_surface.destroy();
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
                    wayland_context.abort();
                    return;
                };
            },
            .closed => wayland_context.abort(),
        }
    }

    fn render(self: *Surface) !void {
        if (!self.configured) return;

        const buffer = (try wayland_context.buffer_pool.nextBuffer(self.width, self.height)) orelse return;
        const image = buffer.*.pixman_image.?;

        self.drawBackground(image, self.width, self.height);

        var Y: u31 = widget_padding;
        if (wayland_context.title) |title| Y += try title.draw(image, widget_padding, Y);
        if (wayland_context.description) |description| Y += try description.draw(image, widget_padding, Y);

        if (wayland_context.readingInput()) {
            if (wayland_context.prompt) |prompt| Y += try prompt.draw(image, widget_padding, Y);
            self.drawPinarea(image, 16, try util.unicodeLen(wayland_context.pin.slice()), Y);
            Y += 40 + widget_padding; // TODO do not hardcode pinarea size;
        }

        if (wayland_context.errmessage) |errmessage| Y += try errmessage.draw(image, widget_padding, Y);

        self.wl_surface.setBufferScale(self.scale);
        self.wl_surface.attach(buffer.*.wl_buffer.?, 0, 0);
        self.wl_surface.damageBuffer(0, 0, math.maxInt(i31), math.maxInt(u31));
        self.wl_surface.commit();
        buffer.*.busy = true;
    }

    fn drawBackground(self: *Surface, image: *pixman.Image, width: u31, height: u31) void {
        const background_colour = comptime pixmanColourFromRGB("0x666666") catch @compileError("bad colour");
        const border_colour = comptime pixmanColourFromRGB("0x333333") catch @compileError("bad colour");
        borderedRectangle(image, 0, 0, width, height, 2, self.scale, &background_colour, &border_colour);
    }

    fn drawPinarea(self: *Surface, image: *pixman.Image, capacity: u31, len: usize, pinarea_y: u31) void {
        // TODO if capacity would overflow, reduce it
        const square_size = 20;
        const square_padding = @divExact(square_size, 2);
        const square_halfpadding = @divExact(square_padding, 2);
        const pinarea_height = square_size + 2 * square_padding;
        const pinarea_width = capacity * (square_size + 2 * square_halfpadding) + 2 * square_halfpadding;
        const pinarea_x = @divFloor(self.width, 2) - @divFloor(pinarea_width, 2);

        const background_colour = comptime pixmanColourFromRGB("0x999999") catch @compileError("bad colour");
        const border_colour = comptime pixmanColourFromRGB("0x7F7F7F") catch @compileError("bad colour");
        const square_colour = comptime pixmanColourFromRGB("0xCCCCCC") catch @compileError("bad colour");

        borderedRectangle(image, pinarea_x, pinarea_y, pinarea_width, pinarea_height, 2, self.scale, &background_colour, &border_colour);

        var i: usize = 0;
        while (i < len and i < capacity) : (i += 1) {
            const x = @intCast(u31, pinarea_x + i * square_size + (i + 1) * square_padding);
            const y = pinarea_y + square_padding;
            borderedRectangle(image, x, y, square_size, square_size, 1, self.scale, &square_colour, &border_colour);
        }
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
                break :blk try os.memfd_createZ("/wayprompt", os.linux.MFD_CLOEXEC);
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
    const Mode = enum { pinentry_getpin, pinentry_message, pinentry_confirm };
    mode: Mode = undefined,

    title: ?TextView = null,
    description: ?TextView = null,
    prompt: ?TextView = null,
    errmessage: ?TextView = null,

    layer_shell: ?*zwlr.LayerShellV1 = null,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    seats: std.TailQueue(Seat) = .{},
    buffer_pool: BufferPool = .{},
    surface: ?Surface = null,

    xkb_context: *xkb.Context = undefined,

    loop: bool = true,
    missing_wayland_interfaces: bool = false,
    pin: std.BoundedArray(u8, 1024) = .{ .buffer = undefined, .len = 0 },

    pub fn abort(self: *WaylandContext) void {
        self.pin = .{ .buffer = undefined, .len = 0 };
        self.loop = false;
    }

    pub fn run(self: *WaylandContext, mode: Mode) !?[]const u8 {
        self.mode = mode;

        _ = fcft.init(.never, false, .none);
        defer fcft.fini();

        var font_regular_names = [_][*:0]const u8{ "sans:size=14", "mono:size=14" };
        const font_regular = try fcft.Font.fromName(font_regular_names[0..], null);
        defer font_regular.destroy();

        var font_large_names = [_][*:0]const u8{ "sans:size=20", "mono:size=20" };
        const font_large = try fcft.Font.fromName(font_large_names[0..], null);
        defer font_large.destroy();

        switch (mode) {
            .pinentry_getpin, .pinentry_confirm, .pinentry_message => {
                if (pinentry_context.title) |title| self.title = try TextView.new(title, font_large);
                if (pinentry_context.description) |description| self.description = try TextView.new(description, font_regular);
                if (pinentry_context.errmessage) |errmessage| self.errmessage = try TextView.new(errmessage, font_regular);
                if (pinentry_context.prompt) |prompt| self.prompt = try TextView.new(prompt, font_large);
            },
        }
        defer {
            if (self.title) |title| title.deinit();
            if (self.description) |description| description.deinit();
            if (self.prompt) |prompt| prompt.deinit();
            if (self.errmessage) |errmessage| errmessage.deinit();
        }

        const wayland_display = blk: {
            if (pinentry_context.wayland_display) |wd| break :blk wd;
            if (os.getenv("WAYLAND_DISPLAY")) |wd| break :blk wd;
            return error.NoWaylandDisplay;
        };

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
            if (self.surface) |s| s.deinit();
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
        if (self.missing_wayland_interfaces) return error.MissingWaylandInterfaces;

        if (self.readingInput() and self.pin.len > 0) {
            const alloc = context.gpa.allocator();
            const pin = try alloc.dupe(u8, self.pin.slice());
            return pin;
        } else {
            return null;
        }
    }

    pub fn readingInput(self: WaylandContext) bool {
        return self.mode == .pinentry_getpin;
    }

    fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, self: *WaylandContext) void {
        switch (event) {
            .global => |ev| {
                if (cstr.cmp(ev.interface, zwlr.LayerShellV1.getInterface().name) == 0) {
                    self.layer_shell = registry.bind(ev.name, zwlr.LayerShellV1, 4) catch {
                        self.abort();
                        return;
                    };
                } else if (cstr.cmp(ev.interface, wl.Compositor.getInterface().name) == 0) {
                    self.compositor = registry.bind(ev.name, wl.Compositor, 4) catch {
                        self.abort();
                        return;
                    };
                } else if (cstr.cmp(ev.interface, wl.Shm.getInterface().name) == 0) {
                    self.shm = registry.bind(ev.name, wl.Shm, 1) catch {
                        self.abort();
                        return;
                    };
                } else if (cstr.cmp(ev.interface, wl.Seat.getInterface().name) == 0) {
                    const seat = registry.bind(ev.name, wl.Seat, 1) catch {
                        self.abort();
                        return;
                    };
                    self.addSeat(seat) catch {
                        seat.destroy();
                        self.abort();
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
            self.missing_wayland_interfaces = true;
            self.abort();
        }

        self.surface = Surface{};
        self.surface.?.init() catch {
            self.surface = null;
            self.abort();
            return;
        };
    }
};

var wayland_context: WaylandContext = undefined;

/// Returned pin is owned by context.gpa.
pub fn run(mode: WaylandContext.Mode) !?[]const u8 {
    wayland_context = .{};
    return (try wayland_context.run(mode));
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
