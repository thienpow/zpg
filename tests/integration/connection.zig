const std = @import("std");
const zpg = @import("zpg");

test "Integration: Connect to PostgreSQL" {
    const config = zpg.Config{
        .host = "localhost",
        .port = 5432,
        .user = "postgres",
        .database = "test",
        .password = "secret",
        .ssl = true,
    };

    var conn = try zpg.Connection.init(std.testing.allocator, config);
    defer conn.deinit();

    const result = try conn.execute("SELECT 1");
    var iter = result.iterator();
    const row = iter.next().?;
    try std.testing.expectEqualStrings("1", row.get("?column?").?.value);
}
