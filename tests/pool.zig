const std = @import("std");
const zpg = @import("zpg");
const ConnectionPool = zpg.ConnectionPool;
const PooledConnection = zpg.PooledConnection;

const User = struct {
    id: i64,
    username: []const u8,

    pub fn deinit(self: User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
    }
};

test "simple pool usage" {
    std.debug.print("\nTEST: simple pool usage\n", .{});
    const allocator = std.testing.allocator;
    // Initialize a connection pool with 10 connections
    const config = zpg.Config{
        .host = "127.0.0.1",
        .port = 5432,
        .username = "postgres",
        .database = "zui",
        .password = "postgres", // Match your server setup
        .ssl = false,
    };
    var pool = try ConnectionPool.init(allocator, config, 10);
    defer pool.deinit();

    // Get a connection from the pool
    {
        var pooled_conn = try PooledConnection.init(&pool);
        defer pooled_conn.deinit(); // Automatically returns to pool

        var query = pooled_conn.createQuery(allocator);
        defer query.deinit();

        // 1st prepare, will take time
        std.debug.print("Benchmark result:\n", .{});
        var start_time = std.time.nanoTimestamp();
        try query.prepare("user_one", "SELECT id, username FROM users WHERE id = $1", User);
        const prepare_time1 = std.time.nanoTimestamp() - start_time;
        std.debug.print("  1st prepare() = {d} ns\n", .{prepare_time1});

        // 2nd prepare(), expect it will skip
        start_time = std.time.nanoTimestamp();
        try query.prepare("user_one", "SELECT id, username FROM users WHERE id = $1", User);
        const prepare_time2 = std.time.nanoTimestamp() - start_time;
        std.debug.print("  2nd prepare() *expect skip = {d} ns\n", .{prepare_time2});

        // Create array and pass slice
        var params = [_][]const u8{"1"};
        start_time = std.time.nanoTimestamp();
        const result = try query.execute(User, "user_one", params[0..], 1);
        const execute_time = std.time.nanoTimestamp() - start_time;

        std.debug.print("  execute() = {d} ns\n", .{execute_time});

        if (result) |rows| {
            defer allocator.free(rows);
            std.debug.print("\nrows.len {}\n", .{rows.len});
            for (rows) |user| {
                defer user.deinit(allocator);
                std.debug.print("User: id={d}, username={s}\n", .{ user.id, user.username });
            }
        } else {
            std.debug.print("No rows returned\n", .{});
        }
    }
}
