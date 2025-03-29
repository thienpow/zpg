const std = @import("std");

pub const Time = struct {
    hours: u8,
    minutes: u8,
    seconds: u8,
    nano_seconds: u32 = 0, // Optional nanoseconds

    pub fn fromPostgresBinary(data: []const u8, allocator: std.mem.Allocator) !Time {
        _ = allocator; // Not needed here
        if (data.len != 8) return error.InvalidTimeFormat;

        // Read microseconds since midnight (big-endian i64)
        var micros: i64 = @bitCast(std.mem.bytesToValue(i64, data[0..8]));
        micros = @byteSwap(micros);

        if (micros < 0) return error.InvalidTime;

        // Convert to hours, minutes, seconds, and nanoseconds
        const total_seconds: i64 = @divTrunc(micros, 1_000_000);
        const nano_seconds: u32 = @intCast((micros % 1_000_000) * 1_000);

        return Time{
            .hours = @intCast(@divTrunc(total_seconds, 3600)),
            .minutes = @intCast(@divTrunc(total_seconds % 3600, 60)),
            .seconds = @intCast(total_seconds % 60),
            .nano_seconds = nano_seconds,
        };
    }

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Time {
        _ = allocator; // Unused for now
        if (text.len < 8) return error.InvalidTimeFormat;

        const hours = try std.fmt.parseInt(u8, text[0..2], 10);
        if (text[2] != ':') return error.InvalidTimeFormat;
        const minutes = try std.fmt.parseInt(u8, text[3..5], 10);
        if (text[5] != ':') return error.InvalidTimeFormat;
        const seconds = try std.fmt.parseInt(u8, text[6..8], 10);

        if (hours > 23 or minutes > 59 or seconds > 59) return error.InvalidTime;

        var time = Time{ .hours = hours, .minutes = minutes, .seconds = seconds };

        // Handle optional fractional seconds (e.g., "14:30:00.123456")
        if (text.len > 8 and text[8] == '.') {
            const pos: usize = 9;
            var nano_end: usize = pos;
            while (nano_end < text.len and text[nano_end] >= '0' and text[nano_end] <= '9') {
                nano_end += 1;
            }
            if (nano_end > pos) {
                var nano_pad: [9]u8 = [_]u8{'0'} ** 9;
                const digits = @min(nano_end - pos, 9);
                std.mem.copyForwards(u8, &nano_pad, text[pos .. pos + digits]);
                time.nano_seconds = try std.fmt.parseInt(u32, &nano_pad, 10);
            }
        }

        return time;
    }

    pub const isTime = true;
};
