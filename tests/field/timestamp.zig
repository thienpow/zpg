const std = @import("std");
const zpg = @import("zpg");

const TimestampTest = struct {
    id: zpg.field.Serial,
    timestamp_col: zpg.field.Timestamp,

    pub fn deinit(self: TimestampTest, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

test "timestamp test" {
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

    var pooled_conn = try zpg.PooledConnection.init(&pool);
    defer pooled_conn.deinit();

    var query = pooled_conn.createQuery(allocator);
    defer query.deinit();

    _ = try query.run("DROP TABLE IF EXISTS timestamp_test", zpg.types.Empty);
    _ = try query.run(
        \\CREATE TABLE timestamp_test (
        \\    id SERIAL PRIMARY KEY,
        \\    timestamp_col TIMESTAMP
        \\)
    , zpg.types.Empty);

    const insert_params = &[_]zpg.Param{
        zpg.Param.string("0001-05-15 14:30:45.123456+00 BC"), // 1 BC, May 15
        zpg.Param.string("0001-01-01 00:00:00+00"), // 1 AD, Jan 1
        zpg.Param.string("0001-02-29 00:00:00+00 BC"), // 1 BC, Feb 29 (leap year)
        zpg.Param.string("2023-05-15 14:30:45.123456+00"), // Modern date
        zpg.Param.string("3000-12-31 23:59:59+00"), // Far future
        zpg.Param.string("0005-02-29 00:00:00+00 BC"), // 5 BC, Feb 29 (leap year)
        zpg.Param.string("4713-01-01 00:00:00+00 BC"), // 4713 BC, near PostgreSQL min
    };

    _ = try query.prepare("insert_data", "INSERT INTO timestamp_test (timestamp_col) VALUES ($1), ($2), ($3), ($4), ($5), ($6), ($7)");
    _ = try query.execute("insert_data", insert_params, zpg.types.Empty);

    const results = try query.run("SELECT * FROM timestamp_test ORDER BY id", TimestampTest);

    switch (results) {
        .select => |rows| {
            defer {
                for (rows) |item| item.deinit(allocator);
                allocator.free(rows);
            }

            try std.testing.expectEqual(@as(usize, 7), rows.len); // Updated to 7 rows

            // 1 BC: May 15, 14:30:45.123456
            const bc_ts = rows[0].timestamp_col;
            const bc_expected = try zpg.field.Timestamp.toUnixSeconds(-1, 5, 15, 14, 30, 45);
            try std.testing.expectEqual(bc_expected, bc_ts.seconds);
            try std.testing.expectEqual(@as(u32, 123456000), bc_ts.nano_seconds);

            // 1 AD: January 1, 00:00:00
            const ad_ts = rows[1].timestamp_col;
            const ad_expected = try zpg.field.Timestamp.toUnixSeconds(1, 1, 1, 0, 0, 0);
            try std.testing.expectEqual(ad_expected, ad_ts.seconds);
            try std.testing.expectEqual(@as(u32, 0), ad_ts.nano_seconds);

            // 1 BC: February 29, 00:00:00 (leap year)
            const leap_bc_ts = rows[2].timestamp_col;
            const leap_bc_expected = try zpg.field.Timestamp.toUnixSeconds(-1, 2, 29, 0, 0, 0);
            try std.testing.expectEqual(leap_bc_expected, leap_bc_ts.seconds);
            try std.testing.expectEqual(@as(u32, 0), leap_bc_ts.nano_seconds);

            // 2023 AD: May 15, 14:30:45.123456
            const modern_ts = rows[3].timestamp_col;
            const modern_expected = try zpg.field.Timestamp.toUnixSeconds(2023, 5, 15, 14, 30, 45);
            try std.testing.expectEqual(modern_expected, modern_ts.seconds);
            try std.testing.expectEqual(@as(u32, 123456000), modern_ts.nano_seconds);

            // 3000 AD: December 31, 23:59:59
            const future_ts = rows[4].timestamp_col;
            const future_expected = try zpg.field.Timestamp.toUnixSeconds(3000, 12, 31, 23, 59, 59);
            try std.testing.expectEqual(future_expected, future_ts.seconds);
            try std.testing.expectEqual(@as(u32, 0), future_ts.nano_seconds);

            // 5 BC: February 29, 00:00:00 (leap year)
            const leap_5bc_ts = rows[5].timestamp_col;
            const leap_5bc_expected = try zpg.field.Timestamp.toUnixSeconds(-5, 2, 29, 0, 0, 0);
            try std.testing.expectEqual(leap_5bc_expected, leap_5bc_ts.seconds);
            try std.testing.expectEqual(@as(u32, 0), leap_5bc_ts.nano_seconds);

            // 4713 BC: January 1, 00:00:00 (near PostgreSQL min)
            const far_bc_ts = rows[6].timestamp_col;
            const far_bc_expected = try zpg.field.Timestamp.toUnixSeconds(-4713, 1, 1, 0, 0, 0);
            try std.testing.expectEqual(far_bc_expected, far_bc_ts.seconds);
            try std.testing.expectEqual(@as(u32, 0), far_bc_ts.nano_seconds);
        },
        else => unreachable,
    }
}
