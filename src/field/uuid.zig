const std = @import("std");

pub const Uuid = struct {
    bytes: [16]u8,
    pub const isUuid = true;

    pub fn fromString(str: []const u8) !Uuid {
        var uuid: Uuid = undefined;

        if (str.len != 36 and str.len != 32) {
            return error.InvalidUuidFormat;
        }

        var pos: usize = 0;
        var byte_pos: usize = 0;

        while (byte_pos < 16) : (byte_pos += 1) {
            if (str.len == 36 and (pos == 8 or pos == 13 or pos == 18 or pos == 23)) {
                if (str[pos] != '-') return error.InvalidUuidFormat;
                pos += 1;
            }

            const high = try charToHex(str[pos]);
            pos += 1;
            const low = try charToHex(str[pos]);
            pos += 1;

            // Explicitly handle the shift and OR as separate steps
            const shifted_high: u8 = @as(u8, high) << 4;
            uuid.bytes[byte_pos] = shifted_high | @as(u8, low);
        }

        return uuid;
    }

    fn charToHex(c: u8) !u4 {
        return switch (c) {
            '0'...'9' => @intCast(c - '0'),
            'a'...'f' => @intCast(c - 'a' + 10),
            'A'...'F' => @intCast(c - 'A' + 10),
            else => error.InvalidHexDigit,
        };
    }

    pub fn toString(self: Uuid, allocator: std.mem.Allocator) ![]u8 {
        const result = try allocator.alloc(u8, 36);

        var i: usize = 0;
        for (self.bytes, 0..) |byte, index| {
            if (index == 4 or index == 6 or index == 8 or index == 10) {
                result[i] = '-';
                i += 1;
            }

            const hex_chars = "0123456789abcdef";
            result[i] = hex_chars[byte >> 4];
            result[i + 1] = hex_chars[byte & 0x0F];
            i += 2;
        }

        return result;
    }
};
