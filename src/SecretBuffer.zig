const builtin = @import("builtin");
const std = @import("std");
const ascii = std.ascii;
const heap = std.heap;
const mem = std.mem;
const os = std.os;
const unicode = std.unicode;

const context = &@import("wayprompt.zig").context;

const Self = @This();

buffer: []align(mem.page_size) u8,
fba: heap.FixedBufferAllocator,
str: std.ArrayListUnmanaged(u8),
len: usize,

extern fn mlock(addr: *const anyopaque, len: usize) c_int;

pub fn new() !Self {
    const gpa = context.gpa.allocator();
    var ret: Self = undefined;
    ret.buffer = try gpa.alignedAlloc(u8, mem.page_size, 1024);
    ret.fba = heap.FixedBufferAllocator.init(ret.buffer);
    ret.str = .{};
    ret.len = 0;

    // Calling mlock(3) prevents the memory page we use for the password buffer
    // to be swapped.
    {
        var attempts: usize = 0;
        while (attempts < 10) : (attempts += 1) {
            const res = mlock(ret.buffer.ptr, ret.buffer.len);
            switch (os.errno(res)) {
                .SUCCESS => break,
                .AGAIN => continue,
                else => return error.UnexpectedError,
            }
        } else {
            return error.MlockFailedTooOften;
        }
    }

    // Prevent this page from showing up in code dumps.
    if (builtin.target.os.tag == .linux) {
        var attempts: usize = 0;
        while (attempts < 10) : (attempts += 1) {
            const res = os.system.madvise(ret.buffer.ptr, ret.buffer.len, os.MADV.DONTDUMP);
            switch (os.errno(res)) {
                .SUCCESS => break,
                .AGAIN => continue,
                else => return error.UnexpectedError,
            }
        } else {
            return error.MadvideFailedTooOften;
        }
    }

    return ret;
}

pub fn deinit(self: *Self) void {
    const gpa = context.gpa.allocator();
    gpa.free(self.buffer);
    self.str = undefined;
    self.len = undefined;
}

pub fn appendSlice(self: *Self, str: []const u8) !void {
    const fixed = self.fba.allocator();
    const len = try unicode.utf8CountCodepoints(str);
    try self.str.appendSlice(fixed, str);
    self.len += len;
}

pub fn deleteBackwards(self: *Self) void {
    if (self.str.items.len == 0) return;
    var i: usize = self.str.items.len - 1;
    while (i >= 0) : (i -= 1) {
        _ = unicode.utf8ByteSequenceLength(self.str.items[i]) catch continue;
        const fixed = self.fba.allocator();
        self.str.shrinkAndFree(fixed, i);
        self.len -= 1;
        return;
    }
    unreachable;
}

pub fn copySlice(self: *Self) !?[]const u8 {
    const gpa = context.gpa.allocator();
    if (self.str.items.len > 0) {
        const ret = try gpa.dupe(u8, self.str.items[0..]);
        return ret;
    } else {
        return null;
    }
}
