const std = @import("std");
const zpg = @import("zpg");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const RLSContext = zpg.RLSContext;

const RLSTestData = struct {
    id: zpg.field.Serial,
    user_id: i32,
    data: []const u8,

    pub fn deinit(self: RLSTestData, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

const SettingResult = struct {
    value: []const u8,
    pub fn deinit(self: SettingResult, allocator: Allocator) void {
        allocator.free(self.value);
    }
};

test "row level security (RLS) test" {
    const allocator = testing.allocator;

    // Setup pool as postgres
    var setup_pool = try zpg.ConnectionPool.init(allocator, zpg.Config{
        .host = "127.0.0.1",
        .port = 5432,
        .username = "postgres",
        .database = "zui",
        .password = "postgres",
        .tls_mode = .disable,
    }, 3);
    defer setup_pool.deinit();

    var setup_conn = try zpg.PooledConnection.init(&setup_pool, null);
    defer setup_conn.deinit();
    var setup_query = setup_conn.createQuery(allocator);
    defer setup_query.deinit();

    _ = try setup_query.run("DROP TABLE IF EXISTS rls_test_table", zpg.types.Empty);
    std.debug.print("Creating rls_test_table...\n", .{});
    _ = try setup_query.run(
        \\CREATE TABLE rls_test_table (
        \\    id SERIAL PRIMARY KEY,
        \\    user_id INTEGER NOT NULL,
        \\    data TEXT
        \\)
    , zpg.types.Empty);

    std.debug.print("Enabling RLS...\n", .{});
    _ = try setup_query.run("ALTER TABLE rls_test_table ENABLE ROW LEVEL SECURITY", zpg.types.Empty);
    _ = try setup_query.run("ALTER TABLE rls_test_table FORCE ROW LEVEL SECURITY", zpg.types.Empty);

    std.debug.print("Creating RLS policy...\n", .{});
    _ = try setup_query.run("DROP POLICY IF EXISTS user_specific_policy ON rls_test_table", zpg.types.Empty);
    _ = try setup_query.run(
        \\CREATE POLICY user_specific_policy ON rls_test_table
        \\    FOR SELECT
        \\    USING (user_id = CAST(current_setting('app.user_id', true) AS INTEGER))
    , zpg.types.Empty);

    std.debug.print("Granting permissions to test_user...\n", .{});
    _ = try setup_query.run("GRANT ALL ON rls_test_table TO test_user", zpg.types.Empty);
    _ = try setup_query.run("GRANT ALL ON rls_test_table_id_seq TO test_user", zpg.types.Empty);

    std.debug.print("Inserting test data...\n", .{});
    _ = try setup_query.prepare("insert_rls", "INSERT INTO rls_test_table (user_id, data) VALUES ($1, $2)");
    _ = try setup_query.execute("insert_rls", &[_]zpg.Param{
        zpg.Param.int(@as(i32, 100)),
        zpg.Param.string("Data for user 100 - A"),
    }, zpg.types.Empty);
    _ = try setup_query.execute("insert_rls", &[_]zpg.Param{
        zpg.Param.int(@as(i32, 200)),
        zpg.Param.string("Data for user 200"),
    }, zpg.types.Empty);
    _ = try setup_query.execute("insert_rls", &[_]zpg.Param{
        zpg.Param.int(@as(i32, 100)),
        zpg.Param.string("Data for user 100 - B"),
    }, zpg.types.Empty);

    // Test pool as test_user
    var pool = try zpg.ConnectionPool.init(allocator, zpg.Config{
        .host = "127.0.0.1",
        .port = 5432,
        .username = "test_user",
        .database = "zui",
        .password = "testpass",
        .tls_mode = .disable,
    }, 3);
    defer pool.deinit();

    std.debug.print("\nTesting as User 100...\n", .{});
    var rls_ctx_100 = RLSContext.init(allocator);
    defer rls_ctx_100.deinit(allocator);
    try rls_ctx_100.put(allocator, "app.user_id", "100");

    var pconn_100 = try zpg.PooledConnection.init(&pool, &rls_ctx_100);
    defer pconn_100.deinit();
    var query_100 = pconn_100.createQuery(allocator);
    defer query_100.deinit();

    const setting_result = try query_100.run("SELECT current_setting('app.user_id', true) AS value", SettingResult);
    switch (setting_result) {
        .select => |rows| {
            defer {
                for (rows) |row| row.deinit(allocator);
                allocator.free(rows);
            }
            std.debug.print("Current app.user_id before SELECT: {s}\n", .{rows[0].value});
        },
        else => std.debug.print("Failed to get setting\n", .{}),
    }

    const debug_result = try query_100.run("SELECT id, user_id, data FROM rls_test_table WHERE user_id = CAST(current_setting('app.user_id', true) AS INTEGER) ORDER BY id", RLSTestData);
    switch (debug_result) {
        .select => |rows| {
            defer {
                for (rows) |row| row.deinit(allocator);
                allocator.free(rows);
            }
            std.debug.print("Debug query received {d} rows\n", .{rows.len});
            for (rows) |row| {
                std.debug.print("Debug Row: id={}, user_id={d}, data={s}\n", .{ row.id.value, row.user_id, row.data });
            }
        },
        else => unreachable,
    }

    const results_100 = try query_100.run("SELECT id, user_id, data FROM rls_test_table ORDER BY id", RLSTestData);
    switch (results_100) {
        .select => |rows| {
            defer {
                for (rows) |row| row.deinit(allocator);
                allocator.free(rows);
            }
            std.debug.print("User 100 received {d} rows\n", .{rows.len});
            for (rows) |row| {
                std.debug.print("Row: id={}, user_id={d}, data={s}\n", .{ row.id.value, row.user_id, row.data });
            }
            try testing.expectEqual(@as(usize, 2), rows.len);
            for (rows) |row| {
                try testing.expectEqual(@as(i32, 100), row.user_id);
                try testing.expect(std.mem.startsWith(u8, row.data, "Data for user 100"));
            }
        },
        else => unreachable,
    }

    std.debug.print("\nTesting as User 200...\n", .{});
    var rls_ctx_200 = RLSContext.init(allocator);
    defer rls_ctx_200.deinit(allocator);
    try rls_ctx_200.put(allocator, "app.user_id", "200");

    var pconn_200 = try zpg.PooledConnection.init(&pool, &rls_ctx_200);
    defer pconn_200.deinit();
    var query_200 = pconn_200.createQuery(allocator);
    defer query_200.deinit();

    const results_200 = try query_200.run("SELECT id, user_id, data FROM rls_test_table ORDER BY id", RLSTestData);
    switch (results_200) {
        .select => |rows| {
            defer {
                for (rows) |row| row.deinit(allocator);
                allocator.free(rows);
            }
            std.debug.print("User 200 received {d} rows\n", .{rows.len});
            for (rows) |row| {
                std.debug.print("Row: id={}, user_id={d}, data={s}\n", .{ row.id.value, row.user_id, row.data });
            }
            try testing.expectEqual(@as(usize, 1), rows.len);
            try testing.expectEqual(@as(i32, 200), rows[0].user_id);
            try testing.expectEqualStrings("Data for user 200", rows[0].data);
        },
        else => unreachable,
    }

    std.debug.print("\nTesting with no context...\n", .{});
    var pconn_null = try zpg.PooledConnection.init(&pool, null);
    defer pconn_null.deinit();
    var query_null = pconn_null.createQuery(allocator);
    defer query_null.deinit();

    const results_null = try query_null.run("SELECT id, user_id, data FROM rls_test_table ORDER BY id", RLSTestData);
    switch (results_null) {
        .select => |rows| {
            defer {
                for (rows) |row| row.deinit(allocator);
                allocator.free(rows);
            }
            std.debug.print("No context received {d} rows\n", .{rows.len});
            for (rows) |row| {
                std.debug.print("Row: id={}, user_id={d}, data={s}\n", .{ row.id.value, row.user_id, row.data });
            }
            try testing.expectEqual(@as(usize, 0), rows.len);
        },
        else => unreachable,
    }

    std.debug.print("\nRLS test finished.\n", .{});
}
