const std = @import("std");

/// Generic Composite Type handler
pub fn Composite(comptime Fields: type) type {
    return struct {
        fields: Fields,

        const Self = @This();

        pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Self {
            if (text.len < 2 or text[0] != '(' or text[text.len - 1] != ')') return error.InvalidCompositeFormat;
            const fields_str = text[1 .. text.len - 1];

            var iter = std.mem.split(u8, fields_str, ",");
            var field_count: usize = 0;
            var result: Fields = undefined;

            inline for (std.meta.fields(Fields), 0..) |f, i| { // Fixed: Added 0.. for index
                _ = i;
                const field = iter.next() orelse return error.InvalidFieldCount;
                const trimmed = std.mem.trim(u8, field, " ");

                if (comptime std.meta.trait.is(.Optional)(f.type)) {
                    const Child = @typeInfo(f.type).Optional.child;
                    if (trimmed.len == 0) {
                        @field(result, f.name) = null;
                    } else {
                        @field(result, f.name) = try parseField(Child, trimmed, allocator);
                    }
                } else {
                    @field(result, f.name) = try parseField(f.type, trimmed, allocator);
                }
                field_count += 1;
            }
            if (iter.next() != null) return error.TooManyFields;
            if (field_count != std.meta.fields(Fields).len) return error.InvalidFieldCount;

            return Self{ .fields = result };
        }

        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            inline for (std.meta.fields(Fields), 0..) |f, i| { // Fixed: Added 0..
                _ = i;
                if (comptime std.meta.trait.is(.Optional)(f.type)) {
                    const Child = @typeInfo(f.type).Optional.child;
                    if (@field(self.fields, f.name)) |val| {
                        freeField(Child, val, allocator);
                    }
                } else {
                    freeField(f.type, @field(self.fields, f.name), allocator);
                }
            }
        }

        pub fn toString(self: Self, allocator: std.mem.Allocator) ![]u8 {
            var result = std.ArrayList(u8).init(allocator);
            defer result.deinit();

            try result.append('(');
            inline for (std.meta.fields(Fields), 0..) |f, i| { // Fixed: Added 0..
                if (i > 0) try result.append(',');
                const value = @field(self.fields, f.name);
                if (comptime std.meta.trait.is(.Optional)(f.type)) {
                    if (value) |v| {
                        try appendField(f.type, v, &result, allocator);
                    }
                } else {
                    try appendField(f.type, value, &result, allocator);
                }
            }
            try result.append(')');

            return result.toOwnedSlice();
        }
    };
}

// Helper functions (unchanged)
fn parseField(comptime T: type, text: []const u8, allocator: std.mem.Allocator) !T {
    return switch (@typeInfo(T)) {
        .Pointer => |ptr| if (ptr.size == .Slice and ptr.child == u8) {
            if (text[0] == '"' and text[text.len - 1] == '"') {
                return try allocator.dupe(u8, text[1 .. text.len - 1]);
            } else {
                return try allocator.dupe(u8, text);
            }
        } else @compileError("Unsupported pointer type"),
        .Int => try std.fmt.parseInt(T, text, 10),
        .Bool => if (std.mem.eql(u8, text, "t")) true else if (std.mem.eql(u8, text, "f")) false else error.InvalidBoolean,
        else => @compileError("Unsupported field type: " ++ @typeName(T)),
    };
}

fn freeField(comptime T: type, value: T, allocator: std.mem.Allocator) void {
    if (comptime std.meta.trait.is(.Pointer)(T) and @typeInfo(T).Pointer.size == .Slice and @typeInfo(T).Pointer.child == u8) {
        allocator.free(value);
    }
}

fn appendField(comptime T: type, value: T, result: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    _ = allocator; // Used if we need to allocate temporary strings
    switch (@typeInfo(T)) {
        .Pointer => |ptr| if (ptr.size == .Slice and ptr.child == u8) {
            if (std.mem.indexOfAny(u8, value, ", )") != null) {
                try result.writer().print("\"{s}\"", .{value});
            } else {
                try result.appendSlice(value);
            }
        },
        .Int => try result.writer().print("{d}", .{value}),
        .Bool => try result.append(if (value) 't' else 'f'),
        else => @compileError("Unsupported field type: " ++ @typeName(T)),
    }
}

// Tests
test "Generic Composite Type" {
    // Example usage with a Person type
    const PersonFields = struct {
        name: ?[]const u8,
        age: ?i32,
        active: ?bool,
    };

    const GenericPerson = Composite(PersonFields);

    const allocator = std.testing.allocator;

    // Test full data
    var person = try GenericPerson.fromPostgresText("(Alice,30,t)", allocator);
    defer person.deinit(allocator);
    try std.testing.expectEqualStrings("Alice", person.fields.name.?);
    try std.testing.expectEqual(@as(i32, 30), person.fields.age.?);
    try std.testing.expectEqual(true, person.fields.active.?);
    const person_str = try person.toString(allocator);
    defer allocator.free(person_str);
    try std.testing.expectEqualStrings("(Alice,30,t)", person_str);

    // Test with NULLs and quoted string
    var person2 = try GenericPerson.fromPostgresText("(\"Alice, Jr.\",,f)", allocator);
    defer person2.deinit(allocator);
    try std.testing.expectEqualStrings("Alice, Jr.", person2.fields.name.?);
    try std.testing.expectEqual(null, person2.fields.age);
    try std.testing.expectEqual(false, person2.fields.active.?);
    const person2_str = try person2.toString(allocator);
    defer allocator.free(person2_str);
    try std.testing.expectEqualStrings("(\"Alice, Jr.\",,f)", person2_str);
}
