const std = @import("std");
const zpg = @import("zpg");
const ConnectionPool = zpg.ConnectionPool;
const PooledConnection = zpg.PooledConnection;
const Param = zpg.Param;

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
    const config = zpg.Config{
        .host = "127.0.0.1",
        .port = 5432,
        .username = "postgres",
        .database = "zui",
        .password = "postgres",
        .ssl = false,
    };

    std.debug.print("Pool init:\n", .{});
    var start_time = std.time.nanoTimestamp();
    var pool = try ConnectionPool.init(allocator, config, 10);
    std.debug.print("  pool.init = {d:.3} µs\n", .{@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0});
    defer pool.deinit();

    std.debug.print("Pooled connection:\n", .{});
    start_time = std.time.nanoTimestamp();
    var pooled_conn = try PooledConnection.init(&pool);
    std.debug.print("  pooled_conn.init = {d:.3} µs\n", .{@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0});
    defer pooled_conn.deinit();

    var query = pooled_conn.createQuery(allocator);
    defer query.deinit();

    // Pool execute
    std.debug.print("Benchmark query.execute:\n", .{});
    start_time = std.time.nanoTimestamp();
    const sql = "SELECT id, username FROM users WHERE id = 1";
    const result = try query.execute(User, sql);
    std.debug.print("  query.execute = {d:.3} µs\n", .{@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1000.0});

    if (result) |rows| {
        defer allocator.free(rows);
        for (rows) |user| {
            defer user.deinit(allocator);
            std.debug.print("User: id={d}, username={s}\n", .{ user.id, user.username });
        }
    } else {
        std.debug.print("No rows returned\n", .{});
    }
}
