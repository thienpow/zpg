const std = @import("std");

pub const Decimal = struct {
    value: i128, // Increased precision
    scale: u8,

    pub fn fromPostgresBinary(data: []const u8, _: std.mem.Allocator) !Decimal {
        if (data.len < 4) return error.InvalidDecimalFormat;

        // Read number of digits (2 bytes, big-endian)
        var num_digits: i16 = @bitCast(std.mem.bytesToValue(i16, data[0..2]));
        num_digits = @byteSwap(num_digits);

        // Read scale (2 bytes, big-endian)
        var scale: i16 = @bitCast(std.mem.bytesToValue(i16, data[2..4]));
        scale = @byteSwap(scale);

        if (num_digits < 0 or scale < 0 or scale > 38) return error.InvalidDecimalFormat;

        // Read digits (each digit is stored as an i16, big-endian, base-10000)
        var value: i128 = 0;
        const base: i128 = 10_000;
        var is_negative = false;

        for (0..@as(usize, @intCast(num_digits))) |i| {
            const offset = 4 + (i * 2);
            if (offset + 2 > data.len) return error.InvalidDecimalFormat;

            var digit: i16 = @bitCast(std.mem.bytesToValue(i16, data[offset .. offset + 2]));
            digit = @byteSwap(digit);

            if (i == 0 and digit < 0) {
                is_negative = true;
                digit = -digit;
            }

            value = value * base + @as(i128, digit);
        }

        return Decimal{
            .value = if (is_negative) -value else value,
            .scale = @intCast(scale),
        };
    }

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Decimal {
        const decimal_point_pos = std.mem.indexOf(u8, text, ".");

        if (decimal_point_pos) |pos| {
            var value_str = try allocator.alloc(u8, text.len - 1);
            defer allocator.free(value_str);

            // Replace std.mem.copy with slice assignment
            @memcpy(value_str[0..pos], text[0..pos]);
            @memcpy(value_str[pos..], text[pos + 1 ..]);

            const value = try std.fmt.parseInt(i128, value_str, 10);
            const scale = @as(u8, @intCast(text.len - pos - 1));
            if (scale > 38) return error.ScaleTooLarge; // Arbitrary limit, PostgreSQL max is ~1000

            return Decimal{ .value = value, .scale = scale };
        } else {
            const value = try std.fmt.parseInt(i128, text, 10);
            return Decimal{ .value = value, .scale = 0 };
        }
    }

    pub fn toString(self: Decimal, allocator: std.mem.Allocator) ![]u8 {
        if (self.scale == 0) {
            return try std.fmt.allocPrint(allocator, "{d}", .{self.value});
        }

        const abs_value = if (self.value < 0) -self.value else self.value;
        const sign = if (self.value < 0) "-" else "";

        const value_str = try std.fmt.allocPrint(allocator, "{d}", .{abs_value});
        defer allocator.free(value_str);

        if (value_str.len <= self.scale) {
            const zeros_needed = self.scale - value_str.len + 1;
            const result = try allocator.alloc(u8, sign.len + zeros_needed + value_str.len + 1);

            // Replace std.mem.copy with slice assignment
            @memcpy(result[0..sign.len], sign);
            result[sign.len] = '0';
            result[sign.len + 1] = '.';
            std.mem.set(u8, result[sign.len + 2 .. sign.len + zeros_needed], '0');
            @memcpy(result[sign.len + zeros_needed ..], value_str);

            return result;
        } else {
            const decimal_pos = value_str.len - self.scale;
            const result = try allocator.alloc(u8, sign.len + value_str.len + 1);

            // Replace std.mem.copy with slice assignment
            @memcpy(result[0..sign.len], sign);
            @memcpy(result[sign.len .. sign.len + decimal_pos], value_str[0..decimal_pos]);
            result[sign.len + decimal_pos] = '.';
            @memcpy(result[sign.len + decimal_pos + 1 ..], value_str[decimal_pos..]);

            return result;
        }
    }
};
