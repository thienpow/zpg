const std = @import("std");
const Allocator = std.mem.Allocator;

pub const RLSContext = struct {
    settings: std.StringHashMap([]const u8), // key: setting name, value: setting value

    pub fn init(allocator: Allocator) RLSContext {
        return .{ .settings = std.StringHashMap([]const u8).init(allocator) };
    }

    // Adds or updates a setting. Takes ownership of copies of key and value.
    pub fn put(self: *RLSContext, allocator: Allocator, key: []const u8, value: []const u8) !void {
        // Prevent potential SQL injection in keys. Basic validation.
        for (key) |c| {
            // Allow alphanumeric, underscore, and dot (common for hierarchical settings)
            // Disallow potentially problematic characters like quotes, semicolons, etc.
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') {
                std.debug.print("Invalid character '{c}' found in RLS setting name: {s}\n", .{ c, key });
                return error.InvalidRLSSettingName;
            }
        }
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        const value_copy = try allocator.dupe(u8, value);
        errdefer allocator.free(value_copy);

        // If put replaced an old value, free the old ones
        if (self.settings.getEntry(key_copy)) |entry| {
            // Key exists, free the OLD value before putting the new one
            allocator.free(entry.value_ptr.*);
            // Update the value in place
            entry.value_ptr.* = value_copy;
            // We don't need the key_copy anymore since the key didn't change
            allocator.free(key_copy);
        } else {
            // Key doesn't exist, put the new key and value
            // The hash map takes ownership of key_copy and value_copy here
            try self.settings.put(key_copy, value_copy);
        }
    }

    pub fn deinit(self: *RLSContext, allocator: Allocator) void {
        var it = self.settings.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.settings.deinit();
    }
};
