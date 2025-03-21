const std = @import("std");
const zpg = @import("zpg");
const Connection = zpg.Connection;
const Config = zpg.Config;
const Query = zpg.Query;

const User = struct {
    id: i64,
    username: []const u8,
    // Removed email since the query only selects id and username

    pub fn deinit(self: User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
    }
};

test "prepare and execute" {
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
    try conn.connect();

    var query = Query.init(allocator, &conn);
    defer query.deinit();

    try query.prepare("user_all", "SELECT id, username FROM Users", User);
    const rows = try query.execute(User, "user_all", null);
    if (rows) |result_rows| {
        defer allocator.free(result_rows);
        for (result_rows) |user| {
            defer user.deinit(allocator);
            std.debug.print("User: id={d}, username={s}\n", .{ user.id, user.username });
        }
    } else {
        std.debug.print("No rows returned\n", .{});
    }
}
