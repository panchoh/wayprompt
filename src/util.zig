const std = @import("std");
const unicode = std.unicode;

pub fn unicodeLen(bytes: []const u8) !usize {
    var view = try unicode.Utf8View.init(bytes);
    var len: usize = 0;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |_| : (len += 1) {}
    return len;
}
