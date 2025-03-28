const std = @import("std");
const zpg = @import("zpg");

const TestResult = struct {
    id: i32,
};

// Add this test before the pool test
test "direct connection" {
    const allocator = std.testing.allocator;
    var conn = try zpg.Connection.init(allocator, .{
        .host = "127.0.0.1",
        .port = 5432,
        .username = "postgres",
        .database = "zui",
        .password = "postgres",
        .tls_mode = .require, // Keep TLS required since server has it enabled
        .tls_ca_file = null, // No CA file provided
    });
    defer conn.deinit();

    try conn.connect();
    try std.testing.expect(conn.isAlive());
}

test "tls connection test" {
    std.debug.print("Starting TLS test...\n", .{});
    const allocator = std.testing.allocator;

    std.debug.print("Creating pool config...\n", .{});
    var pool = try zpg.ConnectionPool.init(allocator, zpg.Config{
        .host = "127.0.0.1",
        .port = 5432,
        .username = "postgres",
        .database = "zui",
        .password = "postgres",
        .tls_mode = .require,
    }, 1);
    defer {
        std.debug.print("Deinitializing pool...\n", .{});
        pool.deinit();
        std.debug.print("Pool deinit complete\n", .{});
    }

    std.debug.print("Creating connection...\n", .{});
    var conn = try zpg.PooledConnection.init(&pool);
    defer {
        std.debug.print("Deinitializing connection...\n", .{});
        conn.deinit();
        std.debug.print("Connection deinit complete\n", .{});
    }

    var query = conn.createQuery(allocator);
    defer query.deinit();

    // Updated query to match the new field name 'id'
    const results = try query.run("SELECT 1 AS id", TestResult);

    switch (results) {
        .select => |rows| {
            defer {
                allocator.free(rows);
            }
            try std.testing.expectEqual(@as(usize, 1), rows.len);
            try std.testing.expectEqual(@as(i32, 1), rows[0].id);
        },
        else => unreachable,
    }
}
