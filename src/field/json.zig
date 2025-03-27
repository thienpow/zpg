const std = @import("std");

pub const JSON = struct {
    data: []u8,

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !JSON {
        const data = try allocator.dupe(u8, text);
        return JSON{ .data = data };
    }

    pub fn deinit(self: JSON, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn toString(self: JSON, allocator: std.mem.Allocator) ![]u8 {
        return try allocator.dupe(u8, self.data);
    }

    pub fn parse(self: JSON, allocator: std.mem.Allocator, comptime T: type) !T {
        const result = try std.json.parseFromSlice(T, allocator, self.data, .{ .allocate = .alloc_always });
        defer result.deinit(); // We'll return the value, so clean up the ParseResult wrapper
        return result.value;
    }
};

pub const JSONB = struct {
    data: []u8,

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !JSONB {
        const data = try allocator.dupe(u8, text);
        return JSONB{ .data = data };
    }

    pub fn deinit(self: JSONB, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn toString(self: JSONB, allocator: std.mem.Allocator) ![]u8 {
        return try allocator.dupe(u8, self.data);
    }

    pub fn parse(self: JSONB, allocator: std.mem.Allocator, comptime T: type) !T {
        const result = try std.json.parseFromSlice(T, allocator, self.data, .{ .allocate = .alloc_always });
        defer result.deinit();
        return result.value;
    }
};
