const std = @import("std");

test {
    //std.testing.refAllDecls(@import("cpu.zig"));
    std.testing.refAllDecls(@import("connection.zig"));
    std.testing.refAllDecls(@import("prepare.zig"));
    std.testing.refAllDecls(@import("pool.zig"));
    std.testing.refAllDecls(@import("field/numeric.zig"));
    std.testing.refAllDecls(@import("field/string.zig"));
}
