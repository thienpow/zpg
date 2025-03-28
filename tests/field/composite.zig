const std = @import("std");
const zpg = @import("zpg");
const Composite = zpg.field.Composite;

test "composite type parsing and serialization" {
    const allocator = std.testing.allocator;

    // Initialize connection pool
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

    // Define the composite type structure
    const MyCompositeFields = struct {
        name: []const u8,
        age: i32,
        is_active: bool,
        nickname: ?[]const u8,

        pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
            alloc.free(self.name);
            if (self.nickname) |nick| alloc.free(nick);
        }
    };
    const MyComposite = Composite(MyCompositeFields);

    // Create the composite type first
    _ = try query.run(
        \\CREATE TYPE mycompositefields AS (
        \\    name TEXT,
        \\    age INT,
        \\    is_active BOOLEAN,
        \\    nickname TEXT
        \\)
    , zpg.types.Empty);

    // Setup database
    _ = try query.run("DROP TABLE IF EXISTS composite_test", zpg.types.Empty);
    _ = try query.run(
        \\CREATE TABLE composite_test (
        \\    id SERIAL PRIMARY KEY,
        \\    data mycompositefields
        \\)
    , zpg.types.Empty);

    // Insert test data
    const insert_params = &[_]zpg.Param{
        zpg.Param.string("(alice,25,t,bob)"), // Full composite
        zpg.Param.string("(eve,30,f,)"), // Null nickname
    };

    _ = try query.prepare("insert_data AS INSERT INTO composite_test (data) VALUES ($1::mycompositefields), ($2::mycompositefields)");
    _ = try query.execute("insert_data", insert_params, zpg.types.Empty);

    // Define result struct for SELECT
    const CompositeTest = struct {
        id: zpg.field.Serial,
        data: MyComposite,

        pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
            self.data.deinit(alloc);
        }
    };

    // Fetch and test results
    const results = try query.run("SELECT * FROM composite_test ORDER BY id", CompositeTest);

    switch (results) {
        .select => |rows| {
            defer {
                for (rows) |item| item.deinit(allocator);
                allocator.free(rows);
            }

            try std.testing.expectEqual(@as(usize, 2), rows.len);

            // Row 1: "(alice,25,t,bob)"
            const row1 = rows[0];
            try std.testing.expectEqualStrings("alice", row1.data.fields.name);
            try std.testing.expectEqual(@as(i32, 25), row1.data.fields.age);
            try std.testing.expectEqual(true, row1.data.fields.is_active);
            try std.testing.expect(row1.data.fields.nickname != null);
            try std.testing.expectEqualStrings("bob", row1.data.fields.nickname.?);

            const output1 = try row1.data.toString(allocator);
            defer allocator.free(output1);
            try std.testing.expectEqualStrings("(alice,25,t,bob)", output1);

            // Row 2: "(eve,30,f,)"
            const row2 = rows[1];
            try std.testing.expectEqualStrings("eve", row2.data.fields.name);
            try std.testing.expectEqual(@as(i32, 30), row2.data.fields.age);
            try std.testing.expectEqual(false, row2.data.fields.is_active);
            try std.testing.expectEqual(@as(?[]const u8, null), row2.data.fields.nickname);

            const output2 = try row2.data.toString(allocator);
            defer allocator.free(output2);
            try std.testing.expectEqualStrings("(eve,30,f)", output2);
        },
        else => unreachable,
    }

    // Cleanup - optional, but good practice in tests
    _ = try query.run("DROP TABLE composite_test", zpg.types.Empty);
    _ = try query.run("DROP TYPE mycompositefields", zpg.types.Empty);
}
