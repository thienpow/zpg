const std = @import("std");
const zpg = @import("zpg");
const Connection = zpg.Connection;
const Config = zpg.Config;
const Query = zpg.Query;

const User = struct {
    id: i64,
    username: []const u8,

    pub fn deinit(self: User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
    }
};

test "prepare and execute with benchmarks" {
    const allocator = std.testing.allocator;
    const config = Config{
        .host = "127.0.0.1",
        .port = 5432,
        .username = "postgres",
        .database = "zui",
        .password = "postgres",
        .ssl = false,
    };

    var conn = try Connection.init(allocator, config);
    defer conn.deinit();

    // Benchmark connection
    var start_time = std.time.nanoTimestamp();
    try conn.connect();
    const connect_time = std.time.nanoTimestamp() - start_time;

    var query = Query.init(allocator, &conn);
    defer query.deinit();

    // Benchmark prepare
    start_time = std.time.nanoTimestamp();
    try query.prepare("user_all", "SELECT id, username FROM Users", User);
    const prepare_time = std.time.nanoTimestamp() - start_time;

    // Benchmark execute
    start_time = std.time.nanoTimestamp();
    const result = try query.execute(User, "user_all", null, null);
    const execute_time = std.time.nanoTimestamp() - start_time;

    // Output benchmark results
    std.debug.print("Benchmark results:\n", .{});
    std.debug.print("  connect() = {d} ns\n", .{connect_time});
    std.debug.print("  prepare() = {d} ns\n", .{prepare_time});
    std.debug.print("  execute() = {d} ns\n", .{execute_time});

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
