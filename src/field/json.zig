const std = @import("std");

/// Represents PostgreSQL's `json` type: JSON data stored as text
pub const JSON = struct {
    data: []u8, // Raw JSON text

    /// Parses JSON from PostgreSQL text representation
    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !JSON {
        // Simply duplicate the text as-is (json preserves exact input)
        const data = try allocator.dupe(u8, text);
        return JSON{ .data = data };
    }

    /// Frees the allocated memory
    pub fn deinit(self: JSON, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    /// Converts back to PostgreSQL-compatible text
    pub fn toString(self: JSON, allocator: std.mem.Allocator) ![]u8 {
        // Return a copy of the raw JSON text
        return try allocator.dupe(u8, self.data);
    }

    /// Optional: Parse the JSON into a Zig value using std.json (if needed)
    pub fn parse(self: JSON, allocator: std.mem.Allocator, comptime T: type) !T {
        var stream = std.json.TokenStream.init(self.data);
        return try std.json.parse(T, &stream, .{ .allocator = allocator });
    }
};

/// Represents PostgreSQL's `jsonb` type: JSON data in binary format, but text for I/O
pub const JSONB = struct {
    data: []u8, // Normalized JSON text (for simplicity, we store as text)

    /// Parses JSONB from PostgreSQL text representation
    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !JSONB {
        // For simplicity, store as text; in a real driver, this could validate/normalize
        const data = try allocator.dupe(u8, text);
        return JSONB{ .data = data };
    }

    /// Frees the allocated memory
    pub fn deinit(self: JSONB, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    /// Converts back to PostgreSQL-compatible text
    pub fn toString(self: JSONB, allocator: std.mem.Allocator) ![]u8 {
        // Return a copy of the normalized JSON text
        return try allocator.dupe(u8, self.data);
    }

    /// Optional: Parse the JSONB into a Zig value using std.json
    pub fn parse(self: JSONB, allocator: std.mem.Allocator, comptime T: type) !T {
        var stream = std.json.TokenStream.init(self.data);
        return try std.json.parse(T, &stream, .{ .allocator = allocator });
    }
};

// Example struct for JSON parsing
const ExampleStruct = struct {
    name: []const u8,
    age: i32,
};

// Tests
test "JSON Types" {
    const allocator = std.testing.allocator;

    // Test JSON
    var json = try JSON.fromPostgresText("{\"name\": \"Alice\", \"age\": 30}", allocator);
    defer json.deinit(allocator);
    const json_str = try json.toString(allocator);
    defer allocator.free(json_str);
    try std.testing.expectEqualStrings("{\"name\": \"Alice\", \"age\": 30}", json_str);

    // Test JSON parsing
    const parsed_json = try json.parse(allocator, ExampleStruct);
    defer std.json.parseFree(ExampleStruct, parsed_json, .{ .allocator = allocator });
    try std.testing.expectEqualStrings("Alice", parsed_json.name);
    try std.testing.expectEqual(@as(i32, 30), parsed_json.age);

    // Test JSONB
    var jsonb = try JSONB.fromPostgresText("{\"age\": 30, \"name\": \"Alice\"}", allocator);
    defer jsonb.deinit(allocator);
    const jsonb_str = try jsonb.toString(allocator);
    defer allocator.free(jsonb_str);
    try std.testing.expectEqualStrings("{\"age\": 30, \"name\": \"Alice\"}", jsonb_str);

    // Test JSONB parsing
    const parsed_jsonb = try jsonb.parse(allocator, ExampleStruct);
    defer std.json.parseFree(ExampleStruct, parsed_jsonb, .{ .allocator = allocator });
    try std.testing.expectEqualStrings("Alice", parsed_jsonb.name);
    try std.testing.expectEqual(@as(i32, 30), parsed_jsonb.age);
}
