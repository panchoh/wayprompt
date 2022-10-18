const std = @import("std");
const ascii = std.ascii;
const unicode = std.unicode;
const debug = std.debug;

const context = &@import("wayprompt.zig").context;

const Self = @This();

buffer: std.ArrayListUnmanaged(u8) = .{},
len: usize = 0,

pub fn appendSlice(self: *Self, str: []const u8) !void {
    const len = try unicode.utf8CountCodepoints(str);
    const alloc = context.gpa.allocator();
    try self.buffer.appendSlice(alloc, str);
    self.len += len;
}

pub fn deleteBackwards(self: *Self) void {
    if (self.buffer.items.len == 0) return;
    const alloc = context.gpa.allocator();
    var i: usize = self.buffer.items.len - 1;
    while (i >= 0) : (i -= 1) {
        _ = unicode.utf8ByteSequenceLength(self.buffer.items[i]) catch continue;
        self.buffer.shrinkAndFree(alloc, i);
        self.len -= 1;
        return;
    }
    unreachable;
}

pub fn toOwnedSlice(self: *Self) ?[]const u8 {
    const alloc = context.gpa.allocator();
    defer self.* = .{};
    if (self.buffer.items.len > 0) {
        return self.buffer.toOwnedSlice(alloc);
    } else {
        return null;
    }
}

pub fn deinit(self: *Self) void {
    const alloc = context.gpa.allocator();
    self.buffer.deinit(alloc);
    self.* = .{};
}
