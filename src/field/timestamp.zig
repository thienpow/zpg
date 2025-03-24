const std = @import("std");

pub const Timestamp = struct {
    seconds: i64,
    nano_seconds: u32,

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Timestamp {
        _ = allocator;
        if (text.len < 19) return error.InvalidTimestampFormat;

        var timestamp: Timestamp = .{ .seconds = 0, .nano_seconds = 0 };

        const year = try std.fmt.parseInt(i16, text[0..4], 10);
        const month = try std.fmt.parseInt(u8, text[5..7], 10);
        const day = try std.fmt.parseInt(u8, text[8..10], 10);
        const hour = try std.fmt.parseInt(u8, text[11..13], 10);
        const minute = try std.fmt.parseInt(u8, text[14..16], 10);
        const second = try std.fmt.parseInt(u8, text[17..19], 10);

        var seconds = try toUnixSeconds(year, month, day, hour, minute, second);

        // Handle fractional seconds and timezone
        if (text.len > 19) {
            var pos: usize = 19;
            if (text[pos] == '.') {
                pos += 1;
                var nano_end: usize = pos;
                while (nano_end < text.len and text[nano_end] >= '0' and text[nano_end] <= '9') {
                    nano_end += 1;
                }
                if (nano_end > pos) {
                    var nano_pad: [9]u8 = [_]u8{'0'} ** 9;
                    const digits = @min(nano_end - pos, 9);
                    std.mem.copy(u8, &nano_pad, text[pos .. pos + digits]);
                    timestamp.nano_seconds = try std.fmt.parseInt(u32, &nano_pad, 10);
                    pos = nano_end;
                }
            }

            // Handle timezone offset (e.g., "+00" or "-05:30")
            if (pos < text.len and (text[pos] == '+' or text[pos] == '-')) {
                const sign = if (text[pos] == '+') 1 else -1;
                pos += 1;
                const tz_hour = try std.fmt.parseInt(i8, text[pos .. pos + 2], 10);
                pos += 2;
                var tz_minute: i8 = 0;
                if (pos < text.len and text[pos] == ':') {
                    tz_minute = try std.fmt.parseInt(i8, text[pos + 1 .. pos + 3], 10);
                }
                const tz_offset = sign * (tz_hour * 3600 + tz_minute * 60);
                seconds -= tz_offset; // Adjust to UTC
            }
        }

        timestamp.seconds = seconds;
        return timestamp;
    }

    fn toUnixSeconds(year: i16, month: u8, day: u8, hour: u8, minute: u8, second: u8) !i64 {
        // More accurate conversion - still simplified
        if (year < 1970 or month < 1 or month > 12 or day < 1 or day > 31 or
            hour > 23 or minute > 59 or second > 59)
        {
            return error.InvalidDateTime;
        }

        const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var days: i64 = 0;

        // Days from 1970 to year-1
        for (1970..year) |y| {
            days += if (isLeapYear(@intCast(y))) 366 else 365;
        }

        // Days in current year up to month-1
        for (0..month - 1) |m| {
            var month_days = days_in_month[m];
            if (m == 1 and isLeapYear(year)) month_days = 29;
            days += month_days;
        }

        days += day - 1;
        return days * 86400 + @as(i64, hour) * 3600 + minute * 60 + second;
    }

    fn isLeapYear(year: i16) bool {
        return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    }

    pub const isTimestamp = true;
};
