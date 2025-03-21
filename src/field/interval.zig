const std = @import("std");

pub const Interval = struct {
    months: i32,
    days: i32,
    microseconds: i64,

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Interval {
        _ = allocator;
        // Parse PostgreSQL interval format
        // Example: "1 year 2 months 3 days 4 hours 5 minutes 6.789 seconds"

        var interval = Interval{
            .months = 0,
            .days = 0,
            .microseconds = 0,
        };

        // Simple parsing logic - production code would be more robust
        var parts = std.mem.split(u8, text, " ");
        var i: usize = 0;

        while (parts.next()) |part| {
            if (i % 2 == 0) {
                // This should be a number
                const value = std.fmt.parseInt(i32, part, 10) catch continue;

                // Get the unit (next part)
                const unit = parts.next() orelse break;

                if (std.mem.startsWith(u8, unit, "year")) {
                    interval.months += value * 12;
                } else if (std.mem.startsWith(u8, unit, "month")) {
                    interval.months += value;
                } else if (std.mem.startsWith(u8, unit, "day")) {
                    interval.days += value;
                } else if (std.mem.startsWith(u8, unit, "hour")) {
                    interval.microseconds += value * 3600 * 1_000_000;
                } else if (std.mem.startsWith(u8, unit, "minute")) {
                    interval.microseconds += value * 60 * 1_000_000;
                } else if (std.mem.startsWith(u8, unit, "second")) {
                    interval.microseconds += value * 1_000_000;
                }
            }
            i += 1;
        }

        return interval;
    }

    pub const isInterval = true;
};
