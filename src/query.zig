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
    is_extended_query: bool = false,

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
    pub fn prepare(self: *Query, name: []const u8, sql: []const u8) !bool {
        var full_sql: []const u8 = undefined;
        var allocated_full_sql = false;
        defer if (allocated_full_sql) self.allocator.free(full_sql);

        // Validate name is not empty
        if (name.len == 0) {
            return error.MissingStatementName;
        }

        // Check if statement is already cached
        const trimmed_sql = std.mem.trim(u8, sql, " \t\n");

        // If statement is already in cache, skip preparation if action matches
        if (self.conn.statement_cache.get(name)) |cached_action| {
            const current_action = try parsing.parsePrepareStatementCommand(trimmed_sql);
            if (cached_action == current_action) {
                return true; // Statement already prepared with same action
            }
        }

        // Prepare the full SQL statement with the provided name
        full_sql = try std.fmt.allocPrint(self.allocator, "PREPARE {s} AS {s}", .{ name, sql });
        allocated_full_sql = true;

        // Validate the command
        const action = try parsing.parsePrepareStatementCommand(trimmed_sql);

        try self.conn.sendMessage(@intFromEnum(RequestType.Query), full_sql, true);

        // Process and cache the result
        const result = try self.protocol.processSimpleCommand();

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name); // Free on error after this point
        try self.conn.statement_cache.put(owned_name, action);

        return result;
    }

    /// Executes a prepared statement with the given name and parameters. If parameters are provided,
    /// it uses the simple query protocol with an EXECUTE statement. If parameters are null, it uses
    /// the extended query protocol. The function returns the result of the execution based on the
    /// type of the prepared statement (SELECT, INSERT, UPDATE, DELETE, or other).
    pub fn execute(self: *Query, name: []const u8, params: ?[]const Param, comptime T: type) !Result(T) {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        // Always construct an EXECUTE statement in text mode
        try buffer.writer().writeAll("EXECUTE ");
        try buffer.writer().writeAll(name);

        if (params) |p| {
            if (p.len > 0) {
                try buffer.writer().writeAll(" (");

                // Format parameters as text
                for (p, 0..) |param, i| {
                    if (i > 0) try buffer.writer().writeAll(", ");
                    try param_utils.formatParamAsText(&buffer, param);
                }

                try buffer.writer().writeAll(")");
            }
        }

        // Delegate to run for execution
        return try self.run(buffer.items, T);
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

        return switch (cmd_type) {
            .Prepare => blk: {
                // Extract name and sql from the PREPARE statement
                const components = try extractPrepareComponents(sql);
                // Note: We don't need to dupe or free here since prepare will handle ownership
                const result = try self.prepare(components.name, components.sql);
                break :blk Result(T){ .success = result };
            },
            .Select => blk: {
                try self.conn.sendMessage(@intFromEnum(RequestType.Query), sql, true);
                break :blk Result(T){
                    .select = (try protocol.processSelectResponses(T, self.is_extended_query)) orelse &[_]T{},
                };
            },
            .Insert, .Update, .Delete, .Merge => blk: {
                try self.conn.sendMessage(@intFromEnum(RequestType.Query), sql, true);
                break :blk Result(T){
                    .command = try protocol.processCommandResponses(),
                };
            },
            .Create, .Alter, .Drop, .Grant, .Revoke, .Begin, .Commit, .Rollback, .Set, .Reset, .Do => blk: {
                try self.conn.sendMessage(@intFromEnum(RequestType.Query), sql, true);
                break :blk Result(T){
                    .success = try protocol.processSimpleCommand(),
                };
            },
            .Explain => blk: {
                try self.conn.sendMessage(@intFromEnum(RequestType.Query), sql, true);
                break :blk Result(T){
                    .explain = try protocol.processExplainResponses(),
                };
            },
            .Execute => blk: {
                try self.conn.sendMessage(@intFromEnum(RequestType.Query), sql, true);
                const stmt_name = try parsing.parseExecuteStatementName(sql);
                const action = self.conn.statement_cache.get(stmt_name) orelse return error.UnknownPreparedStatement;

                break :blk switch (action) {
                    .Select => {
                        const type_info = @typeInfo(T);
                        if (type_info != .@"struct") {
                            @compileError("EXECUTE for SELECT requires T to be a struct");
                        }
                        return Result(T){
                            .select = (try protocol.processSelectResponses(T, self.is_extended_query)) orelse &[_]T{},
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

    fn extractPrepareComponents(sql: []const u8) !struct { name: []const u8, sql: []const u8 } {
        const trimmed = std.mem.trim(u8, sql, " \t\n");
        if (!std.mem.startsWith(u8, trimmed, "PREPARE ")) {
            return error.InvalidPrepareSyntax;
        }
        const after_prepare = std.mem.trimLeft(u8, trimmed["PREPARE ".len..], " ");
        const as_idx = std.mem.indexOf(u8, after_prepare, " AS ") orelse return error.InvalidPrepareSyntax;
        const name = std.mem.trim(u8, after_prepare[0..as_idx], " ");
        if (name.len == 0) return error.MissingStatementName;
        const stmt_sql = std.mem.trimLeft(u8, after_prepare[as_idx + " AS ".len ..], " ");
        if (stmt_sql.len == 0) return error.InvalidPrepareSyntax;
        return .{ .name = name, .sql = stmt_sql };
    }

    // // SELECT: Returns a slice of structs
    // pub fn select(self: *Query, fields: []const []const u8, table: []const u8, condition: ?[]const u8, params: ?[]const Param, comptime T: type) ![]T {
    //     if (@typeInfo(T) != .@"struct") @compileError("SELECT requires T to be a struct");

    //     // Construct SQL dynamically
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

    //     // TODO: Handle params (e.g., parameter binding)
    //     _ = params; // Placeholder; implement parameter substitution if needed

    //     const sql_str = try sql.toOwnedSlice();
    //     defer self.allocator.free(sql_str);

    //     try self.conn.sendMessage(@intFromEnum(RequestType.Query), sql_str, true);
    //     return (try self.protocol.processSelectResponses(T, self.is_extended_query)) orelse &[_]T{};
    // }

    // // INSERT: Returns number of affected rows
    // pub fn insert(self: *Query, table: []const u8, fields: []const []const u8, params: ?[]const Param) !u64 {
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

    //     // TODO: Handle params for values
    //     inline for (0..fields.len) |i| {
    //         if (i > 0) try sql.appendSlice(", ");
    //         try sql.appendSlice("$"); // Placeholder for parameterized query
    //         try std.fmt.formatInt(i + 1, 10, .lower, .{}, sql.writer()) catch unreachable;
    //     }
    //     try sql.appendSlice(")");

    //     _ = params; // Placeholder; implement parameter binding

    //     const sql_str = try sql.toOwnedSlice();
    //     defer self.allocator.free(sql_str);

    //     try self.conn.sendMessage(@intFromEnum(RequestType.Query), sql_str, true);
    //     return try self.protocol.processCommandResponses();
    // }

    // // UPDATE: Returns number of affected rows
    // pub fn update(self: *Query, table: []const u8, fields: []const []const u8, params: ?[]const Param) !u64 {
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

    //     _ = params; // Placeholder; implement condition and parameter binding

    //     const sql_str = try sql.toOwnedSlice();
    //     defer self.allocator.free(sql_str);

    //     try self.conn.sendMessage(@intFromEnum(RequestType.Query), sql_str, true);
    //     return try self.protocol.processCommandResponses();
    // }

    // // DELETE: Returns number of affected rows
    // pub fn delete(self: *Query, table: []const u8, condition: ?[]const u8, params: ?[]const Param) !u64 {
    //     var sql = std.ArrayList(u8).init(self.allocator);
    //     defer sql.deinit();

    //     try sql.appendSlice("DELETE FROM ");
    //     try sql.appendSlice(table);
    //     if (condition) |cond| {
    //         try sql.appendSlice(" WHERE ");
    //         try sql.appendSlice(cond);
    //     }

    //     _ = params; // Placeholder; implement parameter binding

    //     const sql_str = try sql.toOwnedSlice();
    //     defer self.allocator.free(sql_str);

    //     try self.conn.sendMessage(@intFromEnum(RequestType.Query), sql_str, true);
    //     return try self.protocol.processCommandResponses();
    // }
};
