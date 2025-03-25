const std = @import("std");

/// Represents PostgreSQL's `tsvector` type: a sorted list of lexemes with optional positions and weights
pub const TSVector = struct {
    pub const Lexeme = struct {
        word: []const u8,
        positions: ?[]u16, // Optional positions (e.g., word offsets in the document)
        weight: ?u8, // Optional weight (A=65, B=66, C=67, D=68)
    };

    lexemes: []Lexeme,

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !TSVector {
        var lexeme_list = std.ArrayList(Lexeme).init(allocator);
        defer lexeme_list.deinit(); // In case of error

        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) return TSVector{ .lexemes = &[_]Lexeme{} };

        var iter = std.mem.split(u8, trimmed, " ");
        while (iter.next()) |token| {
            const colon_pos = std.mem.indexOf(u8, token, ":") orelse {
                const word = try allocator.dupe(u8, token[1 .. token.len - 1]); // Strip quotes
                try lexeme_list.append(Lexeme{ .word = word, .positions = null, .weight = null });
                continue;
            };

            const word = try allocator.dupe(u8, token[1 .. colon_pos - 1]); // Strip quotes
            const pos_weight_str = token[colon_pos + 1 ..];
            var positions = std.ArrayList(u16).init(allocator);
            var weight: ?u8 = null;

            var pos_iter = std.mem.split(u8, pos_weight_str, ",");
            while (pos_iter.next()) |pos_str| {
                if (std.mem.indexOfAny(u8, pos_str, "ABCD")) |weight_idx| {
                    weight = pos_str[weight_idx];
                    try positions.append(try std.fmt.parseInt(u16, pos_str[0..weight_idx], 10));
                } else {
                    try positions.append(try std.fmt.parseInt(u16, pos_str, 10));
                }
            }

            try lexeme_list.append(Lexeme{
                .word = word,
                .positions = try positions.toOwnedSlice(),
                .weight = weight,
            });
        }

        return TSVector{ .lexemes = try lexeme_list.toOwnedSlice() };
    }

    pub fn deinit(self: TSVector, allocator: std.mem.Allocator) void {
        for (self.lexemes) |lexeme| {
            allocator.free(lexeme.word);
            if (lexeme.positions) |pos| allocator.free(pos);
        }
        allocator.free(self.lexemes);
    }

    pub fn toString(self: TSVector, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        for (self.lexemes, 0..) |lexeme, i| {
            try result.writer().print("'{s}'", .{lexeme.word});
            if (lexeme.positions) |positions| {
                try result.append(':');
                for (positions, 0..) |pos, j| {
                    if (j > 0) try result.append(',');
                    try result.writer().print("{d}", .{pos});
                    if (j == positions.len - 1 and lexeme.weight != null) {
                        try result.append(lexeme.weight.?);
                    }
                }
            }
            if (i < self.lexemes.len - 1) try result.append(' ');
        }

        return result.toOwnedSlice();
    }
};

/// Represents PostgreSQL's `tsquery` type: a search query with terms and operators
pub const TSQuery = struct {
    pub const Node = union(enum) {
        term: struct { word: []const u8, weight: ?[]const u8 },
        operator: u8, // '&' (AND), '|' (OR), '!' (NOT), '<' (phrase start)
        phrase_distance: u32, // For '<->' or '<N>'
    };

    nodes: []Node,

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !TSQuery {
        var node_list = std.ArrayList(Node).init(allocator);
        defer node_list.deinit();

        var trimmed = std.mem.trim(u8, text, " ");
        var i: usize = 0;

        while (i < trimmed.len) {
            switch (trimmed[i]) {
                '&', '|', '!' => {
                    try node_list.append(Node{ .operator = trimmed[i] });
                    i += 1;
                },
                '<' => {
                    if (i + 1 >= trimmed.len) return error.InvalidTSQueryFormat;
                    if (trimmed[i + 1] == '-') {
                        if (i + 3 >= trimmed.len or trimmed[i + 2] != '>') return error.InvalidTSQueryFormat;
                        try node_list.append(Node{ .operator = '<' });
                        try node_list.append(Node{ .phrase_distance = 1 });
                        i += 3;
                    } else {
                        const end = std.mem.indexOf(u8, trimmed[i..], ">") orelse return error.InvalidTSQueryFormat;
                        const dist_str = trimmed[i + 1 .. i + end];
                        const distance = try std.fmt.parseInt(u32, dist_str, 10);
                        try node_list.append(Node{ .operator = '<' });
                        try node_list.append(Node{ .phrase_distance = distance });
                        i += end + 1;
                    }
                },
                else => {
                    var end = i;
                    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '&' and trimmed[end] != '|' and trimmed[end] != '!') {
                        end += 1;
                    }
                    const term_str = trimmed[i..end];
                    const colon_pos = std.mem.indexOf(u8, term_str, ":");
                    if (colon_pos) |pos| {
                        const word = try allocator.dupe(u8, term_str[0..pos]);
                        const weight = try allocator.dupe(u8, term_str[pos + 1 ..]);
                        try node_list.append(Node{ .term = .{ .word = word, .weight = weight } });
                    } else {
                        const word = try allocator.dupe(u8, term_str);
                        try node_list.append(Node{ .term = .{ .word = word, .weight = null } });
                    }
                    i = end;
                },
            }
            while (i < trimmed.len and trimmed[i] == ' ') i += 1;
        }

        return TSQuery{ .nodes = try node_list.toOwnedSlice() };
    }

    pub fn deinit(self: TSQuery, allocator: std.mem.Allocator) void {
        for (self.nodes) |node| {
            if (node == .term) {
                allocator.free(node.term.word);
                if (node.term.weight) |w| allocator.free(w);
            }
        }
        allocator.free(self.nodes);
    }

    pub fn toString(self: TSQuery, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        for (self.nodes, 0..) |node, i| {
            switch (node) {
                .term => |t| {
                    try result.writer().print("{s}", .{t.word});
                    if (t.weight) |w| try result.writer().print(":{s}", .{w});
                },
                .operator => |op| {
                    if (op == '<' and i + 1 < self.nodes.len and self.nodes[i + 1] == .phrase_distance) {
                        continue; // Handled in phrase_distance
                    }
                    try result.append(op);
                },
                .phrase_distance => |dist| {
                    if (i > 0 and self.nodes[i - 1] == .operator and self.nodes[i - 1].operator == '<') {
                        if (dist == 1) {
                            try result.appendSlice("->");
                        } else {
                            try result.writer().print("{d}>", .{dist});
                        }
                    }
                },
            }
            if (i < self.nodes.len - 1 and node != .operator) try result.append(' ');
        }

        return result.toOwnedSlice();
    }
};

// Tests
test "Text Search Types" {
    const allocator = std.testing.allocator;

    // TSVector
    var tsv = try TSVector.fromPostgresText("'fat':1A 'cat':2,3B", allocator);
    defer tsv.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), tsv.lexemes.len);
    try std.testing.expectEqualStrings("fat", tsv.lexemes[0].word);
    try std.testing.expectEqualSlices(u16, &[_]u16{1}, tsv.lexemes[0].positions.?);
    try std.testing.expectEqual(@as(u8, 'A'), tsv.lexemes[0].weight.?);
    const tsv_str = try tsv.toString(allocator);
    defer allocator.free(tsv_str);
    try std.testing.expectEqualStrings("'fat':1A 'cat':2,3B", tsv_str);

    // TSQuery
    var tsq = try TSQuery.fromPostgresText("fat & !cat | dog:AB <2> fish", allocator);
    defer tsq.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 8), tsq.nodes.len);
    try std.testing.expectEqualStrings("fat", tsq.nodes[0].term.word);
    try std.testing.expectEqual(@as(u8, '&'), tsq.nodes[1].operator);
    try std.testing.expectEqual(@as(u8, '!'), tsq.nodes[2].operator);
    try std.testing.expectEqualStrings("cat", tsq.nodes[3].term.word);
    try std.testing.expectEqual(@as(u32, 2), tsq.nodes[6].phrase_distance);
    const tsq_str = try tsq.toString(allocator);
    defer allocator.free(tsq_str);
    try std.testing.expectEqualStrings("fat & !cat | dog:AB <2> fish", tsq_str);
}
