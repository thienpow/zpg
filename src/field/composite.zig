const std = @import("std");

/// Generic Composite Type handler
pub fn Composite(comptime Fields: type) type {
    return struct {
        fields: Fields,

        const Self = @This();

        pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Self {
            if (text.len < 2 or text[0] != '(' or text[text.len - 1] != ')') return error.InvalidCompositeFormat;
            const fields_str = text[1 .. text.len - 1];

            var iter = std.mem.splitScalar(u8, fields_str, ',');
            var field_count: usize = 0;
            var result: Fields = undefined;

            // Track allocations so we can free them on error
            var allocations: [std.meta.fields(Fields).len]?[]const u8 = .{null} ** std.meta.fields(Fields).len;
            errdefer {
                // Clean up any allocations we made before failing
                for (allocations) |maybe_alloc| {
                    if (maybe_alloc) |alloc| {
                        allocator.free(alloc);
                    }
                }
            }

            inline for (std.meta.fields(Fields), 0..) |f, i| {
                const field = iter.next() orelse return error.InvalidFieldCount;
                const trimmed = std.mem.trim(u8, field, " ");

                switch (@typeInfo(f.type)) {
                    .optional => |opt| {
                        const Child = opt.child;
                        if (trimmed.len == 0) {
                            @field(result, f.name) = null;
                        } else {
                            const parsed = try parseField(Child, trimmed, allocator);
                            allocations[i] = if (Child == []const u8) parsed else null;
                            @field(result, f.name) = parsed;
                        }
                    },
                    else => {
                        const parsed = try parseField(f.type, trimmed, allocator);
                        allocations[i] = if (f.type == []const u8) parsed else null;
                        @field(result, f.name) = parsed;
                    },
                }
                field_count += 1;
            }
            if (iter.next() != null) return error.TooManyFields;
            if (field_count != std.meta.fields(Fields).len) return error.InvalidFieldCount;

            return Self{ .fields = result };
        }

        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            inline for (std.meta.fields(Fields), 0..) |f, i| {
                _ = i;
                switch (@typeInfo(f.type)) {
                    .optional => |opt| {
                        const Child = opt.child;
                        if (@field(self.fields, f.name)) |val| {
                            freeField(Child, val, allocator);
                        }
                    },
                    else => {
                        freeField(f.type, @field(self.fields, f.name), allocator);
                    },
                }
            }
        }

        pub fn toString(self: Self, allocator: std.mem.Allocator) ![]u8 {
            var result = std.ArrayList(u8).init(allocator);
            errdefer result.deinit();

            try result.append('(');

            // Keep track if we need a comma before the next field
            var needs_comma = false;
            inline for (std.meta.fields(Fields)) |f| {
                const value = @field(self.fields, f.name);
                switch (@typeInfo(f.type)) {
                    .optional => {
                        if (value) |v| {
                            if (needs_comma) try result.append(',');
                            try appendField(@TypeOf(v), v, &result, allocator);
                            needs_comma = true;
                        }
                        // Simply do nothing for null case - no continue needed
                    },
                    else => {
                        if (needs_comma) try result.append(',');
                        try appendField(f.type, value, &result, allocator);
                        needs_comma = true;
                    },
                }
            }
            try result.append(')');

            return result.toOwnedSlice();
        }
    };
}

// Helper functions
fn parseField(comptime T: type, text: []const u8, allocator: std.mem.Allocator) !T {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8) {
            if (text[0] == '"' and text[text.len - 1] == '"') {
                return try allocator.dupe(u8, text[1 .. text.len - 1]);
            } else {
                return try allocator.dupe(u8, text);
            }
        } else @compileError("Unsupported pointer type"),
        .int => try std.fmt.parseInt(T, text, 10),
        .bool => if (std.mem.eql(u8, text, "t")) true else if (std.mem.eql(u8, text, "f")) false else error.InvalidBoolean,
        else => @compileError("Unsupported field type: " ++ @typeName(T)),
    };
}

fn freeField(comptime T: type, value: T, allocator: std.mem.Allocator) void {
    if (comptime @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice and @typeInfo(T).pointer.child == u8) {
        allocator.free(value);
    }
}

fn appendField(comptime T: type, value: T, result: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    _ = allocator; // Used if we need to allocate temporary strings
    switch (@typeInfo(T)) {
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8) {
            if (std.mem.indexOfAny(u8, value, ", )") != null) {
                try result.writer().print("\"{s}\"", .{value});
            } else {
                try result.appendSlice(value);
            }
        },
        .int => try result.writer().print("{d}", .{value}),
        .bool => try result.append(if (value) 't' else 'f'),
        else => @compileError("Unsupported field type: " ++ @typeName(T)),
    }
}
