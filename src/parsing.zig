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

// Parse the command type from PREPARE
pub fn parsePrepareStatementCommand(sql: []const u8) !CommandType {
    const trimmed = std.mem.trim(u8, sql, " \t\n");
    const as_idx = std.mem.indexOf(u8, trimmed, " AS ") orelse return error.InvalidPrepareSyntax;
    const stmt_sql = std.mem.trimLeft(u8, trimmed[as_idx + 4 ..], " ");
    const upper = stmt_sql[0..@min(stmt_sql.len, 10)];

    return types.getCommandType(upper);
}

// Parse the statement name from EXECUTE
pub fn parseExecuteStatementName(sql: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, sql, " \t\n");
    const execute_end = std.mem.indexOf(u8, trimmed, " ") orelse return error.InvalidExecuteSyntax;
    const after_execute = std.mem.trimLeft(u8, trimmed[execute_end..], " ");
    const name_end = std.mem.indexOfAny(u8, after_execute, " (") orelse after_execute.len;
    return after_execute[0..name_end];
}
