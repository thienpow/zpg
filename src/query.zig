const std = @import("std");
const Allocator = std.mem.Allocator;

const Connection = @import("connection.zig").Connection;

const types = @import("types.zig");
const StatementInfo = types.StatementInfo;
const Error = types.Error;
const ExplainRow = types.ExplainRow;
const Result = types.Result;
const Empty = types.Empty;
const Action = types.Action;

const Param = @import("param.zig").Param;

pub const Query = struct {
    conn: *Connection,
    allocator: Allocator,

    pub fn init(allocator: Allocator, conn: *Connection) Query {
        return Query{
            .conn = conn,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Query) void {
        _ = self;
    }

    pub fn select(self: *Query, comptime T: type, sql: []const u8) ![]const T {
        const trimmed = std.mem.trim(u8, sql, " \t\n");
        const upper = trimmed[0..@min(trimmed.len, 10)];
        if (!std.mem.startsWith(u8, upper, "SELECT") and !std.mem.startsWith(u8, upper, "WITH")) {
            return error.InvalidSelectQuery;
        }

        try self.conn.sendMessage('Q', sql, true);
        const rows = (try self.processSelectResponses(T)) orelse &[_]T{};
        return rows;
    }

    pub fn insert(self: *Query, sql: []const u8) !u64 {
        const result = try self.execute(sql, Empty);
        switch (result) {
            .command => |count| return count,
            else => return error.UnexpectedResult,
        }
    }

    pub fn update(self: *Query, sql: []const u8) !u64 {
        const result = try self.execute(sql, Empty);
        switch (result) {
            .command => |count| return count,
            else => return error.UnexpectedResult,
        }
    }

    pub fn execute(self: *Query, sql: []const u8, comptime T: type) !Result(T) {
        try self.conn.sendMessage('Q', sql, true);
        const trimmed = std.mem.trim(u8, sql, " \t\n");
        const upper = trimmed[0..@min(trimmed.len, 10)];

        if (std.mem.startsWith(u8, upper, "SELECT") or
            std.mem.startsWith(u8, upper, "WITH"))
        {
            return Result(T){ .select = (try self.processSelectResponses(T)) orelse &[_]T{} };
        } else if (std.mem.startsWith(u8, upper, "INSERT") or
            std.mem.startsWith(u8, upper, "UPDATE") or
            std.mem.startsWith(u8, upper, "DELETE") or
            std.mem.startsWith(u8, upper, "MERGE"))
        {
            return Result(T){ .command = try self.processCommandResponses() };
        } else if (std.mem.startsWith(u8, upper, "PREPARE")) {
            const stmt_name = try self.parsePrepareStatementName(sql);
            const action = try self.parsePrepareStatementAction(sql);
            const owned_name = try self.allocator.dupe(u8, stmt_name);
            try self.conn.statement_cache.put(owned_name, action);
            std.debug.print("Cached {s} as {any}\n", .{ owned_name, action });
            return Result(T){ .success = try self.processSimpleCommand() };
        } else if (std.mem.startsWith(u8, upper, "CREATE") or
            std.mem.startsWith(u8, upper, "ALTER") or
            std.mem.startsWith(u8, upper, "DROP") or
            std.mem.startsWith(u8, upper, "GRANT") or
            std.mem.startsWith(u8, upper, "REVOKE") or
            std.mem.startsWith(u8, upper, "COMMIT") or
            std.mem.startsWith(u8, upper, "ROLLBACK"))
        {
            return Result(T){ .success = try self.processSimpleCommand() };
        } else if (std.mem.startsWith(u8, upper, "EXPLAIN")) {
            return Result(T){ .explain = try self.processExplainResponses() };
        } else if (std.mem.startsWith(u8, upper, "EXECUTE")) {
            const stmt_name = try self.parseExecuteStatementName(sql);
            std.debug.print("Executing {s}\n", .{stmt_name});
            if (self.conn.statement_cache.get(stmt_name)) |action| {
                std.debug.print("Action for {s}: {any}\n", .{ stmt_name, action });
                switch (action) {
                    .Select => {
                        const type_info = @typeInfo(T);
                        if (type_info != .@"struct") {
                            @compileError("EXECUTE for SELECT requires T to be a struct");
                        }
                        const rows = (try self.processSelectResponses(T)) orelse &[_]T{};
                        return Result(T){ .select = rows };
                    },
                    .Insert, .Update, .Delete => {
                        return Result(T){ .command = try self.processCommandResponses() };
                    },
                    .Other => {
                        return Result(T){ .success = try self.processSimpleCommand() };
                    },
                }
            } else {
                return error.UnknownPreparedStatement;
            }
        } else {
            return error.UnsupportedOperation;
        }
    }

    pub fn executePrepared(self: *Query, comptime T: type, name: []const u8) !Result(T) {
        const sql = try std.fmt.allocPrint(self.allocator, "EXECUTE {s}", .{name});
        defer self.allocator.free(sql);
        return self.execute(sql, T);
    }

    // Process INSERT/UPDATE/DELETE responses
    fn processCommandResponses(self: *Query) !u64 {
        var buffer: [4096]u8 = undefined;
        var return_value: u64 = 0;
        while (true) {
            const result = try self.conn.readMessageType(&buffer);
            const msg_type = result.type;
            const msg_len = result.len;
            var fbs = std.io.fixedBufferStream(buffer[5..msg_len]);
            const reader = fbs.reader().any();

            switch (msg_type) {
                'T', 'D' => {
                    // ignore
                },
                'C' => {
                    const command_tag = try reader.readUntilDelimiterAlloc(self.allocator, 0, 1024);
                    defer self.allocator.free(command_tag);
                    std.debug.print("Command tag: {s}\n", .{command_tag});
                    const space_idx = std.mem.indexOfScalar(u8, command_tag, ' ') orelse return error.InvalidCommandTag;
                    const count_str = command_tag[space_idx + 1 ..];
                    return_value = try std.fmt.parseInt(u64, count_str, 10);
                },
                'Z' => return return_value, // Shouldn't reach here without 'C'
                'E' => return error.DatabaseError,
                else => {
                    std.debug.print("Bad thing happen, {c}", .{msg_type});
                    return error.ProtocolError;
                },
            }
        }
    }

    fn processSimpleCommand(self: *Query) !void {
        var buffer: [4096]u8 = undefined;

        while (true) {
            const result = try self.conn.readMessageType(&buffer);
            const msg_type = result.type;
            const msg_len = result.len;
            var fbs = std.io.fixedBufferStream(buffer[5..msg_len]);
            const reader = fbs.reader().any();

            switch (msg_type) {
                'C' => {
                    // Command Complete - just verify it’s there
                    const command_tag = try reader.readUntilDelimiterAlloc(self.allocator, 0, 1024);
                    defer self.allocator.free(command_tag);
                    // Could optionally check command_tag for specific completion status
                },
                'Z' => {
                    // Ready for Query - transaction complete
                    return;
                },
                'E' => {
                    // ErrorResponse - handle database errors
                    return error.DatabaseError;
                },
                else => return error.ProtocolError,
            }
        }
    }

    fn processExplainResponses(self: *Query) ![]ExplainRow {
        var buffer: [4096]u8 = undefined;
        var rows = std.ArrayList(ExplainRow).init(self.allocator);
        defer rows.deinit();

        while (true) {
            const result = try self.conn.readMessageType(&buffer);
            const msg_type = result.type;
            const msg_len = result.len;
            var fbs = std.io.fixedBufferStream(buffer[5..msg_len]);
            const reader = fbs.reader().any();

            switch (msg_type) {
                'T' => {
                    // Row Description - verify we have expected columns
                    const column_count = try reader.readInt(u16, .big);
                    if (column_count < 4) return error.InvalidExplainFormat; // Minimum expected columns
                },
                'D' => {
                    // Data Row
                    const column_count = try reader.readInt(u16, .big);
                    if (column_count < 4) return error.InvalidExplainFormat;

                    var row: ExplainRow = undefined;

                    // Operation (column 1)
                    row.operation = try readString(reader, self.allocator);

                    // Target (column 2)
                    row.target = try readString(reader, self.allocator);

                    // Cost (column 3) - assuming a string like "12.34"
                    const cost_str = try readString(reader, self.allocator);
                    defer self.allocator.free(cost_str);
                    row.cost = try std.fmt.parseFloat(f64, cost_str);

                    // Rows (column 4)
                    const rows_str = try readString(reader, self.allocator);
                    defer self.allocator.free(rows_str);
                    row.rows = try std.fmt.parseInt(u64, rows_str, 10);

                    // Details (optional column 5)
                    row.details = if (column_count > 4)
                        try readString(reader, self.allocator)
                    else
                        null;

                    try rows.append(row);
                },
                'C' => {
                    // Command Complete - ignore for EXPLAIN
                },
                'Z' => {
                    return try rows.toOwnedSlice();
                },
                else => return error.ProtocolError,
            }
        }
    }

    // Helper function to read null-terminated strings
    fn readString(reader: anytype, allocator: std.mem.Allocator) ![]const u8 {
        const len = try reader.readInt(u16, .big);
        if (len == 0xffff) return ""; // NULL value
        const str = try allocator.alloc(u8, len);
        try reader.readNoEof(str);
        return str;
    }

    fn readValueForType(reader: std.io.AnyReader, comptime FieldType: type, allocator: std.mem.Allocator) !FieldType {
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

                pos = try parseArrayElements(bytes, &pos, read - 1, // Up to but not including '}'
                    array_info.child, &elements, allocator);

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

    // Helper to parse array elements recursively
    fn parseArrayElements(
        bytes: []u8,
        pos: *usize, // Pointer to usize, mutable
        end: usize,
        comptime ElementType: type,
        elements: *std.ArrayList(ElementType),
        allocator: std.mem.Allocator,
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
                (*pos) = try parseArrayElements(bytes, pos, end, element_type_info.array.child, &nested_elements, allocator);

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

    // Helper to ව

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

    // Helper to fill default values for any type
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

    // Parse the statement name from PREPARE
    fn parsePrepareStatementName(_: *Query, sql: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, sql, " \t\n");
        const prepare_end = std.mem.indexOf(u8, trimmed, " ") orelse return error.InvalidPrepareSyntax;
        const after_prepare = std.mem.trimLeft(u8, trimmed[prepare_end..], " ");
        const name_end = std.mem.indexOfAny(u8, after_prepare, " (") orelse return error.InvalidPrepareSyntax;
        return after_prepare[0..name_end];
    }

    // Parse the action type from PREPARE
    fn parsePrepareStatementAction(_: *Query, sql: []const u8) !Action {
        const trimmed = std.mem.trim(u8, sql, " \t\n");
        const as_idx = std.mem.indexOf(u8, trimmed, " AS ") orelse return error.InvalidPrepareSyntax;
        const stmt_sql = std.mem.trimLeft(u8, trimmed[as_idx + 4 ..], " ");
        const upper = stmt_sql[0..@min(stmt_sql.len, 10)];
        if (std.mem.startsWith(u8, upper, "SELECT") or std.mem.startsWith(u8, upper, "WITH")) {
            return .Select;
        } else if (std.mem.startsWith(u8, upper, "INSERT")) {
            return .Insert;
        } else if (std.mem.startsWith(u8, upper, "UPDATE")) {
            return .Update;
        } else if (std.mem.startsWith(u8, upper, "DELETE")) {
            return .Delete;
        } else {
            return .Other;
        }
    }

    // Parse the statement name from EXECUTE
    fn parseExecuteStatementName(_: *Query, sql: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, sql, " \t\n");
        const execute_end = std.mem.indexOf(u8, trimmed, " ") orelse return error.InvalidExecuteSyntax;
        const after_execute = std.mem.trimLeft(u8, trimmed[execute_end..], " ");
        const name_end = std.mem.indexOfAny(u8, after_execute, " (") orelse after_execute.len;
        return after_execute[0..name_end];
    }

    fn processSelectResponses(self: *Query, comptime T: type) !?[]T {
        var buffer: [4096]u8 = undefined;
        var rows = std.ArrayList(T).init(self.allocator);
        defer rows.deinit();

        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            @compileError("processSelectResponses requires T to be a struct");
        }
        const struct_info = type_info.@"struct";

        const expected_columns: u16 = @intCast(struct_info.fields.len);

        while (true) {
            const result = try self.conn.readMessageType(&buffer);
            const msg_type = result.type;
            const msg_len = result.len;
            var fbs = std.io.fixedBufferStream(buffer[5..msg_len]);
            const reader = fbs.reader().any();

            switch (msg_type) {
                'T' => {
                    // Row Description - verify column count
                    const column_count = try reader.readInt(u16, .big);
                    if (column_count != expected_columns) return error.ColumnCountMismatch;
                },
                'D' => {
                    const column_count = try reader.readInt(u16, .big);
                    if (column_count != expected_columns) return error.ColumnCountMismatch;

                    var instance: T = undefined;
                    inline for (struct_info.fields) |field| {
                        @field(instance, field.name) = try readValueForType(reader, field.type, self.allocator);
                    }
                    try rows.append(instance);
                },
                'C' => {
                    const command_tag = try reader.readUntilDelimiterAlloc(self.allocator, 0, 1024);
                    defer self.allocator.free(command_tag);
                    if (!std.mem.startsWith(u8, command_tag, "SELECT")) {
                        return error.NotASelectQuery; // Fail if not a SELECT response
                    }
                },
                'Z' => {
                    const owned_slice = try rows.toOwnedSlice();
                    if (owned_slice.len == 0) {
                        return null;
                    }
                    return owned_slice;
                },
                else => return error.ProtocolError,
            }
        }
    }
};
