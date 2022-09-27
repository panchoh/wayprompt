const std = @import("std");
const math = std.math;
const mem = std.mem;
const unicode = std.unicode;

const Self = @This();

const Direction = enum {
    left,
    right,
};

buffer: std.ArrayList(u21),
cursor: usize = 0,

pub fn new(alloc: mem.Allocator) !Self {
    return Self{
        .buffer = try std.ArrayList(u21).initCapacity(alloc, 1024),
    };
}

pub fn toOwnedUtf8Slice(self: *Self) ![]const u8 {
    defer self.deinit();
    return try codepointSliceToUtf8SlizeAlloc(self.buffer.allocator, self.buffer.items);
}

pub fn deinit(self: *Self) void {
    self.buffer.deinit();
}

pub fn moveCursor(self: *Self, comptime direction: Direction, amount: usize) void {
    switch (direction) {
        .right => self.cursor = math.min(self.cursor +| amount, self.buffer.items.len),
        .left => self.cursor -|= amount,
    }
}

pub fn delete(self: *Self, comptime direction: Direction, amount: usize) void {
    var i: usize = 0;
    switch (direction) {
        .right => while (i < amount) : (i += 1) {
            if (self.cursor < self.buffer.items.len) {
                _ = self.buffer.orderedRemove(self.cursor);
            }
        },
        .left => while (i < amount) : (i += 1) {
            if (self.cursor > 0) {
                self.cursor -= 1;
                _ = self.buffer.orderedRemove(self.cursor);
            }
        },
    }
}

pub fn lenToNextWordStart(self: *Self, comptime direction: Direction) ?usize {
    if (direction == .right and self.cursor == self.buffer.items.len) return null;
    if (direction == .left and self.cursor == 0) return null;

    var i: usize = self.cursor;
    switch (direction) {
        .left => {
            while (i > 0 and isSpace(self.buffer.items[i - 1])) : (i -= 1) {}
            while (i > 0 and !isSpace(self.buffer.items[i - 1])) : (i -= 1) {}
            return self.cursor - i;
        },
        .right => {
            while (i < self.buffer.items.len - 1 and !isSpace(self.buffer.items[i])) : (i += 1) {}
            while (i < self.buffer.items.len - 1 and isSpace(self.buffer.items[i])) : (i += 1) {}
            if (isSpace(self.buffer.items[i])) i += 1;
            return i - self.cursor;
        },
    }
}

pub fn insertUTF8Slice(self: *Self, slice: []const u8) !void {
    const buflen = try unicode.utf8CountCodepoints(slice);
    try self.buffer.ensureUnusedCapacity(buflen);
    const view = unicode.Utf8View.initUnchecked(slice); // Errors would have been raised above.
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        try self.insertCodepoint(cp);
    }
}

pub fn insertCodepoint(self: *Self, char: u21) !void {
    try self.buffer.insert(self.cursor, char);
    self.cursor += 1;
}

pub fn insertCodepointSlice(self: *Self, slice: []const u8) !void {
    try self.buffer.insertSlice(self.cursor, slice);
    self.cursor += slice.len;
}

fn isSpace(cp: u21) bool {
    if (cp == ' ') return true;
    if (cp == '\t') return true;
    if (cp == '\n') return true;
    if (cp == '\r') return true;
    return false;
}

fn codepointSliceToUtf8SlizeAlloc(alloc: mem.Allocator, slice: []const u21) ![]u8 {
    const buf_size = blk: {
        var len: usize = 0;
        for (slice) |cp| {
            len += try unicode.utf8CodepointSequenceLength(cp);
        }
        break :blk len;
    };

    var list: std.ArrayListUnmanaged(u8) = .{};
    try list.ensureUnusedCapacity(alloc, buf_size);
    errdefer list.deinit(alloc);

    var it = CodePointToUtf8Iterator.from(slice);
    while (try it.next()) |c| list.appendAssumeCapacity(c);

    return list.toOwnedSlice(alloc);
}

pub const CodePointToUtf8Iterator = struct {
    a: ?u8 = null,
    b: ?u8 = null,
    c: ?u8 = null,
    buf: []const u21,

    pub fn from(s: []const u21) CodePointToUtf8Iterator {
        return .{ .buf = s };
    }

    pub fn next(self: *CodePointToUtf8Iterator) !?u8 {
        if (self.a) |a| {
            defer self.a = null;
            return a;
        }
        if (self.b) |b| {
            defer self.b = null;
            return b;
        }
        if (self.c) |c| {
            defer self.c = null;
            return c;
        }
        if (self.buf.len == 0) return null;
        defer self.buf = self.buf[1..];
        var out: [4]u8 = undefined;
        const len = try unicode.utf8Encode(self.buf[0], &out);
        if (len > 1) self.a = out[1];
        if (len > 2) self.b = out[2];
        if (len > 3) self.c = out[3];
        return out[0];
    }
};
