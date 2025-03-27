const std = @import("std");

pub const Timestamp = struct {
    seconds: i64,
    nano_seconds: u32,

    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Timestamp {
        _ = allocator;
        std.debug.print("Parsing timestamp: '{s}'\n", .{text});
        if (text.len < 19) return error.InvalidTimestampFormat;

        var timestamp: Timestamp = .{ .seconds = 0, .nano_seconds = 0 };

        const year_end = std.mem.indexOfScalar(u8, text, '-') orelse return error.InvalidTimestampFormat;
        var year = try std.fmt.parseInt(i32, text[0..year_end], 10);
        if (text[year_end] != '-') return error.InvalidTimestampFormat;

        const month_start = year_end + 1;
        const month_end = month_start + 2;
        if (month_end >= text.len or text[month_end] != '-') return error.InvalidTimestampFormat;
        const month = try std.fmt.parseInt(u8, text[month_start..month_end], 10);

        const day_start = month_end + 1;
        const day_end = day_start + 2;
        if (day_end >= text.len or (text[day_end] != ' ' and text[day_end] != 'T')) return error.InvalidTimestampFormat;
        const day = try std.fmt.parseInt(u8, text[day_start..day_end], 10);

        const time_start = day_end + 1;
        const hour_end = time_start + 2;
        if (hour_end >= text.len or text[hour_end] != ':') return error.InvalidTimestampFormat;
        const hour = try std.fmt.parseInt(u8, text[time_start..hour_end], 10);

        const minute_start = hour_end + 1;
        const minute_end = minute_start + 2;
        if (minute_end >= text.len or text[minute_end] != ':') return error.InvalidTimestampFormat;
        const minute = try std.fmt.parseInt(u8, text[minute_start..minute_end], 10);

        const second_start = minute_end + 1;
        const second_end = second_start + 2;
        if (second_end > text.len) return error.InvalidTimestampFormat;
        const second = try std.fmt.parseInt(u8, text[second_start..second_end], 10);

        var is_bc = false;
        if (std.mem.endsWith(u8, text, " BC")) {
            is_bc = true;
            year = -year;
        }

        var pos = second_end;
        if (pos < text.len and text[pos] == '.') {
            pos += 1;
            var nano_end: usize = pos;
            while (nano_end < text.len and text[nano_end] >= '0' and text[nano_end] <= '9') {
                nano_end += 1;
            }
            if (nano_end > pos) {
                var nano_pad: [9]u8 = [_]u8{'0'} ** 9;
                const digits = @min(nano_end - pos, 9);
                std.mem.copyForwards(u8, &nano_pad, text[pos .. pos + digits]);
                timestamp.nano_seconds = try std.fmt.parseInt(u32, &nano_pad, 10);
            }
            pos = nano_end;
        }

        var seconds = try toUnixSeconds(year, month, day, hour, minute, second);

        if (pos < text.len and (text[pos] == '+' or text[pos] == '-')) {
            const sign: i32 = if (text[pos] == '+') 1 else -1;
            pos += 1;
            const tz_hour_end = pos + 2;
            if (tz_hour_end > text.len) return error.InvalidTimestampFormat;
            const tz_hour = try std.fmt.parseInt(i8, text[pos..tz_hour_end], 10);
            pos = tz_hour_end;
            var tz_minute: i8 = 0;
            if (pos < text.len and text[pos] == ':') {
                pos += 1;
                const tz_minute_end = pos + 2;
                if (tz_minute_end > text.len) return error.InvalidTimestampFormat;
                tz_minute = try std.fmt.parseInt(i8, text[pos..tz_minute_end], 10);
            }
            const tz_offset = sign * (@as(i32, tz_hour) * 3600 + @as(i32, tz_minute) * 60);
            seconds -= tz_offset;
        }

        timestamp.seconds = seconds;
        return timestamp;
    }

    pub fn toUnixSeconds(year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8) !i64 {
        if (month < 1 or month > 12 or day < 1 or day > 31 or
            hour > 23 or minute > 59 or second > 59)
        {
            return error.InvalidDateTime;
        }

        var days: i64 = 0;

        if (year >= 1970) {
            for (1970..@as(usize, @intCast(year))) |y| {
                days += if (isLeapYear(@intCast(y))) 366 else 365;
            }
        } else if (year > 0) {
            var y: i32 = year;
            while (y < 1970) : (y += 1) {
                days -= if (isLeapYear(y)) 366 else 365;
            }
        } else if (year <= 0) {
            var y: i32 = year + 1;
            while (y < 1970) : (y += 1) {
                if (y == 0) continue;
                days -= if (isLeapYear(y)) 366 else 365;
            }
        }

        for (0..month - 1) |m| {
            var month_days = days_in_month[m];
            if (m == 1 and isLeapYear(year)) month_days = 29;
            days += month_days;
        }

        const target_month_idx = month - 1;
        var max_days = days_in_month[target_month_idx];
        if (target_month_idx == 1 and isLeapYear(year)) max_days = 29;
        if (day > max_days or day == 0) {
            std.debug.print("Invalid date: year={d}, month={d}, day={d}, max_days={d}\n", .{ year, month, day, max_days });
            return error.InvalidDateTime;
        }

        days += day - 1;
        return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    }

    pub fn fromUnixSeconds(seconds: i64) !struct { year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8 } {
        var remaining_seconds = seconds;
        var year: i32 = 1970;

        if (remaining_seconds >= 0) {
            while (remaining_seconds >= 0) {
                const days_in_year = if (isLeapYear(year)) 366 else 365;
                const seconds_in_year = days_in_year * 86400;
                if (remaining_seconds < seconds_in_year) break;
                remaining_seconds -= seconds_in_year;
                year += 1;
            }
        } else {
            while (remaining_seconds < 0) {
                year -= 1;
                const days_in_year = if (isLeapYear(year)) 366 else 365;
                const seconds_in_year = days_in_year * 86400;
                remaining_seconds += seconds_in_year;
            }
        }

        var days = @divFloor(remaining_seconds, 86400);
        remaining_seconds = @mod(remaining_seconds, 86400);
        if (remaining_seconds < 0) {
            days -= 1;
            remaining_seconds += 86400;
        }

        var month: u8 = 1;
        while (days != 0) {
            var month_days = days_in_month[month - 1];
            if (month == 2 and isLeapYear(year)) month_days = 29;
            if (days > 0 and days < month_days) break;
            if (days > 0) {
                days -= month_days;
                month += 1;
            } else {
                days += month_days;
                month -= 1;
            }
            if (month > 12) {
                month = 1;
                year += 1;
            } else if (month < 1) {
                month = 12;
                year -= 1;
            }
        }

        const day: u8 = if (days >= 0) @intCast(days + 1) else @intCast(days + days_in_month[month - 1] + 1);
        const hour: u8 = @intCast(@divFloor(remaining_seconds, 3600));
        remaining_seconds = @mod(remaining_seconds, 3600);
        const minute: u8 = @intCast(@divFloor(remaining_seconds, 60));
        const second: u8 = @intCast(@mod(remaining_seconds, 60));

        return .{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute, .second = second };
    }

    fn isLeapYear(year: i32) bool {
        const y = if (year <= 0) year + 1 else year; // 1 BC = 0, 2 BC = -1, etc.
        return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or (@mod(y, 400) == 0);
    }

    pub const isTimestamp = true;
};
