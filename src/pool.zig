const std = @import("std");
const Connection = @import("connection.zig").Connection;
const Error = @import("connection.zig").Error;
const query = @import("query.zig").query;

pub const ConnectionPool = struct {
    connections: []Connection,
    allocator: std.mem.Allocator,
    available: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator, config: @import("zpg.zig").Config, size: usize) !ConnectionPool {
        var connections = try allocator.alloc(Connection, size);
        var available = std.ArrayList(usize).init(allocator);

        for (0..size) |i| {
            connections[i] = try Connection.init(allocator, config);
            try available.append(i);
        }

        return .{
            .connections = connections,
            .allocator = allocator,
            .available = available,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        for (self.connections) |*conn| conn.deinit();
        self.allocator.free(self.connections);
        self.available.deinit();
    }

    pub fn get(self: *ConnectionPool) !*Connection {
        if (self.available.popOrNull()) |index| {
            return &self.connections[index];
        }
        return error.NoAvailableConnections;
    }

    pub fn release(self: *ConnectionPool, conn: *Connection) !void {
        for (self.connections, 0..) |c, i| {
            if (&c == conn) {
                try self.available.append(i);
                return;
            }
        }
        return error.ConnectionNotFound;
    }

    pub fn query(self: *ConnectionPool, query_str: []const u8) !void {
        var conn = try self.get();
        defer self.release(conn) catch |e| std.debug.print("Failed to release: {}\n", .{e});
        try query(conn, query_str);
    }
};

test "Pool query" {
    const allocator = std.testing.allocator;
    const config = @import("zpg.zig").Config{
        .host = "127.0.0.1",
        .port = 5432,
        .username = "postgres",
        .database = "zui",
        .password = "postgres",
        .ssl = false,
    };
    var pool = try ConnectionPool.init(allocator, config, 2);
    defer pool.deinit();

    try pool.query("SELECT 1");
}
