const std = @import("std");

pub const TLSMode = enum {
    disable, // No TLS
    prefer, // Try TLS, fall back to unencrypted if unavailable
    require, // Require TLS, fail if unavailable
};

pub const Config = struct {
    host: []const u8,
    port: u16 = 5432, // Default PostgreSQL port
    username: []const u8,
    database: ?[]const u8 = null,
    password: ?[]const u8 = null,
    tls_mode: TLSMode = .prefer, // Default: attempt TLS, allow unencrypted if unsupported
    tls_ca_file: ?[]const u8 = null, // Path to CA certificate file (optional)
    tls_client_cert: ?[]const u8 = null, // Path to client certificate (optional)
    tls_client_key: ?[]const u8 = null, // Path to client key (optional)
    timeout: u32 = 10_000, // Connection timeout in milliseconds

    /// Validates the configuration, returning an error if invalid.
    pub fn validate(self: Config) !void {
        if (self.host.len == 0) return error.EmptyHost;
        if (self.username.len == 0) return error.EmptyUsername;
        if (self.port == 0) return error.InvalidPort;
        if (self.tls_mode == .require and self.tls_client_cert != null and self.tls_client_key == null) {
            return error.TLSClientCertNeedsKey; // Ensure key is paired with cert
        }
    }
};
