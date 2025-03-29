const std = @import("std");
const Allocator = std.mem.Allocator;

const Connection = @import("connection.zig").Connection;
const types = @import("types.zig");
const StatementInfo = types.StatementInfo;
const Error = types.Error;
const ExplainRow = types.ExplainRow;
const Result = types.Result;
const Empty = types.Empty;
const RequestType = types.RequestType;
const ResponseType = types.ResponseType;
const CommandType = types.CommandType;

const Param = @import("param.zig").Param;
const param_utils = @import("param_utils.zig");
const parsing = @import("parsing.zig");
const Protocol = @import("protocol.zig").Protocol;

pub const QueryEx = struct {
    conn: *Connection,
    allocator: Allocator,
    protocol: Protocol,
    is_extended_query: bool = true,

    pub fn init(allocator: Allocator, conn: *Connection) QueryEx {
        return QueryEx{
            .conn = conn,
            .allocator = allocator,
            .protocol = Protocol.init(conn, allocator),
        };
    }

    pub fn deinit(self: *QueryEx) void {
        _ = self;
    }

    /// Prepares a SQL statement using the extended query protocol.
    pub fn prepare(self: *QueryEx, name: []const u8, sql: []const u8) !bool {
        const trimmed_sql = std.mem.trim(u8, sql, " \t\n");

        if (self.conn.statement_cache.get(name)) |cached_action| {
            const current_action = try parsing.parseExtendedStatementCommand(trimmed_sql);
            if (cached_action == current_action) return true;
        }

        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        try buffer.writer().writeByte('P');
        try buffer.writer().writeInt(i32, 0, .big);
        try buffer.writer().writeAll(name);
        try buffer.writer().writeByte(0);
        try buffer.writer().writeAll(trimmed_sql);
        try buffer.writer().writeByte(0);
        try buffer.writer().writeInt(i16, 0, .big);
        const len: i32 = @intCast(buffer.items.len - 1);
        std.mem.writeInt(i32, buffer.items[1..5], len, .big);
        try self.conn.sendMessageRaw(buffer.items);

        try self.conn.sendMessage(@intFromEnum(RequestType.Sync), "", false);
        const result = try self.protocol.processPrepareResponses();
        const action = try parsing.parseExtendedStatementCommand(trimmed_sql);
        const owned_name = try self.allocator.dupe(u8, name);
        try self.conn.statement_cache.put(owned_name, action);
        return result;
    }

    /// Executes a prepared statement using the extended query protocol with optional binary results.
    pub fn execute(self: *QueryEx, name: []const u8, params: ?[]const Param, comptime T: type) !Result(T) {
        const protocol = &self.protocol;

        // Send Bind, Execute, and Sync
        const start = std.time.nanoTimestamp();
        try protocol.sendBind(name, params);
        try protocol.sendDescribe('S', name);
        try protocol.sendExecute("", 0);
        try protocol.sendSync();
        const sent = std.time.nanoTimestamp();
        std.debug.print("Send time: {d:.3} ms\n", .{@as(f64, @floatFromInt(sent - start)) / 1_000_000.0});

        // Process responses
        const result = if (self.conn.statement_cache.get(name)) |action| switch (action) {
            .Select => blk: {
                const type_info = @typeInfo(T);
                if (type_info != .@"struct") @compileError("EXECUTE for SELECT requires T to be a struct");
                const rows = (try protocol.processSelectResponses(T, self.is_extended_query)) orelse &[_]T{};
                break :blk Result(T){ .select = rows };
            },
            .Insert, .Update, .Delete => Result(T){ .command = try protocol.processCommandResponses() },
            else => Result(T){ .success = try protocol.processSimpleCommand() },
        } else return error.UnknownPreparedStatement;

        const received = std.time.nanoTimestamp();
        std.debug.print("Bind to BindComplete: {d:.3} ms\n", .{@as(f64, @floatFromInt(received - sent)) / 1_000_000.0});
        return result;
    }

    // pub fn select(self: *QueryEx, fields: []const []const u8, table: []const u8, condition: ?[]const u8, params: []const Param, comptime T: type) ![]T {
    //     if (@typeInfo(T) != .@"struct") @compileError("SELECT requires T to be a struct");

    //     var sql = std.ArrayList(u8).init(self.allocator);
    //     defer sql.deinit();

    //     try sql.appendSlice("SELECT ");
    //     for (fields, 0..) |field, i| {
    //         if (i > 0) try sql.appendSlice(", ");
    //         try sql.appendSlice(field);
    //     }
    //     try sql.appendSlice(" FROM ");
    //     try sql.appendSlice(table);
    //     if (condition) |cond| {
    //         try sql.appendSlice(" WHERE ");
    //         try sql.appendSlice(cond);
    //     }

    //     const sql_str = try sql.toOwnedSlice();
    //     defer self.allocator.free(sql_str);

    //     // Send query with parameters
    //     try self.conn.sendBindMessage(sql_str, params);
    //     try self.conn.sendExecuteMessage();
    //     return (try self.protocol.processSelectResponses(T, self.is_extended_query)) orelse &[_]T{};
    // }

    // pub fn insert(self: *QueryEx, table: []const u8, fields: []const []const u8, params: []const Param) !u64 {
    //     var sql = std.ArrayList(u8).init(self.allocator);
    //     defer sql.deinit();

    //     try sql.appendSlice("INSERT INTO ");
    //     try sql.appendSlice(table);
    //     try sql.appendSlice(" (");
    //     for (fields, 0..) |field, i| {
    //         if (i > 0) try sql.appendSlice(", ");
    //         try sql.appendSlice(field);
    //     }
    //     try sql.appendSlice(") VALUES (");
    //     for (0..fields.len) |i| {
    //         if (i > 0) try sql.appendSlice(", ");
    //         try sql.appendSlice("$");
    //         try std.fmt.formatInt(i + 1, 10, .lower, .{}, sql.writer()) catch unreachable;
    //     }
    //     try sql.appendSlice(")");

    //     const sql_str = try sql.toOwnedSlice();
    //     defer self.allocator.free(sql_str);

    //     try self.conn.sendBindMessage(sql_str, params);
    //     try self.conn.sendExecuteMessage();
    //     return try self.protocol.processCommandResponses();
    // }

    // pub fn update(self: *QueryEx, table: []const u8, fields: []const []const u8, params: []const Param) !u64 {
    //     var sql = std.ArrayList(u8).init(self.allocator);
    //     defer sql.deinit();

    //     try sql.appendSlice("UPDATE ");
    //     try sql.appendSlice(table);
    //     try sql.appendSlice(" SET ");
    //     for (fields, 0..) |field, i| {
    //         if (i > 0) try sql.appendSlice(", ");
    //         try sql.appendSlice(field);
    //         try sql.appendSlice(" = $");
    //         try std.fmt.formatInt(i + 1, 10, .lower, .{}, sql.writer()) catch unreachable;
    //     }
    //     // Assuming params includes condition values; adjust as needed
    //     if (params.len > fields.len) {
    //         try sql.appendSlice(" WHERE ");
    //         try sql.appendSlice("$");
    //         try std.fmt.formatInt(fields.len + 1, 10, .lower, .{}, sql.writer()) catch unreachable;
    //     }

    //     const sql_str = try sql.toOwnedSlice();
    //     defer self.allocator.free(sql_str);

    //     try self.conn.sendBind(sql_str, params);
    //     try self.conn.sendExecuteMessage();
    //     return try self.protocol.processCommandResponses();
    // }

    // pub fn delete(self: *QueryEx, table: []const u8, condition: ?[]const u8, params: []const Param) !u64 {
    //     var sql = std.ArrayList(u8).init(self.allocator);
    //     defer sql.deinit();

    //     try sql.appendSlice("DELETE FROM ");
    //     try sql.appendSlice(table);
    //     if (condition) |cond| {
    //         try sql.appendSlice(" WHERE ");
    //         try sql.appendSlice(cond);
    //     }

    //     const sql_str = try sql.toOwnedSlice();
    //     defer self.allocator.free(sql_str);

    //     try self.conn.sendBindMessage(sql_str, params);
    //     try self.conn.sendExecuteMessage();
    //     return try self.protocol.processCommandResponses();
    // }
};
