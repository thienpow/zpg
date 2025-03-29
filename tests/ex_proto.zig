const std = @import("std");
const zpg = @import("zpg");
const ConnectionPool = zpg.ConnectionPool;
const PooledConnection = zpg.PooledConnection;
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

// Define a User struct (binary-compatible)
const User = struct {
    id: i64,
    username: []const u8,
    pub fn deinit(self: User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
    }
};

const params = &[_]Param{
    Param.int(@as(i64, 1)),
};

const params_for_user_update = &[_]Param{
    Param.string("Joe"),
    Param.int(@as(i64, 1)),
};

// Define a UserWithFirstName struct (binary-compatible)
const UserWithFirstName = struct {
    id: i64,
    first_name: []const u8,
    pub fn deinit(self: UserWithFirstName, allocator: std.mem.Allocator) void {
        allocator.free(self.first_name);
    }
};

// Test function using QueryEx for extended query protocol with binary results
test "simple pool test with QueryEx" {
    const allocator = std.testing.allocator;

    // Initialize a connection pool with 3 connections
    std.debug.print("\nInitializing connection pool with 3 connections...\n", .{});
    var pool = try ConnectionPool.init(allocator, config, 3);
    defer pool.deinit();

    // Get a pooled connection from the pool
    std.debug.print("\nAcquiring a connection from the pool...\n", .{});
    var pooled_conn = try PooledConnection.init(&pool);
    defer pooled_conn.deinit();

    // Create a QueryEx object for extended query protocol
    std.debug.print("\nCreating a QueryEx object...\n", .{});
    var query = pooled_conn.createQueryEx(allocator);
    defer query.deinit();

    // Step 1. Benchmark and prepare a SELECT statement
    std.debug.print("\nPreparing SELECT statement 'user_one'...\n", .{});
    var start_time = std.time.nanoTimestamp();
    const prepared_user_one = try query.prepare("user_one", "SELECT id, username FROM users WHERE id = $1");
    const prepare_select_time = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0;
    std.debug.print("  Time taken to prepare SELECT statement: {d:.3} µs\n", .{prepare_select_time});
    start_time = std.time.nanoTimestamp();
    const repeat_ok = try query.prepare("user_one", "SELECT id, username FROM users WHERE id = $1");
    const prepare_select_time2 = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0;
    std.debug.print("  Repeat, expect skip happen because of cached: {d:.3} {any} µs\n", .{ prepare_select_time2, repeat_ok });
    std.debug.print("  SELECT statement prepared successfully. {}\n", .{prepared_user_one});

    // Step 2. Execute the prepared SELECT statement with binary results
    std.debug.print("\nExecuting SELECT statement 'user_one' with id = 1 (binary)...\n", .{});
    start_time = std.time.nanoTimestamp();
    const select_result = try query.execute("user_one", params, User);
    const execute_select_time = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0;
    std.debug.print("  Time taken to execute SELECT statement: {d:.3} µs\n", .{execute_select_time});
    switch (select_result) {
        .select => |rows| {
            defer allocator.free(rows);
            std.debug.print("  Retrieved {d} user(s):\n", .{rows.len});
            for (rows) |user| {
                defer user.deinit(allocator);
                std.debug.print("    User ID: {d}, Username: {s}\n", .{ user.id, user.username });
            }
        },
        else => unreachable,
    }

    // Step 3. Re-execute the prepared SELECT statement
    std.debug.print("\nRe-executing SELECT statement 'user_one' with id = 1 (binary)...\n", .{});
    start_time = std.time.nanoTimestamp();
    const select_result2 = try query.execute("user_one", params, User);
    const re_execute_select_time = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0;
    std.debug.print("  Time taken to re-execute SELECT statement: {d:.3} µs\n", .{re_execute_select_time});
    switch (select_result2) {
        .select => |rows| {
            defer allocator.free(rows);
            std.debug.print("  Retrieved {d} user(s):\n", .{rows.len});
            for (rows) |user| {
                defer user.deinit(allocator);
                std.debug.print("    User ID: {d}, Username: {s}\n", .{ user.id, user.username });
            }
        },
        else => unreachable,
    }

    // Step 4. Benchmark and prepare an UPDATE statement
    std.debug.print("\nPreparing UPDATE statement 'user_update'...\n", .{});
    start_time = std.time.nanoTimestamp();
    const prepared_user_update = try query.prepare("user_update", "UPDATE users SET first_name = $1 WHERE id = $2");
    const prepare_update_time = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0;
    std.debug.print("  Time taken to prepare UPDATE statement: {d:.3} µs\n", .{prepare_update_time});
    std.debug.print("  UPDATE statement prepared successfully. {}\n", .{prepared_user_update});

    // Step 5. Reset the first_name field using execute
    std.debug.print("\nResetting first_name to 'Alice' for user with id = 1...\n", .{});
    start_time = std.time.nanoTimestamp();
    const reset_params = &[_]Param{ Param.string("Alice"), Param.int(@as(i64, 1)) };
    const reset_result = try query.execute("user_update", reset_params, zpg.types.Empty);
    const reset_update_time = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0;
    std.debug.print("  Time taken to reset first_name: {d:.3} µs\n", .{reset_update_time});
    switch (reset_result) {
        .command => |count| std.debug.print("  Reset first_name for {d} user(s).\n", .{count}),
        else => unreachable,
    }

    // Verify the state before the update (using binary SELECT)
    std.debug.print("\nChecking user data before UPDATE...\n", .{});
    const before_result = try query.execute("user_one", params, UserWithFirstName);
    switch (before_result) {
        .select => |rows| {
            defer allocator.free(rows);
            std.debug.print("  Retrieved {d} user(s):\n", .{rows.len});
            for (rows) |user| {
                defer user.deinit(allocator);
                std.debug.print("    User ID: {d}, First Name: {s}\n", .{ user.id, user.first_name });
            }
        },
        else => unreachable,
    }

    // Step 6. Execute the prepared UPDATE statement
    std.debug.print("\nExecuting UPDATE statement 'user_update' with params (binary)...\n", .{});
    start_time = std.time.nanoTimestamp();
    const update_result = try query.execute("user_update", params_for_user_update, zpg.types.Empty);
    const execute_update_time = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0;
    std.debug.print("  Time taken to execute UPDATE statement: {d:.3} µs\n", .{execute_update_time});
    switch (update_result) {
        .command => |count| std.debug.print("  Updated {d} user(s).\n", .{count}),
        else => {
            std.debug.print("  Unexpected result: {any}\n", .{update_result});
            unreachable;
        },
    }

    // Step 7. Re-execute the prepared UPDATE statement with new params
    std.debug.print("\nRe-executing UPDATE statement 'user_update' to set first_name to 'Dave'...\n", .{});
    start_time = std.time.nanoTimestamp();
    const new_params = &[_]Param{ Param.string("Dave"), Param.int(@as(i64, 1)) };
    const update_result2 = try query.execute("user_update", new_params, zpg.types.Empty);
    const re_execute_update_time = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0;
    std.debug.print("  Time taken to re-execute UPDATE statement: {d:.3} µs\n", .{re_execute_update_time});
    switch (update_result2) {
        .command => |count| std.debug.print("  Updated {d} user(s).\n", .{count}),
        else => {
            std.debug.print("  Unexpected result: {any}\n", .{update_result2});
            unreachable;
        },
    }

    // Verify the state after the re-executed UPDATE (using binary SELECT)
    std.debug.print("\nChecking user data after re-executed UPDATE...\n", .{});
    const after_result = try query.execute("user_one", params, UserWithFirstName);
    switch (after_result) {
        .select => |rows| {
            defer allocator.free(rows);
            std.debug.print("  Retrieved {d} user(s):\n", .{rows.len});
            for (rows) |user| {
                defer user.deinit(allocator);
                std.debug.print("    User ID: {d}, First Name: {s}\n", .{ user.id, user.first_name });
            }
        },
        else => unreachable,
    }

    // Benchmark Summary
    std.debug.print("\n=== Benchmark Summary (QueryEx - Binary) ===\n", .{});
    std.debug.print("1. Prepare SELECT statement: {d:.3} µs\n", .{prepare_select_time});
    std.debug.print("2. Execute SELECT statement: {d:.3} µs\n", .{execute_select_time});
    std.debug.print("3. Re-execute SELECT statement: {d:.3} µs\n", .{re_execute_select_time});
    std.debug.print("4. Prepare UPDATE statement: {d:.3} µs\n", .{prepare_update_time});
    std.debug.print("5. Reset first_name (UPDATE via execute): {d:.3} µs\n", .{reset_update_time});
    std.debug.print("6. Execute UPDATE statement: {d:.3} µs\n", .{execute_update_time});
    std.debug.print("7. Re-execute UPDATE statement: {d:.3} µs\n", .{re_execute_update_time});
    std.debug.print("=====================================\n", .{});
}
