const std = @import("std");

/// Represents PostgreSQL's `point` type: (x, y)
pub const Point = struct {
    x: f64,
    y: f64,

    pub fn fromPostgresBinary(data: []const u8) !Point {
        if (data.len != 16) return error.InvalidPointBinaryFormat;

        return Point{
            .x = std.mem.read(f64, data[0..8]),
            .y = std.mem.read(f64, data[8..16]),
        };
    }

    pub fn fromPostgresText(text: []const u8, _: std.mem.Allocator) !Point {
        if (text.len < 3 or text[0] != '(' or text[text.len - 1] != ')') return error.InvalidPointFormat;
        const coords = text[1 .. text.len - 1];
        const comma_pos = std.mem.indexOf(u8, coords, ",") orelse return error.InvalidPointFormat;

        const x = try std.fmt.parseFloat(f64, coords[0..comma_pos]);
        const y = try std.fmt.parseFloat(f64, coords[comma_pos + 1 ..]);
        return Point{ .x = x, .y = y };
    }

    pub fn toString(self: Point, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "({d},{d})", .{ self.x, self.y });
    }
};

/// Represents PostgreSQL's `line` type: {A,B,C} for equation Ax + By + C = 0
pub const Line = struct {
    a: f64,
    b: f64,
    c: f64,

    pub fn fromPostgresBinary(data: []const u8) !Line {
        if (data.len != 24) return error.InvalidLineBinaryFormat;

        return Line{
            .a = std.mem.read(f64, data[0..8]),
            .b = std.mem.read(f64, data[8..16]),
            .c = std.mem.read(f64, data[16..24]),
        };
    }

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Line {
        _ = allocator;
        if (text.len < 5 or text[0] != '{' or text[text.len - 1] != '}') return error.InvalidLineFormat;
        const coeffs = text[1 .. text.len - 1];
        var iter = std.mem.splitScalar(u8, coeffs, ',');

        const a = try std.fmt.parseFloat(f64, iter.next() orelse return error.InvalidLineFormat);
        const b = try std.fmt.parseFloat(f64, iter.next() orelse return error.InvalidLineFormat);
        const c = try std.fmt.parseFloat(f64, iter.next() orelse return error.InvalidLineFormat);
        if (iter.next() != null) return error.InvalidLineFormat;

        return Line{ .a = a, .b = b, .c = c };
    }

    pub fn toString(self: Line, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{{{d},{d},{d}}}", .{ self.a, self.b, self.c });
    }
};

/// Represents PostgreSQL's `lseg` type: [(x1,y1),(x2,y2)]
pub const LineSegment = struct {
    start: Point,
    end: Point,

    pub fn fromPostgresBinary(data: []const u8) !LineSegment {
        if (data.len != 32) return error.InvalidLsegBinaryFormat;

        return LineSegment{
            .start = try Point.fromPostgresBinary(data[0..16]),
            .end = try Point.fromPostgresBinary(data[16..32]),
        };
    }

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !LineSegment {
        if (text.len < 7 or text[0] != '[' or text[text.len - 1] != ']') return error.InvalidLsegFormat;
        const points = text[1 .. text.len - 1];
        const comma_pos = std.mem.indexOf(u8, points, "),(") orelse return error.InvalidLsegFormat;

        const start = try Point.fromPostgresText(points[0 .. comma_pos + 1], allocator);
        const end = try Point.fromPostgresText(points[comma_pos + 2 ..], allocator);
        return LineSegment{ .start = start, .end = end };
    }

    pub fn toString(self: LineSegment, allocator: std.mem.Allocator) ![]u8 {
        const start_str = try self.start.toString(allocator);
        defer allocator.free(start_str);
        const end_str = try self.end.toString(allocator);
        defer allocator.free(end_str);
        return try std.fmt.allocPrint(allocator, "[{s},{s}]", .{ start_str, end_str });
    }
};

/// Represents PostgreSQL's `box` type: (x1,y1),(x2,y2)
pub const Box = struct {
    top_right: Point,
    bottom_left: Point,

    pub fn fromPostgresBinary(data: []const u8) !Box {
        if (data.len != 32) return error.InvalidBoxBinaryFormat;

        return Box{
            .top_right = try Point.fromPostgresBinary(data[0..16]),
            .bottom_left = try Point.fromPostgresBinary(data[16..32]),
        };
    }

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Box {
        if (text.len < 5 or text[0] != '(' or text[text.len - 1] != ')') return error.InvalidBoxFormat;
        const points = text[0..];
        const comma_pos = std.mem.indexOf(u8, points, "),(") orelse return error.InvalidBoxFormat;

        const top_right = try Point.fromPostgresText(points[0 .. comma_pos + 1], allocator);
        const bottom_left = try Point.fromPostgresText(points[comma_pos + 2 ..], allocator);
        return Box{ .top_right = top_right, .bottom_left = bottom_left };
    }

    pub fn toString(self: Box, allocator: std.mem.Allocator) ![]u8 {
        const tr_str = try self.top_right.toString(allocator);
        defer allocator.free(tr_str);
        const bl_str = try self.bottom_left.toString(allocator);
        defer allocator.free(bl_str);
        return try std.fmt.allocPrint(allocator, "{s},{s}", .{ tr_str, bl_str });
    }
};

/// Represents PostgreSQL's `path` type: [(x1,y1),(x2,y2),...] or ((x1,y1),(x2,y2),...)
pub const Path = struct {
    points: []Point,
    is_closed: bool,

    pub fn fromPostgresBinary(data: []const u8, allocator: std.mem.Allocator) !Path {
        if (data.len < 5) return error.InvalidPathBinaryFormat;

        var index: usize = 0;
        const npoints = std.mem.readInt(u32, data[index..][0..4], .little);
        index += 4;

        const is_closed = data[index] != 0;
        index += 1;

        if (data.len != 5 + npoints * 16) return error.InvalidPathBinaryFormat;

        const points = try allocator.alloc(Point, npoints);
        errdefer allocator.free(points);

        for (points, 0..) |*point, i| {
            point.* = try Point.fromPostgresBinary(data[index + i * 16 .. index + (i + 1) * 16]);
        }

        return Path{ .points = points, .is_closed = is_closed };
    }

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Path {
        const is_closed = text[0] == '(';
        const points_str = if (is_closed) text[1 .. text.len - 1] else text[1 .. text.len - 1];
        var point_list = std.ArrayList(Point).init(allocator);

        var buf = try allocator.alloc(u8, points_str.len);
        defer allocator.free(buf);
        var buf_idx: usize = 0;
        var i: usize = 0;
        while (i < points_str.len) : (i += 1) {
            if (i + 2 < points_str.len and points_str[i] == ')' and points_str[i + 1] == ',' and points_str[i + 2] == '(') {
                buf[buf_idx] = ')'; // Keep the closing parenthesis
                buf_idx += 1;
                buf[buf_idx] = '|'; // Insert delimiter
                buf_idx += 1;
                buf[buf_idx] = '('; // Keep the opening parenthesis
                buf_idx += 1;
                i += 2; // Skip ",("
            } else {
                buf[buf_idx] = points_str[i];
                buf_idx += 1;
            }
        }
        const cleaned_points = buf[0..buf_idx];

        var iter = std.mem.splitScalar(u8, cleaned_points, '|');
        while (iter.next()) |point_str| {
            const trimmed = std.mem.trim(u8, point_str, " ");
            const point = try Point.fromPostgresText(trimmed, allocator);
            try point_list.append(point);
        }

        return Path{ .points = try point_list.toOwnedSlice(), .is_closed = is_closed };
    }

    pub fn deinit(self: Path, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
    }

    pub fn toString(self: Path, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        try result.append(if (self.is_closed) '(' else '[');

        for (self.points, 0..) |point, i| {
            const point_str = try point.toString(allocator);
            defer allocator.free(point_str);
            try result.appendSlice(point_str);
            if (i < self.points.len - 1) try result.appendSlice(",");
        }

        try result.append(if (self.is_closed) ')' else ']');
        return result.toOwnedSlice();
    }
};

/// Represents PostgreSQL's `polygon` type: ((x1,y1),(x2,y2),...)
pub const Polygon = struct {
    points: []Point,

    pub fn fromPostgresBinary(data: []const u8, allocator: std.mem.Allocator) !Polygon {
        if (data.len < 4) return error.InvalidPolygonBinaryFormat;

        var index: usize = 0;
        const npoints = std.mem.readInt(u32, data[index..][0..4], .little);
        index += 4;

        if (data.len != 4 + npoints * 16) return error.InvalidPolygonBinaryFormat;

        const points = try allocator.alloc(Point, npoints);
        errdefer allocator.free(points);

        for (points, 0..) |*point, i| {
            point.* = try Point.fromPostgresBinary(data[index + i * 16 .. index + (i + 1) * 16]);
        }

        return Polygon{ .points = points };
    }

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Polygon {
        if (text.len < 5 or text[0] != '(' or text[text.len - 1] != ')') return error.InvalidPolygonFormat;
        var point_list = std.ArrayList(Point).init(allocator);

        const points_str = text[1 .. text.len - 1];

        var buf = try allocator.alloc(u8, points_str.len);
        defer allocator.free(buf);
        var buf_idx: usize = 0;
        var i: usize = 0;
        while (i < points_str.len) : (i += 1) {
            if (i + 2 < points_str.len and points_str[i] == ')' and points_str[i + 1] == ',' and points_str[i + 2] == '(') {
                buf[buf_idx] = ')';
                buf_idx += 1;
                buf[buf_idx] = '|';
                buf_idx += 1;
                buf[buf_idx] = '(';
                buf_idx += 1;
                i += 2; // Skip ",("
            } else {
                buf[buf_idx] = points_str[i];
                buf_idx += 1;
            }
        }
        const cleaned_points = buf[0..buf_idx];

        var iter = std.mem.splitScalar(u8, cleaned_points, '|');
        while (iter.next()) |point_str| {
            const trimmed = std.mem.trim(u8, point_str, " ");
            const point = try Point.fromPostgresText(trimmed, allocator);
            try point_list.append(point);
        }

        return Polygon{ .points = try point_list.toOwnedSlice() };
    }

    pub fn deinit(self: Polygon, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
    }

    pub fn toString(self: Polygon, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        try result.append('(');

        for (self.points, 0..) |point, i| {
            const point_str = try point.toString(allocator);
            defer allocator.free(point_str);
            try result.appendSlice(point_str);
            if (i < self.points.len - 1) try result.appendSlice(",");
        }

        try result.append(')');
        return result.toOwnedSlice();
    }
};

/// Represents PostgreSQL's `circle` type: <(x,y),r>
pub const Circle = struct {
    center: Point,
    radius: f64,

    pub fn fromPostgresBinary(data: []const u8, _: std.mem.Allocator) !Circle {
        if (data.len != 24) return error.InvalidCircleBinaryFormat;

        const center = try Point.fromPostgresBinary(data[0..16]);
        const radius = std.mem.readInt(f64, data[16..24], .little);

        return Circle{ .center = center, .radius = radius };
    }

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Circle {
        if (text.len < 5 or text[0] != '<' or text[text.len - 1] != '>') return error.InvalidCircleFormat;
        const parts = text[1 .. text.len - 1];

        // Find the end of the point (closing parenthesis)
        const paren_close = std.mem.indexOf(u8, parts, ")") orelse return error.InvalidCircleFormat;
        if (paren_close == parts.len - 1) return error.InvalidCircleFormat; // No radius
        const comma_pos = std.mem.indexOfPos(u8, parts, paren_close + 1, ",") orelse return error.InvalidCircleFormat;

        const center = try Point.fromPostgresText(parts[0 .. paren_close + 1], allocator);
        const radius = try std.fmt.parseFloat(f64, parts[comma_pos + 1 ..]);
        return Circle{ .center = center, .radius = radius };
    }

    pub fn toString(self: Circle, allocator: std.mem.Allocator) ![]u8 {
        const center_str = try self.center.toString(allocator);
        defer allocator.free(center_str);
        return try std.fmt.allocPrint(allocator, "<{s},{d}>", .{ center_str, self.radius });
    }
};
