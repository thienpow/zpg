const std = @import("std");

test {
    // std.testing.refAllDecls(@import("cpu.zig"));
    // std.testing.refAllDecls(@import("connection.zig"));
    // std.testing.refAllDecls(@import("prepare.zig"));
    // std.testing.refAllDecls(@import("pool.zig"));
    // std.testing.refAllDecls(@import("field/numeric.zig"));
    // std.testing.refAllDecls(@import("field/string.zig"));
    // std.testing.refAllDecls(@import("field/timestamp.zig"));
    // std.testing.refAllDecls(@import("field/interval.zig"));
    // std.testing.refAllDecls(@import("field/datetime.zig"));
    // std.testing.refAllDecls(@import("field/search.zig"));
    // std.testing.refAllDecls(@import("field/net.zig"));
    std.testing.refAllDecls(@import("field/uuid.zig"));
}
