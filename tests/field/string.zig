const std = @import("std");
const zpg = @import("zpg");
const ConnectionPool = zpg.ConnectionPool;
const PooledConnection = zpg.PooledConnection;
const Param = zpg.Param;
const CHAR = zpg.field.CHAR;
const VARCHAR = zpg.field.VARCHAR;

const config = zpg.Config{
    .host = "127.0.0.1",
    .port = 5432,
    .username = "postgres",
    .database = "zui",
    .password = "postgres",
    .ssl = false,
};

// Modified struct with optional fields for decimal and money
const StringTest = struct {
    id: zpg.field.Serial,
    text_col: []const u8,
    char_col: CHAR(5),
    varchar_col: VARCHAR(20),

    pub fn init(allocator: std.mem.Allocator) !StringTest {
        return StringTest{ .id = .{ .value = 0 }, .text_col = try allocator.dupe(u8, ""), .char_col = .{ .value = "     " }, .varchar_col = .{ .value = try allocator.dupe(u8, "") } };
    }

    pub fn deinit(self: StringTest, allocator: std.mem.Allocator) void {
        allocator.free(self.text_col);
        allocator.free(self.varchar_col.value);
    }
};

test "string types test" {
    const allocator = std.testing.allocator;
    var pool = try ConnectionPool.init(allocator, config, 3);
    defer pool.deinit();

    var pooled_conn = try PooledConnection.init(&pool);
    defer pooled_conn.deinit();

    var query = pooled_conn.createQuery(allocator);
    defer query.deinit();

    // Drop and recreate table with explicit type specifications
    _ = try query.run("DROP TABLE IF EXISTS string_test", zpg.types.Empty);
    _ = try query.run(
        \\CREATE TABLE string_test (
        \\    id SERIAL PRIMARY KEY,
        \\    text_col TEXT,
        \\    char_col CHAR(5),
        \\    varchar_col VARCHAR(20)
        \\)
    , zpg.types.Empty);

    // Insert test data with explicit type casting
    const insert_params = &[_]Param{ Param.string("This is a text column"), Param.string("abc"), Param.string("Hello VARCHAR") };

    _ = try query.prepare("insert_data AS INSERT INTO string_test (text_col, char_col, varchar_col) VALUES ($1, $2, $3)");
    _ = try query.execute("insert_data", insert_params, zpg.types.Empty);

    // Select with explicit type specification
    const select_params = &[_]Param{Param.int(@as(u32, 1))};

    _ = try query.prepare("select_data AS SELECT * FROM string_test WHERE id = $1");
    const results = try query.execute("select_data", select_params, StringTest);

    switch (results) {
        .select => |rows| {
            defer {
                for (rows) |item| item.deinit(allocator);
                allocator.free(rows);
            }

            if (rows.len == 0) {
                std.debug.print("No rows returned from query\n", .{});
                return error.NoRowsReturned;
            }

            for (rows) |item| {

                // Detailed VARCHAR diagnostics
                std.debug.print("VARCHAR raw value length: {}\n", .{item.varchar_col.value.len});
                std.debug.print("VARCHAR raw value hex: ", .{});
                for (item.varchar_col.value) |byte| {
                    std.debug.print("{x} ", .{byte});
                }
                std.debug.print("\n", .{});

                // Print type information
                std.debug.print("VARCHAR type info: {s}\n", .{@typeName(@TypeOf(item.varchar_col))});

                try std.testing.expectEqual(@as(u32, 1), item.id.value);
                try std.testing.expectEqualStrings("This is a text column", item.text_col);
                try std.testing.expectEqualStrings("abc  ", &item.char_col);
                try std.testing.expectEqualStrings("Hello VARCHAR", item.varchar_col.value);
            }
        },
        else => unreachable,
    }
}
