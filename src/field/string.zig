const std = @import("std");

pub fn StringType(comptime n: usize, comptime is_fixed: bool) type {
    return if (is_fixed) [n]u8 else struct {
        value: []const u8,
        pub fn init(value: []const u8) !@This() {
            if (value.len > n) return error.StringTooLong;
            return .{ .value = value };
        }
        pub fn fromPostgresText(text: []const u8, _: std.mem.Allocator) !@This() {
            if (text.len > n) return error.StringTooLong;
            return .{ .value = text };
        }
    };
}

// Define VARCHAR and CHAR as functions that return a type
pub fn VARCHAR(comptime n: usize) type {
    return StringType(n, false);
}

pub fn CHAR(comptime n: usize) type {
    return StringType(n, true);
}
