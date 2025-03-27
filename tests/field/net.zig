const std = @import("std");
const zpg = @import("zpg");

const NetworkTest = struct {
    id: zpg.field.Serial,
    cidr_col: zpg.field.CIDR,
    inet_col: zpg.field.Inet,
    mac_col: zpg.field.MACAddress,
    mac8_col: zpg.field.MACAddress8,

    pub fn deinit(self: NetworkTest, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

test "network types test" {
    const allocator = std.testing.allocator;
    var pool = try zpg.ConnectionPool.init(allocator, zpg.Config{
        .host = "127.0.0.1",
        .port = 5432,
        .username = "postgres",
        .database = "zui",
        .password = "postgres",
        .ssl = false,
    }, 3);
    defer pool.deinit();

    var pooled_conn = try zpg.PooledConnection.init(&pool);
    defer pooled_conn.deinit();

    var query = pooled_conn.createQuery(allocator);
    defer query.deinit();

    _ = try query.run("DROP TABLE IF EXISTS network_test", zpg.types.Empty);
    _ = try query.run(
        \\CREATE TABLE network_test (
        \\    id SERIAL PRIMARY KEY,
        \\    cidr_col CIDR,
        \\    inet_col INET,
        \\    mac_col MACADDR,
        \\    mac8_col MACADDR8
        \\)
    , zpg.types.Empty);

    const insert_params = &[_]zpg.Param{
        // CIDR values
        zpg.Param.string("192.168.1.0/24"),
        zpg.Param.string("2001:db8::/32"),
        // INET values
        zpg.Param.string("192.168.1.5/24"),
        zpg.Param.string("2001:db8::1"),
        // MACADDR values
        zpg.Param.string("08:00:2b:01:02:03"),
        zpg.Param.string("00:11:22:33:44:55"),
        // MACADDR8 values
        zpg.Param.string("08:00:2b:ff:fe:01:02:03"),
        zpg.Param.string("00:11:22:ff:fe:33:44:55"),
    };

    _ = try query.prepare("insert_data AS INSERT INTO network_test (cidr_col, inet_col, mac_col, mac8_col) VALUES ($1, $3, $5, $7), ($2, $4, $6, $8)");
    _ = try query.execute("insert_data", insert_params, zpg.types.Empty);

    const results = try query.run("SELECT * FROM network_test ORDER BY id", NetworkTest);

    switch (results) {
        .select => |rows| {
            defer {
                for (rows) |item| item.deinit(allocator);
                allocator.free(rows);
            }

            try std.testing.expectEqual(@as(usize, 2), rows.len);

            // Row 1 tests
            const row1 = rows[0];

            // CIDR: 192.168.1.0/24
            try std.testing.expectEqual(false, row1.cidr_col.is_ipv6);
            try std.testing.expectEqual(@as(u8, 24), row1.cidr_col.mask);
            try std.testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &row1.cidr_col.address);

            // INET: 192.168.1.5/24
            try std.testing.expectEqual(false, row1.inet_col.is_ipv6);
            try std.testing.expectEqual(@as(u8, 24), row1.inet_col.mask);
            try std.testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &row1.inet_col.address);

            // MACADDR: 08:00:2b:01:02:03
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x00, 0x2b, 0x01, 0x02, 0x03 }, &row1.mac_col.bytes);

            // MACADDR8: 08:00:2b:ff:fe:01:02:03
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x00, 0x2b, 0xff, 0xfe, 0x01, 0x02, 0x03 }, &row1.mac8_col.bytes);

            // Row 2 tests
            const row2 = rows[1];

            // CIDR: 2001:db8::/32
            try std.testing.expectEqual(true, row2.cidr_col.is_ipv6);
            try std.testing.expectEqual(@as(u8, 32), row2.cidr_col.mask);
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, &row2.cidr_col.address);

            // INET: 2001:db8::1 (no mask specified, should be 255)
            try std.testing.expectEqual(true, row2.inet_col.is_ipv6);
            try std.testing.expectEqual(@as(u8, 255), row2.inet_col.mask);
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 }, &row2.inet_col.address);

            // MACADDR: 00:11:22:33:44:55
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 }, &row2.mac_col.bytes);

            // MACADDR8: 00:11:22:ff:fe:33:44:55
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x11, 0x22, 0xff, 0xfe, 0x33, 0x44, 0x55 }, &row2.mac8_col.bytes);
        },
        else => unreachable,
    }
}
