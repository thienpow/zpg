const std = @import("std");
const zpg = @import("zpg");

const BitTest = struct {
    id: zpg.field.Serial,
    bit_col: zpg.field.Bit10, // Use specific type
    varbit_col: zpg.field.VarBit16, // Use specific type

    pub fn deinit(self: BitTest, allocator: std.mem.Allocator) void {
        self.bit_col.deinit(allocator);
        self.varbit_col.deinit(allocator);
    }
};

test "bit and varbit test" {
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

    _ = try query.run("DROP TABLE IF EXISTS bit_test", zpg.types.Empty);
    _ = try query.run(
        \\CREATE TABLE bit_test (
        \\    id SERIAL PRIMARY KEY,
        \\    bit_col BIT(10),
        \\    varbit_col BIT VARYING(16)
        \\)
    , zpg.types.Empty);

    const insert_params = &[_]zpg.Param{
        zpg.Param.string("1010101010"), // BIT(10)
        zpg.Param.string("1111000011"), // BIT(10)
        zpg.Param.string("1100"), // BIT VARYING(16)
        zpg.Param.string("1010101010101010"), // BIT VARYING(16)
    };

    _ = try query.prepare("insert_data", "INSERT INTO bit_test (bit_col, varbit_col) VALUES ($1, $3), ($2, $4)");
    _ = try query.execute("insert_data", insert_params, zpg.types.Empty);

    const results = try query.run("SELECT * FROM bit_test ORDER BY id", BitTest);

    switch (results) {
        .select => |rows| {
            defer {
                for (rows) |item| item.deinit(allocator);
                allocator.free(rows);
            }

            try std.testing.expectEqual(@as(usize, 2), rows.len);

            // Row 1
            const row1 = rows[0];

            // BIT(10): "1010101010"
            try std.testing.expectEqual(@as(usize, 10), row1.bit_col.length);
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0b10101010, 0b10000000 }, row1.bit_col.bits);
            const bit1_str = try row1.bit_col.toString(allocator);
            defer allocator.free(bit1_str);
            try std.testing.expectEqualStrings("1010101010", bit1_str);

            // BIT VARYING(16): "1100"
            try std.testing.expectEqual(@as(usize, 4), row1.varbit_col.length);
            try std.testing.expectEqual(@as(usize, 16), row1.varbit_col.max_length);
            try std.testing.expectEqualSlices(u8, &[_]u8{0b11000000}, row1.varbit_col.bits);
            const varbit1_str = try row1.varbit_col.toString(allocator);
            defer allocator.free(varbit1_str);
            try std.testing.expectEqualStrings("1100", varbit1_str);

            // Row 2
            const row2 = rows[1];

            // BIT(10): "1111000011"
            try std.testing.expectEqual(@as(usize, 10), row2.bit_col.length);
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0b11110000, 0b11000000 }, row2.bit_col.bits);
            const bit2_str = try row2.bit_col.toString(allocator);
            defer allocator.free(bit2_str);
            try std.testing.expectEqualStrings("1111000011", bit2_str);

            // BIT VARYING(16): "1010101010101010"
            try std.testing.expectEqual(@as(usize, 16), row2.varbit_col.length);
            try std.testing.expectEqual(@as(usize, 16), row2.varbit_col.max_length);
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0b10101010, 0b10101010 }, row2.varbit_col.bits);
            const varbit2_str = try row2.varbit_col.toString(allocator);
            defer allocator.free(varbit2_str);
            try std.testing.expectEqualStrings("1010101010101010", varbit2_str);
        },
        else => unreachable,
    }
}
