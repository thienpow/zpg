const std = @import("std");

pub const Date = struct {
    year: i16,
    month: u8,
    day: u8,

    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    pub fn fromPostgresBinary(data: []const u8) !Date {
        if (data.len != 4) return error.InvalidDateFormat;

        // Read days since 2000-01-01 (big-endian i32)
        const days_since_epoch: i32 = std.mem.readInt(i32, data[0..4], .big);

        // Convert to YYYY-MM-DD
        const epoch_year: i16 = 2000;
        var y: i16 = epoch_year;
        var m: u8 = 1;
        var d: u8 = 1;
        var days_left: i32 = days_since_epoch;

        // Handle years before or after 2000
        while (days_left != 0) {
            var leap: u8 = if ((@rem(y, 4) == 0 and @rem(y, 100) != 0) or @rem(y, 400) == 0) 1 else 0;
            const days_in_year: i32 = 365 + @as(i32, leap); // Cast leap to i32 to avoid overflow
            if (days_left >= days_in_year) {
                days_left -= days_in_year;
                y += 1;
            } else if (days_left < 0) {
                y -= 1;
                leap = if ((@rem(y, 4) == 0 and @rem(y, 100) != 0) or @rem(y, 400) == 0) 1 else 0;
                days_left += (365 + @as(i32, leap));
            } else {
                break;
            }
        }

        // Adjust remaining days into months and days
        var month_days = days_in_month;
        const is_leap = (@rem(y, 4) == 0 and @rem(y, 100) != 0) or @rem(y, 400) == 0;
        if (is_leap) month_days[1] = 29;

        if (days_left < 0) {
            // Move back one month if days_left is negative
            m = 12;
            y -= 1;
            const prev_leap = (@rem(y, 4) == 0 and @rem(y, 100) != 0) or @rem(y, 400) == 0;
            month_days = days_in_month;
            if (prev_leap) month_days[1] = 29;
            days_left += month_days[11]; // December of previous year
        }

        for (0..12) |i| {
            if (days_left >= month_days[i]) {
                days_left -= month_days[i];
                m += 1;
            } else {
                break;
            }
        }
        d += @intCast(days_left);

        // Validation
        if (m < 1 or m > 12 or d < 1 or d > month_days[m - 1]) {
            return error.InvalidDate;
        }

        return Date{ .year = y, .month = m, .day = d };
    }

    pub fn fromPostgresText(text: []const u8) !Date {
        if (text.len < 10) return error.InvalidDateFormat;

        // Parse YYYY-MM-DD format
        const year = try std.fmt.parseInt(i16, text[0..4], 10);
        if (text[4] != '-') return error.InvalidDateFormat;
        const month = try std.fmt.parseInt(u8, text[5..7], 10);
        if (text[7] != '-') return error.InvalidDateFormat;
        const day = try std.fmt.parseInt(u8, text[8..10], 10);

        // Basic range validation
        if (month < 1 or month > 12 or day < 1) return error.InvalidDate;

        // Detailed validation with leap year consideration
        var month_days = days_in_month;
        const is_leap = (@rem(year, 4) == 0 and @rem(year, 100) != 0) or @rem(year, 400) == 0;
        if (is_leap) month_days[1] = 29;
        if (day > month_days[month - 1]) return error.InvalidDate;

        return Date{ .year = year, .month = month, .day = day };
    }

    pub fn toPostgresText(self: Date, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{:0>4}-{:0>2}-{:0>2}", .{ self.year, self.month, self.day });
    }

    pub const isDate = true;
};
