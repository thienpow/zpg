const std = @import("std");

pub const Time = struct {
    hours: u8,
    minutes: u8,
    seconds: u8,
    nano_seconds: u32 = 0, // Optional microseconds/nanoseconds

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
                std.mem.copy(u8, &nano_pad, text[pos .. pos + digits]);
                time.nano_seconds = try std.fmt.parseInt(u32, &nano_pad, 10);
            }
        }

        return time;
    }
};
