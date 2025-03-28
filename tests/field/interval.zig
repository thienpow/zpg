const std = @import("std");
const zpg = @import("zpg");

const IntervalTest = struct {
    id: zpg.field.Serial,
    interval_col: zpg.field.Interval,

    pub fn deinit(self: IntervalTest, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

test "interval test" {
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

    _ = try query.run("DROP TABLE IF EXISTS interval_test", zpg.types.Empty);
    _ = try query.run(
        \\CREATE TABLE interval_test (
        \\    id SERIAL PRIMARY KEY,
        \\    interval_col INTERVAL
        \\)
    , zpg.types.Empty);

    const insert_params = &[_]zpg.Param{
        zpg.Param.string("1 year 2 months 3 days 4 hours 5 minutes 6.789 seconds"),
        zpg.Param.string("6 months"),
        zpg.Param.string("15 days"),
        zpg.Param.string("2 hours 30 minutes"),
        zpg.Param.string("-1 year -6 months"),
        zpg.Param.string("0 seconds"),
    };

    _ = try query.prepare("insert_data AS INSERT INTO interval_test (interval_col) VALUES ($1), ($2), ($3), ($4), ($5), ($6)");
    _ = try query.execute("insert_data", insert_params, zpg.types.Empty);

    const results = try query.run("SELECT * FROM interval_test ORDER BY id", IntervalTest);

    switch (results) {
        .select => |rows| {
            defer {
                for (rows) |item| item.deinit(allocator);
                allocator.free(rows);
            }

            try std.testing.expectEqual(@as(usize, 6), rows.len);

            // Test 1: 1 year 2 months 3 days 4 hours 5 minutes 6.789 seconds
            const complex = rows[0].interval_col;
            try std.testing.expectEqual(@as(i32, 14), complex.months);
            try std.testing.expectEqual(@as(i32, 3), complex.days);
            try std.testing.expectEqual(@as(i64, (4 * 3600 + 5 * 60 + 6) * 1_000_000 + 789_000), complex.microseconds);

            // Test 2: 6 months
            const months = rows[1].interval_col;
            try std.testing.expectEqual(@as(i32, 6), months.months);
            try std.testing.expectEqual(@as(i32, 0), months.days);
            try std.testing.expectEqual(@as(i64, 0), months.microseconds);

            // Test 3: 15 days
            const days = rows[2].interval_col;
            try std.testing.expectEqual(@as(i32, 0), days.months);
            try std.testing.expectEqual(@as(i32, 15), days.days);
            try std.testing.expectEqual(@as(i64, 0), days.microseconds);

            // Test 4: 2 hours 30 minutes
            const time = rows[3].interval_col;
            try std.testing.expectEqual(@as(i32, 0), time.months);
            try std.testing.expectEqual(@as(i32, 0), time.days);
            try std.testing.expectEqual(@as(i64, (2 * 3600 + 30 * 60) * 1_000_000), time.microseconds);

            // Test 5: -1 year -6 months
            const negative = rows[4].interval_col;
            try std.testing.expectEqual(@as(i32, -18), negative.months); // -1 year = -12 months - 6 months
            try std.testing.expectEqual(@as(i32, 0), negative.days);
            try std.testing.expectEqual(@as(i64, 0), negative.microseconds);

            // Test 6: 0 seconds
            const zero = rows[5].interval_col;
            try std.testing.expectEqual(@as(i32, 0), zero.months);
            try std.testing.expectEqual(@as(i32, 0), zero.days);
            try std.testing.expectEqual(@as(i64, 0), zero.microseconds);
        },
        else => unreachable,
    }
}
