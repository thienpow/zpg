pub const Config = struct {
    host: []const u8,
    port: u16,
    username: []const u8,
    database: ?[]const u8,
    password: ?[]const u8,
    ssl: bool = true, // Optional field with a default value
};
