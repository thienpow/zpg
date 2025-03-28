const std = @import("std");
const mem = std.mem;
const net = std.net;
const tls = std.crypto.tls;

pub const Client = tls.Client;

/// Initializes a TLS client for the given stream and hostname.
pub fn initClient(
    stream: net.Stream,
    hostname: []const u8,
    allocator: mem.Allocator,
    ca_file: ?[]const u8,
    client_cert: ?[]const u8,
    client_key: ?[]const u8,
) !Client {
    _ = hostname; // Ignore hostname verification for development
    _ = allocator;
    _ = ca_file;
    _ = client_cert;
    _ = client_key;

    const options = tls.Client.Options{
        .host = .no_verification, // Disable hostname verification
        .ca = .no_verification, // Don't verify CA for self-signed certs
        .ssl_key_log_file = null,
    };

    return try Client.init(stream, options);
}

/// Sends a PostgreSQL TLS request message to the server.
pub fn requestTLS(stream: net.Stream) !void {
    const tls_request = [_]u8{
        0, 0, 0, 8, // Length (8 bytes)
        0x04, 0xd2, 0x16, 0x2f, // 80877103 (TLS request code)
    };
    try stream.writeAll(&tls_request);
}

/// Reads the server's single-byte TLS support response ('S' or 'N').
pub fn readTLSResponse(stream: net.Stream) !u8 {
    var response: [1]u8 = undefined;
    const bytes_read = try stream.read(&response);
    if (bytes_read != 1) return error.UnexpectedEOF;
    return response[0];
}

/// Reads a PostgreSQL message over TLS, returning the total length.
pub fn readMessage(client: *Client, stream: net.Stream, buffer: []u8) !usize {
    const header = try client.readAtLeast(stream, buffer[0..5], 5);
    if (header != 5) return error.UnexpectedEOF;

    const len = mem.readInt(i32, buffer[1..5], .big);
    if (len < 4) return error.ProtocolError;

    const total_len: usize = @intCast(len + 1);
    if (buffer.len < total_len) return error.BufferTooSmall;

    const remaining = total_len - 5;
    const bytes_read = try client.readAtLeast(stream, buffer[5..total_len], remaining);
    if (bytes_read < remaining) return error.UnexpectedEOF;

    return total_len;
}

/// Writes data over the TLS connection.
pub fn writeAll(client: *Client, stream: net.Stream, data: []const u8) !void {
    try client.writeAll(stream, data);
}
