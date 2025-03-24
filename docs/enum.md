Let’s explore how to use an `enum` field with PostgreSQL and integrate it into our `User` struct, leveraging the `processSelectResponses` function’s existing support for enums.

### PostgreSQL Table with Enum

PostgreSQL supports custom `ENUM` types, which are useful for fields with a fixed set of possible values. Here’s how to define an `ENUM` type and use it in the `users` table:

```sql
-- Create the ENUM type
CREATE TYPE user_status AS ENUM ('active', 'inactive', 'suspended');

-- Update the users table to include the enum field
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    status user_status DEFAULT 'active'
);
```

- `user_status` is a custom ENUM type with three possible values: 'active', 'inactive', 'suspended'
- PostgreSQL outputs these as text strings (e.g., "active")
- The `DEFAULT 'active'` sets the initial status

### Enum Support in processSelectResponses

The `processSelectResponses` function already has explicit support for enums:

```zig
.@"enum" => |enum_info| {
    _ = enum_info;
    const len = try reader.readInt(i32, .big);
    if (len < 0) return @as(FieldType, 0); // NULL value, return first enum value
    const bytes = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(bytes);
    const read = try reader.readAtLeast(bytes, @intCast(len));
    if (read < @as(usize, @intCast(len))) return error.IncompleteRead;
    // Try to convert string to enum
    return std.meta.stringToEnum(FieldType, bytes[0..read]) orelse error.InvalidEnum;
}
```

This works because:
1. It reads the text representation from PostgreSQL
2. Uses Zig’s `std.meta.stringToEnum` to convert the string to the corresponding enum value
3. Returns the first enum value (numeric 0) for NULL
4. Returns `error.InvalidEnum` if the string doesn’t match any enum variant

### Defining the Enum and Updating User Struct

Here’s how to define a matching `UserStatus` enum in Zig and integrate it into the `User` struct:

```zig
const std = @import("std");
const zpg = @import("zpg");
const Uuid = zpg.field.Uuid;


pub const UserStatus = enum {
    active,
    inactive,
    suspended,
};

pub const User = struct {
    id: Uuid,
    username: []const u8,
    email: []const u8,
    status: UserStatus,
};
```

### How It Works

1. **PostgreSQL Output**:
   - The `status` column returns strings like "active", "inactive", or "suspended"
   - For NULL values, it sends a length of -1

2. **Zig Enum Mapping**:
   - `std.meta.stringToEnum(UserStatus, "active")` returns `UserStatus.active`
   - The enum values are implicitly numbered: `active = 0`, `inactive = 1`, `suspended = 2`
   - NULL maps to `active` (0) due to the `return @as(FieldType, 0)` in the NULL case

3. **Type Safety**:
   - If PostgreSQL returns an invalid value (e.g., "deleted"), `stringToEnum` returns `null`, and `processSelectResponses` raises `error.InvalidEnum`

### Usage Example

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example user data (simulating database output)
    const user = User{
        .id = try Uuid.fromString("550e8400-e29b-41d4-a716-446655440000"),
        .username = "johndoe",
        .email = "john@example.com",
        .status = UserStatus.active, // This would come from processSelectResponses
    };

    // Convert enum to string for display
    const status_str = @tagName(user.status);
    std.debug.print("User status: {s}\n", .{status_str});

    // Example of matching
    switch (user.status) {
        .active => std.debug.print("User is active\n", .{}),
        .inactive => std.debug.print("User is inactive\n", .{}),
        .suspended => std.debug.print("User is suspended\n", .{}),
    }
}
```

### Improvements and Considerations

1. **NULL Handling**:
   - Currently, NULL maps to `.active` (first variant)
   - If you want explicit NULL support, make it an optional:

```zig
pub const User = struct {
    // ... other fields
    status: ?UserStatus, // Now NULL maps to null instead of .active
};
```

Then modify `processSelectResponses` to handle optional enums explicitly, or rely on the `.optional` case:

```zig
.optional => |opt_info| {
    const len = try reader.readInt(i32, .big);
    if (len < 0) return null;
    var limitedReader = std.io.limitedReader(reader, len);
    const value = try readValueForType(limitedReader.reader(), opt_info.child, allocator);
    return value;
},
```

2. **Custom Mapping**:
   - If PostgreSQL enum values don’t match Zig enum names, you could add a custom conversion:

```zig
pub const UserStatus = enum {
    active,
    not_active, // Different name from "inactive"
    suspended,

    pub fn fromPostgresString(str: []const u8) !UserStatus {
        if (std.mem.eql(u8, str, "active")) return .active;
        if (std.mem.eql(u8, str, "inactive")) return .not_active;
        if (std.mem.eql(u8, str, "suspended")) return .suspended;
        return error.InvalidEnum;
    }
};
```

But since `processSelectResponses` uses `stringToEnum`, the enum names must match PostgreSQL exactly, or you’d need to modify the parsing logic.

3. **Debugging**:
   - Add a `toString` helper if needed:

```zig
pub const UserStatus = enum {
    active,
    inactive,
    suspended,

    pub fn toString(self: UserStatus) []const u8 {
        return @tagName(self);
    }
};
```

### Notes

- **Sync with Database**: Ensure the Zig enum variants match the PostgreSQL ENUM type values exactly (case-sensitive)
- **Order**: The order in Zig doesn’t need to match PostgreSQL, but names must correspond
- **Extensibility**: To add new values, update both the PostgreSQL ENUM (using `ALTER TYPE`) and the Zig enum

This setup provides type-safe handling of PostgreSQL ENUMs within your Zig application, fully compatible with `processSelectResponses`. The enum approach is ideal for fields with a small, fixed set of valid states.
