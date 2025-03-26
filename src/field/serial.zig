const std = @import("std");

pub fn SERIAL(comptime IntType: type) type {
    const type_info = @typeInfo(IntType);
    if (type_info != .int or type_info.int.signedness != .unsigned) {
        @compileError("SERIAL must be based on an unsigned integer type (u16, u32, or u64)");
    }

    return struct {
        value: IntType,

        const Self = @This();

        // Default constructor
        pub fn init(value: IntType) Self {
            return .{ .value = value };
        }

        // Parse from PostgreSQL text format (e.g., "12345")
        pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Self {
            _ = allocator; // Unused here, but included for consistency with Decimal/Money
            const value = try std.fmt.parseUnsigned(IntType, text, 10);
            // Optionally enforce serial constraints (e.g., value > 0)
            if (value == 0) return error.InvalidSerialValue; // Serials start at 1
            return Self{ .value = value };
        }

        // Helper to identify this as a SERIAL type
        pub const isSerial = true;
    };
}

// Define specific serial types
pub const SmallSerial = SERIAL(u16);
pub const Serial = SERIAL(u32);
pub const BigSerial = SERIAL(u64);
