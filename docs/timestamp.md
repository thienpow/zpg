Let's see how to use this `Timestamp` struct with a PostgreSQL table and integrate it with the existing `User` struct and `processSelectResponses` function.

### PostgreSQL Table with Timestamp

In PostgreSQL, you can add a timestamp field using the `TIMESTAMP` or `TIMESTAMP WITH TIME ZONE` type. Here's an example:

```sql
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
```

- `TIMESTAMP WITH TIME ZONE` stores the timestamp with timezone information
- `DEFAULT CURRENT_TIMESTAMP` automatically sets it to the current time
- PostgreSQL outputs this in a format like "2025-03-24 15:30:45.123456+00" (ISO 8601 with microseconds and UTC offset)

### Updated User Struct with Timestamp

Here's how we can modify the `User` struct to include the `Timestamp`:

```zig
const std = @import("std");
const zpg = @import("zpg");
const Uuid = zpg.field.Uuid;
const Timestamp = zpg.field.Timestamp;

pub const User = struct {
    id: Uuid,
    username: []const u8,
    email: []const u8,
    created_at: Timestamp,
};
```

### Integration with processSelectResponses

The `processSelectResponses` function already supports timestamps:

```zig
} else if (@hasDecl(FieldType, "isTimestamp") and FieldType.isTimestamp) {
    const len = try reader.readInt(i32, .big);
    if (len < 0) return FieldType{}; // NULL timestamp, return empty
    const bytes = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(bytes);
    const read = try reader.readAtLeast(bytes, @intCast(len));
    if (read < @as(usize, @intCast(len))) return error.IncompleteRead;
    return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidTimestamp;
}
```

This works with our `Timestamp` struct because:
1. It has `pub const isTimestamp = true`
2. It implements `fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Timestamp`
3. It handles the NULL case by returning a zeroed struct (seconds: 0, nano_seconds: 0)

### Usage Example

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example from database
    const db_timestamp = "2025-03-24 15:30:45.123456+00";
    const ts = try Timestamp.fromPostgresText(db_timestamp, allocator);

    const user = User{
        .id = try Uuid.fromString("550e8400-e29b-41d4-a716-446655440000"),
        .username = "johndoe",
        .email = "john@example.com",
        .created_at = ts,
    };

    std.debug.print("Created at: {}s {}ns\n", .{user.created_at.seconds, user.created_at.nano_seconds});

    // alternative way of preparing timestamp value, converting formated datetime into timestamp.
    const ts = try Timestamp.parse("%Y-%m-%d %H:%M:%S", "2025-03-25 14:30:00");
    std.debug.print("Parsed: {}s, {}ns\n", .{ts.seconds, ts.nano_seconds});

    const formatted = try ts.format("%Y/%m/%d %H:%M:%S", allocator);
    defer allocator.free(formatted);
    std.debug.print("Formatted: {s}\n", .{formatted});
}
```

The timestamp will be stored as UTC seconds since epoch with nanosecond precision, which is useful for calculations and comparisons. For production use, you might want to use a proper date/time library instead of the simplified conversion logic.
