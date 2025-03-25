const std = @import("std");

pub const Money = struct {
    value: i64, // Stored as cents (or smallest unit), matching PostgreSQL money type
    scale: u8 = 2, // Default scale of 2 for cents; adjustable if needed

    /// Creates a Money instance from PostgreSQL text representation (e.g., "$12.34" or "12.34").
    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Money {
        // Remove currency symbols and whitespace (e.g., "$" or "USD ")
        var cleaned_text = text;
        for (text, 0..) |c, i| {
            if (std.ascii.isDigit(c) or c == '.' or c == '-') {
                cleaned_text = text[i..];
                break;
            }
        }

        const decimal_point_pos = std.mem.indexOf(u8, cleaned_text, ".");
        var value: i64 = undefined;

        if (decimal_point_pos) |pos| {
            // Handle decimal part
            var value_str = try allocator.alloc(u8, cleaned_text.len - 1);
            defer allocator.free(value_str);

            std.mem.copy(u8, value_str[0..pos], cleaned_text[0..pos]);
            std.mem.copy(u8, value_str[pos..], cleaned_text[pos + 1 ..]);

            value = try std.fmt.parseInt(i64, value_str, 10);
            const scale = @as(u8, @intCast(cleaned_text.len - pos - 1));
            if (scale > 2) return error.InvalidMoneyScale; // PostgreSQL money typically has scale 2
        } else {
            // No decimal, assume whole units and convert to cents
            const whole_value = try std.fmt.parseInt(i64, cleaned_text, 10);
            value = whole_value * 100; // Convert to cents
        }

        return Money{ .value = value };
    }

    /// Converts the Money value to a string with a "$" prefix (e.g., "$12.34").
    pub fn toString(self: Money, allocator: std.mem.Allocator) ![]u8 {
        const abs_value = if (self.value < 0) -self.value else self.value;
        const sign = if (self.value < 0) "-" else "";
        const dollars = abs_value / 100;
        const cents = abs_value % 100;

        // Format with 2 decimal places
        return try std.fmt.allocPrint(allocator, "{s}${d}.{d:0>2}", .{ sign, dollars, cents });
    }

    /// Adds two Money values together.
    pub fn add(self: Money, other: Money) Money {
        return Money{ .value = self.value + other.value };
    }

    /// Subtracts one Money value from another.
    pub fn subtract(self: Money, other: Money) Money {
        return Money{ .value = self.value - other.value };
    }
};

// Example usage and tests
test "Money.fromPostgresText and toString" {
    const allocator = std.testing.allocator;

    // Test parsing "$12.34"
    const money1 = try Money.fromPostgresText("$12.34", allocator);
    try std.testing.expectEqual(@as(i64, 1234), money1.value);
    const str1 = try money1.toString(allocator);
    defer allocator.free(str1);
    try std.testing.expectEqualStrings("$12.34", str1);

    // Test parsing "12.34" (no symbol)
    const money2 = try Money.fromPostgresText("12.34", allocator);
    try std.testing.expectEqual(@as(i64, 1234), money2.value);

    // Test parsing "-$5.00"
    const money3 = try Money.fromPostgresText("-$5.00", allocator);
    try std.testing.expectEqual(@as(i64, -500), money3.value);
    const str3 = try money3.toString(allocator);
    defer allocator.free(str3);
    try std.testing.expectEqualStrings("-$5.00", str3);

    // Test parsing whole number "10"
    const money4 = try Money.fromPostgresText("10", allocator);
    try std.testing.expectEqual(@as(i64, 1000), money4.value);
    const str4 = try money4.toString(allocator);
    defer allocator.free(str4);
    try std.testing.expectEqualStrings("$10.00", str4);
}

test "Money arithmetic" {
    const money1 = Money{ .value = 1234 }; // $12.34
    const money2 = Money{ .value = 567 }; // $5.67

    const sum = money1.add(money2);
    try std.testing.expectEqual(@as(i64, 1801), sum.value); // $18.01

    const diff = money1.subtract(money2);
    try std.testing.expectEqual(@as(i64, 667), diff.value); // $6.67
}
