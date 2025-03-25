const std = @import("std");
const Allocator = std.mem.Allocator;

const Connection = @import("connection.zig").Connection;
const Query = @import("query.zig").Query;

const types = @import("types.zig");
const RequestType = types.RequestType;
const ResponseType = types.ResponseType;
const ExplainRow = types.ExplainRow;

const Param = @import("param.zig").Param;
const value_parsing = @import("value_parsing.zig");

pub const Protocol = struct {
    conn: *Connection,
    allocator: Allocator,

    pub fn init(conn: *Connection, allocator: Allocator) Protocol {
        return .{ .conn = conn, .allocator = allocator };
    }

    pub fn sendBindMessage(self: *Protocol, name: []const u8, params: ?[]const Param) !void {
        const allocator = self.allocator;
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();
        const writer = buffer.writer();

        try writer.writeByte(0); // Empty portal name
        try writer.writeAll(name);
        try writer.writeByte(0);

        const param_count = if (params) |p| p.len else 0;

        // Format codes section
        try writer.writeInt(u16, @intCast(param_count), .big);
        if (params) |p| {
            for (p) |param| {
                try writer.writeInt(u16, param.format, .big);
            }
        }

        // Parameter values section
        try writer.writeInt(u16, @intCast(param_count), .big);
        if (params) |p| {
            for (p) |param| {
                try param.writeTo(writer); // Use Param’s method
            }
        }

        // Result format code section (we want text results)
        try writer.writeInt(u16, 0, .big);

        try self.conn.sendMessage(@intFromEnum(RequestType.Bind), buffer.items, false);
    }

    pub fn processSelectResponses(self: *Protocol, comptime T: type) !?[]T {
        const allocator = self.allocator;
        var buffer: [4096]u8 = undefined;
        var rows = std.ArrayList(T).init(allocator);
        defer rows.deinit();

        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            @compileError("processSelectResponses requires T to be a struct");
        }
        const struct_info = type_info.@"struct";

        const expected_columns: u16 = @intCast(struct_info.fields.len);

        while (true) {
            const result = try self.conn.readMessageType(&buffer);
            const response_type: ResponseType = @enumFromInt(result.type);
            const msg_len = result.len;
            var fbs = std.io.fixedBufferStream(buffer[5..msg_len]);
            const reader = fbs.reader().any();

            switch (response_type) {
                .BindComplete => {
                    // ignnore BindComplete
                },
                .RowDescription => {
                    // Row Description - verify column count
                    const column_count = try reader.readInt(u16, .big);
                    if (column_count != expected_columns) return error.ColumnCountMismatch;
                },
                .DataRow => {
                    const column_count = try reader.readInt(u16, .big);
                    if (column_count != expected_columns) return error.ColumnCountMismatch;

                    var instance: T = undefined;
                    inline for (struct_info.fields) |field| {
                        @field(instance, field.name) = try value_parsing.readValueForType(allocator, reader, field.type);
                    }
                    try rows.append(instance);
                },
                .CommandComplete => {
                    // CommandComplete
                    const command_tag = try reader.readUntilDelimiterAlloc(allocator, 0, 1024);
                    defer allocator.free(command_tag);
                    if (!std.mem.startsWith(u8, command_tag, "SELECT")) {
                        return error.NotASelectQuery; // Fail if not a SELECT response
                    }
                },
                .ReadyForQuery => {
                    const owned_slice = try rows.toOwnedSlice();
                    if (owned_slice.len == 0) {
                        return null;
                    }
                    return owned_slice;
                },
                else => {
                    std.debug.print("Bad thing happen, response_type: {}", .{response_type});
                    return error.ProtocolError;
                },
            }
        }
    }

    // Process INSERT/UPDATE/DELETE responses
    pub fn processCommandResponses(self: *Protocol) !u64 {
        const allocator = self.allocator;
        var buffer: [4096]u8 = undefined;
        var return_value: u64 = 0;
        while (true) {
            const result = try self.conn.readMessageType(&buffer);
            const response_type: ResponseType = @enumFromInt(result.type);

            const msg_len = result.len;
            var fbs = std.io.fixedBufferStream(buffer[5..msg_len]);
            const reader = fbs.reader().any();

            switch (response_type) {
                .RowDescription, .DataRow => {
                    // ignore, even if it will arrive here.
                    // TODO: keep this empty section here for future improvement.
                },
                .CommandComplete => {
                    const command_tag = try reader.readUntilDelimiterAlloc(allocator, 0, 1024);
                    defer allocator.free(command_tag);
                    std.debug.print("Command tag: {s}\n", .{command_tag});
                    const space_idx = std.mem.indexOfScalar(u8, command_tag, ' ') orelse return error.InvalidCommandTag;
                    const count_str = command_tag[space_idx + 1 ..];
                    return_value = try std.fmt.parseInt(u64, count_str, 10);
                },
                .ReadyForQuery => return return_value, // Shouldn't reach here without 'C'
                .ErrorResponse => return error.DatabaseError,
                else => {
                    std.debug.print("Bad thing happen, response_type: {}", .{response_type});
                    return error.ProtocolError;
                },
            }
        }
    }

    pub fn processSimpleCommand(self: *Protocol) !bool {
        const allocator = self.allocator;
        var buffer: [4096]u8 = undefined;

        var success = false;
        while (true) {
            const result = try self.conn.readMessageType(&buffer);
            const response_type: ResponseType = @enumFromInt(result.type);

            const msg_len = result.len;
            var fbs = std.io.fixedBufferStream(buffer[5..msg_len]);
            const reader = fbs.reader().any();

            switch (response_type) {
                .CommandComplete => {
                    // CommandComplete - just verify it’s there
                    const command_tag = try reader.readUntilDelimiterAlloc(allocator, 0, 1024);
                    defer allocator.free(command_tag);
                    // Could optionally check command_tag for specific completion status
                    success = true;
                },
                .ReadyForQuery => {
                    // ReadyForQuery - transaction complete
                    return success;
                },
                .ErrorResponse => {
                    // ErrorResponse - handle database errors
                    return error.DatabaseError;
                },
                else => {
                    std.debug.print("Bad thing happen, response_type: {}", .{response_type});
                    return error.ProtocolError;
                },
            }
        }
    }

    pub fn processExplainResponses(self: *Protocol) ![]ExplainRow {
        const allocator = self.allocator;
        var buffer: [4096]u8 = undefined;
        var rows = std.ArrayList(ExplainRow).init(allocator);
        defer rows.deinit();

        while (true) {
            const result = try self.conn.readMessageType(&buffer);
            const response_type: ResponseType = @enumFromInt(result.type);

            const msg_len = result.len;
            var fbs = std.io.fixedBufferStream(buffer[5..msg_len]);
            const reader = fbs.reader().any();

            switch (response_type) {
                .RowDescription => {
                    // RowDescription - verify we have expected columns
                    const column_count = try reader.readInt(u16, .big);
                    if (column_count < 4) return error.InvalidExplainFormat; // Minimum expected columns
                },
                .DataRow => {
                    // Data Row
                    const column_count = try reader.readInt(u16, .big);
                    if (column_count < 4) return error.InvalidExplainFormat;

                    var row: ExplainRow = undefined;

                    // Operation (column 1)
                    row.operation = try value_parsing.readString(allocator, reader);

                    // Target (column 2)
                    row.target = try value_parsing.readString(allocator, reader);

                    // Cost (column 3) - assuming a string like "12.34"
                    const cost_str = try value_parsing.readString(allocator, reader);
                    defer allocator.free(cost_str);
                    row.cost = try std.fmt.parseFloat(f64, cost_str);

                    // Rows (column 4)
                    const rows_str = try value_parsing.readString(allocator, reader);
                    defer allocator.free(rows_str);
                    row.rows = try std.fmt.parseInt(u64, rows_str, 10);

                    // Details (optional column 5)
                    row.details = if (column_count > 4)
                        try value_parsing.readString(allocator, reader)
                    else
                        null;

                    try rows.append(row);
                },
                .CommandComplete => {
                    // Command Complete - ignore for EXPLAIN
                },
                .ReadyForQuery => {
                    return try rows.toOwnedSlice();
                },
                else => {
                    std.debug.print("Bad thing happen, response_type: {}", .{response_type});
                    return error.ProtocolError;
                },
            }
        }
    }
};
