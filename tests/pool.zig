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

        try query.prepare("user_one", "SELECT id, username FROM users WHERE id = $1", User);
        // Create array and pass slice
        var params = [_][]const u8{"1"};
        const start_time = std.time.nanoTimestamp();
        const results = try query.execute(User, "user_one", params[0..], 1);
        const execute_time = std.time.nanoTimestamp() - start_time;
        defer {
            // Free each User's username
            if (results) |users| {
                for (users) |user| {
                    user.deinit(allocator);
                }
                // Free the array of Users itself
                allocator.free(users);
            }
        }
        std.debug.print("\nTEST: simple pool usage, results.len {}\n", .{results.?.len});
        std.debug.print("Benchmark results:\n", .{});
        std.debug.print("  execute() = {d} ns\n", .{execute_time});
    }
}
