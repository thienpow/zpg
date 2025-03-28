const std = @import("std");
const zpg = @import("zpg");
const ConnectionPool = zpg.ConnectionPool;
const PooledConnection = zpg.PooledConnection;
const Transaction = zpg.Transaction;
const Param = zpg.Param;

// Configuration for connecting to the PostgreSQL database
const config = zpg.Config{
    .host = "127.0.0.1",
    .port = 5432,
    .username = "postgres",
    .database = "zui",
    .password = "postgres",
    .tls_mode = .disable,
};

// Define a simple TestUser struct for the test table
const TestUser = struct {
    id: i64,
    name: []const u8,
    pub fn deinit(self: TestUser, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

test "transaction test" {
    const allocator = std.testing.allocator;

    // Initialize connection pool
    std.debug.print("\nInitializing connection pool with 1 connection...\n", .{});
    var pool = try ConnectionPool.init(allocator, config, 1);
    defer pool.deinit();

    // Get a pooled connection
    std.debug.print("Acquiring a connection from the pool...\n", .{});
    var pooled_conn = try PooledConnection.init(&pool);
    defer pooled_conn.deinit();

    // Create a query object
    std.debug.print("Creating a query object...\n", .{});
    var query = pooled_conn.createQuery(allocator);
    defer query.deinit();

    // Step 1: Set up a test table
    std.debug.print("Creating test_users table...\n", .{});
    _ = try query.run(
        \\ DROP TABLE IF EXISTS test_users;
        \\ CREATE TABLE test_users (
        \\     id BIGSERIAL PRIMARY KEY,
        \\     name TEXT NOT NULL
        \\ )
    , zpg.types.Empty);
    std.debug.print("Test table created successfully.\n", .{});

    // Step 2: Test transaction with COMMIT
    std.debug.print("\nTesting transaction with COMMIT...\n", .{});
    {
        var tx = try Transaction.begin(&query);
        defer if (tx.active) tx.rollback() catch |err| std.debug.print("Rollback failed: {}\n", .{err});

        // Insert a user within the transaction
        std.debug.print("Inserting user 'Alice' within transaction...\n", .{});
        const insert_result = try query.run("INSERT INTO test_users (name) VALUES ('Alice')", zpg.types.Empty);
        switch (insert_result) {
            .command => |count| std.debug.print("Inserted {d} row(s).\n", .{count}),
            else => unreachable,
        }

        // Verify the user is visible within the transaction
        std.debug.print("Verifying user within transaction...\n", .{});
        const select_result = try query.run("SELECT id, name FROM test_users WHERE name = 'Alice'", TestUser);
        switch (select_result) {
            .select => |rows| {
                defer allocator.free(rows);
                std.debug.print("Found {d} user(s) within transaction:\n", .{rows.len});
                for (rows) |user| {
                    defer user.deinit(allocator);
                    std.debug.print("  ID: {d}, Name: {s}\n", .{ user.id, user.name });
                }
                try std.testing.expectEqual(@as(usize, 1), rows.len);
            },
            else => unreachable,
        }

        // Commit the transaction
        std.debug.print("Committing transaction...\n", .{});
        try tx.commit();
    }

    // Verify the user persists after commit
    std.debug.print("Verifying user 'Alice' after commit...\n", .{});
    const after_commit_result = try query.run("SELECT id, name FROM test_users WHERE name = 'Alice'", TestUser);
    switch (after_commit_result) {
        .select => |rows| {
            defer allocator.free(rows);
            std.debug.print("Found {d} user(s) after commit:\n", .{rows.len});
            for (rows) |user| {
                defer user.deinit(allocator);
                std.debug.print("  ID: {d}, Name: {s}\n", .{ user.id, user.name });
            }
            try std.testing.expectEqual(@as(usize, 1), rows.len);
        },
        else => unreachable,
    }

    // Step 3: Test transaction with ROLLBACK
    std.debug.print("\nTesting transaction with ROLLBACK...\n", .{});
    {
        var tx = try Transaction.begin(&query);
        defer if (tx.active) tx.rollback() catch |err| std.debug.print("Rollback failed: {}\n", .{err});

        // Insert a user within the transaction
        std.debug.print("Inserting user 'Bob' within transaction...\n", .{});
        const insert_result = try query.run("INSERT INTO test_users (name) VALUES ('Bob')", zpg.types.Empty);
        switch (insert_result) {
            .command => |count| std.debug.print("Inserted {d} row(s).\n", .{count}),
            else => unreachable,
        }

        // Verify the user is visible within the transaction
        std.debug.print("Verifying user within transaction...\n", .{});
        const select_result = try query.run("SELECT id, name FROM test_users WHERE name = 'Bob'", TestUser);
        switch (select_result) {
            .select => |rows| {
                defer allocator.free(rows);
                std.debug.print("Found {d} user(s) within transaction:\n", .{rows.len});
                for (rows) |user| {
                    defer user.deinit(allocator);
                    std.debug.print("  ID: {d}, Name: {s}\n", .{ user.id, user.name });
                }
                try std.testing.expectEqual(@as(usize, 1), rows.len);
            },
            else => unreachable,
        }

        // Rollback the transaction
        std.debug.print("Rolling back transaction...\n", .{});
        try tx.rollback();
    }

    // Verify the user does not persist after rollback
    std.debug.print("Verifying user 'Bob' after rollback...\n", .{});
    const after_rollback_result = try query.run("SELECT id, name FROM test_users WHERE name = 'Bob'", TestUser);
    switch (after_rollback_result) {
        .select => |rows| {
            defer allocator.free(rows);
            std.debug.print("Found {d} user(s) after rollback:\n", .{rows.len});
            try std.testing.expectEqual(@as(usize, 0), rows.len);
        },
        else => unreachable,
    }

    // Step 4: Test error on commit/rollback without active transaction
    std.debug.print("\nTesting error handling for commit/rollback without active transaction...\n", .{});
    {
        var tx = try Transaction.begin(&query);
        try tx.commit(); // Commit to end the transaction
        try std.testing.expectError(error.NoActiveTransaction, tx.commit());
        try std.testing.expectError(error.NoActiveTransaction, tx.rollback());
    }

    // Cleanup: Drop the test table
    std.debug.print("\nCleaning up: Dropping test_users table...\n", .{});
    _ = try query.run("DROP TABLE test_users", zpg.types.Empty);
    std.debug.print("Test table dropped successfully.\n", .{});
}
