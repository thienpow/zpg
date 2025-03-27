const std = @import("std");
const Allocator = std.mem.Allocator;

const Decimal = @import("field/decimal.zig").Decimal;
const Money = @import("field/money.zig").Money;

pub fn readString(allocator: std.mem.Allocator, reader: anytype) ![]const u8 {
    const len = try reader.readInt(u16, .big);
    if (len == 0xffff) return ""; // NULL value
    const str = try allocator.alloc(u8, len);
    try reader.readNoEof(str);
    return str;
}

pub fn parseArrayElements(
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
            try elements.append(fillDefaultValue(ElementType, @as(ElementType, 0)));
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
        const value = try readValueForType(allocator, element_fbs.reader().any(), ElementType);
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
        if (info.child == u8) {
            @memset(result[0..info.len], ' '); // Pad CHAR(n) with spaces
        } else {
            @memset(result[0..info.len], default); // Use default for other types
        }
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
                std.debug.print("Attempting to read string for type {s}\n", .{@typeName(FieldType)});

                const len = try reader.readInt(i32, .big);
                std.debug.print("Read length: {}\n", .{len});

                if (len < 0) return "";
                if (len > 1024) return error.StringTooLong;

                const bytes = try allocator.alloc(u8, @intCast(len));
                defer allocator.free(bytes);

                // Zero out the memory before reading
                @memset(bytes, 0);

                std.debug.print("Pre-read memory state: ", .{});
                for (bytes) |byte| {
                    std.debug.print("{x} ", .{byte});
                }
                std.debug.print("\n", .{});

                const read = try reader.readAtLeast(bytes, @intCast(len));
                std.debug.print("Bytes read: {}\n", .{read});

                std.debug.print("Post-read memory state: ", .{});
                for (bytes[0..read]) |byte| {
                    std.debug.print("{x} ", .{byte});
                }
                std.debug.print("\n", .{});

                if (read < @as(usize, @intCast(len))) return error.IncompleteRead;

                // Detailed hex and ASCII diagnostics
                std.debug.print("Read string content as ASCII: {s}\n", .{bytes[0..read]});
                std.debug.print("Read string content as hex: ", .{});
                for (bytes[0..read]) |byte| {
                    std.debug.print("{x} ", .{byte});
                }
                std.debug.print("\n", .{});

                // Ensure we can actually read the bytes
                const result = try allocator.dupe(u8, bytes[0..read]);
                return result;
            } else {
                @compileError("Unsupported pointer type: " ++ @typeName(FieldType));
            }
        },
        .@"enum" => |enum_info| {
            _ = enum_info;
            const len = try reader.readInt(i32, .big);
            if (len < 0) return @as(FieldType, 0);

            const bytes = try allocator.alloc(u8, @intCast(len));
            defer allocator.free(bytes);
            const read = try reader.readAtLeast(bytes, @intCast(len));
            if (read < @as(usize, @intCast(len))) return error.IncompleteRead;

            return std.meta.stringToEnum(FieldType, bytes[0..read]) orelse error.InvalidEnum;
        },
        .optional => |opt_info| {
            if (@hasDecl(opt_info.child, "isSerial") and opt_info.child.isSerial) {
                @compileError("SERIAL types (SmallSerial, Serial, BigSerial) cannot be optional");
            }

            const len = try reader.readInt(i32, .big);
            if (len < 0) return null;
            const len_u64 = @as(u64, @intCast(len));
            var limitedReader = std.io.limitedReader(reader, len_u64);

            const child_info = @typeInfo(opt_info.child);
            const value = switch (child_info) {
                .int, .float, .bool => blk: {
                    if (len_u64 == 0) return error.IncompleteRead;
                    const child_value = try readValueForType(allocator, limitedReader.reader().any(), opt_info.child);
                    break :blk child_value;
                },
                .@"struct" => blk: {
                    if (len_u64 == 0) return error.IncompleteRead;
                    if (opt_info.child == Decimal) {
                        const bytes = try allocator.alloc(u8, len_u64);
                        defer allocator.free(bytes);
                        const read = try limitedReader.reader().readAtLeast(bytes, @intCast(len_u64));
                        if (read < len_u64) return error.IncompleteRead;
                        const child_value = try Decimal.fromPostgresText(bytes[0..read], allocator);
                        break :blk child_value;
                    }
                    if (opt_info.child == Money) {
                        const bytes = try allocator.alloc(u8, len_u64);
                        defer allocator.free(bytes);
                        const read = try limitedReader.reader().readAtLeast(bytes, @intCast(len_u64));
                        if (read < len_u64) return error.IncompleteRead;
                        const child_value = try Money.fromPostgresText(bytes[0..read], allocator);
                        break :blk child_value;
                    }
                    const child_value = try readValueForType(allocator, limitedReader.reader().any(), opt_info.child);
                    break :blk child_value;
                },
                .pointer, .array, .@"enum" => blk: {
                    if (len_u64 == 0) return error.IncompleteRead;
                    const child_value = try readValueForType(allocator, limitedReader.reader().any(), opt_info.child);
                    break :blk child_value;
                },
                else => @compileError("Unsupported optional child type: " ++ @typeName(opt_info.child)),
            };

            var remaining_buffer: [1]u8 = undefined;
            const bytes_left = try limitedReader.reader().read(&remaining_buffer);
            if (bytes_left > 0) {
                std.debug.print("Unexpected data left: {} bytes\n", .{bytes_left});
                return error.UnexpectedData;
            }

            return value;
        },
        .array => |array_info| {
            const len = try reader.readInt(i32, .big);
            if (array_info.child == u8) { // CHAR(n)
                if (len < 0) {
                    return fillDefaultArray(FieldType, array_info, ' ');
                }
                const bytes = try allocator.alloc(u8, @intCast(len));
                defer allocator.free(bytes);
                const read = try reader.readAtLeast(bytes, @intCast(len));
                if (read < @as(usize, @intCast(len))) return error.IncompleteRead;
                if (read > array_info.len) return error.StringTooLong;
                var result: FieldType = undefined;
                @memcpy(result[0..read], bytes[0..read]);
                @memset(result[read..array_info.len], ' ');
                return result;
            } else { // Handle all other arrays and slices
                if (len < 0) {
                    if (array_info.size == .slice) {
                        return @as(FieldType, &[_]array_info.child{});
                    } else {
                        return fillDefaultArray(FieldType, array_info, @as(array_info.child, 0));
                    }
                }
                const bytes = try allocator.alloc(u8, @intCast(len));
                defer allocator.free(bytes);
                const read = try reader.readAtLeast(bytes, @intCast(len));
                if (read < @as(usize, @intCast(len))) return error.IncompleteRead;

                if (bytes[0] != '{') return error.InvalidArrayFormat;
                if (bytes[read - 1] != '}') return error.InvalidArrayFormat;

                var pos: usize = 1;
                var elements = std.ArrayList(array_info.child).init(allocator);
                defer elements.deinit();

                pos = try parseArrayElements(allocator, bytes, &pos, read - 1, array_info.child, &elements);

                if (array_info.size == .slice) {
                    return elements.toOwnedSlice();
                } else {
                    if (elements.items.len != array_info.len) return error.ArrayLengthMismatch;
                    var result: FieldType = undefined;
                    @memcpy(result[0..array_info.len], elements.items[0..array_info.len]);
                    return result;
                }
            }
        },
        .@"struct" => |struct_info| {
            _ = struct_info;
            const len = try reader.readInt(i32, .big);

            if (len < 0) {
                if (FieldType == Decimal) return FieldType{ .value = 0, .scale = 0 };
                if (FieldType == Money) return FieldType{ .value = 0 };
                if (@hasDecl(FieldType, "isSerial") and FieldType.isSerial) return error.SerialCannotBeNull;
                if (@hasDecl(FieldType, "isUuid") and FieldType.isUuid) return FieldType{};
                if (@hasDecl(FieldType, "isVarchar") and FieldType.isVarchar) return FieldType{ .value = "" };
                if (@hasDecl(FieldType, "isTimestamp") and FieldType.isTimestamp) return FieldType{ .seconds = 0, .nano_seconds = 0 };
                if (@hasDecl(FieldType, "isInterval") and FieldType.isInterval) return FieldType{};
                if (@hasDecl(FieldType, "fromPostgresText")) return FieldType{};
                @compileError("Unsupported struct type for NULL: " ++ @typeName(FieldType));
            }
            if (len > 1024 * 1024) {
                std.debug.print("Struct: length {} exceeds maximum allowed, type={s}\n", .{ len, @typeName(FieldType) });
                return error.LengthTooLarge;
            }

            // Peek at the first few bytes without consuming them
            // var peek_buffer: [8]u8 = undefined;
            // const peeked = try reader.readAtLeast(&peek_buffer, @min(8, @as(usize, @intCast(len))));
            // std.debug.print("Struct: peeked {} bytes: '{s}'\n", .{ peeked, peek_buffer[0..peeked] });
            // Instead of rewinding (which isn't directly supported), we'll read again
            // Or we could use a buffered reader if available in your context

            const bytes = try allocator.alloc(u8, @intCast(len));
            defer allocator.free(bytes);
            const read = try reader.readAtLeast(bytes, @intCast(len));
            //std.debug.print("Struct: read {} of {} bytes, data='{s}'\n", .{ read, len, bytes[0..read] });
            if (read < @as(usize, @intCast(len))) {
                //std.debug.print("Struct: incomplete read, expected {}, got {}\n", .{ len, read });
                return error.IncompleteRead;
            }

            if (FieldType == Decimal) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidCustomType;
            }
            if (FieldType == Money) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidCustomType;
            }
            if (@hasDecl(FieldType, "isSerial") and FieldType.isSerial) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidSerial;
            }
            if (@hasDecl(FieldType, "isUuid") and FieldType.isUuid) {
                return FieldType.fromString(bytes[0..read]) catch return error.InvalidUuid;
            }
            if (@hasDecl(FieldType, "isTimestamp") and FieldType.isTimestamp) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidTimestamp;
            }
            if (@hasDecl(FieldType, "isInterval") and FieldType.isInterval) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidInterval;
            }
            if (@hasDecl(FieldType, "fromPostgresText")) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidCustomType;
            }
            @compileError("Unsupported struct type: " ++ @typeName(FieldType));
        },
        else => @compileError("Unsupported field type: " ++ @typeName(FieldType)),
    };
}
