const std = @import("std");
const zpg = @import("zpg");

// Assuming these are defined in your zpg field types
const GeoTest = struct {
    id: zpg.field.Serial,
    point_col: zpg.field.Point,
    line_col: zpg.field.Line,
    lseg_col: zpg.field.LineSegment,
    box_col: zpg.field.Box,
    path_col: zpg.field.Path,
    polygon_col: zpg.field.Polygon,
    circle_col: zpg.field.Circle,

    pub fn deinit(self: GeoTest, allocator: std.mem.Allocator) void {
        self.path_col.deinit(allocator);
        self.polygon_col.deinit(allocator);
    }
};

test "geometric types test" {
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

    _ = try query.run("DROP TABLE IF EXISTS geo_test", zpg.types.Empty);
    _ = try query.run(
        \\CREATE TABLE geo_test (
        \\    id SERIAL PRIMARY KEY,
        \\    point_col POINT,
        \\    line_col LINE,
        \\    lseg_col LSEG,
        \\    box_col BOX,
        \\    path_col PATH,
        \\    polygon_col POLYGON,
        \\    circle_col CIRCLE
        \\)
    , zpg.types.Empty);

    const insert_params = &[_]zpg.Param{
        zpg.Param.string("(1.5,2.3)"),
        zpg.Param.string("{1,-1,0}"),
        zpg.Param.string("[(1,1),(2,2)]"),
        zpg.Param.string("(2,2),(0,0)"),
        zpg.Param.string("[(0,0),(1,1),(2,2)]"),
        zpg.Param.string("((0,0),(1,1),(2,0))"),
        zpg.Param.string("<(0,0),5>"),
    };

    _ = try query.prepare("insert_data", "INSERT INTO geo_test (point_col, line_col, lseg_col, box_col, path_col, polygon_col, circle_col) VALUES ($1, $2, $3, $4, $5, $6, $7)");
    _ = try query.execute("insert_data", insert_params, zpg.types.Empty);

    const results = try query.run("SELECT * FROM geo_test ORDER BY id", GeoTest);

    switch (results) {
        .select => |rows| {
            defer {
                for (rows) |item| item.deinit(allocator); // Free path_col and polygon_col
                allocator.free(rows); // Free the rows slice
            }

            try std.testing.expectEqual(@as(usize, 1), rows.len);
            const row = rows[0];

            // Debug values before assertions
            try std.testing.expectApproxEqAbs(1.5, row.point_col.x, 0.0001);
            try std.testing.expectApproxEqAbs(2.3, row.point_col.y, 0.0001);
            const point_str = try row.point_col.toString(allocator);
            defer allocator.free(point_str);
            try std.testing.expectEqualStrings("(1.5,2.3)", point_str);

            try std.testing.expectApproxEqAbs(1.0, row.line_col.a, 0.0001);
            try std.testing.expectApproxEqAbs(-1.0, row.line_col.b, 0.0001);
            try std.testing.expectApproxEqAbs(0.0, row.line_col.c, 0.0001);
            const line_str = try row.line_col.toString(allocator);
            defer allocator.free(line_str);
            try std.testing.expectEqualStrings("{1,-1,0}", line_str);

            try std.testing.expectApproxEqAbs(1.0, row.lseg_col.start.x, 0.0001);
            try std.testing.expectApproxEqAbs(1.0, row.lseg_col.start.y, 0.0001);
            try std.testing.expectApproxEqAbs(2.0, row.lseg_col.end.x, 0.0001);
            try std.testing.expectApproxEqAbs(2.0, row.lseg_col.end.y, 0.0001);
            const lseg_str = try row.lseg_col.toString(allocator);
            defer allocator.free(lseg_str);
            try std.testing.expectEqualStrings("[(1,1),(2,2)]", lseg_str);

            try std.testing.expectApproxEqAbs(2.0, row.box_col.top_right.x, 0.0001);
            try std.testing.expectApproxEqAbs(2.0, row.box_col.top_right.y, 0.0001);
            try std.testing.expectApproxEqAbs(0.0, row.box_col.bottom_left.x, 0.0001);
            try std.testing.expectApproxEqAbs(0.0, row.box_col.bottom_left.y, 0.0001);
            const box_str = try row.box_col.toString(allocator);
            defer allocator.free(box_str);
            try std.testing.expectEqualStrings("(2,2),(0,0)", box_str);

            try std.testing.expectEqual(@as(usize, 3), row.path_col.points.len);
            try std.testing.expectEqual(false, row.path_col.is_closed);
            try std.testing.expectApproxEqAbs(0.0, row.path_col.points[0].x, 0.0001);
            try std.testing.expectApproxEqAbs(1.0, row.path_col.points[1].x, 0.0001);
            try std.testing.expectApproxEqAbs(2.0, row.path_col.points[2].x, 0.0001);
            const path_str = try row.path_col.toString(allocator);
            defer allocator.free(path_str);
            try std.testing.expectEqualStrings("[(0,0),(1,1),(2,2)]", path_str);

            try std.testing.expectEqual(@as(usize, 3), row.polygon_col.points.len);
            try std.testing.expectApproxEqAbs(0.0, row.polygon_col.points[0].x, 0.0001);
            try std.testing.expectApproxEqAbs(1.0, row.polygon_col.points[1].x, 0.0001);
            try std.testing.expectApproxEqAbs(2.0, row.polygon_col.points[2].x, 0.0001);
            const poly_str = try row.polygon_col.toString(allocator);
            defer allocator.free(poly_str);
            try std.testing.expectEqualStrings("((0,0),(1,1),(2,0))", poly_str);

            try std.testing.expectApproxEqAbs(0.0, row.circle_col.center.x, 0.0001);
            try std.testing.expectApproxEqAbs(0.0, row.circle_col.center.y, 0.0001);
            try std.testing.expectApproxEqAbs(5.0, row.circle_col.radius, 0.0001);
            const circle_str = try row.circle_col.toString(allocator);
            defer allocator.free(circle_str);
            try std.testing.expectEqualStrings("<(0,0),5>", circle_str);
        },
        else => unreachable,
    }
}
