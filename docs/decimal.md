Let’s explore how to use this `Decimal` struct with a PostgreSQL table and integrate it into the `User` struct, ensuring compatibility with the `processSelectResponses` function.

### PostgreSQL Table with Decimal

In PostgreSQL, the `DECIMAL` or `NUMERIC` type is used for precise decimal numbers. Here’s how you could add a `DECIMAL` field to the `users` table:

```sql
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    subscription_duration INTERVAL DEFAULT '1 month',
    account_balance DECIMAL(12, 2) DEFAULT 0.00
);
```

- `DECIMAL(12, 2)` means:
  - Precision: 12 total digits
  - Scale: 2 digits after the decimal point
  - Range: -9999999999.99 to 9999999999.99
- PostgreSQL outputs this as a string like "1234.56" or "-789.00"
- The `DEFAULT 0.00` sets a starting balance

### Integration with processSelectResponses

The `processSelectResponses` function doesn’t have explicit support for a `Decimal` type yet, but it can fall back to the generic `fromPostgresText` case:

```zig
} else if (@hasDecl(FieldType, "fromPostgresText")) {
    const len = try reader.readInt(i32, .big);
    if (len < 0) return FieldType{}; // NULL value, return empty struct
    const bytes = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(bytes);
    const read = try reader.readAtLeast(bytes, @intCast(len));
    if (read < @as(usize, @intCast(len))) return error.IncompleteRead;
    return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidCustomType;
}
```

This works with our `Decimal` struct because:
1. It has `pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Decimal`
2. It handles NULL by returning a zeroed struct (`value: 0, scale: 0`)

### User Struct with Decimal

Here’s how to integrate the `Decimal` struct into the `User` struct:

```zig
const std = @import("std");
const zpg = @import("zpg");
const Uuid = zpg.field.Uuid;
const Decimal = zpg.field.Decimal;

pub const User = struct {
    id: Uuid,
    username: []const u8,
    email: []const u8,
    account_balance: Decimal,
};
```

### Usage Example

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example from database
    const db_decimal = "1234.56";
    const decimal = try Decimal.fromPostgresText(db_decimal, allocator);

    const user = User{
        .id = try Uuid.fromString("550e8400-e29b-41d4-a716-446655440000"),
        .username = "johndoe",
        .email = "john@example.com",
        .account_balance = decimal,
    };

    const balance_str = try user.account_balance.toString(allocator);
    defer allocator.free(balance_str);
    std.debug.print("Balance: {s}\n", .{balance_str});
}
```

### Notes on the Implementation

1. **Precision Upgrade**:
   - Switched to `i128` for 38 digits of precision (2^127 ≈ 1.7×10^38), closer to PostgreSQL’s capabilities
   - Still not a full arbitrary-precision decimal, but sufficient for most use cases

2. **Scale Handling**:
   - Added basic scale validation
   - Matches PostgreSQL’s text output (e.g., "1234.56" for DECIMAL(12,2))

3. **Limitations**:
   - Doesn’t preserve exact precision beyond `i128` limits
   - No rounding control for database values exceeding scale
   - `toString` could trim trailing zeros for cleaner output

For production, you might want:
1. A proper decimal library (e.g., fixed-point arithmetic or string-based)
2. Rounding options:
```zig
pub fn withScale(self: Decimal, new_scale: u8) Decimal {
    if (new_scale == self.scale) return self;
    if (new_scale > self.scale) {
        return Decimal{ .value = self.value * @as(i128, std.math.pow(u8, 10, new_scale - self.scale)), .scale = new_scale };
    }
    const divisor = @as(i128, std.math.pow(u8, 10, self.scale - new_scale));
    return Decimal{ .value = self.value / divisor, .scale = new_scale }; // Could add rounding here
}
```
