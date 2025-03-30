const std = @import("std");
const zpg = @import("zpg");

const DateTimeTest = struct {
    id: zpg.field.Serial,
    date_col: zpg.field.Date,
    time_col: zpg.field.Time,

    pub fn deinit(self: DateTimeTest, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

test "date and time test" {
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

    _ = try query.run("DROP TABLE IF EXISTS date_time_test", zpg.types.Empty);
    _ = try query.run(
        \\CREATE TABLE date_time_test (
        \\    id SERIAL PRIMARY KEY,
        \\    date_col DATE,
        \\    time_col TIME
        \\)
    , zpg.types.Empty);

    const insert_params = &[_]zpg.Param{
        // Date params
        zpg.Param.string("2023-05-15"), // Modern date
        zpg.Param.string("0001-01-01"), // Earliest AD date
        zpg.Param.string("9999-12-31"), // Latest date
        zpg.Param.string("2020-02-29"), // Leap year date
        // Time params (paired with above dates)
        zpg.Param.string("14:30:45.123456"), // Time with microseconds
        zpg.Param.string("00:00:00"), // Midnight
        zpg.Param.string("23:59:59"), // Last second of day
        zpg.Param.string("12:00:00.5"), // Time with half second
    };

    _ = try query.prepare("insert_data", "INSERT INTO date_time_test (date_col, time_col) VALUES ($1, $5), ($2, $6), ($3, $7), ($4, $8)");
    _ = try query.execute("insert_data", insert_params, zpg.types.Empty);

    const results = try query.run("SELECT * FROM date_time_test ORDER BY id", DateTimeTest);

    switch (results) {
        .select => |rows| {
            defer {
                for (rows) |item| item.deinit(allocator);
                allocator.free(rows);
            }

            try std.testing.expectEqual(@as(usize, 4), rows.len);

            // Test 1: 2023-05-15 14:30:45.123456
            const modern = rows[0];
            try std.testing.expectEqual(@as(i16, 2023), modern.date_col.year);
            try std.testing.expectEqual(@as(u8, 5), modern.date_col.month);
            try std.testing.expectEqual(@as(u8, 15), modern.date_col.day);
            try std.testing.expectEqual(@as(u8, 14), modern.time_col.hours);
            try std.testing.expectEqual(@as(u8, 30), modern.time_col.minutes);
            try std.testing.expectEqual(@as(u8, 45), modern.time_col.seconds);
            try std.testing.expectEqual(@as(u32, 123456000), modern.time_col.nano_seconds);

            // Test 2: 0001-01-01 00:00:00
            const earliest = rows[1];
            try std.testing.expectEqual(@as(i16, 1), earliest.date_col.year);
            try std.testing.expectEqual(@as(u8, 1), earliest.date_col.month);
            try std.testing.expectEqual(@as(u8, 1), earliest.date_col.day);
            try std.testing.expectEqual(@as(u8, 0), earliest.time_col.hours);
            try std.testing.expectEqual(@as(u8, 0), earliest.time_col.minutes);
            try std.testing.expectEqual(@as(u8, 0), earliest.time_col.seconds);
            try std.testing.expectEqual(@as(u32, 0), earliest.time_col.nano_seconds);

            // Test 3: 9999-12-31 23:59:59
            const latest = rows[2];
            try std.testing.expectEqual(@as(i16, 9999), latest.date_col.year);
            try std.testing.expectEqual(@as(u8, 12), latest.date_col.month);
            try std.testing.expectEqual(@as(u8, 31), latest.date_col.day);
            try std.testing.expectEqual(@as(u8, 23), latest.time_col.hours);
            try std.testing.expectEqual(@as(u8, 59), latest.time_col.minutes);
            try std.testing.expectEqual(@as(u8, 59), latest.time_col.seconds);
            try std.testing.expectEqual(@as(u32, 0), latest.time_col.nano_seconds);

            // Test 4: 2020-02-29 12:00:00.5
            const leap = rows[3];
            try std.testing.expectEqual(@as(i16, 2020), leap.date_col.year);
            try std.testing.expectEqual(@as(u8, 2), leap.date_col.month);
            try std.testing.expectEqual(@as(u8, 29), leap.date_col.day);
            try std.testing.expectEqual(@as(u8, 12), leap.time_col.hours);
            try std.testing.expectEqual(@as(u8, 0), leap.time_col.minutes);
            try std.testing.expectEqual(@as(u8, 0), leap.time_col.seconds);
            try std.testing.expectEqual(@as(u32, 500000000), leap.time_col.nano_seconds);
        },
        else => unreachable,
    }
}
