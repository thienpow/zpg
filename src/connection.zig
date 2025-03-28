const std = @import("std");
const mem = std.mem;
const net = std.net;

const Auth = @import("auth.zig").Auth;
const types = @import("types.zig");
const ConnectionState = types.ConnectionState;
const RequestType = types.RequestType;
const ResponseType = types.ResponseType;
const CommandType = types.CommandType;
const Config = @import("config.zig").Config;
const net_utils = @import("net.zig");
const tls = @import("tls.zig");

pub const Connection = struct {
    stream: net.Stream,
    tls_client: ?tls.Client = null,
    allocator: mem.Allocator,
    state: ConnectionState = .Disconnected,
    config: Config,
    statement_cache: std.StringHashMap(CommandType),
    protocol_version: u32 = 0x30000,

    comptime {
        if (@alignOf(Connection) != 8) { // Or whatever alignment you expect
            @compileError("Connection has unexpected alignment");
        }
    }

    pub fn init(allocator: mem.Allocator, config: Config) !Connection {
        const address = try net_utils.resolveHostname(allocator, config.host, config.port);
        const stream = try net.tcpConnectToAddress(address);

        return Connection{
            .stream = stream,
            .allocator = allocator,
            .state = .Disconnected,
            .config = config,
            .statement_cache = std.StringHashMap(CommandType).init(allocator),
        };
    }

    pub fn deinit(self: *Connection) void {
        if (self.state == .Connected) {
            self.sendMessage(@intFromEnum(RequestType.Terminate), "", true) catch |err| {
                std.debug.print("Failed to send termination for {s}: {}\n", .{ self.config.host, err });
            };
        }
        self.stream.close();
        self.state = .Disconnected;

        var it = self.statement_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.statement_cache.deinit();
    }

    pub fn connect(self: *Connection) !void {
        self.state = .Connecting;

        switch (self.config.tls_mode) {
            .disable => {},
            .prefer, .require => {
                try self.negotiateTLS();
            },
        }

        try self.startup();

        const auth = Auth.init(self.allocator, self);
        try auth.authenticate();

        var buffer: [1024]u8 = undefined;
        while (true) {
            const msg_len = try self.readMessage(&buffer);
            var fbs = std.io.fixedBufferStream(buffer[0..msg_len]);
            const reader = fbs.reader();

            const response_type: ResponseType = @enumFromInt(try reader.readByte());

            switch (response_type) {
                .ParameterStatus => {
                    const key = try reader.readUntilDelimiterAlloc(self.allocator, 0, 256);
                    defer self.allocator.free(key);
                    const value = try reader.readUntilDelimiterAlloc(self.allocator, 0, 256);
                    defer self.allocator.free(value);
                },
                .BackendKeyData => {
                    const pid = try reader.readInt(i32, .big);
                    const secret = try reader.readInt(i32, .big);
                    _ = pid;
                    _ = secret;
                },
                .ReadyForQuery => {
                    const status = try reader.readByte();
                    _ = status;
                    self.state = .Connected;
                    break;
                },
                .ErrorResponse => {
                    std.debug.print("ErrorResponse from {s}: {s}\n", .{ self.config.host, buffer[1..msg_len] });
                    self.state = .Error;
                    return error.ConnectionFailed;
                },
                else => return error.ProtocolError,
            }
        }
    }

    pub fn isAlive(self: *Connection) bool {
        return self.state == .Connected;
    }

    pub fn sendMessage(self: *Connection, request_type: u8, payload: []const u8, append_null: bool) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        const total_size = 1 + 4 + payload.len + @intFromBool(append_null);
        try buffer.ensureTotalCapacity(total_size);

        const writer = buffer.writer();
        try writer.writeByte(request_type);
        try writer.writeInt(i32, @intCast(4 + payload.len + @intFromBool(append_null)), .big);
        try writer.writeAll(payload);
        if (append_null) try writer.writeByte(0);

        if (self.tls_client) |*tls_client| {
            try tls_client.writeAll(self.stream, buffer.items);
        } else {
            try self.stream.writeAll(buffer.items);
        }
    }

    pub fn readMessage(self: *Connection, buffer: []u8) !usize {
        if (self.tls_client) |*tls_client| {
            return try tls.readMessage(tls_client, self.stream, buffer);
        } else {
            const header = try self.stream.reader().readBytesNoEof(5);
            const len = std.mem.readInt(i32, header[1..5], .big);
            if (len < 4) return error.ProtocolError;

            const total_len: usize = @intCast(len + 1);
            if (buffer.len < total_len) return error.BufferTooSmall;

            std.mem.copyForwards(u8, buffer[0..5], &header);
            const payload = buffer[5..total_len];
            const bytes_read = try self.stream.reader().readAtLeast(payload, payload.len);

            if (bytes_read < payload.len) return error.UnexpectedEOF;
            return total_len;
        }
    }

    pub fn readMessageType(self: *Connection, buffer: []u8) !struct { type: u8, len: usize } {
        const total_len = try self.readMessage(buffer);
        if (total_len < 1) return error.ProtocolError;
        const response_type = buffer[0];
        return .{ .type = response_type, .len = total_len };
    }

    fn startup(self: *Connection) !void {
        var buffer: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        const writer = fbs.writer();

        try writer.writeInt(i32, 0, .big);
        try writer.writeInt(u32, self.protocol_version, .big);
        try writer.writeAll("user\x00");
        try writer.writeAll(self.config.username);
        try writer.writeByte(0);
        try writer.writeAll("database\x00");
        try writer.writeAll(self.config.database orelse self.config.username);
        try writer.writeByte(0);
        try writer.writeByte(0);

        const len: i32 = @intCast(fbs.pos);
        fbs.reset();
        try writer.writeInt(i32, len, .big);

        if (self.tls_client) |*tls_client| {
            try tls_client.writeAll(self.stream, buffer[0..@intCast(len)]);
        } else {
            try self.stream.writeAll(buffer[0..@intCast(len)]);
        }
    }

    fn negotiateTLS(self: *Connection) !void {
        switch (self.config.tls_mode) {
            .disable => return,
            .prefer, .require => {
                try tls.requestTLS(self.stream);
                const response = try tls.readTLSResponse(self.stream);
                if (response == 'S') {
                    self.tls_client = try tls.initClient(
                        self.stream,
                        self.config.host,
                        self.allocator,
                        self.config.tls_ca_file,
                        self.config.tls_client_cert,
                        self.config.tls_client_key,
                    );
                } else if (response == 'N') {
                    if (self.config.tls_mode == .require) {
                        return error.TLSRequiredButNotSupported;
                    }
                } else {
                    return error.InvalidTLSResponse;
                }
            },
        }
    }
};
