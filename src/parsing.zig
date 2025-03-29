const std = @import("std");
const types = @import("types.zig");
const CommandType = types.CommandType;

// Parse the statement name from PREPARE
pub fn parsePrepareStatementName(sql: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, sql, " \t\n");
    const prepare_end = std.mem.indexOf(u8, trimmed, " ") orelse return error.InvalidPrepareSyntax;
    const after_prepare = std.mem.trimLeft(u8, trimmed[prepare_end..], " ");
    const name_end = std.mem.indexOfAny(u8, after_prepare, " (") orelse return error.InvalidPrepareSyntax;
    return after_prepare[0..name_end];
}

pub fn parseExtendedStatementCommand(sql: []const u8) !CommandType {
    const trimmed = std.mem.trim(u8, sql, " \t\n");
    const upper = trimmed[0..@min(trimmed.len, 10)];
    const command_type = types.getCommandType(upper);

    switch (command_type) {
        .Select, .Insert, .Update, .Delete => return command_type,
        else => {
            std.debug.print("\x1b[31mError\x1b[0m: Unsupported command '{s}' in extended statement. Only SELECT, INSERT, UPDATE, and DELETE are allowed.\n", .{@tagName(command_type)});
            return error.UnsupportedPrepareCommand;
        },
    }
}

// Parse the command type from PREPARE
pub fn parsePrepareStatementCommand(sql: []const u8) !CommandType {
    const trimmed = std.mem.trim(u8, sql, " \t\n");
    const as_idx = std.mem.indexOf(u8, trimmed, " AS ") orelse return error.InvalidPrepareSyntax;
    const stmt_sql = std.mem.trimLeft(u8, trimmed[as_idx + 4 ..], " ");
    const upper = stmt_sql[0..@min(stmt_sql.len, 10)];

    const command_type = types.getCommandType(upper);

    // Check if the command type is allowed in PREPARE
    switch (command_type) {
        .Select, .Insert, .Update, .Delete => return command_type, // Allowed commands
        else => {
            std.debug.print("\x1b[31mError\x1b[0m: Unsupported command '{s}' in PREPARE statement. Only SELECT, INSERT, UPDATE, and DELETE are allowed.\n", .{@tagName(command_type)});
            return error.UnsupportedPrepareCommand;
        }, // Reject everything else
    }
}

// Parse the statement name from EXECUTE
pub fn parseExecuteStatementName(sql: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, sql, " \t\n");
    const execute_end = std.mem.indexOf(u8, trimmed, " ") orelse return error.InvalidExecuteSyntax;
    const after_execute = std.mem.trimLeft(u8, trimmed[execute_end..], " ");
    const name_end = std.mem.indexOfAny(u8, after_execute, " (") orelse after_execute.len;
    return after_execute[0..name_end];
}
