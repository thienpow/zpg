const std = @import("std");

pub const Timestamp = struct {
    seconds: i64,
    nano_seconds: u32,

    // Parse from PostgreSQL text format (existing method)
    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Timestamp {
        _ = allocator;
        if (text.len < 19) return error.InvalidTimestampFormat;

        var timestamp: Timestamp = .{ .seconds = 0, .nano_seconds = 0 };

        const year = try std.fmt.parseInt(i16, text[0..4], 10);
        if (text[4] != '-') return error.InvalidTimestampFormat;
        const month = try std.fmt.parseInt(u8, text[5..7], 10);
        if (text[7] != '-') return error.InvalidTimestampFormat;
        const day = try std.fmt.parseInt(u8, text[8..10], 10);
        if (text[10] != ' ' and text[10] != 'T') return error.InvalidTimestampFormat;
        const hour = try std.fmt.parseInt(u8, text[11..13], 10);
        if (text[13] != ':') return error.InvalidTimestampFormat;
        const minute = try std.fmt.parseInt(u8, text[14..16], 10);
        if (text[16] != ':') return error.InvalidTimestampFormat;
        const second = try std.fmt.parseInt(u8, text[17..19], 10);

        var seconds = try toUnixSeconds(year, month, day, hour, minute, second);

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

    pub fn parse(fmt: []const u8, text: []const u8) !Timestamp {
        var year: i16 = 1970;
        var month: u8 = 1;
        var day: u8 = 1;
        var hour: u8 = 0;
        var minute: u8 = 0;
        var second: u8 = 0;
        var nano_seconds: u32 = 0;

        var fmt_pos: usize = 0;
        var text_pos: usize = 0;

        while (fmt_pos < fmt.len and text_pos < text.len) {
            if (fmt[fmt_pos] == '%') {
                fmt_pos += 1;
                if (fmt_pos >= fmt.len) return error.InvalidFormat;
                switch (fmt[fmt_pos]) {
                    'Y' => { // 4-digit year
                        if (text_pos + 4 > text.len) return error.InvalidTimestampFormat;
                        year = try std.fmt.parseInt(i16, text[text_pos .. text_pos + 4], 10);
                        text_pos += 4;
                    },
                    'm' => { // 2-digit month
                        if (text_pos + 2 > text.len) return error.InvalidTimestampFormat;
                        month = try std.fmt.parseInt(u8, text[text_pos .. text_pos + 2], 10);
                        text_pos += 2;
                    },
                    'd' => { // 2-digit day
                        if (text_pos + 2 > text.len) return error.InvalidTimestampFormat;
                        day = try std.fmt.parseInt(u8, text[text_pos .. text_pos + 2], 10);
                        text_pos += 2;
                    },
                    'H' => { // 2-digit hour (24-hour)
                        if (text_pos + 2 > text.len) return error.InvalidTimestampFormat;
                        hour = try std.fmt.parseInt(u8, text[text_pos .. text_pos + 2], 10);
                        text_pos += 2;
                    },
                    'M' => { // 2-digit minute
                        if (text_pos + 2 > text.len) return error.InvalidTimestampFormat;
                        minute = try std.fmt.parseInt(u8, text[text_pos .. text_pos + 2], 10);
                        text_pos += 2;
                    },
                    'S' => { // 2-digit second
                        if (text_pos + 2 > text.len) return error.InvalidTimestampFormat;
                        second = try std.fmt.parseInt(u8, text[text_pos .. text_pos + 2], 10);
                        text_pos += 2;
                    },
                    'f' => { // Fractional seconds (up to 9 digits)
                        if (text_pos < text.len and text[text_pos] == '.') {
                            text_pos += 1;
                            var nano_end = text_pos;
                            while (nano_end < text.len and text[nano_end] >= '0' and text[nano_end] <= '9') {
                                nano_end += 1;
                            }
                            if (nano_end > text_pos) {
                                var nano_pad: [9]u8 = [_]u8{'0'} ** 9;
                                const digits = @min(nano_end - text_pos, 9);
                                std.mem.copy(u8, &nano_pad, text[text_pos .. text_pos + digits]);
                                nano_seconds = try std.fmt.parseInt(u32, &nano_pad, 10);
                                text_pos = nano_end;
                            }
                        }
                    },
                    else => return error.UnsupportedFormatSpecifier,
                }
            } else {
                if (fmt[fmt_pos] != text[text_pos]) return error.InvalidTimestampFormat;
                fmt_pos += 1;
                text_pos += 1;
            }
        }

        const seconds = try toUnixSeconds(year, month, day, hour, minute, second);
        return Timestamp{ .seconds = seconds, .nano_seconds = nano_seconds };
    }

    pub fn format(self: Timestamp, fmt: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const broken_down = try fromUnixSeconds(self.seconds);
        var buf = try std.ArrayList(u8).initCapacity(allocator, 32);
        defer buf.deinit();

        var i: usize = 0;
        while (i < fmt.len) : (i += 1) {
            if (fmt[i] == '%' and i + 1 < fmt.len) {
                i += 1;
                switch (fmt[i]) {
                    'Y' => try buf.writer().print("{:0>4}", .{broken_down.year}),
                    'm' => try buf.writer().print("{:0>2}", .{broken_down.month}),
                    'd' => try buf.writer().print("{:0>2}", .{broken_down.day}),
                    'H' => try buf.writer().print("{:0>2}", .{broken_down.hour}),
                    'M' => try buf.writer().print("{:0>2}", .{broken_down.minute}),
                    'S' => try buf.writer().print("{:0>2}", .{broken_down.second}),
                    'f' => try buf.writer().print("{:0>9}", .{self.nano_seconds}),
                    else => return error.UnsupportedFormatSpecifier,
                }
            } else {
                try buf.append(fmt[i]);
            }
        }

        return buf.toOwnedSlice();
    }

    fn toUnixSeconds(year: i16, month: u8, day: u8, hour: u8, minute: u8, second: u8) !i64 {
        if (year < 1970 or month < 1 or month > 12 or day < 1 or day > 31 or
            hour > 23 or minute > 59 or second > 59)
        {
            return error.InvalidDateTime;
        }

        const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var days: i64 = 0;

        for (1970..year) |y| {
            days += if (isLeapYear(@intCast(y))) 366 else 365;
        }

        for (0..month - 1) |m| {
            var month_days = days_in_month[m];
            if (m == 1 and isLeapYear(year)) month_days = 29;
            days += month_days;
        }

        days += day - 1;
        return days * 86400 + @as(i64, hour) * 3600 + minute * 60 + second;
    }

    // Helper to break down Unix seconds into components
    fn fromUnixSeconds(seconds: i64) !struct { year: i16, month: u8, day: u8, hour: u8, minute: u8, second: u8 } {
        var remaining_seconds = seconds;
        var year: i16 = 1970;
        const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

        while (remaining_seconds >= 0) {
            const days_in_year = if (isLeapYear(year)) 366 else 365;
            const seconds_in_year = days_in_year * 86400;
            if (remaining_seconds < seconds_in_year) break;
            remaining_seconds -= seconds_in_year;
            year += 1;
        }

        var days = @divFloor(remaining_seconds, 86400);
        remaining_seconds = @mod(remaining_seconds, 86400);

        var month: u8 = 1;
        while (days > 0) {
            var month_days = days_in_month[month - 1];
            if (month == 2 and isLeapYear(year)) month_days = 29;
            if (days < month_days) break;
            days -= month_days;
            month += 1;
            if (month > 12) {
                month = 1;
                year += 1;
            }
        }

        const day: u8 = @intCast(days + 1);
        const hour: u8 = @intCast(@divFloor(remaining_seconds, 3600));
        remaining_seconds = @mod(remaining_seconds, 3600);
        const minute: u8 = @intCast(@divFloor(remaining_seconds, 60));
        const second: u8 = @intCast(@mod(remaining_seconds, 60));

        return .{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute, .second = second };
    }

    fn isLeapYear(year: i16) bool {
        return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    }

    pub const isTimestamp = true;
};
