const std = @import("std");

/// Represents PostgreSQL's `bit(n)` type: a fixed-length bit string
pub const Bit = struct {
    bits: []u8, // Stores bits packed into bytes (8 bits per u8)
    length: usize, // Number of bits (fixed, matches n)

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator, expected_length: usize) !Bit {
        if (text.len != expected_length) return error.InvalidBitLength;

        // Allocate enough bytes to hold the bits (1 byte = 8 bits)
        const byte_count = (expected_length + 7) / 8; // Ceiling division
        var bits = try allocator.alloc(u8, byte_count);
        @memset(bits, 0); // Initialize to 0

        // Parse bit string (e.g., "1010")
        for (text, 0..) |c, i| {
            const byte_idx = i / 8;
            const bit_idx: u3 = @intCast(7 - (i % 8)); // Big-endian bit order
            if (c == '1') {
                bits[byte_idx] |= @as(u8, 1) << bit_idx;
            } else if (c != '0') {
                allocator.free(bits);
                return error.InvalidBitFormat;
            }
        }

        return Bit{ .bits = bits, .length = expected_length };
    }

    pub fn deinit(self: Bit, allocator: std.mem.Allocator) void {
        allocator.free(self.bits);
    }

    pub fn toString(self: Bit, allocator: std.mem.Allocator) ![]u8 {
        var result = try allocator.alloc(u8, self.length);
        for (0..self.length) |i| {
            const byte_idx = i / 8;
            const bit_idx: u3 = @intCast(7 - (i % 8));
            result[i] = if ((self.bits[byte_idx] & (@as(u8, 1) << bit_idx)) != 0) '1' else '0';
        }
        return result;
    }
};

/// Represents PostgreSQL's `bit varying(n)` type: a variable-length bit string
pub const VarBit = struct {
    bits: []u8, // Stores bits packed into bytes
    length: usize, // Number of bits (variable, <= max_length)
    max_length: usize, // Maximum allowed bits (n)

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator, max_length: usize) !VarBit {
        if (text.len > max_length) return error.BitLengthExceedsMax;

        // Allocate enough bytes to hold the bits
        const byte_count = (text.len + 7) / 8;
        var bits = try allocator.alloc(u8, byte_count);
        @memset(bits, 0);

        // Parse bit string
        for (text, 0..) |c, i| {
            const byte_idx = i / 8;
            const bit_idx: u3 = @intCast(7 - (i % 8));
            if (c == '1') {
                bits[byte_idx] |= @as(u8, 1) << bit_idx;
            } else if (c != '0') {
                allocator.free(bits);
                return error.InvalidBitFormat;
            }
        }

        return VarBit{ .bits = bits, .length = text.len, .max_length = max_length };
    }

    pub fn deinit(self: VarBit, allocator: std.mem.Allocator) void {
        allocator.free(self.bits);
    }

    pub fn toString(self: VarBit, allocator: std.mem.Allocator) ![]u8 {
        var result = try allocator.alloc(u8, self.length);
        for (0..self.length) |i| {
            const byte_idx = i / 8;
            const bit_idx: u3 = @intCast(7 - (i % 8));
            result[i] = if ((self.bits[byte_idx] & (@as(u8, 1) << bit_idx)) != 0) '1' else '0';
        }
        return result;
    }
};

// Tests
test "Bit String Types" {
    const allocator = std.testing.allocator;

    // Test bit(4)
    var bit = try Bit.fromPostgresText("1010", allocator, 4);
    defer bit.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), bit.length);
    try std.testing.expectEqualSlices(u8, &[_]u8{0b10100000}, bit.bits);
    const bit_str = try bit.toString(allocator);
    defer allocator.free(bit_str);
    try std.testing.expectEqualStrings("1010", bit_str);

    // Test bit(10)
    var bit10 = try Bit.fromPostgresText("1100110011", allocator, 10);
    defer bit10.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0b11001100, 0b11000000 }, bit10.bits);
    const bit10_str = try bit10.toString(allocator);
    defer allocator.free(bit10_str);
    try std.testing.expectEqualStrings("1100110011", bit10_str);

    // Test varbit(8)
    var varbit = try VarBit.fromPostgresText("101", allocator, 8);
    defer varbit.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), varbit.length);
    try std.testing.expectEqualSlices(u8, &[_]u8{0b10100000}, varbit.bits);
    const varbit_str = try varbit.toString(allocator);
    defer allocator.free(varbit_str);
    try std.testing.expectEqualStrings("101", varbit_str);

    // Test invalid input
    try std.testing.expectError(error.InvalidBitFormat, Bit.fromPostgresText("10a0", allocator, 4));
    try std.testing.expectError(error.InvalidBitLength, Bit.fromPostgresText("101", allocator, 4));
    try std.testing.expectError(error.BitLengthExceedsMax, VarBit.fromPostgresText("10101", allocator, 4));
}
