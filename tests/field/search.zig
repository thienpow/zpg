const std = @import("std");
const zpg = @import("zpg");

const TextSearchTest = struct {
    id: zpg.field.Serial,
    tsv_col: zpg.field.TSVector,
    tsq_col: zpg.field.TSQuery,

    pub fn deinit(self: TextSearchTest, allocator: std.mem.Allocator) void {
        self.tsv_col.deinit(allocator);
        self.tsq_col.deinit(allocator);
    }
};

test "Text Search Types" {
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

    _ = try query.run("DROP TABLE IF EXISTS text_search_test", zpg.types.Empty);
    _ = try query.run(
        \\CREATE TABLE text_search_test (
        \\    id SERIAL PRIMARY KEY,
        \\    tsv_col TSVECTOR,
        \\    tsq_col TSQUERY
        \\)
    , zpg.types.Empty);

    const insert_params = &[_]zpg.Param{
        // TSVector params
        zpg.Param.string("'fat' 'cat' 'rat'"), // Simple words
        zpg.Param.string("'fat':1A 'cat':2B 'rat':3,4"), // With positions and weights
        zpg.Param.string("'super':1,2A 'cali':3B 'fragi':4 'listic':5C"), // Multiple positions
        zpg.Param.string(""), // Empty tsvector
        // TSQuery params
        zpg.Param.string("fat & cat"), // Simple AND
        zpg.Param.string("fat | cat & !rat"), // OR, AND, NOT
        zpg.Param.string("super <-> cali"), // Phrase search (adjacent)
        zpg.Param.string("super <2> cali"), // Phrase search with distance
    };

    _ = try query.prepare("insert_data AS INSERT INTO text_search_test (tsv_col, tsq_col) VALUES ($1, $5), ($2, $6), ($3, $7), ($4, $8)");
    _ = try query.execute("insert_data", insert_params, zpg.types.Empty);

    const results = try query.run("SELECT * FROM text_search_test ORDER BY id", TextSearchTest);

    switch (results) {
        .select => |rows| {
            defer {
                for (rows) |item| item.deinit(allocator);
                allocator.free(rows);
            }

            try std.testing.expectEqual(@as(usize, 4), rows.len);

            // Test 1: 'fat' 'cat' 'rat' / fat & cat
            const simple = rows[0];
            try std.testing.expectEqual(@as(usize, 3), simple.tsv_col.lexemes.len);
            try std.testing.expectEqualStrings("cat", simple.tsv_col.lexemes[0].word); // Sorted: "cat" first
            try std.testing.expectEqualStrings("fat", simple.tsv_col.lexemes[1].word); // Sorted: "fat" second
            try std.testing.expectEqualStrings("rat", simple.tsv_col.lexemes[2].word); // Sorted: "rat" third
            try std.testing.expectEqual(@as(usize, 3), simple.tsq_col.nodes.len);
            try std.testing.expectEqualStrings("fat", simple.tsq_col.nodes[0].term.word);
            try std.testing.expectEqual('&', simple.tsq_col.nodes[1].operator);
            try std.testing.expectEqualStrings("cat", simple.tsq_col.nodes[2].term.word);

            // Test 2: 'fat':1A 'cat':2B 'rat':3,4 / fat | cat & !rat
            const weighted = rows[1];
            try std.testing.expectEqual(@as(usize, 3), weighted.tsv_col.lexemes.len);
            try std.testing.expectEqualStrings("cat", weighted.tsv_col.lexemes[0].word); // Sorted: 'cat' first
            try std.testing.expectEqual(@as(u8, 'B'), weighted.tsv_col.lexemes[0].weight.?);
            try std.testing.expectEqual(@as(usize, 1), weighted.tsv_col.lexemes[0].positions.?.len);
            try std.testing.expectEqual(@as(u16, 2), weighted.tsv_col.lexemes[0].positions.?[0]);
            try std.testing.expectEqualStrings("fat", weighted.tsv_col.lexemes[1].word); // Sorted: 'fat' second
            try std.testing.expectEqual(@as(u8, 'A'), weighted.tsv_col.lexemes[1].weight.?);
            try std.testing.expectEqual(@as(usize, 1), weighted.tsv_col.lexemes[1].positions.?.len);
            try std.testing.expectEqual(@as(u16, 1), weighted.tsv_col.lexemes[1].positions.?[0]);
            try std.testing.expectEqualStrings("rat", weighted.tsv_col.lexemes[2].word); // Sorted: 'rat' third
            try std.testing.expectEqual(@as(usize, 2), weighted.tsv_col.lexemes[2].positions.?.len);
            try std.testing.expectEqual(@as(u16, 3), weighted.tsv_col.lexemes[2].positions.?[0]);
            try std.testing.expectEqual(@as(u16, 4), weighted.tsv_col.lexemes[2].positions.?[1]);

            try std.testing.expectEqual(@as(usize, 6), weighted.tsq_col.nodes.len);
            try std.testing.expectEqualStrings("fat", weighted.tsq_col.nodes[0].term.word);
            try std.testing.expectEqual('|', weighted.tsq_col.nodes[1].operator);
            try std.testing.expectEqualStrings("cat", weighted.tsq_col.nodes[2].term.word);
            try std.testing.expectEqual('&', weighted.tsq_col.nodes[3].operator);
            try std.testing.expectEqual('!', weighted.tsq_col.nodes[4].operator);
            try std.testing.expectEqualStrings("rat", weighted.tsq_col.nodes[5].term.word);

            // Test 3: 'super':1,2A 'cali':3B 'fragi':4 'listic':5C / super <-> cali
            const multi = rows[2];
            try std.testing.expectEqual(@as(usize, 4), multi.tsv_col.lexemes.len);
            try std.testing.expectEqualStrings("cali", multi.tsv_col.lexemes[0].word);
            try std.testing.expectEqual(@as(usize, 1), multi.tsv_col.lexemes[0].positions.?.len);
            try std.testing.expectEqual(@as(u16, 3), multi.tsv_col.lexemes[0].positions.?[0]);
            try std.testing.expectEqual(@as(u8, 'B'), multi.tsv_col.lexemes[0].weight.?);
            try std.testing.expectEqualStrings("fragi", multi.tsv_col.lexemes[1].word);
            try std.testing.expectEqual(@as(usize, 1), multi.tsv_col.lexemes[1].positions.?.len);
            try std.testing.expectEqual(@as(u16, 4), multi.tsv_col.lexemes[1].positions.?[0]);
            try std.testing.expectEqualStrings("listic", multi.tsv_col.lexemes[2].word);
            try std.testing.expectEqual(@as(usize, 1), multi.tsv_col.lexemes[2].positions.?.len);
            try std.testing.expectEqual(@as(u16, 5), multi.tsv_col.lexemes[2].positions.?[0]);
            try std.testing.expectEqual(@as(u8, 'C'), multi.tsv_col.lexemes[2].weight.?);
            try std.testing.expectEqualStrings("super", multi.tsv_col.lexemes[3].word);
            try std.testing.expectEqual(@as(usize, 2), multi.tsv_col.lexemes[3].positions.?.len);
            try std.testing.expectEqual(@as(u16, 1), multi.tsv_col.lexemes[3].positions.?[0]);
            try std.testing.expectEqual(@as(u16, 2), multi.tsv_col.lexemes[3].positions.?[1]);
            try std.testing.expectEqual(@as(u8, 'A'), multi.tsv_col.lexemes[3].weight.?);

            try std.testing.expectEqual(@as(usize, 3), multi.tsq_col.nodes.len); // Should be 3: super, <, 1
            try std.testing.expectEqualStrings("super", multi.tsq_col.nodes[0].term.word);
            try std.testing.expectEqual('<', multi.tsq_col.nodes[1].operator);
            try std.testing.expectEqual(@as(u32, 1), multi.tsq_col.nodes[2].phrase_distance);

            // Test 4: '' / super <2> cali
            const empty = rows[3];
            try std.testing.expectEqual(@as(usize, 0), empty.tsv_col.lexemes.len);
            try std.testing.expectEqual(@as(usize, 3), empty.tsq_col.nodes.len); // Should be 3: super, <, 2
            try std.testing.expectEqualStrings("super", empty.tsq_col.nodes[0].term.word);
            try std.testing.expectEqual('<', empty.tsq_col.nodes[1].operator);
            try std.testing.expectEqual(@as(u32, 2), empty.tsq_col.nodes[2].phrase_distance);
        },
        else => unreachable,
    }
}
