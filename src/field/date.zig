const std = @import("std");

pub const Date = struct {
    year: i16,
    month: u8,
    day: u8,

    pub fn fromPostgresBinary(data: []const u8, allocator: std.mem.Allocator) !Date {
        _ = allocator; // Not needed here
        if (data.len != 4) return error.InvalidDateFormat;

        // Read days since 2000-01-01 (big-endian i32)
        var days_since_epoch: i32 = @bitCast(std.mem.bytesToValue(i32, data[0..4]));
        days_since_epoch = @byteSwap(days_since_epoch);

        // Convert to YYYY-MM-DD
        const epoch_year: i16 = 2000;
        const absolute_days: i32 = days_since_epoch + 730120; // Adjust to match Zig's epoch (0000-03-01)
        var y: i16 = epoch_year;
        var m: u8 = 1;
        var d: u8 = 1;

        var days_left: i32 = absolute_days;
        while (days_left >= 365) {
            const leap = if ((y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)) 1 else 0;
            if (days_left >= (365 + leap)) {
                days_left -= (365 + leap);
                y += 1;
            } else break;
        }

        const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        if ((y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)) month_days[1] = 29; // Leap year

        for (0..12) |i| {
            if (days_left >= month_days[i]) {
                days_left -= month_days[i];
                m += 1;
            } else break;
        }
        d += @intCast(days_left);

        return Date{ .year = y, .month = m, .day = d };
    }

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
