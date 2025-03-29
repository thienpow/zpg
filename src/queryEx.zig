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
};
