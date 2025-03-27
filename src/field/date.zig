const std = @import("std");

pub const Date = struct {
    year: i16,
    month: u8,
    day: u8,

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Date {
        _ = allocator; // Unused for now, but keeping for consistency
        if (text.len < 10) return error.InvalidDateFormat;

        const year = try std.fmt.parseInt(i16, text[0..4], 10);
        if (text[4] != '-') return error.InvalidDateFormat;
        const month = try std.fmt.parseInt(u8, text[5..7], 10);
        if (text[7] != '-') return error.InvalidDateFormat;
        const day = try std.fmt.parseInt(u8, text[8..10], 10);

        if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidDate;
        // Optional: Add more precise day validation (e.g., Feb 29 only in leap years)

        return Date{ .year = year, .month = month, .day = day };
    }

    pub const isDate = true;
};
