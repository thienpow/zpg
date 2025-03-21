const std = @import("std");

pub const Decimal = struct {
    // Using a simplified representation - in production you might want
    // a more sophisticated decimal implementation
    value: i64,
    scale: u8, // Number of digits to the right of the decimal point

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Decimal {
        const decimal_point_pos = std.mem.indexOf(u8, text, ".");

        if (decimal_point_pos) |pos| {
            // Has decimal point
            var value_str = try allocator.alloc(u8, text.len - 1);
            defer allocator.free(value_str);

            std.mem.copy(u8, value_str[0..pos], text[0..pos]);
            std.mem.copy(u8, value_str[pos..], text[pos + 1 ..]);

            const value = try std.fmt.parseInt(i64, value_str, 10);
            const scale: u8 = @intCast(text.len - pos - 1);

            return Decimal{ .value = value, .scale = scale };
        } else {
            // No decimal point
            const value = try std.fmt.parseInt(i64, text, 10);
            return Decimal{ .value = value, .scale = 0 };
        }
    }

    pub fn toString(self: Decimal, allocator: std.mem.Allocator) ![]u8 {
        if (self.scale == 0) {
            return try std.fmt.allocPrint(allocator, "{d}", .{self.value});
        }

        const abs_value = if (self.value < 0) -self.value else self.value;
        const sign = if (self.value < 0) "-" else "";

        // Convert to string without decimal point
        const value_str = try std.fmt.allocPrint(allocator, "{d}", .{abs_value});
        defer allocator.free(value_str);

        // Add leading zeros if needed
        if (value_str.len <= self.scale) {
            const zeros_needed = self.scale - value_str.len + 1;
            const result = try allocator.alloc(u8, sign.len + zeros_needed + value_str.len + 1);

            std.mem.copy(u8, result[0..], sign);
            std.mem.set(u8, result[sign.len .. sign.len + zeros_needed], '0');
            result[sign.len] = '0'; // First zero before decimal
            result[sign.len + 1] = '.'; // Decimal point
            std.mem.set(u8, result[sign.len + 2 .. sign.len + zeros_needed], '0'); // Zeros after decimal
            std.mem.copy(u8, result[sign.len + zeros_needed ..], value_str);

            return result;
        } else {
            // Normal case with enough digits
            const decimal_pos = value_str.len - self.scale;
            const result = try allocator.alloc(u8, sign.len + value_str.len + 1);

            std.mem.copy(u8, result[0..], sign);
            std.mem.copy(u8, result[sign.len .. sign.len + decimal_pos], value_str[0..decimal_pos]);
            result[sign.len + decimal_pos] = '.';
            std.mem.copy(u8, result[sign.len + decimal_pos + 1 ..], value_str[decimal_pos..]);

            return result;
        }
    }
};
