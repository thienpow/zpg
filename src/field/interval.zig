const std = @import("std");

pub const Interval = struct {
    months: i32,
    days: i32,
    microseconds: i64,

    pub fn fromPostgresBinary(data: []const u8, allocator: std.mem.Allocator) !Interval {
        _ = allocator; // Unused

        if (data.len != 16) return error.InvalidIntervalFormat;

        return Interval{
            .microseconds = @byteSwap(@as(i64, @bitCast(std.mem.bytesToValue(u64, data[0..8])))),
            .days = @byteSwap(@as(i32, @bitCast(std.mem.bytesToValue(u32, data[8..12])))),
            .months = @byteSwap(@as(i32, @bitCast(std.mem.bytesToValue(u32, data[12..16])))),
        };
    }

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Interval {
        _ = allocator;
        var interval = Interval{ .months = 0, .days = 0, .microseconds = 0 };

        // Check if it's in HH:MM:SS format
        if (std.mem.count(u8, text, ":") >= 2) {
            var time_parts = std.mem.splitSequence(u8, text, " ");
            var last_number: []const u8 = ""; // Store the last number for units

            while (time_parts.next()) |part| {
                if (std.mem.containsAtLeast(u8, part, 2, ":")) {
                    var components = std.mem.splitSequence(u8, part, ":");
                    if (components.next()) |hours_str| {
                        if (std.fmt.parseInt(i32, hours_str, 10)) |hours| {
                            interval.microseconds += @as(i64, hours) * 3600 * 1_000_000;
                        } else |_| {}
                    }
                    if (components.next()) |minutes_str| {
                        if (std.fmt.parseInt(i32, minutes_str, 10)) |minutes| {
                            interval.microseconds += @as(i64, minutes) * 60 * 1_000_000;
                        } else |_| {}
                    }
                    if (components.next()) |seconds_str| {
                        const seconds = std.fmt.parseFloat(f64, seconds_str) catch 0.0;
                        interval.microseconds += @as(i64, @intFromFloat(seconds * 1_000_000));
                    }
                } else if (std.mem.startsWith(u8, part, "year")) {
                    if (std.fmt.parseInt(i32, last_number, 10)) |value| {
                        interval.months += value * 12;
                    } else |_| {}
                } else if (std.mem.startsWith(u8, part, "mon")) {
                    if (std.fmt.parseInt(i32, last_number, 10)) |value| {
                        interval.months += value;
                    } else |_| {}
                } else if (std.mem.startsWith(u8, part, "day")) {
                    if (std.fmt.parseInt(i32, last_number, 10)) |value| {
                        interval.days += value;
                    } else |_| {}
                } else {
                    // If it's not a unit, assume it's a number
                    last_number = part;
                }
            }
        } else {
            // Original format parsing
            var parts = std.mem.splitSequence(u8, text, " ");
            var i: usize = 0;
            var last_value: ?i32 = null;
            var last_number: []const u8 = "";

            while (parts.next()) |part| {
                if (i % 2 == 0) {
                    last_value = std.fmt.parseInt(i32, part, 10) catch continue;
                    last_number = part;
                } else if (last_value) |value| {
                    if (std.mem.startsWith(u8, part, "year")) {
                        interval.months += value * 12;
                    } else if (std.mem.startsWith(u8, part, "mon")) {
                        interval.months += value;
                    } else if (std.mem.startsWith(u8, part, "day")) {
                        interval.days += value;
                    } else if (std.mem.startsWith(u8, part, "hour")) {
                        interval.microseconds += @as(i64, value) * 3600 * 1_000_000;
                    } else if (std.mem.startsWith(u8, part, "min")) {
                        interval.microseconds += @as(i64, value) * 60 * 1_000_000;
                    } else if (std.mem.startsWith(u8, part, "sec")) {
                        const float_val = std.fmt.parseFloat(f64, last_number) catch @as(f64, @floatFromInt(value));
                        interval.microseconds += @as(i64, @intFromFloat(float_val * 1_000_000));
                    }
                    last_value = null;
                }
                i += 1;
            }
        }

        return interval;
    }

    pub fn toString(self: Interval, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        try std.fmt.format(buf.writer(), "{} mon {} days {} us", .{ self.months, self.days, self.microseconds });
        return buf.toOwnedSlice();
    }

    pub const isInterval = true;
};
