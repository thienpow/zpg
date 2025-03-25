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

pub const Query = struct {
    conn: *Connection,
    allocator: Allocator,
    protocol: Protocol,

    pub fn init(allocator: Allocator, conn: *Connection) Query {
        return Query{
            .conn = conn,
            .allocator = allocator,
            .protocol = Protocol.init(conn, allocator),
        };
    }

    pub fn deinit(self: *Query) void {
        _ = self;
    }

    /// Prepares a SQL statement for execution. If the statement is already cached with the same action,
    /// it skips preparation and returns true. Otherwise, it prepares the statement, caches it, and
    /// returns the result of the preparation process. If the statement name is missing from the SQL,
    /// it returns an error.
    pub fn prepare(self: *Query, sql: []const u8) !bool {
        var full_sql = sql;
        var allocated_full_sql = false;
        defer if (allocated_full_sql) self.allocator.free(full_sql);

        // Check if statement is already cached
        const trimmed_sql = std.mem.trim(u8, sql, " \t\n");
        var temp_sql: ?[]const u8 = null;
        defer if (temp_sql) |ts| self.allocator.free(ts);

        const stmt_name = owned: {
            if (std.mem.startsWith(u8, trimmed_sql, "PREPARE ")) {
                const name = try parsing.parsePrepareStatementName(sql);
                if (name.len == 0) {
                    return error.MissingStatementName; // Error if name not found
                }
                break :owned name;
            } else {
                temp_sql = try std.fmt.allocPrint(self.allocator, "PREPARE {s}", .{sql});
                const name = try parsing.parsePrepareStatementName(temp_sql.?);
                if (name.len == 0) {
                    return error.MissingStatementName; // Error if name not found
                }
                break :owned try self.allocator.dupe(u8, name);
            }
        };
        defer self.allocator.free(stmt_name);

        // If statement is already in cache, skip preparation if action matches
        if (self.conn.statement_cache.get(stmt_name)) |cached_action| {
            const current_action = blk: {
                if (std.mem.startsWith(u8, trimmed_sql, "PREPARE ")) {
                    break :blk try parsing.parsePrepareStatementCommand(sql);
                } else {
                    if (temp_sql == null) {
                        temp_sql = try std.fmt.allocPrint(self.allocator, "PREPARE {s}", .{sql});
                    }
                    break :blk try parsing.parsePrepareStatementCommand(temp_sql.?);
                }
            };

            if (cached_action == current_action) {
                return true; // Statement already prepared with same action
            }
        }

        // Prepare the statement if not cached or if action differs
        if (!std.mem.startsWith(u8, trimmed_sql, "PREPARE ")) {
            full_sql = try std.fmt.allocPrint(self.allocator, "PREPARE {s}", .{sql});
            allocated_full_sql = true;
        }

        try self.conn.sendMessage(@intFromEnum(RequestType.Query), full_sql, true);

        const owned_name = try self.allocator.dupe(u8, stmt_name);
        const action = try parsing.parsePrepareStatementCommand(full_sql);

        // Only cache if processing succeeds
        const result = try self.protocol.processSimpleCommand();
        try self.conn.statement_cache.put(owned_name, action);

        return result;
    }

    /// Executes a prepared statement with the given name and parameters. If parameters are provided,
    /// it uses the simple query protocol with an EXECUTE statement. If parameters are null, it uses
    /// the extended query protocol. The function returns the result of the execution based on the
    /// type of the prepared statement (SELECT, INSERT, UPDATE, DELETE, or other).
    pub fn execute(self: *Query, name: []const u8, params: ?[]const Param, comptime T: type) !Result(T) {
        // Fast path: Use simple query protocol with EXECUTE statement
        if (params) |p| {
            var buffer = std.ArrayList(u8).init(self.allocator);
            defer buffer.deinit();
            try buffer.writer().writeAll("EXECUTE ");
            try buffer.writer().writeAll(name);
            if (p.len > 0) {
                try buffer.writer().writeAll(" (");

                // Format parameters
                for (p, 0..) |param, i| {
                    if (i > 0) try buffer.writer().writeAll(", ");
                    try param_utils.formatParamAsText(&buffer, param);
                }

                try buffer.writer().writeAll(")");
            }

            return try self.run(buffer.items, T);
        } else {
            const protocol = &self.protocol;
            // Slow path: Use extended query protocol for NULL params
            try protocol.sendBindMessage(name, params);
            try self.conn.sendMessage(@intFromEnum(RequestType.Execute), &[_]u8{ 0, 0, 0, 0, 0 }, false);
            try self.conn.sendMessage(@intFromEnum(RequestType.Sync), "", false);

            if (self.conn.statement_cache.get(name)) |action| {
                switch (action) {
                    .Select => {
                        const type_info = @typeInfo(T);
                        if (type_info != .@"struct") {
                            @compileError("EXECUTE for SELECT requires T to be a struct");
                        }
                        const rows = (try protocol.processSelectResponses(T)) orelse &[_]T{};
                        return Result(T){ .select = rows };
                    },
                    .Insert, .Update, .Delete => {
                        return Result(T){ .command = try protocol.processCommandResponses() };
                    },
                    else => {
                        return Result(T){ .success = try protocol.processSimpleCommand() };
                    },
                }
            } else {
                return error.UnknownPreparedStatement;
            }
        }
    }

    /// Runs a SQL query and returns the result based on the type of the query. It supports SELECT,
    /// INSERT, UPDATE, DELETE, MERGE, PREPARE, CREATE, ALTER, DROP, GRANT, REVOKE, COMMIT, ROLLBACK,
    /// EXPLAIN, and EXECUTE statements. For PREPARE statements, it caches the prepared statement.
    /// For EXECUTE statements, it executes the prepared statement and returns the result based on
    /// the statement's action.
    pub fn run(self: *Query, sql: []const u8, comptime T: type) !Result(T) {
        const protocol = &self.protocol;
        const trimmed = std.mem.trim(u8, sql, " \t\n");
        const command = trimmed[0..@min(trimmed.len, 10)];
        const cmd_type = types.getCommandType(command);

        try self.conn.sendMessage(@intFromEnum(RequestType.Query), sql, true);

        return switch (cmd_type) {
            .Select => Result(T){
                .select = (try protocol.processSelectResponses(T)) orelse &[_]T{},
            },
            .Insert, .Update, .Delete, .Merge => Result(T){
                .command = try protocol.processCommandResponses(),
            },
            .Prepare => blk: {
                const result = try protocol.processSimpleCommand();
                const stmt_name = try parsing.parsePrepareStatementName(sql);
                const action = try parsing.parsePrepareStatementCommand(sql);
                const owned_name = try self.allocator.dupe(u8, stmt_name);
                try self.conn.statement_cache.put(owned_name, action);
                break :blk Result(T){ .success = result };
            },
            .Create, .Alter, .Drop, .Grant, .Revoke, .Commit, .Rollback => Result(T){
                .success = try protocol.processSimpleCommand(),
            },
            .Explain => Result(T){
                .explain = try protocol.processExplainResponses(),
            },
            .Execute => blk: {
                const stmt_name = try parsing.parseExecuteStatementName(sql);
                std.debug.print("Executing {s}\n", .{stmt_name});

                const action = self.conn.statement_cache.get(stmt_name) orelse return error.UnknownPreparedStatement;

                break :blk switch (action) {
                    .Select => {
                        const type_info = @typeInfo(T);
                        if (type_info != .@"struct") {
                            @compileError("EXECUTE for SELECT requires T to be a struct");
                        }
                        return Result(T){
                            .select = (try protocol.processSelectResponses(T)) orelse &[_]T{},
                        };
                    },
                    .Insert, .Update, .Delete => Result(T){
                        .command = try protocol.processCommandResponses(),
                    },
                    else => error.UnsupportedOperation,
                };
            },
            .Unknown => error.UnsupportedOperation,
        };
    }
};
