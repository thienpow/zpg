const std = @import("std");
const zpg = @import("zpg");
const ConnectionPool = zpg.ConnectionPool;
const PooledConnection = zpg.PooledConnection;
const Param = zpg.Param;

const config = zpg.Config{
    .host = "127.0.0.1",
    .port = 5432,
    .username = "postgres",
    .database = "zui",
    .password = "postgres",
    .tls_mode = .disable,
};

test "invalid prepare test" {
    const allocator = std.testing.allocator;

    var pool = try ConnectionPool.init(allocator, config, 3);
    defer pool.deinit();

    var pooled_conn = try PooledConnection.init(&pool, null);
    defer pooled_conn.deinit();

    var query = pooled_conn.createQuery(allocator);
    defer query.deinit();

    // Test that PREPARE with DROP TABLE fails as expected, because Only SELECT, INSERT, UPDATE, and DELETE are allowed.
    const invalid_prepare_result = query.prepare("drop_table", "DROP TABLE IF EXISTS numeric_test");
    try std.testing.expectError(error.UnsupportedPrepareCommand, invalid_prepare_result);

    const ok_prepare_result = try query.prepare("user_list_all", "SELECT * FROM users");
    try std.testing.expect(ok_prepare_result);

    const ok_prepare_via_run_result = try query.run("PREPARE user_list_all AS SELECT * FROM users", zpg.types.Empty);
    switch (ok_prepare_via_run_result) {
        .success => |success| std.debug.print("  PREPARE via query.run {}.\n", .{success}),
        else => unreachable,
    }

    const ok_prepare_via_run_result2 = try query.run("PREPARE user_list_all2 AS SELECT * FROM users", zpg.types.Empty);
    switch (ok_prepare_via_run_result2) {
        .success => |success| std.debug.print("  PREPARE via query.run {}.\n", .{success}),
        else => unreachable,
    }
}
