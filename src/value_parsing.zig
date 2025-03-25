const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn readString(allocator: std.mem.Allocator, reader: anytype) ![]const u8 {
    const len = try reader.readInt(u16, .big);
    if (len == 0xffff) return ""; // NULL value
    const str = try allocator.alloc(u8, len);
    try reader.readNoEof(str);
    return str;
}

fn parseArrayElements(
    allocator: std.mem.Allocator,
    bytes: []u8,
    pos: *usize, // Pointer to usize, mutable
    end: usize,
    comptime ElementType: type,
    elements: *std.ArrayList(ElementType),
) !usize {
    while (*pos < end) {
        // Skip whitespace
        while (*pos < end and bytes[*pos] == ' ') {
            (*pos) += 1; // Increment pos to skip spaces
        }
        if (*pos >= end) break;

        if (bytes[*pos] == '}') {
            return *pos; // Return current position at end of array
        }

        if (bytes[*pos] == ',') {
            (*pos) += 1; // Skip comma
            continue;
        }

        // Handle NULL
        if (*pos + 4 <= end and std.mem.eql(u8, bytes[*pos .. *pos + 4], "NULL")) {
            try elements.append(fillDefaultValue(ElementType, @as(ElementType, 0), allocator));
            (*pos) += 4; // Skip "NULL"
            continue;
        }

        // Check for nested array
        const element_type_info = @typeInfo(ElementType);
        if (bytes[*pos] == '{' and (element_type_info == .array or element_type_info == .pointer)) {
            var nested_elements = std.ArrayList(element_type_info.array.child).init(allocator);
            defer nested_elements.deinit();
            (*pos) += 1; // Skip '{'
            (*pos) = try parseArrayElements(allocator, bytes, pos, end, element_type_info.array.child, &nested_elements);

            if (element_type_info == .array) {
                if (nested_elements.items.len != element_type_info.array.len) return error.ArrayLengthMismatch;
                var nested_array: ElementType = undefined;
                @memcpy(nested_array[0..element_type_info.array.len], nested_elements.items[0..element_type_info.array.len]);
                try elements.append(nested_array);
            } else { // .pointer (slice)
                try elements.append(try nested_elements.toOwnedSlice());
            }
            (*pos) += 1; // Skip '}'
            continue;
        }

        // Parse a single element
        var start = *pos;
        const in_quotes = bytes[*pos] == '"';
        if (in_quotes) start += 1;

        while (*pos < end) {
            if (in_quotes) {
                if (bytes[*pos] == '"') break;
            } else if (bytes[*pos] == ',' or bytes[*pos] == '}') {
                break;
            }
            (*pos) += 1; // Move to next character
        }

        var element_end = *pos;
        if (in_quotes) {
            if (*pos >= end or bytes[*pos] != '"') return error.InvalidArrayFormat;
            element_end -= 1; // Exclude closing quote
            (*pos) += 1; // Skip closing quote
        }

        const element_str = bytes[start..element_end];
        var element_fbs = std.io.fixedBufferStream(element_str);
        const value = try readValueForType(element_fbs.reader().any(), ElementType, allocator);
        try elements.append(value);
    }
    return *pos;
}

fn fillDefaultArray(comptime T: type, info: std.builtin.Type.Array, default: anytype) T {
    var result: T = undefined;
    const child_info = @typeInfo(info.child);
    if (child_info == .array) {
        for (0..info.len) |i| {
            result[i] = fillDefaultArray(info.child, child_info.array, default);
        }
    } else {
        @memset(result[0..info.len], default);
    }
    return result;
}

fn fillDefaultValue(comptime T: type, default: T) T {
    const type_info = @typeInfo(T);
    return switch (type_info) {
        .int, .float => default,
        .bool => false,
        .pointer => if (type_info.pointer.size == .slice) "" else @compileError("Unsupported pointer type"),
        .array => fillDefaultArray(T, type_info.array, default),
        .optional => null,
        else => @compileError("Unsupported type for default value: " ++ @typeName(T)),
    };
}

pub fn readValueForType(allocator: std.mem.Allocator, reader: std.io.AnyReader, comptime FieldType: type) !FieldType {
    return switch (@typeInfo(FieldType)) {
        .int => |info| {
            const len = try reader.readInt(i32, .big);
            if (len < 0) return 0;
            const bytes = try allocator.alloc(u8, @intCast(len));
            defer allocator.free(bytes);
            const read = try reader.readAtLeast(bytes, @intCast(len));
            if (read < @as(usize, @intCast(len))) return error.IncompleteRead;

            // Handle signed vs unsigned integers differently
            if (info.signedness == .unsigned) {
                return std.fmt.parseUnsigned(FieldType, bytes[0..read], 10) catch return error.InvalidNumber;
            } else {
                return std.fmt.parseInt(FieldType, bytes[0..read], 10) catch return error.InvalidNumber;
            }
        },
        .float => {
            const len = try reader.readInt(i32, .big);
            if (len < 0) return 0;
            const bytes = try allocator.alloc(u8, @intCast(len));
            defer allocator.free(bytes);
            const read = try reader.readAtLeast(bytes, @intCast(len));
            if (read < @as(usize, @intCast(len))) return error.IncompleteRead;

            return std.fmt.parseFloat(FieldType, bytes[0..read]) catch return error.InvalidNumber;
        },
        .bool => {
            const len = try reader.readInt(i32, .big);
            if (len < 0) return false;
            const bytes = try allocator.alloc(u8, @intCast(len));
            defer allocator.free(bytes);
            const read = try reader.readAtLeast(bytes, @intCast(len));
            if (read < @as(usize, @intCast(len))) return error.IncompleteRead;

            if (read == 1) {
                return switch (bytes[0]) {
                    't', 'T', '1' => true,
                    'f', 'F', '0' => false,
                    else => return error.InvalidBoolean,
                };
            } else if (std.mem.eql(u8, bytes[0..read], "true") or std.mem.eql(u8, bytes[0..read], "TRUE")) {
                return true;
            } else if (std.mem.eql(u8, bytes[0..read], "false") or std.mem.eql(u8, bytes[0..read], "FALSE")) {
                return false;
            }

            return error.InvalidBoolean;
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                const len = try reader.readInt(i32, .big);
                if (len < 0) return "";
                if (len > 1024) return error.StringTooLong;
                const bytes = try allocator.alloc(u8, @intCast(len));
                // Note: No defer free here - this is intentional, as the caller must free this memory
                const read = try reader.readAtLeast(bytes, @intCast(len));
                if (read < @as(usize, @intCast(len))) return error.IncompleteRead;
                return bytes[0..read];
            } else {
                @compileError("Unsupported pointer type: " ++ @typeName(FieldType));
            }
        },
        .optional => |opt_info| {
            const len = try reader.readInt(i32, .big);
            if (len < 0) return null; // NULL value

            // Create a reader that doesn't consume the length prefix (we already read it)
            var limitedReader = std.io.limitedReader(reader, len);

            // Read the value using recursion for the contained type
            const value = try readValueForType(limitedReader.reader(), opt_info.child, allocator);
            return value;
        },
        .array => |array_info| {
            const len = try reader.readInt(i32, .big);
            if (len < 0) {
                if (array_info.size == .slice) {
                    return @as(FieldType, &[_]array_info.child{}); // Empty slice for NULL
                } else {
                    // For fixed-size, fill with defaults (recursively for nested arrays)
                    return fillDefaultArray(FieldType, array_info, @as(array_info.child, 0));
                }
            }

            const bytes = try allocator.alloc(u8, @intCast(len));
            defer allocator.free(bytes);
            const read = try reader.readAtLeast(bytes, @intCast(len));
            if (read < @as(usize, @intCast(len))) return error.IncompleteRead;

            if (bytes[0] != '{') return error.InvalidArrayFormat;
            if (bytes[read - 1] != '}') return error.InvalidArrayFormat;

            // Parse the array recursively
            var pos: usize = 1; // Skip '{'
            var elements = std.ArrayList(array_info.child).init(allocator);
            defer elements.deinit();

            pos = try parseArrayElements(allocator, bytes, &pos, read - 1, // Up to but not including '}'
                array_info.child, &elements);

            // Return based on type
            if (array_info.size == .slice) {
                return elements.toOwnedSlice();
            } else {
                if (elements.items.len != array_info.len) return error.ArrayLengthMismatch;
                var result: FieldType = undefined;
                @memcpy(result[0..array_info.len], elements.items[0..array_info.len]);
                return result;
            }
        },
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
        },
        .@"struct" => |struct_info| {
            _ = struct_info;
            if (@hasDecl(FieldType, "isUuid") and FieldType.isUuid) {
                const len = try reader.readInt(i32, .big);
                if (len < 0) return FieldType{}; // NULL UUID, return empty

                const bytes = try allocator.alloc(u8, @intCast(len));
                defer allocator.free(bytes);
                const read = try reader.readAtLeast(bytes, @intCast(len));
                if (read < @as(usize, @intCast(len))) return error.IncompleteRead;

                // Assuming the UUID struct has a fromString method
                return FieldType.fromString(bytes[0..read]) catch return error.InvalidUuid;
            } else if (@hasDecl(FieldType, "isTimestamp") and FieldType.isTimestamp) {
                // Handle timestamp type
                const len = try reader.readInt(i32, .big);
                if (len < 0) return FieldType{}; // NULL timestamp, return empty

                const bytes = try allocator.alloc(u8, @intCast(len));
                defer allocator.free(bytes);
                const read = try reader.readAtLeast(bytes, @intCast(len));
                if (read < @as(usize, @intCast(len))) return error.IncompleteRead;

                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidTimestamp;
            } else if (@hasDecl(FieldType, "isInterval") and FieldType.isInterval) {
                // Handle interval type
                const len = try reader.readInt(i32, .big);
                if (len < 0) return FieldType{}; // NULL interval, return empty

                const bytes = try allocator.alloc(u8, @intCast(len));
                defer allocator.free(bytes);
                const read = try reader.readAtLeast(bytes, @intCast(len));
                if (read < @as(usize, @intCast(len))) return error.IncompleteRead;

                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidInterval;
            } else if (@hasDecl(FieldType, "fromPostgresText")) {
                // Support for custom types that know how to parse themselves
                const len = try reader.readInt(i32, .big);
                if (len < 0) return FieldType{}; // NULL value, return empty struct

                const bytes = try allocator.alloc(u8, @intCast(len));
                defer allocator.free(bytes);
                const read = try reader.readAtLeast(bytes, @intCast(len));
                if (read < @as(usize, @intCast(len))) return error.IncompleteRead;

                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidCustomType;
            } else {
                @compileError("Unsupported struct type: " ++ @typeName(FieldType));
            }
        },
        else => @compileError("Unsupported field type: " ++ @typeName(FieldType)),
    };
}
