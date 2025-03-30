const std = @import("std");
const zpg = @import("zpg");

const UuidTest = struct {
    id: zpg.field.Serial,
    uuid_col: zpg.field.Uuid,

    pub fn deinit(self: UuidTest, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

test "uuid test" {
    const allocator = std.testing.allocator;
    var pool = try zpg.ConnectionPool.init(allocator, zpg.Config{
        .host = "127.0.0.1",
        .port = 5432,
        .username = "postgres",
        .database = "zui",
        .password = "postgres",
        .tls_mode = .disable,
    }, 3);
    defer pool.deinit();

    var pooled_conn = try zpg.PooledConnection.init(&pool, null);
    defer pooled_conn.deinit();

    var query = pooled_conn.createQuery(allocator);
    defer query.deinit();

    _ = try query.run("DROP TABLE IF EXISTS uuid_test", zpg.types.Empty);
    _ = try query.run(
        \\CREATE TABLE uuid_test (
        \\    id SERIAL PRIMARY KEY,
        \\    uuid_col UUID
        \\)
    , zpg.types.Empty);

    const insert_params = &[_]zpg.Param{
        // UUID with hyphens
        zpg.Param.string("550e8400-e29b-41d4-a716-446655440000"),
        // UUID without hyphens
        zpg.Param.string("1234567890abcdef1234567890abcdef"),
    };

    _ = try query.prepare("insert_data", "INSERT INTO uuid_test (uuid_col) VALUES ($1), ($2)");
    _ = try query.execute("insert_data", insert_params, zpg.types.Empty);

    const results = try query.run("SELECT * FROM uuid_test ORDER BY id", UuidTest);

    switch (results) {
        .select => |rows| {
            defer {
                for (rows) |item| item.deinit(allocator);
                allocator.free(rows);
            }

            try std.testing.expectEqual(@as(usize, 2), rows.len);

            // Row 1: UUID with hyphens "550e8400-e29b-41d4-a716-446655440000"
            const row1 = rows[0];
            try std.testing.expectEqualSlices(u8, &[_]u8{
                0x55, 0x0e, 0x84, 0x00, // 550e8400
                0xe2, 0x9b, // e29b
                0x41, 0xd4, // 41d4
                0xa7, 0x16, // a716
                0x44, 0x66,
                0x55, 0x44,
                0x00, 0x00, // 446655440000
            }, &row1.uuid_col.bytes);

            // Row 2: UUID without hyphens "1234567890abcdef1234567890abcdef"
            const row2 = rows[1];
            try std.testing.expectEqualSlices(u8, &[_]u8{
                0x12, 0x34, 0x56, 0x78, // 12345678
                0x90, 0xab, // 90ab
                0xcd, 0xef, // cdef
                0x12, 0x34, 0x56, 0x78, // 12345678
                0x90, 0xab, 0xcd, 0xef, // 90abcdef
            }, &row2.uuid_col.bytes);

            // Test toString for row1
            const uuid_str = try row1.uuid_col.toString(allocator);
            defer allocator.free(uuid_str);
            try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", uuid_str);

            // Test toString for row2
            const uuid_str2 = try row2.uuid_col.toString(allocator);
            defer allocator.free(uuid_str2);
            try std.testing.expectEqualStrings("12345678-90ab-cdef-1234-567890abcdef", uuid_str2);
        },
        else => unreachable,
    }
}
