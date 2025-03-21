const std = @import("std");

test {
    //std.testing.refAllDecls(@import("connection.zig"));
    std.testing.refAllDecls(@import("query.zig"));
    //std.testing.refAllDecls(@import("statement.zig"));
    //std.testing.refAllDecls(@import("result.zig"));
}
