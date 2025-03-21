fn readValueForType(reader: std.io.AnyReader, comptime FieldType: type, allocator: std.mem.Allocator) !FieldType {
    return switch (@typeInfo(FieldType)) {
        // Integer types (signed and unsigned)
        .int => |info| {
            const len = try reader.readInt(i32, .big);
            if (len < 0) return 0;
            const bytes = try allocator.alloc(u8, @intCast(len));
            defer allocator.free(bytes);
            const read = try reader.readAll(bytes);
            if (read != @as(usize, @intCast(len))) return error.IncompleteRead;

            // Handle signed vs unsigned integers differently
            if (info.signedness == .unsigned) {
                return std.fmt.parseUnsigned(FieldType, bytes, 10) catch return error.InvalidNumber;
            } else {
                return std.fmt.parseInt(FieldType, bytes, 10) catch return error.InvalidNumber;
            }
        },

        // Floating point types (f32, f64)
        .float => {
            const len = try reader.readInt(i32, .big);
            if (len < 0) return 0;
            const bytes = try allocator.alloc(u8, @intCast(len));
            defer allocator.free(bytes);
            const read = try reader.readAll(bytes);
            if (read != @as(usize, @intCast(len))) return error.IncompleteRead;

            return std.fmt.parseFloat(FieldType, bytes) catch return error.InvalidNumber;
        },

        // Boolean type
        .bool => {
            const len = try reader.readInt(i32, .big);
            if (len < 0) return false;
            const bytes = try allocator.alloc(u8, @intCast(len));
            defer allocator.free(bytes);
            const read = try reader.readAll(bytes);
            if (read != @as(usize, @intCast(len))) return error.IncompleteRead;

            if (bytes.len == 1) {
                return switch (bytes[0]) {
                    't', 'T', '1' => true,
                    'f', 'F', '0' => false,
                    else => return error.InvalidBoolean,
                };
            } else if (std.mem.eql(u8, bytes, "true") or std.mem.eql(u8, bytes, "TRUE")) {
                return true;
            } else if (std.mem.eql(u8, bytes, "false") or std.mem.eql(u8, bytes, "FALSE")) {
                return false;
            }

            return error.InvalidBoolean;
        },

        // String slices ([]const u8, []u8)
        .pointer => |ptr| {
            if (ptr.size == .slice and (ptr.child == u8 or ptr.child == u8)) {
                const len = try reader.readInt(i32, .big);
                if (len < 0) return ""; // NULL value, return empty string
                if (len > 1024 * 1024) return error.StringTooLong; // 1MB limit for safety
                const bytes = try allocator.alloc(u8, @intCast(len));
                // Note: No defer free here - the caller must free this memory
                const read = try reader.readAll(bytes);
                if (read != @as(usize, @intCast(len))) {
                    allocator.free(bytes);
                    return error.IncompleteRead;
                }
                return bytes;
            } else {
                @compileError("Unsupported pointer type: " ++ @typeName(FieldType));
            }
        },

        // Optional values (handle NULL)
        .optional => |opt_info| {
            const len = try reader.readInt(i32, .big);
            if (len < 0) return null; // NULL value

            // Create a reader that doesn't consume the length prefix (we already read it)
            var limitedReader = std.io.limitedReader(reader, len);

            // Read the value using recursion for the contained type
            const value = try readValueForType(limitedReader.reader(), opt_info.child, allocator);
            return value;
        },

        // UUID support (if represented as a struct)
        .struct => |struct_info| {
            if (@hasDecl(FieldType, "isUuid") and FieldType.isUuid) {
                const len = try reader.readInt(i32, .big);
                if (len < 0) return FieldType{}; // NULL UUID, return empty

                const bytes = try allocator.alloc(u8, @intCast(len));
                defer allocator.free(bytes);
                const read = try reader.readAll(bytes);
                if (read != @as(usize, @intCast(len))) return error.IncompleteRead;

                // Assuming the UUID struct has a fromString method
                return FieldType.fromString(bytes) catch return error.InvalidUuid;
            } else if (@hasDecl(FieldType, "fromPostgresText")) {
                // Support for custom types that know how to parse themselves
                const len = try reader.readInt(i32, .big);
                if (len < 0) return FieldType{}; // NULL value, return empty struct

                const bytes = try allocator.alloc(u8, @intCast(len));
                defer allocator.free(bytes);
                const read = try reader.readAll(bytes);
                if (read != @as(usize, @intCast(len))) return error.IncompleteRead;

                return FieldType.fromPostgresText(bytes, allocator) catch return error.InvalidCustomType;
            } else {
                @compileError("Unsupported struct type: " ++ @typeName(FieldType));
            }
        },

        // Add support for arrays (for PostgreSQL array types)
        .array => |array_info| {
            @compileError("Array types not yet supported: " ++ @typeName(FieldType));
            // Implementation would need to parse PostgreSQL array literal format like {1,2,3}
        },

        // Add support for enums (map from strings or numbers)
        .enum_full => |enum_info| {
            const len = try reader.readInt(i32, .big);
            if (len < 0) return @as(FieldType, 0); // NULL value, return first enum value

            const bytes = try allocator.alloc(u8, @intCast(len));
            defer allocator.free(bytes);
            const read = try reader.readAll(bytes);
            if (read != @as(usize, @intCast(len))) return error.IncompleteRead;

            // Try to convert string to enum
            return std.meta.stringToEnum(FieldType, bytes) orelse error.InvalidEnum;
        },

        // Fallback for unsupported types
        else => @compileError("Unsupported field type: " ++ @typeName(FieldType)),
    };
}

// Example custom Decimal type for PostgreSQL numeric/decimal values
pub const Decimal = struct {
    // Using a simplified representation - in production you might want
    // a more sophisticated decimal implementation
    value: i64,
    scale: u8,  // Number of digits to the right of the decimal point

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Decimal {
        const decimal_point_pos = std.mem.indexOf(u8, text, ".");

        if (decimal_point_pos) |pos| {
            // Has decimal point
            var value_str = try allocator.alloc(u8, text.len - 1);
            defer allocator.free(value_str);

            std.mem.copy(u8, value_str[0..pos], text[0..pos]);
            std.mem.copy(u8, value_str[pos..], text[pos+1..]);

            const value = try std.fmt.parseInt(i64, value_str, 10);
            const scale = @intCast(text.len - pos - 1);

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
            std.mem.set(u8, result[sign.len..sign.len+zeros_needed], '0');
            result[sign.len] = '0'; // First zero before decimal
            result[sign.len+1] = '.'; // Decimal point
            std.mem.set(u8, result[sign.len+2..sign.len+zeros_needed], '0'); // Zeros after decimal
            std.mem.copy(u8, result[sign.len+zeros_needed..], value_str);

            return result;
        } else {
            // Normal case with enough digits
            const decimal_pos = value_str.len - self.scale;
            const result = try allocator.alloc(u8, sign.len + value_str.len + 1);

            std.mem.copy(u8, result[0..], sign);
            std.mem.copy(u8, result[sign.len..sign.len+decimal_pos], value_str[0..decimal_pos]);
            result[sign.len+decimal_pos] = '.';
            std.mem.copy(u8, result[sign.len+decimal_pos+1..], value_str[decimal_pos..]);

            return result;
        }
    }
};

// Example UUID implementation
pub const Uuid = struct {
    bytes: [16]u8,

    pub const isUuid = true;

    pub fn fromString(str: []const u8) !Uuid {
        var uuid: Uuid = undefined;

        if (str.len != 36 and str.len != 32) {
            return error.InvalidUuidFormat;
        }

        var pos: usize = 0;
        var byte_pos: usize = 0;

        while (byte_pos < 16) : (byte_pos += 1) {
            // Skip hyphens if present
            if (str.len == 36 and (pos == 8 or pos == 13 or pos == 18 or pos == 23)) {
                if (str[pos] != '-') return error.InvalidUuidFormat;
                pos += 1;
            }

            const high = try charToHex(str[pos]);
            pos += 1;
            const low = try charToHex(str[pos]);
            pos += 1;

            uuid.bytes[byte_pos] = (high << 4) | low;
        }

        return uuid;
    }

    fn charToHex(c: u8) !u4 {
        return switch (c) {
            '0'...'9' => @intCast(c - '0'),
            'a'...'f' => @intCast(c - 'a' + 10),
            'A'...'F' => @intCast(c - 'A' + 10),
            else => error.InvalidHexDigit,
        };
    }

    pub fn toString(self: Uuid, allocator: std.mem.Allocator) ![]u8 {
        const result = try allocator.alloc(u8, 36);

        var i: usize = 0;
        for (self.bytes, 0..) |byte, index| {
            // Add hyphens at specific positions
            if (index == 4 or index == 6 or index == 8 or index == 10) {
                result[i] = '-';
                i += 1;
            }

            // Write hex representation of byte
            const hex_chars = "0123456789abcdef";
            result[i] = hex_chars[byte >> 4];
            result[i + 1] = hex_chars[byte & 0x0F];
            i += 2;
        }

        return result;
    }
};

// Helper function to cleanly read nullable fields
pub fn readNullableField(reader: std.io.AnyReader, comptime T: type, allocator: std.mem.Allocator) !?T {
    const len = try reader.readInt(i32, .big);
    if (len < 0) return null; // NULL value

    var limitedReader = std.io.limitedReader(reader, len);
    return try readValueForType(limitedReader.reader(), T, allocator);
}
