const std = @import("std");
const Config = @import("config.zig").Config;

pub fn md5Hash(input: []const u8, output: *[16]u8) void {
    var hash = std.crypto.hash.Md5.init(.{});
    hash.update(input);
    hash.final(output);
}

pub fn readIntBig(comptime T: type, bytes: []const u8) T {
    return std.mem.readIntBig(T, bytes[0..@sizeOf(T)]);
}

pub fn writeIntBig(comptime T: type, bytes: []u8, value: T) void {
    std.mem.writeIntBig(T, bytes[0..@sizeOf(T)], value);
}

pub fn createConnectionString(config: Config) []const u8 {
    _ = config;
    // Format connection string from config
    // Example: "host=localhost port=5432 user=postgres dbname=test password=secret"
}
