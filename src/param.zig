const std = @import("std");

pub const Param = struct {
    format: u16, // 0 = text, 1 = binary
    value: ParamValue,

    pub fn writeTo(self: Param, writer: anytype) !void {
        return self.value.writeTo(writer, self.format);
    }

    // Create a parameter with a string value
    pub fn string(value: []const u8) Param {
        return .{
            .format = 0,
            .value = .{ .String = value },
        };
    }

    // Create a parameter with an int value
    pub fn int(value: anytype) Param {
        return .{
            .format = 1,
            .value = .{ .Int = .{ .bytes = intToBytes(value), .size = @sizeOf(@TypeOf(value)) } },
        };
    }

    // Create a parameter with a float value
    pub fn float(value: anytype) Param {
        const T = @TypeOf(value);
        if (T != f32 and T != f64) {
            @compileError("float parameter must be f32 or f64");
        }

        return .{
            .format = 1,
            .value = .{ .Float = .{ .bytes = floatToBytes(value), .size = @sizeOf(T) } },
        };
    }

    // Create a parameter with a boolean value
    pub fn boolean(value: bool) Param {
        return .{
            .format = 1,
            .value = .{ .Bool = value },
        };
    }

    // Create a null parameter
    pub fn nullValue() Param {
        return .{
            .format = 0,
            .value = .Null,
        };
    }
};

const ParamValue = union(enum) {
    Null,
    String: []const u8,
    Int: struct {
        bytes: [8]u8,
        size: usize,
    },
    Float: struct {
        bytes: [8]u8,
        size: usize,
    },
    Bool: bool,

    pub fn writeTo(self: ParamValue, writer: anytype, format: u16) !void {
        _ = format;
        switch (self) {
            .Null => {
                try writer.writeInt(i32, -1, .big); // -1 indicates NULL
            },
            .String => |value| {
                try writer.writeInt(i32, @intCast(value.len), .big);
                try writer.writeAll(value);
            },
            .Int => |data| {
                try writer.writeInt(i32, @intCast(data.size), .big);
                try writer.writeAll(data.bytes[0..data.size]);
            },
            .Float => |data| {
                try writer.writeInt(i32, @intCast(data.size), .big);
                try writer.writeAll(data.bytes[0..data.size]);
            },
            .Bool => |value| {
                try writer.writeInt(i32, 1, .big); // 1 byte
                try writer.writeByte(if (value) 1 else 0);
            },
        }
    }
};

// Helper function to convert integers to network byte order
fn intToBytes(value: anytype) [8]u8 {
    const T = @TypeOf(value);
    var bytes = [_]u8{0} ** 8;

    switch (@typeInfo(T)) {
        .int => |info| {
            const size = @sizeOf(T);
            switch (size) {
                1 => {
                    if (info.signedness == .signed) {
                        bytes[0] = @bitCast(@as(i8, @intCast(value)));
                    } else {
                        bytes[0] = @intCast(value);
                    }
                },
                2 => {
                    if (info.signedness == .signed) {
                        std.mem.writeInt(i16, bytes[0..2], @intCast(value), .big);
                    } else {
                        std.mem.writeInt(u16, bytes[0..2], @intCast(value), .big);
                    }
                },
                4 => {
                    if (info.signedness == .signed) {
                        std.mem.writeInt(i32, bytes[0..4], @intCast(value), .big);
                    } else {
                        std.mem.writeInt(u32, bytes[0..4], @intCast(value), .big);
                    }
                },
                8 => {
                    if (info.signedness == .signed) {
                        std.mem.writeInt(i64, bytes[0..8], @intCast(value), .big);
                    } else {
                        std.mem.writeInt(u64, bytes[0..8], @intCast(value), .big);
                    }
                },
                else => @compileError("Unsupported integer size (must be 1, 2, 4, or 8 bytes)"),
            }
        },
        else => @compileError("Value must be an integer type"),
    }

    return bytes;
}

// Helper function to convert floats to network byte order
fn floatToBytes(value: anytype) [8]u8 {
    const T = @TypeOf(value);
    var bytes = [_]u8{0} ** 8;

    if (T == f32) {
        std.mem.writeInt(u32, bytes[0..4], @as(u32, @bitCast(value)), .big);
    } else if (T == f64) {
        std.mem.writeInt(u64, bytes[0..8], @as(u64, @bitCast(value)), .big);
    } else {
        @compileError("Value must be f32 or f64");
    }

    return bytes;
}
