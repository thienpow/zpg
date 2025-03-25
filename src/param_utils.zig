const std = @import("std");
const Param = @import("param.zig").Param;

pub fn formatParamAsText(buffer: *std.ArrayList(u8), param: Param) !void {
    const writer = buffer.writer();
    switch (param.value) {
        .Null => try writer.writeAll("NULL"),
        .String => |value| {
            // Escape single quotes for SQL
            try writer.writeByte('\'');
            for (value) |c| {
                if (c == '\'') try writer.writeByte('\''); // Double single quotes to escape
                try writer.writeByte(c);
            }
            try writer.writeByte('\'');
        },
        .Int => |data| {
            // Extract the integer based on its size
            switch (data.size) {
                1 => {
                    const value = std.mem.readInt(i8, data.bytes[0..1], .big);
                    try std.fmt.format(writer, "{d}", .{value});
                },
                2 => {
                    const value = std.mem.readInt(i16, data.bytes[0..2], .big);
                    try std.fmt.format(writer, "{d}", .{value});
                },
                4 => {
                    const value = std.mem.readInt(i32, data.bytes[0..4], .big);
                    try std.fmt.format(writer, "{d}", .{value});
                },
                8 => {
                    const value = std.mem.readInt(i64, data.bytes[0..8], .big);
                    try std.fmt.format(writer, "{d}", .{value});
                },
                else => unreachable,
            }
        },
        .Float => |data| {
            // Extract the float based on its size
            if (data.size == 4) {
                const bits = std.mem.readInt(u32, data.bytes[0..4], .big);
                const value: f32 = @bitCast(bits);
                try std.fmt.format(writer, "{d}", .{value});
            } else if (data.size == 8) {
                const bits = std.mem.readInt(u64, data.bytes[0..8], .big);
                const value: f64 = @bitCast(bits);
                try std.fmt.format(writer, "{d}", .{value});
            } else {
                unreachable;
            }
        },
        .Bool => |value| try writer.writeAll(if (value) "TRUE" else "FALSE"),
    }
}

pub fn formatExecuteStatement(buffer: *std.ArrayList(u8), name: []const u8, params: []const Param) !void {
    try buffer.writer().writeAll("EXECUTE ");
    try buffer.writer().writeAll(name);
    if (params.len > 0) {
        try buffer.writer().writeAll(" (");
        for (params, 0..) |param, i| {
            if (i > 0) try buffer.writer().writeAll(", ");
            try formatParamAsText(buffer, param);
        }
        try buffer.writer().writeAll(")");
    }
}
