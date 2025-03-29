const std = @import("std");

/// Represents PostgreSQL's `tsvector` type: a sorted list of lexemes with optional positions and weights
pub const TSVector = struct {
    pub const Lexeme = struct {
        word: []const u8,
        positions: ?[]u16,
        weight: ?u8, // A=65, B=66, C=67, D=68
    };

    lexemes: []Lexeme,

    pub fn fromPostgresBinary(data: []const u8, allocator: std.mem.Allocator) !TSVector {
        var lexeme_list = std.ArrayList(TSVector.Lexeme).init(allocator);
        defer lexeme_list.deinit();

        var stream = std.io.fixedBufferStream(data);
        var reader = stream.reader();

        const lexeme_count = try reader.readInt(u32, .little);

        var i: usize = 0;
        while (i < lexeme_count) : (i += 1) {
            // Read word (null-terminated)
            var word_buf = std.ArrayList(u8).init(allocator);
            defer word_buf.deinit();

            while (true) {
                const byte = try reader.readByte();
                if (byte == 0) break; // End of string
                try word_buf.append(byte);
            }
            const word = try word_buf.toOwnedSlice();

            // Read position count
            const pos_count = try reader.readInt(u16, .little);
            var positions = std.ArrayList(u16).init(allocator);
            defer positions.deinit();

            var weight: ?u8 = null;

            var j: usize = 0;
            while (j < pos_count) : (j += 1) {
                var pos = try reader.readInt(u16, .little);
                if ((pos & 0xC000) != 0) { // Check for weight bits
                    weight = @as(u8, @intCast((pos >> 14))) + 'A';
                    pos &= 0x3FFF; // Mask out weight bits
                }
                try positions.append(pos);
            }

            try lexeme_list.append(TSVector.Lexeme{
                .word = word,
                .positions = try positions.toOwnedSlice(),
                .weight = weight,
            });
        }

        return TSVector{ .lexemes = try lexeme_list.toOwnedSlice() };
    }

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !TSVector {
        var lexeme_list = std.ArrayList(Lexeme).init(allocator);
        defer lexeme_list.deinit();

        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) return TSVector{ .lexemes = &[_]Lexeme{} };

        var iter = std.mem.splitSequence(u8, trimmed, " ");
        while (iter.next()) |token| {
            var word_slice = token;
            const colon_pos = std.mem.indexOf(u8, word_slice, ":") orelse {
                if (word_slice.len >= 2 and word_slice[0] == '\'' and word_slice[word_slice.len - 1] == '\'') {
                    word_slice = word_slice[1 .. word_slice.len - 1]; // Strip quotes
                }
                const word = try allocator.dupe(u8, word_slice);
                try lexeme_list.append(Lexeme{ .word = word, .positions = null, .weight = null });
                continue;
            };

            // Handle word part before colon, stripping quotes if present
            var word_part = word_slice[0..colon_pos];
            if (word_part.len >= 2 and word_part[0] == '\'' and word_part[word_part.len - 1] == '\'') {
                word_part = word_part[1 .. word_part.len - 1]; // Strip quotes
            }
            const word = try allocator.dupe(u8, word_part);

            // Handle positions and weight after colon
            const pos_weight_str = word_slice[colon_pos + 1 ..];
            var positions = std.ArrayList(u16).init(allocator);
            var weight: ?u8 = null;

            var pos_iter = std.mem.splitSequence(u8, pos_weight_str, ",");
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

    pub fn fromPostgresBinary(data: []const u8, allocator: std.mem.Allocator) !TSQuery {
        var stream = std.io.fixedBufferStream(data);
        var reader = stream.reader();

        const num_nodes = try reader.readInt(u32, .little);
        var node_list = std.ArrayList(TSQuery.Node).init(allocator);
        errdefer {
            for (node_list.items) |node| {
                if (node == .term) {
                    allocator.free(node.term.word);
                }
            }
            node_list.deinit();
        }

        var i: usize = 0;
        while (i < num_nodes) : (i += 1) {
            const node_type = try reader.readByte();

            switch (node_type) {
                '&', '|', '!' => {
                    try node_list.append(TSQuery.Node{ .operator = node_type });
                },
                '<' => {
                    try node_list.append(TSQuery.Node{ .operator = '<' });
                    const distance = try reader.readInt(u32, .little);
                    try node_list.append(TSQuery.Node{ .phrase_distance = distance });
                },
                else => {
                    // It's a term
                    stream.pos -= 1; // Move back since we read the first byte assuming operator

                    const word_len = try reader.readInt(u16, .little);
                    const word = try allocator.dupe(u8, data[stream.pos .. stream.pos + word_len]);
                    stream.pos += word_len;

                    var weight_slice: ?[]const u8 = null;
                    if (stream.pos < data.len and (data[stream.pos] == 'A' or data[stream.pos] == 'B' or data[stream.pos] == 'C' or data[stream.pos] == 'D')) {
                        // Create a single-character slice from the weight character
                        weight_slice = try allocator.dupe(u8, data[stream.pos .. stream.pos + 1]);
                        stream.pos += 1;
                    }
                    try node_list.append(TSQuery.Node{ .term = .{ .word = word, .weight = weight_slice } });
                },
            }
        }

        return TSQuery{ .nodes = try node_list.toOwnedSlice() };
    }

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
                    if (node_list.items.len == 0 or node_list.items[node_list.items.len - 1] != .term) {
                        return error.InvalidTSQueryFormat;
                    }
                    if (trimmed[i + 1] == '-') {
                        if (i + 3 >= trimmed.len or trimmed[i + 2] != '>') return error.InvalidTSQueryFormat;
                        try node_list.append(Node{ .operator = '<' });
                        try node_list.append(Node{ .phrase_distance = 1 });
                        i += 3;
                        while (i < trimmed.len and trimmed[i] == ' ') i += 1;
                        // Skip the right term
                        var end = i;
                        while (end < trimmed.len and end != ' ' and end != '&' and end != '|' and end != '!') {
                            end += 1;
                        }
                        i = end;
                    } else {
                        const end = std.mem.indexOf(u8, trimmed[i..], ">") orelse return error.InvalidTSQueryFormat;
                        const dist_str = trimmed[i + 1 .. i + end];
                        const distance = try std.fmt.parseInt(u32, dist_str, 10);
                        try node_list.append(Node{ .operator = '<' });
                        try node_list.append(Node{ .phrase_distance = distance });
                        i += end + 1;
                        while (i < trimmed.len and trimmed[i] == ' ') i += 1;
                        // Skip the right term
                        var end_right = i;
                        while (end_right < trimmed.len and end_right != ' ' and end_right != '&' and end_right != '!') {
                            end_right += 1;
                        }
                        i = end_right;
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
                        var word = term_str[0..pos];
                        if (word.len >= 2 and word[0] == '\'' and word[word.len - 1] == '\'') {
                            word = word[1 .. word.len - 1]; // Strip quotes
                        }
                        const word_dup = try allocator.dupe(u8, word);
                        const weight = try allocator.dupe(u8, term_str[pos + 1 ..]);
                        try node_list.append(Node{ .term = .{ .word = word_dup, .weight = weight } });
                    } else {
                        var word = term_str;
                        if (term_str.len >= 2 and term_str[0] == '\'' and word[word.len - 1] == '\'') {
                            word = word[1 .. word.len - 1]; // Strip quotes
                        }
                        const word_dup = try allocator.dupe(u8, word);
                        try node_list.append(Node{ .term = .{ .word = word_dup, .weight = null } });
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
                        continue;
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
