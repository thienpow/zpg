const std = @import("std");
const zpg = @import("zpg");

test "json and jsonb type handling" {
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

    _ = try query.run("DROP TABLE IF EXISTS json_test", zpg.types.Empty);
    _ = try query.run(
        \\CREATE TABLE json_test (
        \\    id SERIAL PRIMARY KEY,
        \\    json_data JSON,
        \\    jsonb_data JSONB
        \\)
    , zpg.types.Empty);

    const JsonTest = struct {
        id: zpg.field.Serial,
        json_data: zpg.field.JSON,
        jsonb_data: zpg.field.JSONB,

        pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
            self.json_data.deinit(alloc);
            self.jsonb_data.deinit(alloc);
        }
    };

    const insert_params = &[_]zpg.Param{
        zpg.Param.string("{\"name\": \"Alice\", \"age\": 25, \"active\": true}"),
        zpg.Param.string("{\"age\": 30, \"name\": \"Bob\", \"active\": false}"),
    };

    _ = try query.prepare("insert_data", "INSERT INTO json_test (json_data, jsonb_data) VALUES ($1::json, $2::jsonb)");
    _ = try query.execute("insert_data", insert_params, zpg.types.Empty);

    const results = try query.run("SELECT * FROM json_test ORDER BY id", JsonTest);

    switch (results) {
        .select => |rows| {
            defer {
                for (rows) |item| item.deinit(allocator);
                allocator.free(rows);
            }

            try std.testing.expectEqual(@as(usize, 1), rows.len);

            const row = rows[0];

            // Test JSON field (exact string match since JSON preserves order)
            const json_str = try row.json_data.toString(allocator);
            defer allocator.free(json_str);
            try std.testing.expectEqualStrings("{\"name\": \"Alice\", \"age\": 25, \"active\": true}", json_str);

            // Parse JSON to verify contents
            const JsonStruct = struct {
                name: []const u8,
                age: i32,
                active: bool,
            };
            const json_parsed = try std.json.parseFromSlice(JsonStruct, allocator, row.json_data.data, .{ .allocate = .alloc_always });
            defer json_parsed.deinit();
            try std.testing.expectEqualStrings("Alice", json_parsed.value.name);
            try std.testing.expectEqual(@as(i32, 25), json_parsed.value.age);
            try std.testing.expectEqual(true, json_parsed.value.active);

            // Test JSONB field (check parsed values instead of exact string)
            const jsonb_str = try row.jsonb_data.toString(allocator);
            defer allocator.free(jsonb_str);

            const jsonb_parsed = try std.json.parseFromSlice(JsonStruct, allocator, row.jsonb_data.data, .{ .allocate = .alloc_always });
            defer jsonb_parsed.deinit();
            try std.testing.expectEqualStrings("Bob", jsonb_parsed.value.name);
            try std.testing.expectEqual(@as(i32, 30), jsonb_parsed.value.age);
            try std.testing.expectEqual(false, jsonb_parsed.value.active);

            // Optional: Verify it's valid JSONB by ensuring it parses, but don't check exact string
            try std.testing.expect(jsonb_str.len > 0); // Basic sanity check
        },
        else => unreachable,
    }

    _ = try query.run("DROP TABLE json_test", zpg.types.Empty);
}
