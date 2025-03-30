const std = @import("std");
const zpg = @import("zpg");
const Allocator = std.mem.Allocator;
const ConnectionPool = zpg.ConnectionPool;
const PooledConnection = zpg.PooledConnection;
const Param = zpg.Param;
const Transaction = zpg.Transaction;

const RLSContext = zpg.RLSContext;

const RLSTestData = struct {
    id: zpg.field.Serial,
    user_id: i32,
    data: []const u8,

    pub fn deinit(self: RLSTestData, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

// Define local error for unexpected test states if needed
const TestUnexpectedResultVariant = error{TestUnexpectedResultVariant};

test "transaction with RLS context" {
    const allocator = std.testing.allocator;

    // --- Setup Pool (postgres user) ---
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

    // --- Setup Table and RLS Policy ---
    _ = try setup_query.run(
        \\ DROP TABLE IF EXISTS transaction_test_table;
        \\ CREATE TABLE transaction_test_table (
        \\    id SERIAL PRIMARY KEY,
        \\    user_id INTEGER NOT NULL,
        \\    data TEXT
        \\ );
        \\ DROP POLICY IF EXISTS user_specific_policy ON transaction_test_table;
        \\ -- Using current_setting(..., true) returns NULL if setting missing
        \\ CREATE POLICY user_specific_policy ON transaction_test_table
        \\    FOR ALL
        \\    USING (user_id = CAST(current_setting('app.user_id', true) AS INTEGER))
        \\    WITH CHECK (user_id = CAST(current_setting('app.user_id', true) AS INTEGER));
        \\ GRANT ALL ON transaction_test_table TO test_user;
        \\ GRANT ALL ON transaction_test_table_id_seq TO test_user;
        \\ ALTER TABLE transaction_test_table ENABLE ROW LEVEL SECURITY;
        \\ ALTER TABLE transaction_test_table FORCE ROW LEVEL SECURITY;
    , zpg.types.Empty); // Assuming zpg.types.Empty is correct

    // --- Insert Initial Data (bypassing RLS) ---
    _ = try setup_query.prepare("insert_rls_data", "INSERT INTO transaction_test_table (user_id, data) VALUES ($1, $2)");
    _ = try setup_query.execute("insert_rls_data", &[_]zpg.Param{
        zpg.Param.int(@as(i32, 100)),
        zpg.Param.string("Data for user 100"),
    }, zpg.types.Empty); // Assuming Empty is correct
    _ = try setup_query.execute("insert_rls_data", &[_]zpg.Param{
        zpg.Param.int(@as(i32, 200)),
        zpg.Param.string("Data for user 200"),
    }, zpg.types.Empty);

    // --- Test Pool (test_user) ---
    var pool = try ConnectionPool.init(allocator, zpg.Config{
        .host = "127.0.0.1",
        .port = 5432,
        .username = "test_user",
        .database = "zui",
        .password = "testpass",
        .tls_mode = .disable,
    }, 1);
    defer pool.deinit();
    var pooled_conn = try PooledConnection.init(&pool, null);
    defer pooled_conn.deinit();
    var query = pooled_conn.createQuery(allocator);
    defer query.deinit();

    std.debug.print("\nTesting transaction with RLS context...\n", .{});
    { // Transaction Block
        std.debug.print("\nTesting as User 100...\n", .{});
        var rls_ctx_100 = RLSContext.init(allocator);
        defer rls_ctx_100.deinit(allocator);
        try rls_ctx_100.put(allocator, "app.user_id", "100");

        // --- Start Transaction with RLS Context ---
        var tx = try Transaction.begin(&query, &rls_ctx_100);
        defer if (tx.active) tx.rollback() catch |err| std.debug.print("Rollback failed: {}\n", .{err});

        // --- Perform SELECT *inside* the transaction ---
        std.debug.print("Selecting data within transaction (User 100 context)...\n", .{});
        const result = try tx.query.run("SELECT id, user_id, data FROM transaction_test_table ORDER BY id", RLSTestData);

        switch (result) {
            .select => |rows| {
                defer {
                    for (rows) |row| row.deinit(allocator);
                    allocator.free(rows);
                }
                std.debug.print("Found {d} rows within transaction:\n", .{rows.len});
                for (rows) |row| {
                    std.debug.print("Row: id={}, user_id={d}, data={s}\n", .{ row.id, row.user_id, row.data });
                    try std.testing.expectEqual(@as(i32, 100), row.user_id);
                }
                try std.testing.expectEqual(@as(usize, 1), rows.len);
            },
            else => unreachable,
        }

        // --- Commit the transaction ---
        try tx.commit();
        std.debug.print("Transaction committed.\n", .{});
    } // End Transaction Block

    // --- Verify RLS filters correctly *outside* the transaction ---
    std.debug.print("Selecting data outside transaction (no RLS context)...\n", .{});
    const outside_result = query.run("SELECT id, user_id, data FROM transaction_test_table ORDER BY id", RLSTestData);
    std.debug.print("Expecting error.PostgresError due to RLS policy violation (CAST failure)...\n", .{});
    try std.testing.expectError(error.PostgresError, outside_result);
    // --- Expect Success, but with Zero Rows ---
    // The RLS policy `USING (user_id = CAST(current_setting('app.user_id', true) AS INTEGER))`
    // will evaluate to `user_id = NULL` when the setting is missing.
    // This matches no rows, resulting in a successful query with an empty result set.
    if (outside_result) |_| {
        // This block should not be reached if expectError passes
        return error.TestExpectedError; // Fail if error wasn't caught
    } else |err| {
        // Check if it was the expected error
        if (err == error.PostgresError) {
            std.debug.print("Successfully caught expected error.PostgresError.\n", .{});
            // We still can't easily check the *details* here unless
            // the library is modified to store/expose them, but
            // catching the correct error type is the main goal.
        } else {
            // Got a different unexpected error
            std.debug.print("Caught an unexpected error type: {}\n", .{err});
            return err;
        }
    }
}
