const std = @import("std");

/// Generic Bit type with fixed length as a parameter
fn BitType(comptime n: usize) type {
    return struct {
        bits: []u8,
        length: usize,

        pub fn fromPostgresBinary(data: []const u8, allocator: std.mem.Allocator) !@This() {
            const byte_count = (n + 7) / 8;
            if (data.len != byte_count) return error.InvalidBitLength;

            const bits = try allocator.alloc(u8, byte_count);
            @memcpy(bits, data); // Directly copy raw bytes

            return .{ .bits = bits, .length = n };
        }

        pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !@This() {
            if (text.len != n) return error.InvalidBitLength;

            const byte_count = (n + 7) / 8;
            var bits = try allocator.alloc(u8, byte_count);
            @memset(bits, 0);

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

            return .{ .bits = bits, .length = n };
        }

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.bits);
        }

        pub fn toString(self: @This(), allocator: std.mem.Allocator) ![]u8 {
            var result = try allocator.alloc(u8, self.length);
            for (0..self.length) |i| {
                const byte_idx = i / 8;
                const bit_idx: u3 = @intCast(7 - (i % 8));
                result[i] = if ((self.bits[byte_idx] & (@as(u8, 1) << bit_idx)) != 0) '1' else '0';
            }
            return result;
        }
    };
}

/// Generic VarBit type with max length as a parameter
fn VarBitType(comptime n: usize) type {
    return struct {
        bits: []u8,
        length: usize,
        max_length: usize,

        pub fn fromPostgresBinary(data: []const u8, allocator: std.mem.Allocator) !@This() {
            if (data.len < 4) return error.InvalidBitFormat;

            // Read bit length (first 4 bytes are big-endian int32)
            var bit_length: i32 = @bitCast(std.mem.bytesToValue(i32, data[0..4]));
            bit_length = @byteSwap(bit_length); // Convert big-endian to little-endian

            if (bit_length < 0 or @as(usize, @intCast(bit_length)) > n) return error.InvalidBitLength;

            const byte_count = (@as(usize, @intCast(bit_length)) + 7) / 8;
            if (data.len - 4 != byte_count) return error.InvalidBitLength;

            const bits = try allocator.alloc(u8, byte_count);
            @memcpy(bits, data[4..]); // Copy the bit data

            return .{ .bits = bits, .length = @intCast(bit_length), .max_length = n };
        }

        pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !@This() {
            if (text.len > n) return error.BitLengthExceedsMax;

            const byte_count = (text.len + 7) / 8;
            var bits = try allocator.alloc(u8, byte_count);
            @memset(bits, 0);

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

            return .{ .bits = bits, .length = text.len, .max_length = n };
        }

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.bits);
        }

        pub fn toString(self: @This(), allocator: std.mem.Allocator) ![]u8 {
            var result = try allocator.alloc(u8, self.length);
            for (0..self.length) |i| {
                const byte_idx = i / 8;
                const bit_idx: u3 = @intCast(7 - (i % 8));
                result[i] = if ((self.bits[byte_idx] & (@as(u8, 1) << bit_idx)) != 0) '1' else '0';
            }
            return result;
        }
    };
}

// Define specific types for your test
pub const Bit10 = BitType(10);
pub const VarBit16 = VarBitType(16);
