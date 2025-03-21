const std = @import("std");

test "cpu speed test" {
    const start_time = std.time.nanoTimestamp();
    var sum: u64 = 0;
    for (0..1_000_000_000) |_| {
        sum += 1;
    }
    const elapsed = std.time.nanoTimestamp();
    const elapsed_ms = @divFloor(elapsed - start_time, 1_000_000);

    std.debug.print("CPU Benchmark: {d} ms\n", .{elapsed_ms});
}

test {
    //std.testing.refAllDecls(@import("connection.zig"));
    std.testing.refAllDecls(@import("query.zig"));
    //std.testing.refAllDecls(@import("statement.zig"));
    //std.testing.refAllDecls(@import("result.zig"));
}
