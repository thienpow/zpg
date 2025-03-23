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
    .ssl = false,
};

const User = struct {
    id: i64,
    username: []const u8,
    pub fn deinit(self: User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
    }
};

const UserWithFirstName = struct {
    id: i64,
    first_name: []const u8,
    pub fn deinit(self: UserWithFirstName, allocator: std.mem.Allocator) void {
        allocator.free(self.first_name);
    }
};

test "simple pool test" {
    const allocator = std.testing.allocator;
    var pool = try ConnectionPool.init(allocator, config, 3);
    defer pool.deinit();

    var pooled_conn = try PooledConnection.init(&pool);
    defer pooled_conn.deinit();

    var query = pooled_conn.createQuery(allocator);
    defer query.deinit();

    // Pool execute select

    // PREPARE SELECT
    std.debug.print("\n\nBenchmark PREPARE user_one:\n", .{});
    var start_time = std.time.nanoTimestamp();
    const prepare_result = try query.execute("PREPARE user_one (int8) AS SELECT id, username FROM users WHERE id = $1", zpg.types.Empty);
    std.debug.print("  query.execute = {d:.3} µs\n", .{@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0});
    switch (prepare_result) {
        .success => std.debug.print("Prepared statement successfully\n", .{}),
        else => unreachable,
    }

    // EXECUTE SELECT
    // std.debug.print("\nBenchmark SELECT via EXECUTE user_one:\n", .{});
    start_time = std.time.nanoTimestamp();
    const select_result = try query.execute("EXECUTE user_one (1)", User);
    std.debug.print("  query.execute = {d:.3} µs\n", .{@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0});
    switch (select_result) {
        .select => |rows| {
            defer allocator.free(rows);
            for (rows) |user| {
                defer user.deinit(allocator);
                std.debug.print("id: {d}, username: {s}\n", .{ user.id, user.username });
            }
        },
        else => unreachable,
    }

    std.debug.print("\nAgain, SELECT via EXECUTE user_one:\n", .{});
    start_time = std.time.nanoTimestamp();
    const select_result2 = try query.execute("EXECUTE user_one (1)", User);
    std.debug.print("  query.execute = {d:.3} µs\n", .{@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0});
    switch (select_result2) {
        .select => |rows| {
            defer allocator.free(rows);
            for (rows) |user| {
                defer user.deinit(allocator);
                std.debug.print("id: {d}, username: {s}\n", .{ user.id, user.username });
            }
        },
        else => unreachable,
    }

    // PREPARE UPDATE
    std.debug.print("\n\nBenchmark PREPARE user_update:\n", .{});
    start_time = std.time.nanoTimestamp();
    const prepare_result2 = try query.execute("PREPARE user_update (text, int8) AS UPDATE users SET first_name = $1 WHERE id = $2", zpg.types.Empty);
    std.debug.print("  query.execute = {d:.3} µs\n", .{@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0});
    switch (prepare_result2) {
        .success => std.debug.print("Prepared statement successfully\n", .{}),
        else => unreachable,
    }

    // Reset first_name
    std.debug.print("\n\nResetting first_name with Raw UPDATE:\n", .{});
    start_time = std.time.nanoTimestamp();
    const reset_result = try query.execute("UPDATE users SET first_name = 'Alice' WHERE id = 1", zpg.types.Empty);
    std.debug.print("  reset = {d:.3} µs\n", .{@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0});
    switch (reset_result) {
        .command => |count| std.debug.print("Reset {d} rows\n", .{count}),
        else => unreachable,
    }

    // Verify state before
    std.debug.print("\nChecking state before update:\n", .{});
    const before_rows = try query.execute("SELECT id, first_name FROM users WHERE id = 1", UserWithFirstName);
    switch (before_rows) {
        .select => |rows| {
            defer allocator.free(rows);
            for (rows) |user| {
                defer user.deinit(allocator);
                std.debug.print("Before: id: {d}, first_name: {s}\n", .{ user.id, user.first_name });
            }
        },
        else => unreachable,
    }

    // EXECUTE UPDATE
    std.debug.print("\n\nBenchmark UPDATE via EXECUTE user_update:\n", .{});
    start_time = std.time.nanoTimestamp();
    const update_result = try query.execute("EXECUTE user_update ('Carol', 1)", zpg.types.Empty);
    std.debug.print("  query.execute = {d:.3} µs\n", .{@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0});
    switch (update_result) {
        .command => |count| std.debug.print("Updated {d} rows\n", .{count}),
        else => {
            std.debug.print("Unexpected result: {any}\n", .{update_result});
            unreachable;
        },
    }

    // Verify state after
    std.debug.print("\nChecking state after update:\n", .{});
    const after_rows = try query.execute("SELECT id, first_name FROM users WHERE id = 1", UserWithFirstName);
    switch (after_rows) {
        .select => |rows| {
            defer allocator.free(rows);
            for (rows) |user| {
                defer user.deinit(allocator);
                std.debug.print("After: id: {d}, first_name: {s}\n", .{ user.id, user.first_name });
            }
        },
        else => unreachable,
    }
}
