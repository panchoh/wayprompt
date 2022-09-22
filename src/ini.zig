// This file is part of nfm, the neat file manager.
//
// Copyright © 2021 Leon Henrik Plickat
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License version 3 as published
// by the Free Software Foundation.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const ascii = std.ascii;
const io = std.io;
const mem = std.mem;

fn IniTok(comptime T: type) type {
    return struct {
        const Content = union(enum) {
            section: []const u8,
            assign: struct {
                variable: []const u8,
                value: []const u8,
            },
        };

        const Self = @This();

        reader: T,
        stack_buffer: [1024]u8 = undefined,
        // TODO maybe there should be an additional heap buffer for very long lines.

        pub fn next(self: *Self, line: *usize) !?Content {
            while (true) {
                line.* += 1;
                if (try self.reader.readUntilDelimiterOrEof(&self.stack_buffer, '\n')) |__buf| {
                    if (__buf.len == 1) {
                        if (__buf[0] == '#') {
                            continue;
                        } else {
                            return error.InvalidLine;
                        }
                    }
                    if (__buf.len == 0) continue;

                    const buf = blk: {
                        const _buf = mem.trim(u8, __buf, &ascii.spaces);
                        if (_buf.len == 0) continue;
                        if (_buf[0] == '#') continue;
                        for (_buf[1..]) |char, i| {
                            if (char == '#' and _buf[i - 1] != '\\') {
                                break :blk mem.trim(u8, _buf[0 .. i + 1], &ascii.spaces);
                            }
                        }
                        break :blk _buf;
                    };

                    // Is this line a section header?
                    if (buf[0] == '[') {
                        if (buf[buf.len - 1] != ']') return error.InvalidLine;
                        if (buf.len < 3) return error.InvalidLine;
                        return Content{ .section = buf[1 .. buf.len - 1] };
                    }

                    // Is this line an assignment?
                    var eq_pos = blk: {
                        for (buf) |char, i| {
                            if (char == '=') {
                                if (i == buf.len - 1) return error.InvalidLine;
                                break :blk i;
                            }
                        }
                        return error.InvalidLine;
                    };
                    return Content{
                        .assign = .{
                            .variable = blk: {
                                const variable = mem.trim(u8, buf[0..eq_pos], &ascii.spaces);
                                if (variable.len == 0) return error.InvalidLine;
                                break :blk variable;
                            },
                            .value = blk: {
                                const value = mem.trim(u8, buf[eq_pos + 1 ..], &ascii.spaces);
                                if (value.len < 2 or value[value.len - 1] != ';') return error.InvalidLine;
                                // TODO[zig] should be inline, but that crashes the zig compiler right now
                                for ([_]u8{ '\'', '"' }) |q| {
                                    if (value[0] == q) {
                                        if (value[value.len - 2] == q and value.len > 3) {
                                            break :blk value[1 .. value.len - 2];
                                        } else {
                                            return error.InvalidLine;
                                        }
                                    }
                                }
                                break :blk value[0 .. value.len - 1];
                            },
                        },
                    };
                } else {
                    return null;
                }
            }
        }
    };
}

pub fn tokenize(reader: anytype) IniTok(@TypeOf(reader)) {
    return .{
        .reader = reader,
    };
}

test "ini tokenizer good input" {
    const reader = io.fixedBufferStream(
        \\[header] # I am a comment
        \\a = b;
        \\
        \\c=d;
        \\e= f;# Another comment
        \\
        \\[header2]
        \\[header3]
        \\#
        \\
        \\hello = this has spaces;
        \\hello = this one; is weird;
        \\hello = test=test;
        \\
    ).reader();

    var it = tokenize(reader);
    var line: usize = 0;

    if (try it.next(&line)) |a| {
        try std.testing.expect(a == .section);
        try std.testing.expectEqualSlices(u8, "header", a.section);
        try std.testing.expect(line == 1);
    } else {
        unreachable;
    }

    if (try it.next(&line)) |a| {
        try std.testing.expect(a == .assign);
        try std.testing.expectEqualSlices(u8, "a", a.assign.variable);
        try std.testing.expectEqualSlices(u8, "b", a.assign.value);
        try std.testing.expect(line == 2);
    } else {
        unreachable;
    }

    if (try it.next(&line)) |a| {
        try std.testing.expect(a == .assign);
        try std.testing.expectEqualSlices(u8, "c", a.assign.variable);
        try std.testing.expectEqualSlices(u8, "d", a.assign.value);
        try std.testing.expect(line == 4);
    } else {
        unreachable;
    }

    if (try it.next(&line)) |a| {
        try std.testing.expect(a == .assign);
        try std.testing.expectEqualSlices(u8, "e", a.assign.variable);
        try std.testing.expectEqualSlices(u8, "f", a.assign.value);
        try std.testing.expect(line == 5);
    } else {
        unreachable;
    }

    if (try it.next(&line)) |a| {
        try std.testing.expect(a == .section);
        try std.testing.expectEqualSlices(u8, "header2", a.section);
        try std.testing.expect(line == 7);
    } else {
        unreachable;
    }

    if (try it.next(&line)) |a| {
        try std.testing.expect(a == .section);
        try std.testing.expectEqualSlices(u8, "header3", a.section);
        try std.testing.expect(line == 8);
    } else {
        unreachable;
    }

    if (try it.next(&line)) |a| {
        try std.testing.expect(a == .assign);
        try std.testing.expectEqualSlices(u8, "hello", a.assign.variable);
        try std.testing.expectEqualSlices(u8, "this has spaces", a.assign.value);
        try std.testing.expect(line == 11);
    } else {
        unreachable;
    }

    if (try it.next(&line)) |a| {
        try std.testing.expect(a == .assign);
        try std.testing.expectEqualSlices(u8, "hello", a.assign.variable);
        try std.testing.expectEqualSlices(u8, "this one; is weird", a.assign.value);
        try std.testing.expect(line == 12);
    } else {
        unreachable;
    }

    if (try it.next(&line)) |a| {
        try std.testing.expect(a == .assign);
        try std.testing.expectEqualSlices(u8, "hello", a.assign.variable);
        try std.testing.expectEqualSlices(u8, "test=test", a.assign.value);
        try std.testing.expect(line == 13);
    } else {
        unreachable;
    }

    try std.testing.expect((try it.next(&line)) == null);
}

test "ini tokenizer bad input" {
    {
        const reader = io.fixedBufferStream(
            \\[section
            \\
        ).reader();
        var it = tokenize(reader);
        var line: usize = 0;
        try std.testing.expectError(error.InvalidLine, it.next(&line));
        try std.testing.expect(line == 1);
    }
    {
        const reader = io.fixedBufferStream(
            \\section]
            \\
        ).reader();
        var it = tokenize(reader);
        var line: usize = 0;
        try std.testing.expectError(error.InvalidLine, it.next(&line));
        try std.testing.expect(line == 1);
    }
    {
        const reader = io.fixedBufferStream(
            \\[]
            \\
        ).reader();
        var it = tokenize(reader);
        var line: usize = 0;
        try std.testing.expectError(error.InvalidLine, it.next(&line));
        try std.testing.expect(line == 1);
    }
    {
        const reader = io.fixedBufferStream(
            \\ =B;
            \\
        ).reader();
        var it = tokenize(reader);
        var line: usize = 0;
        try std.testing.expectError(error.InvalidLine, it.next(&line));
        try std.testing.expect(line == 1);
    }
    {
        const reader = io.fixedBufferStream(
            \\a =
            \\
        ).reader();
        var it = tokenize(reader);
        var line: usize = 0;
        try std.testing.expectError(error.InvalidLine, it.next(&line));
        try std.testing.expect(line == 1);
    }
    {
        const reader = io.fixedBufferStream(
            \\a =  ;
            \\
        ).reader();
        var it = tokenize(reader);
        var line: usize = 0;
        try std.testing.expectError(error.InvalidLine, it.next(&line));
        try std.testing.expect(line == 1);
    }
}
