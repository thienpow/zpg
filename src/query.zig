const std = @import("std");
const Connection = @import("connection.zig").Connection;

const types = @import("types.zig");
const StatementInfo = types.StatementInfo;
const Error = types.Error;

const Allocator = std.mem.Allocator;

pub const Query = struct {
    conn: *Connection,
    allocator: Allocator,
    portal_name: []const u8 = "portal",

    pub fn init(allocator: Allocator, conn: *Connection) Query {
        return Query{
            .conn = conn,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Query) void {
        _ = self;
    }

    pub fn prepare(self: *Query, name: []const u8, sql: []const u8, comptime T: type) !void {
        if (self.isStatementCached(name)) {
            return;
        }

        try self.sendParseMessage(name, sql);
        try self.sendSyncMessage();
        try self.processParseResponses();
        try self.cacheStatement(name, sql, T);
    }

    pub fn execute(self: *Query, comptime T: type, name: []const u8, params: ?[][]const u8) !?[]T {
        if (!self.isStatementCached(name)) {
            return error.StatementNotPrepared;
        }

        try self.sendBindMessage(name, params);
        try self.sendExecuteMessage();
        try self.sendSyncMessage();
        return try self.processExecuteResponses(T, name);
    }

    fn sendSyncMessage(self: *Query) !void {
        try self.conn.sendMessage('S', "", false);
    }

    fn sendParseMessage(self: *Query, name: []const u8, sql: []const u8) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        const writer = buffer.writer();

        try writer.writeAll(name);
        try writer.writeByte(0);
        try writer.writeAll(sql);
        try writer.writeByte(0);
        try writer.writeInt(u16, 0, .big);

        try self.conn.sendMessage('P', buffer.items, false);
    }

    fn sendBindMessage(self: *Query, name: []const u8, params: ?[]const []const u8) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        const writer = buffer.writer();

        try writer.writeAll(self.portal_name);
        try writer.writeByte(0);
        try writer.writeAll(name);
        try writer.writeByte(0);

        const param_count = if (params) |p| p.len else 0;
        try writer.writeInt(u16, @intCast(param_count), .big);
        for (0..param_count) |_| {
            try writer.writeInt(u16, 0, .big);
        }
        try writer.writeInt(u16, @intCast(param_count), .big);
        if (params) |p| {
            for (p) |param| {
                try writer.writeInt(i32, @intCast(param.len), .big);
                try writer.writeAll(param);
            }
        }
        try writer.writeInt(u16, 0, .big);

        try self.conn.sendMessage('B', buffer.items, false);
    }

    fn sendExecuteMessage(self: *Query) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        const writer = buffer.writer();

        try writer.writeAll(self.portal_name);
        try writer.writeByte(0);
        try writer.writeInt(i32, 0, .big);

        try self.conn.sendMessage('E', buffer.items, false);
    }

    fn processParseResponses(self: *Query) !void {
        var buffer: [1024]u8 = undefined;

        while (true) {
            const msg_len = try self.conn.readMessage(&buffer);
            var fbs = std.io.fixedBufferStream(buffer[0..msg_len]);
            const reader = fbs.reader();
            const msg_type = try reader.readByte();

            switch (msg_type) {
                '1' => {
                    //std.debug.print("ParseComplete\n", .{})
                },
                'Z' => {
                    break;
                },
                'E' => return error.QueryFailed,
                else => return error.ProtocolError,
            }
        }
    }

    fn processExecuteResponses(self: *Query, comptime T: type, name: []const u8) !?[]T {
        var buffer: [4096]u8 = undefined;
        var rows = std.ArrayList(T).init(self.allocator);
        defer rows.deinit();

        const stmt_info = self.conn.statement_cache.get(name) orelse return error.StatementNotPrepared;
        const expected_type_id = typeId(T);
        if (stmt_info.type_id != expected_type_id) {
            return error.StructTypeMismatch;
        }

        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            @compileError("processExecuteResponses requires T to be a struct");
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
                'D' => {
                    const column_count = try reader.readInt(u16, .big);
                    if (column_count != expected_columns) return error.ColumnCountMismatch;

                    var instance: T = undefined;
                    inline for (struct_info.fields) |field| {
                        @field(instance, field.name) = try readValueForType(reader, field.type, self.allocator);
                    }
                    try rows.append(instance);
                },
                '2', 'C' => {}, // Ignore BindComplete and CommandComplete
                'Z' => {
                    const slice = try rows.toOwnedSlice();
                    return slice;
                },
                else => return error.ProtocolError,
            }
        }
    }

    fn cacheStatement(self: *Query, name: []const u8, query: []const u8, comptime T: type) !void {
        const dupe_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(dupe_name);

        const dupe_query = try self.allocator.dupe(u8, query);
        errdefer self.allocator.free(dupe_query);

        const info = StatementInfo{
            .query = dupe_query,
            .type_id = typeId(T),
        };

        try self.conn.statement_cache.put(dupe_name, info);
    }

    fn isStatementCached(self: *const Query, name: []const u8) bool {
        return self.conn.statement_cache.contains(name);
    }

    fn typeId(comptime T: type) usize {
        return @intCast(std.hash.Wyhash.hash(0, @typeName(T)));
    }

    pub fn readNullableField(reader: std.io.AnyReader, comptime T: type, allocator: std.mem.Allocator) !?T {
        const len = try reader.readInt(i32, .big);
        if (len < 0) return null; // NULL value

        var limitedReader = std.io.limitedReader(reader, len);
        return try readValueForType(limitedReader.reader(), T, allocator);
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
                _ = array_info;
                @compileError("Array types not yet supported: " ++ @typeName(FieldType));
                // Implementation would need to parse PostgreSQL array literal format like {1,2,3}
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
};
