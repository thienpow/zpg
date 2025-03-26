const std = @import("std");

pub const Money = struct {
    value: i64, // Stored as cents

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Money {
        if (text.len == 0 or text[0] != '$') return error.InvalidMoneyFormat;

        const number_part = text[1..]; // Skip the '$'
        const decimal_pos = std.mem.indexOf(u8, number_part, ".") orelse return error.InvalidMoneyFormat;

        var value_str = try allocator.alloc(u8, number_part.len - 1); // Remove the '.'
        defer allocator.free(value_str);

        @memcpy(value_str[0..decimal_pos], number_part[0..decimal_pos]);
        @memcpy(value_str[decimal_pos..], number_part[decimal_pos + 1 ..]);

        const value = try std.fmt.parseInt(i64, value_str, 10);

        const scale = number_part.len - decimal_pos - 1;
        if (scale != 2) return error.InvalidMoneyScale;

        return Money{ .value = value };
    }

    pub fn toString(self: Money, allocator: std.mem.Allocator) ![]u8 {
        const abs_value = if (self.value < 0) -self.value else self.value;
        const sign = if (self.value < 0) "-" else "";
        const dollars: i64 = @divTrunc(abs_value, 100);
        const cents: u64 = @intCast(@rem(abs_value, 100));
        const result = try std.fmt.allocPrint(allocator, "{s}${d}.{d:0>2}", .{ sign, dollars, cents });
        return result;
    }
};
