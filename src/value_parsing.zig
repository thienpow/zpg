const std = @import("std");
const Allocator = std.mem.Allocator;

const field = @import("field/mod.zig");
const SmallSerial = field.SmallSerial;
const Serial = field.Serial;
const BigSerial = field.BigSerial;
const Time = field.Time;
const Date = field.Date;
const Timestamp = field.Timestamp;
const Interval = field.Interval;
const Uuid = field.Uuid;
const CHAR = field.CHAR;
const VARCHAR = field.VARCHAR;

const Decimal = field.Decimal;
const Money = field.Money;
const TSVector = field.TSVector;
const TSQuery = field.TSQuery;

pub const CIDR = field.CIDR;
pub const Inet = field.Inet;
pub const MACAddress = field.MACAddress;
pub const MACAddress8 = field.MACAddress8;

pub const Bit10 = field.Bit10;
pub const VarBit16 = field.VarBit16;

pub const Box = field.Box;
pub const Circle = field.Circle;
pub const Line = field.Line;
pub const LineSegment = field.LineSegment;
pub const Path = field.Path;
pub const Point = field.Point;
pub const Polygon = field.Polygon;

pub const JSON = field.JSON;
pub const JSONB = field.JSONB;

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

fn readPostgresText(allocator: std.mem.Allocator, reader: anytype, len: u64) ![]u8 {
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);

    const read = try reader.readAtLeast(bytes, len);
    if (read < len) {
        allocator.free(bytes);
        return error.IncompleteRead;
    }
    return bytes[0..read];
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
                const len = try reader.readInt(i32, .big);

                if (len < 0) return "";
                if (len > 1024) return error.StringTooLong;

                const bytes = try allocator.alloc(u8, @intCast(len));
                defer allocator.free(bytes);

                @memset(bytes, 0);
                const read = try reader.readAtLeast(bytes, @intCast(len));

                if (read < @as(usize, @intCast(len))) return error.IncompleteRead;

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
                    const child_value = if (@hasDecl(opt_info.child, "isVarchar") and opt_info.child.isVarchar)
                        try parsePostgresText(VARCHAR, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Uuid)
                        try parsePostgresText(Uuid, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Decimal)
                        try parsePostgresText(Decimal, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Money)
                        try parsePostgresText(Money, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Timestamp)
                        try parsePostgresText(Timestamp, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Interval)
                        try parsePostgresText(Interval, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Date)
                        try parsePostgresText(Date, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Time)
                        try parsePostgresText(Time, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == TSVector)
                        try parsePostgresText(TSVector, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == TSQuery)
                        try parsePostgresText(TSQuery, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == CIDR)
                        try parsePostgresText(CIDR, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Inet)
                        try parsePostgresText(Inet, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == MACAddress)
                        try parsePostgresText(MACAddress, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == MACAddress8)
                        try parsePostgresText(MACAddress8, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Bit10)
                        try parsePostgresText(Bit10, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == VarBit16)
                        try parsePostgresText(VarBit16, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Box)
                        try parsePostgresText(Box, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Circle)
                        try parsePostgresText(Circle, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Line)
                        try parsePostgresText(Line, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == LineSegment)
                        try parsePostgresText(LineSegment, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Path)
                        try parsePostgresText(Path, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Point)
                        try parsePostgresText(Point, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == Polygon)
                        try parsePostgresText(Polygon, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == JSON)
                        try parsePostgresText(JSON, allocator, limitedReader.reader(), len_u64)
                    else if (opt_info.child == JSONB)
                        try parsePostgresText(JSONB, allocator, limitedReader.reader(), len_u64)
                    else
                        try readValueForType(allocator, limitedReader.reader().any(), opt_info.child);

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
        .@"struct" => |struct_info| {
            _ = struct_info;
            const len = try reader.readInt(i32, .big);

            const bytes = try allocator.alloc(u8, @intCast(len));
            defer allocator.free(bytes);
            const read = try reader.readAtLeast(bytes, @intCast(len));
            if (read < @as(usize, @intCast(len))) {
                return error.IncompleteRead;
            }

            if (@hasDecl(FieldType, "isSerial") and FieldType.isSerial) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidSerial;
            } else if (@hasDecl(FieldType, "isVarchar") and FieldType.isVarchar) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidVARCHAR;
            } else if (FieldType == Decimal) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidDecimalType;
            } else if (FieldType == Money) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidMoneyType;
            } else if (FieldType == Uuid) {
                return FieldType.fromPostgresText(bytes[0..read]) catch return error.InvalidUuid;
            } else if (FieldType == Timestamp) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidTimestamp;
            } else if (FieldType == Interval) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidInterval;
            } else if (FieldType == Date) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidDate;
            } else if (FieldType == Time) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidTime;
            } else if (FieldType == TSVector) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidTSVector;
            } else if (FieldType == TSQuery) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidTSQuery;
            } else if (FieldType == CIDR) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidCIDR;
            } else if (FieldType == Inet) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidInet;
            } else if (FieldType == MACAddress) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidMACAddress;
            } else if (FieldType == MACAddress8) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidMACAddress8;
            } else if (FieldType == Bit10) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidBit10;
            } else if (FieldType == VarBit16) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidVarBit16;
            } else if (FieldType == Box) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidBox;
            } else if (FieldType == Circle) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidCircle;
            } else if (FieldType == Line) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidLine;
            } else if (FieldType == LineSegment) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidLineSegment;
            } else if (FieldType == Path) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidPath;
            } else if (FieldType == Point) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidPoint;
            } else if (FieldType == Polygon) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidPolygon;
            } else if (FieldType == JSON) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidJSON;
            } else if (FieldType == JSONB) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidJSONB;
            } else if (@hasDecl(FieldType, "fromPostgresText")) {
                return FieldType.fromPostgresText(bytes[0..read], allocator) catch return error.InvalidCustomType;
            }
            @compileError("Unsupported struct type: " ++ @typeName(FieldType));
        },
        else => @compileError("Unsupported field type: " ++ @typeName(FieldType)),
    };
}

fn parsePostgresText(comptime T: type, allocator: std.mem.Allocator, reader: anytype, len: u64) !T {
    const bytes = try readPostgresText(allocator, reader, len);
    defer allocator.free(bytes);
    return try T.fromPostgresText(bytes, allocator);
}
