const std = @import("std");

test "format string sanity check" {
    const allocator = std.testing.allocator;
    const result = try std.fmt.allocPrint(allocator, "{s}${d}.{d:0>2}", .{ "", 999, 99 });
    defer allocator.free(result);
    std.debug.print("Formatted: '{s}'\n", .{result});
    try std.testing.expectEqualStrings("$999.99", result);
}
