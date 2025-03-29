const std = @import("std");
const zpg = @import("zpg");
const Connection = zpg.Connection;

test "Connection initialization failure with invalid host" {
    const allocator = std.testing.allocator;
    const config = zpg.Config{
        .host = "invalid_host",
        .port = 5432,
        .username = "postgres",
        .database = "test",
        .password = "postgres", // Match your server setup
        .tls_mode = .disable,
    };

    const conn = Connection.init(allocator, config);
    //defer conn.deinit();

    try std.testing.expectError(error.TemporaryNameServerFailure, conn);
}

test "Connection success" {
    const allocator = std.testing.allocator;
    const config = zpg.Config{
        .host = "127.0.0.1",
        .port = 5432,
        .username = "postgres",
        .database = "postgres",
        .password = "postgres",
        .tls_mode = .disable,
    };

    var conn = try Connection.init(allocator, config);
    defer conn.deinit();
    try conn.connect();

    if (conn.state == .Connected) {
        try std.testing.expect(conn.stream.handle != -1);
    }
}

test "Connection failure with wrong password" {
    const allocator = std.testing.allocator;
    const config = zpg.Config{
        .host = "127.0.0.1",
        .port = 5432,
        .username = "postgres",
        .database = "zui",
        .password = "wrongpassword",
        .tls_mode = .disable,
    };

    var conn = try Connection.init(allocator, config);
    defer conn.deinit();

    try std.testing.expectError(error.AuthenticationFailed, conn.connect());
}
