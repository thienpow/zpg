const std = @import("std");

pub fn StringType(comptime n: usize, comptime is_fixed: bool) type {
    return if (is_fixed) [n]u8 else struct {
        value: []const u8,
        pub const isVarchar = true; // Marker for VARCHAR(n)

        pub fn init(value: []const u8) !@This() {
            if (value.len > n) return error.StringTooLong;

            return .{ .value = value };
        }
        pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !@This() {
            if (text.len > n) return error.StringTooLong;
            const persistent = try allocator.dupe(u8, text);
            return .{ .value = persistent };
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
