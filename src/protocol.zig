const std = @import("std");
const Allocator = std.mem.Allocator;

const Connection = @import("connection.zig").Connection;
const Query = @import("query.zig").Query;

const types = @import("types.zig");
const RequestType = types.RequestType;
const ResponseType = types.ResponseType;
const ExplainRow = types.ExplainRow;

const Notice = types.Notice;
const NoticeField = types.NoticeField;
const PostgresError = types.PostgresError;
const ErrorField = types.ErrorField;

const Param = @import("param.zig").Param;
const value_parsing = @import("value_parsing.zig");

pub const Protocol = struct {
    conn: *Connection,
    allocator: Allocator,

    pub fn init(conn: *Connection, allocator: Allocator) Protocol {
        return .{ .conn = conn, .allocator = allocator };
    }

    pub fn sendBind(self: *Protocol, name: []const u8, params: ?[]const Param) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        // Bind message starts with 'B' (Bind)
        try buffer.append('B');

        // Prepare placeholder for message length (will be updated later)
        try buffer.appendNTimes(0, 4);

        // Empty portal name (null-terminated)
        try buffer.append(0);

        // Statement name (null-terminated)
        try buffer.appendSlice(name);
        try buffer.append(0);

        // Parameter format codes
        const param_count = if (params) |p| p.len else 0;
        try buffer.writer().writeInt(u16, @intCast(param_count), .big);

        // Aassign parameters with format code
        if (params) |p| {
            for (0..p.len) |_| {
                try buffer.writer().writeInt(u16, 1, .big); // Binary=1, Text=0
            }
        }

        // Number of parameter values
        try buffer.writer().writeInt(u16, @intCast(param_count), .big);

        // Write parameter values
        if (params) |p| {
            for (p) |param| {
                try param.writeTo(buffer.writer());
            }
        }

        // Result format codes
        // Specify one result format code (binary)
        try buffer.writer().writeInt(u16, 1, .big);
        try buffer.writer().writeInt(u16, 1, .big); // Binary format

        // Calculate and set the message length
        const total_len = buffer.items.len;
        const msg_len: i32 = @intCast(total_len - 1);

        // Set message length in big-endian (bytes 1-4)
        buffer.items[1] = @intCast((msg_len >> 24) & 0xFF);
        buffer.items[2] = @intCast((msg_len >> 16) & 0xFF);
        buffer.items[3] = @intCast((msg_len >> 8) & 0xFF);
        buffer.items[4] = @intCast(msg_len & 0xFF);

        std.debug.print("Bind message raw: {x}\n", .{buffer.items});
        std.debug.print("Total length: {d}, Message length: {d}\n", .{ total_len, msg_len });

        // Send the raw message
        const start = std.time.microTimestamp();
        try self.conn.sendMessageRaw(buffer.items);
        const send_time = std.time.microTimestamp() - start;
        std.debug.print("Send time: {} µs\n", .{send_time});
    }

    pub fn sendDescribe(self: *Protocol, target: u8, name: []const u8) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        const writer = buffer.writer();

        // Message type
        try writer.writeByte('D');

        // Length placeholder (will be updated later)
        try writer.writeInt(i32, 0, .big);

        // Target type: 'S' for statement, 'P' for portal
        try writer.writeByte(target);

        // Target name (null-terminated)
        try writer.writeAll(name);
        try writer.writeByte(0);

        // Update length (total length - message type byte)
        const len: i32 = @intCast(buffer.items.len - 1);
        std.mem.writeInt(i32, buffer.items[1..5], len, .big);

        // Send the message
        try self.conn.sendMessageRaw(buffer.items);
    }

    pub fn sendExecute(self: *Protocol, portal: []const u8, max_rows: i32) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        const writer = buffer.writer();

        // Message type
        try writer.writeByte('E');

        // Length placeholder
        try writer.writeInt(i32, 0, .big);

        // Portal name (null-terminated)
        try writer.writeAll(portal);
        try writer.writeByte(0);

        // Maximum number of rows
        try writer.writeInt(i32, max_rows, .big);

        // Update length (total length - message type byte)
        const len: i32 = @intCast(buffer.items.len - 1);
        std.mem.writeInt(i32, buffer.items[1..5], len, .big);

        // Send the message
        try self.conn.sendMessageRaw(buffer.items);
    }

    pub fn sendSync(self: *Protocol) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        const writer = buffer.writer();

        // Message type
        try writer.writeByte('S');

        // Length (always 4 for Sync)
        try writer.writeInt(i32, 4, .big);

        // Send the message
        try self.conn.sendMessageRaw(buffer.items);
    }

    pub fn processPrepareResponses(self: *Protocol) !bool {
        var buffer: [4096]u8 = undefined;
        var saw_parse_complete = false;
        while (true) {
            const result = try self.conn.readMessageType(&buffer);
            const response_type: ResponseType = @enumFromInt(result.type);
            switch (response_type) {
                .ParseComplete => saw_parse_complete = true,
                .ReadyForQuery => return saw_parse_complete,
                else => {
                    std.debug.print("Unexpected response type: {}\n", .{response_type});
                    return error.ProtocolError;
                },
            }
        }
    }

    pub fn processSelectResponses(self: *Protocol, comptime T: type, is_extended_query: bool) !?[]T {
        const allocator = self.allocator;
        var buffer: [4096]u8 = undefined;

        var rows = std.ArrayList(T).init(allocator);
        defer rows.deinit();

        const type_info = @typeInfo(T);
        if (type_info != .@"struct") @compileError("processSelectResponses requires T to be a struct");
        const struct_info = type_info.@"struct";

        const expected_columns: u16 = @intCast(struct_info.fields.len);
        var column_formats: ?[]i16 = null;
        defer if (column_formats) |cf| allocator.free(cf);

        while (true) {
            const result = try self.conn.readMessageType(&buffer);
            const response_type: ResponseType = @enumFromInt(result.type);
            const msg_len = result.len;
            var fbs = std.io.fixedBufferStream(buffer[5..msg_len]);
            const reader = fbs.reader().any();

            switch (response_type) {
                .BindComplete => {
                    //
                },
                .ParameterDescription => {},
                .RowDescription => {
                    const column_count = try reader.readInt(u16, .big);
                    if (column_count != expected_columns) return error.ColumnCountMismatch;

                    column_formats = try allocator.alloc(i16, column_count);
                    for (0..column_count) |i| {
                        const name = try reader.readUntilDelimiterAlloc(allocator, 0, 1024);
                        defer allocator.free(name);
                        try reader.skipBytes(16, .{}); // OID (4), attr (2), type OID (4), size (2), modifier (4)
                        column_formats.?[i] = try reader.readInt(i16, .big);
                    }
                },
                .DataRow => {
                    const column_count = try reader.readInt(u16, .big);
                    if (column_count != expected_columns) return error.ColumnCountMismatch;

                    if (is_extended_query and column_formats == null) return error.MissingRowDescription;

                    var instance: T = undefined;
                    inline for (struct_info.fields) |field| {
                        @field(instance, field.name) = if (is_extended_query)
                            try value_parsing.readValueForTypeEx(allocator, reader, field.type)
                        else
                            try value_parsing.readValueForType(allocator, reader, field.type);
                    }
                    try rows.append(instance);
                },
                .CommandComplete => {
                    const command_tag = try reader.readUntilDelimiterAlloc(allocator, 0, 1024);
                    defer allocator.free(command_tag);
                    if (!std.mem.startsWith(u8, command_tag, "SELECT")) return error.NotASelectQuery;
                },
                .ReadyForQuery => {
                    const owned_slice = try rows.toOwnedSlice();
                    return if (owned_slice.len == 0) null else owned_slice;
                },
                .ErrorResponse => {
                    var current_error: types.PostgresError = try processErrorResponse(self, reader, allocator);

                    if (current_error.severity) |severity| {
                        std.debug.print("Error Severity: {s}\n", .{severity});
                    }
                    if (current_error.message) |message| {
                        std.debug.print("Error Message: {s}\n", .{message});
                    }

                    if (current_error.severity) |severity| {
                        if (std.mem.eql(u8, severity, "ERROR") or
                            std.mem.eql(u8, severity, "FATAL") or
                            std.mem.eql(u8, severity, "PANIC"))
                        {
                            current_error.deinit(allocator);
                            return error.PostgresError;
                        }
                    }

                    current_error.deinit(allocator);
                    continue;
                },
                else => {
                    std.debug.print("Unexpected response type: {}\n", .{response_type});
                    return error.ProtocolError;
                },
            }
        }
    }

    // Process INSERT/UPDATE/DELETE responses for both simple and extended queries
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
                    // Ignore for command responses (relevant for SELECT, not INSERT/UPDATE/DELETE)
                },
                .BindComplete => {
                    // Extended query: Bind step completed
                    continue;
                },
                .ParseComplete => {
                    // Extended query: Parse step completed
                    continue;
                },
                .ParameterDescription => {
                    // Extended query: Describes parameter types, skip for command responses
                    _ = try reader.readInt(i16, .big); // Number of parameters
                    while (fbs.pos < msg_len - 5) {
                        _ = try reader.readInt(i32, .big); // Skip OIDs
                    }
                    continue;
                },
                .NoData => {
                    // Extended query: No result set (e.g., for UPDATE after Describe)
                    continue;
                },
                .CommandComplete => {
                    const command_tag = try reader.readUntilDelimiterAlloc(allocator, 0, 1024);
                    defer allocator.free(command_tag);

                    if (std.mem.startsWith(u8, command_tag, "INSERT")) {
                        const last_space_idx = std.mem.lastIndexOfScalar(u8, command_tag, ' ') orelse {
                            return_value = 0;
                            continue;
                        };
                        const count_str = command_tag[last_space_idx + 1 ..];
                        return_value = std.fmt.parseInt(u64, count_str, 10) catch |err| {
                            std.debug.print("Failed to parse count from: {s}, error: {}\n", .{ count_str, err });
                            return_value = 0;
                            continue;
                        };
                    } else if (std.mem.indexOfScalar(u8, command_tag, ' ')) |space_idx| {
                        const count_str = command_tag[space_idx + 1 ..];
                        return_value = std.fmt.parseInt(u64, count_str, 10) catch |err| {
                            std.debug.print("Failed to parse count from: {s}, error: {}\n", .{ count_str, err });
                            return_value = 0;
                            continue;
                        };
                    } else {
                        return_value = 0;
                    }
                },
                .ReadyForQuery => {
                    return return_value;
                },
                .ErrorResponse => {
                    var current_error: types.PostgresError = try processErrorResponse(self, reader, allocator);

                    if (current_error.severity) |severity| {
                        std.debug.print("Error Severity: {s}\n", .{severity});
                    }
                    if (current_error.message) |message| {
                        std.debug.print("Error Message: {s}\n", .{message});
                    }

                    if (current_error.severity) |severity| {
                        if (std.mem.eql(u8, severity, "ERROR") or
                            std.mem.eql(u8, severity, "FATAL") or
                            std.mem.eql(u8, severity, "PANIC"))
                        {
                            current_error.deinit(allocator);
                            return error.PostgresError;
                        }
                    }

                    current_error.deinit(allocator);
                    continue;
                },
                .NoticeResponse => {
                    var notice = try processNoticeResponse(self, reader, allocator);
                    defer notice.deinit(allocator);
                    if (notice.message) |message| {
                        std.debug.print("Notice: {s}\n", .{message});
                    }
                    continue;
                },
                else => {
                    std.debug.print("Unexpected response type: {}\n", .{response_type});
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
                    const command_tag = try reader.readUntilDelimiterAlloc(allocator, 0, 1024);
                    defer allocator.free(command_tag);
                    success = true;
                },
                .ReadyForQuery => {
                    return success;
                },
                .ErrorResponse => {
                    var current_error: types.PostgresError = try processErrorResponse(self, reader, allocator);

                    if (current_error.severity) |severity| {
                        std.debug.print("Error Severity: {s}\n", .{severity});
                    }
                    if (current_error.message) |message| {
                        std.debug.print("Error Message: {s}\n", .{message});
                    }

                    if (current_error.severity) |severity| {
                        if (std.mem.eql(u8, severity, "ERROR") or
                            std.mem.eql(u8, severity, "FATAL") or
                            std.mem.eql(u8, severity, "PANIC"))
                        {
                            current_error.deinit(allocator);
                            return error.PostgresError;
                        }
                    }

                    current_error.deinit(allocator);
                    continue;
                },
                .NoticeResponse => {
                    var notice = try processNoticeResponse(self, reader, allocator);
                    defer notice.deinit(allocator);

                    if (notice.message) |message| {
                        std.debug.print("Notice: {s}\n", .{message});
                    }

                    continue;
                },
                .ParameterStatus => {
                    const param_name = try reader.readUntilDelimiterAlloc(allocator, 0, 1024);
                    defer allocator.free(param_name);
                    const param_value = try reader.readUntilDelimiterAlloc(allocator, 0, 1024);
                    defer allocator.free(param_value);
                    std.debug.print("ParameterStatus: {s} = {s}\n", .{ param_name, param_value });
                    continue;
                },
                else => {
                    std.debug.print("Unexpected response type: {}", .{response_type});
                    return error.ProtocolError;
                },
            }
        }
    }

    pub fn processNoticeResponse(_: *Protocol, reader: anytype, allocator: std.mem.Allocator) !Notice {
        var notice = Notice{};
        errdefer notice.deinit(allocator);

        while (true) {
            const field_type = try reader.readByte();
            if (field_type == 0) break; // End of notice fields

            const field_value = try reader.readUntilDelimiterAlloc(allocator, 0, // null terminator
                1024 // max length
            );
            defer allocator.free(field_value);

            switch (@as(NoticeField, @enumFromInt(field_type))) {
                .Severity => notice.severity = try allocator.dupe(u8, field_value),
                .Message => notice.message = try allocator.dupe(u8, field_value),
                .Detail => notice.detail = try allocator.dupe(u8, field_value),
                .Hint => notice.hint = try allocator.dupe(u8, field_value),
                .Code => notice.code = try allocator.dupe(u8, field_value),
                else => {
                    // Optionally log or ignore other fields
                    // std.debug.print("Unhandled notice field type: {c}\n", .{field_type});
                },
            }
        }

        return notice;
    }

    pub fn processErrorResponse(_: *Protocol, reader: anytype, allocator: std.mem.Allocator) !PostgresError {
        var error_info = PostgresError{};
        errdefer error_info.deinit(allocator);

        while (true) {
            const field_type = try reader.readByte();
            if (field_type == 0) break; // End of error fields

            const field_value = try reader.readUntilDelimiterAlloc(allocator, 0, // null terminator
                1024 // max length
            );
            defer allocator.free(field_value);

            switch (@as(ErrorField, @enumFromInt(field_type))) {
                .Severity => error_info.severity = try allocator.dupe(u8, field_value),
                .Code => error_info.code = try allocator.dupe(u8, field_value),
                .Message => error_info.message = try allocator.dupe(u8, field_value),
                .Detail => error_info.detail = try allocator.dupe(u8, field_value),
                .Hint => error_info.hint = try allocator.dupe(u8, field_value),
                else => {
                    // Optionally log or ignore other fields
                },
            }
        }

        return error_info;
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
                .ErrorResponse => {
                    var current_error: types.PostgresError = try processErrorResponse(self, reader, allocator);

                    if (current_error.severity) |severity| {
                        std.debug.print("Error Severity: {s}\n", .{severity});
                    }
                    if (current_error.message) |message| {
                        std.debug.print("Error Message: {s}\n", .{message});
                    }

                    if (current_error.severity) |severity| {
                        if (std.mem.eql(u8, severity, "ERROR") or
                            std.mem.eql(u8, severity, "FATAL") or
                            std.mem.eql(u8, severity, "PANIC"))
                        {
                            current_error.deinit(allocator);
                            return error.PostgresError;
                        }
                    }

                    current_error.deinit(allocator);
                    continue;
                },
                else => {
                    std.debug.print("Unexpected response type: {}", .{response_type});
                    return error.ProtocolError;
                },
            }
        }
    }
};
