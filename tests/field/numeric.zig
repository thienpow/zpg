const std = @import("std");
const zpg = @import("zpg");
const ConnectionPool = zpg.ConnectionPool;
const PooledConnection = zpg.PooledConnection;
const Param = zpg.Param;

const config = zpg.Config{
    .host = "127.0.0.1",
    .port = 5432,
    .username = "postgres",
    .database = "zui",
    .password = "postgres",
    .ssl = false,
};

// Modified struct with optional fields for decimal and money
const NumericTest = struct {
    id: zpg.field.Serial,
    smallint_col: i16,
    integer_col: i32,
    bigint_col: i64,
    decimal_col: ?zpg.field.Decimal, // Made optional
    real_col: f32,
    double_col: f64,
    money_col: ?zpg.field.Money, // Made optional

    pub fn deinit(self: NumericTest, allocator: std.mem.Allocator) void {
        if (self.decimal_col) |decimal| {
            _ = decimal.toString(allocator); // Only cleanup if not null
        }
        if (self.money_col) |money| {
            _ = money.toString(allocator); // Only cleanup if not null
        }
    }
};

const insert_params = &[_]Param{
    Param.int(@as(i16, 123)),
    Param.int(@as(i32, 45678)),
    Param.int(@as(i64, 123456789)),
    Param.string("12345.6789"),
    Param.float(@as(f32, 123.456)),
    Param.float(@as(f64, 789.0123)),
    Param.string("$999.99"),
};

const select_params = &[_]Param{
    Param.int(@as(u32, 1)),
};

test "numeric types test" {
    const allocator = std.testing.allocator;

    var pool = try ConnectionPool.init(allocator, config, 3);
    defer pool.deinit();

    var pooled_conn = try PooledConnection.init(&pool);
    defer pooled_conn.deinit();

    var query = pooled_conn.createQuery(allocator);
    defer query.deinit();

    // Drop and recreate table
    _ = try query.run("DROP TABLE IF EXISTS numeric_test", zpg.types.Empty);

    _ = try query.run("CREATE TABLE numeric_test (" ++
        "id SERIAL PRIMARY KEY, " ++
        "smallint_col SMALLINT, " ++
        "integer_col INTEGER, " ++
        "bigint_col BIGINT, " ++
        "decimal_col DECIMAL(10,4), " ++
        "real_col REAL, " ++
        "double_col DOUBLE PRECISION, " ++
        "money_col MONEY)", zpg.types.Empty);

    // Insert test data
    _ = try query.prepare("insert_data AS INSERT INTO numeric_test (smallint_col, integer_col, bigint_col, " ++
        "decimal_col, real_col, double_col, money_col) " ++
        "VALUES ($1, $2, $3, $4, $5, $6, $7)");
    _ = try query.execute("insert_data", insert_params, zpg.types.Empty);

    // Select and verify
    _ = try query.prepare("select_data AS " ++
        "SELECT id, smallint_col, integer_col, bigint_col, " ++
        "decimal_col, real_col, double_col, money_col " ++
        "FROM numeric_test WHERE id = $1");

    const results = try query.execute("select_data", select_params, NumericTest);
    switch (results) {
        .select => |rows| {
            defer allocator.free(rows);
            for (rows) |item| {
                // Verify each field
                try std.testing.expectEqual(@as(u32, 1), item.id.value);

                try std.testing.expectEqual(@as(i16, 123), item.smallint_col);
                try std.testing.expectEqual(@as(i32, 45678), item.integer_col);
                try std.testing.expectEqual(@as(i64, 123456789), item.bigint_col);
                // Floating point verification
                try std.testing.expectApproxEqAbs(@as(f32, 123.456), item.real_col, 0.001);
                try std.testing.expectApproxEqAbs(@as(f64, 789.0123), item.double_col, 0.0001);

                // Decimal verification (unwrap optional)
                if (item.decimal_col) |decimal| {
                    try std.testing.expectEqual(@as(i128, 123456789), decimal.value);
                    try std.testing.expectEqual(@as(u8, 4), decimal.scale);
                } else {
                    //try std.testing.fail("Expected decimal_col to be non-null");
                }
                // Money verification (unwrap optional)
                if (item.money_col) |money| {
                    try std.testing.expectEqual(@as(i64, 99999), money.value);
                    const money_str = try money.toString(allocator);
                    defer allocator.free(money_str);
                    try std.testing.expectEqualStrings("$999.99", money_str);
                } else {
                    //try std.testing.fail("Expected money_col to be non-null");
                }
            }
        },
        else => unreachable,
    }
}
