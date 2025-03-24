Let's examine how to use this `Interval` struct with PostgreSQL and integrate it into our `User` struct alongside the existing `processSelectResponses` functionality.

### PostgreSQL Table with Interval

In PostgreSQL, you can use the `INTERVAL` data type to store time intervals. Here's how you might add it to the users table:

```sql
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    subscription_duration INTERVAL DEFAULT '1 month'
);
```

- `INTERVAL` can store durations like "1 year 2 months 3 days 04:05:06.789"
- PostgreSQL outputs intervals in a human-readable format
- The default value '1 month' is just an example

### Integration with processSelectResponses

The `processSelectResponses` function already supports intervals:

```zig
} else if (@hasDecl(FieldType, "isInterval") and FieldType.isInterval) {
    const len = try reader.readInt(i32, .big);
    if (len < 0) return FieldType{}; // NULL interval, return empty
    const bytes = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(bytes);
    const read = try reader.readAtLeast(bytes, @intCast(len));
    if (read < @as(usize, @intCast(len))) return error.IncompleteRead;
    return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidInterval;
}
```

This matches our `Interval` struct because:
1. It has `pub const isInterval = true`
2. It implements `fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Interval`
3. It handles NULL by returning a zeroed struct (months: 0, days: 0, microseconds: 0)

### Updated User Struct with Interval

Here's how we can update the `User` struct to include the `Interval`:

```zig
const std = @import("std");
const zpg = @import("zpg");
const Uuid = zpg.field.Uuid;
const Interval = zpg.field.Interval;

pub const User = struct {
    id: Uuid,
    username: []const u8,
    email: []const u8,
    subscription_duration: Interval,
};
```

### Usage Example

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example from database
    const db_interval = "1 year 2 mon 3 days 04:05:06.789";
    const interval = try Interval.fromPostgresText(db_interval, allocator);

    const user = User{
        .id = try Uuid.fromString("550e8400-e29b-41d4-a716-446655440000"),
        .username = "johndoe",
        .email = "john@example.com",
        .subscription_duration = interval,
    };

    std.debug.print("Subscription: {} months, {} days, {} microseconds\n", .{
        user.subscription_duration.months,
        user.subscription_duration.days,
        user.subscription_duration.microseconds
    });
}
```

### Notes on the Implementation

1. **Format Handling**:
   - PostgreSQL outputs intervals in a space-separated format with units like "year", "mon", "day", "hour", "min", "sec"
   - The parser now handles this more accurately

2. **Precision**:
   - Stores everything in months, days, and microseconds for precise representation
   - Microseconds cover hours, minutes, and seconds with sub-second precision

3. **Limitations**:
   - Still simplified - doesn't handle negative intervals properly (e.g., "-1 day")
   - Doesn't validate ranges (e.g., could accept invalid days per month)
   - Decimal handling is basic

For production use, you might want to:
1. Add negative value support:
```zig
if (part.len > 0 and part[0] == '-') {
    last_value = -(std.fmt.parseInt(i32, part[1..], 10) catch continue);
} else {
    last_value = std.fmt.parseInt(i32, part, 10) catch continue;
}
```


This `Interval` struct will work seamlessly with `processSelectResponses` and PostgreSQL's INTERVAL type, providing a good foundation for handling time durations in your application.
