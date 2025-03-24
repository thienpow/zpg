const std = @import("std");

pub const Interval = struct {
    months: i32,
    days: i32,
    microseconds: i64,

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Interval {
        _ = allocator;
        var interval = Interval{
            .months = 0,
            .days = 0,
            .microseconds = 0,
        };

        var parts = std.mem.split(u8, text, " ");
        var i: usize = 0;
        var last_value: ?i32 = null;

        while (parts.next()) |part| {
            if (i % 2 == 0) {
                // Handle number
                last_value = std.fmt.parseInt(i32, part, 10) catch continue;
            } else if (last_value) |value| {
                // Handle unit
                if (std.mem.startsWith(u8, part, "year")) {
                    interval.months += value * 12;
                } else if (std.mem.startsWith(u8, part, "mon")) { // "mon" for "months"
                    interval.months += value;
                } else if (std.mem.startsWith(u8, part, "day")) {
                    interval.days += value;
                } else if (std.mem.startsWith(u8, part, "hour")) {
                    interval.microseconds += value * 3600 * 1_000_000;
                } else if (std.mem.startsWith(u8, part, "min")) { // "min" for "minutes"
                    interval.microseconds += value * 60 * 1_000_000;
                } else if (std.mem.startsWith(u8, part, "sec")) { // "sec" for "seconds"
                    // Check for decimal seconds
                    if (i > 1 and parts.peek() == null) {
                        // Last part might be a float like "6.789"
                        const float_val = std.fmt.parseFloat(f64, parts.buffer[parts.index - part.len - 1 ..]) catch value;
                        interval.microseconds += @as(i64, @intFromFloat(float_val * 1_000_000));
                        break;
                    } else {
                        interval.microseconds += value * 1_000_000;
                    }
                }
                last_value = null;
            }
            i += 1;
        }

        return interval;
    }

    pub const isInterval = true;
};
