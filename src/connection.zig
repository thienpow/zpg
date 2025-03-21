const std = @import("std");
const mem = std.mem;
const net = std.net;
const posix = std.posix;

const Auth = @import("auth.zig").Auth;

const types = @import("types.zig");
const Error = types.Error;
const ConnectionState = types.ConnectionState;
const TypeInfo = types.TypeInfo;

const net_utils = @import("net.zig");
const Config = @import("config.zig").Config;

const StatementInfo = types.StatementInfo;
const StatementCache = std.StringHashMap(StatementInfo);

pub const Connection = struct {
    stream: net.Stream,
    allocator: mem.Allocator,
    state: ConnectionState = .Disconnected,
    config: Config,
    statement_cache: std.StringHashMap(StatementInfo),

    /// PostgreSQL protocol version (3.0 by default)
    protocol_version: u32 = 0x30000,

    /// Initializes a new PostgreSQL connection
    pub fn init(allocator: mem.Allocator, config: Config) Error!Connection {
        const address = try net_utils.resolveHostname(allocator, config.host, config.port);
        const stream = try net.tcpConnectToAddress(address);

        return Connection{
            .stream = stream,
            .allocator = allocator,
            .state = .Disconnected,
            .config = config,
            .statement_cache = StatementCache.init(allocator),
        };
    }

    /// Closes the connection and cleans up resources
    pub fn deinit(self: *Connection) void {
        if (self.state == .Connected) {
            self.sendTermination() catch |err| {
                std.debug.print("Failed to send termination: {}\n", .{err});
            };
        }
        self.stream.close();
        self.state = .Disconnected;

        var it = self.statement_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*); // Free dupe_name
            self.allocator.free(entry.value_ptr.query); // Free dupe_query
        }
        self.statement_cache.deinit();
    }

    pub fn connect(self: *Connection) Error!void {
        self.state = .Connecting;
        try self.startup();

        const auth = Auth.init(self.allocator, self);
        auth.authenticate() catch |err| {
            self.state = .Error;
            return err;
        };

        // Process server messages until ReadyForQuery ('Z')
        var buffer: [1024]u8 = undefined;
        while (true) {
            const msg_len = try self.readMessage(&buffer);
            var fbs = std.io.fixedBufferStream(buffer[0..msg_len]);
            const reader = fbs.reader();
            const msg_type = try reader.readByte();

            switch (msg_type) {
                'S' => {
                    // ParameterStatus: key-value pair
                    const key = try reader.readUntilDelimiterAlloc(self.allocator, 0, 256);
                    defer self.allocator.free(key);
                    const value = try reader.readUntilDelimiterAlloc(self.allocator, 0, 256);
                    defer self.allocator.free(value);
                },
                'K' => {
                    // BackendKeyData: PID and secret key
                    const pid = try reader.readInt(i32, .big);
                    const secret = try reader.readInt(i32, .big);
                    _ = pid;
                    _ = secret;
                    // Optionally store these in Connection for cancellation support
                },
                'Z' => {
                    // ReadyForQuery
                    const status = try reader.readByte();
                    _ = status;
                    self.state = .Connected;
                    break;
                },
                'E' => {
                    const err_msg = buffer[1..msg_len];
                    std.debug.print("ErrorResponse: {s}\n", .{err_msg});
                    self.state = .Error;
                    return error.ConnectionFailed;
                },
                else => {
                    return error.ProtocolError;
                },
            }
        }
    }

    pub fn isAlive(self: *Connection) bool {
        return self.state == .Connected;
    }

    /// Generic method to send a PostgreSQL message
    pub fn sendMessage(self: *Connection, msg_type: u8, payload: []const u8, append_null: bool) !void {
        // Calculate total message size: 1 (type) + 4 (length) + payload + optional null
        const total_size = 1 + 4 + payload.len + @intFromBool(append_null);

        // Use an ArrayList for dynamic sizing instead of a fixed buffer
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        // Reserve space to avoid reallocations
        try buffer.ensureTotalCapacity(total_size);

        const writer = buffer.writer();

        // Write message type
        try writer.writeByte(msg_type);

        // Write length (includes length field itself, excludes type byte)
        const length = 4 + payload.len + @intFromBool(append_null);
        try writer.writeInt(i32, @intCast(length), .big);

        // Write payload
        try writer.writeAll(payload);

        // Write null terminator if requested
        if (append_null) {
            try writer.writeByte(0);
        }

        // Send the complete message
        try self.stream.writeAll(buffer.items);
    }

    pub fn readMessageType(self: *Connection, buffer: []u8) !struct { type: u8, len: usize } {
        const total_len = try self.readMessage(buffer);
        if (total_len < 1) return error.ProtocolError;
        const msg_type = buffer[0];
        return .{ .type = msg_type, .len = total_len };
    }

    /// Reads a message from the server, returning the length including type byte
    pub fn readMessage(self: *Connection, buffer: []u8) !usize {
        const header = try self.stream.reader().readBytesNoEof(5);

        const len = std.mem.readInt(i32, header[1..5], .big);
        if (len < 4) return error.ProtocolError;

        const len_usize: usize = @intCast(len);
        const total_len: usize = len_usize + 1;
        if (buffer.len < total_len) return error.BufferTooSmall;

        std.mem.copyForwards(u8, buffer[0..5], &header);
        const payload = buffer[5..total_len];
        const bytes_read = try self.stream.reader().readAtLeast(payload, payload.len);

        if (bytes_read < payload.len) return error.UnexpectedEOF;

        return total_len;
    }

    /// Sends the PostgreSQL startup message and handles authentication
    fn startup(self: *Connection) Error!void {
        // Construct startup message
        var buffer: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        const writer = fbs.writer();

        // Length placeholder (will be filled later)
        try writer.writeInt(i32, 0, .big);

        // Protocol version
        try writer.writeInt(u32, self.protocol_version, .big);

        // Parameters (key-value pairs, null-terminated)
        try writer.writeAll("user\x00");
        try writer.writeAll(self.config.username);
        try writer.writeByte(0);

        try writer.writeAll("database\x00");
        const db_name = self.config.database orelse self.config.username;
        try writer.writeAll(db_name);
        try writer.writeByte(0);

        // Null terminator for parameter list
        try writer.writeByte(0);

        // Update length (excluding the length field itself)
        const len: i32 = @intCast(fbs.pos);
        fbs.reset();
        try writer.writeInt(i32, len, .big);

        // Send startup message
        try self.stream.writeAll(buffer[0..@intCast(len)]);
    }

    /// Sends a termination message
    fn sendTermination(self: *Connection) types.Error!void {
        try self.sendMessage('X', "", true);
    }
};
