const std = @import("std");
const Allocator = std.mem.Allocator;
const SASL = @import("sasl.zig").SASL;

const Connection = @import("connection.zig").Connection;
const types = @import("types.zig");
const Error = types.Error;
const AuthType = types.AuthType;
const ResponseType = types.ResponseType;
const Config = @import("config.zig").Config;

pub const Auth = struct {
    allocator: Allocator,
    conn: *Connection,

    pub fn init(allocator: Allocator, conn: *Connection) Auth {
        return Auth{ .allocator = allocator, .conn = conn };
    }

    pub fn deinit(_: *Auth) void {}

    pub fn authenticate(self: *const Auth) Error!void {
        var sasl = SASL.init(self.allocator, self.conn);
        defer sasl.deinit();

        var buffer: [64]u8 = undefined;
        const msg_len = try self.conn.readMessage(&buffer);
        var fbs = std.io.fixedBufferStream(buffer[0..msg_len]);
        var reader = fbs.reader();

        const response_type: ResponseType = @enumFromInt(try reader.readByte());
        if (response_type != ResponseType.AuthenticationRequest) {
            return error.ProtocolError;
        }

        // Skip length field (already accounted for in msg_len)
        const len = try reader.readInt(i32, .big);
        _ = len; // Unused, just for alignment

        const auth_type: AuthType = @enumFromInt(try reader.readInt(i32, .big));
        switch (auth_type) {
            .AuthenticationOk => { // AuthenticationOk
                return;
            },
            .Sasl => { // SASL (SCRAM-SHA-256)
                var mechanisms = std.ArrayList([]const u8).init(self.allocator);
                defer {
                    for (mechanisms.items) |mech| self.allocator.free(mech);
                    mechanisms.deinit();
                }
                while (true) {
                    const mech = try reader.readUntilDelimiterAlloc(self.allocator, 0, 256);
                    if (mech.len == 0) {
                        self.allocator.free(mech);
                        break;
                    }
                    try mechanisms.append(mech);
                }
                const scram_mech = "SCRAM-SHA-256";
                var supports_scram = false;
                for (mechanisms.items) |mech| {
                    if (std.mem.eql(u8, mech, scram_mech)) {
                        supports_scram = true;
                        break;
                    }
                }
                if (!supports_scram) return error.AuthenticationFailed;
                const password = self.conn.config.password orelse return error.AuthenticationFailed;
                try sasl.sendScramClientFirst(scram_mech);
                try sasl.handleScramChallenge(password);

                // Read AuthenticationOk
                const ok_msg_len = try self.conn.readMessage(&buffer);
                fbs = std.io.fixedBufferStream(buffer[0..ok_msg_len]);
                reader = fbs.reader();

                const ok_response_type: ResponseType = @enumFromInt(try reader.readByte());
                if (ok_response_type != ResponseType.AuthenticationRequest) return error.ProtocolError;

                _ = try reader.readInt(i32, .big); // Skip length
                const ok_auth_type = try reader.readInt(i32, .big);
                if (ok_auth_type != 0) {
                    return error.AuthenticationFailed;
                }
            },
            .KerberosV5 => { // KerberosV5
                return error.KerberosNotSupported;
            },
            .CleartextPassword => { // Cleartext password
                return error.CleartextPasswordNotSupported;
            },
            .Md5Password => { // MD5 password
                return error.Md5PasswordNotSupported;
            },
            .ScmCredentials => { // SCM credentials
                return error.ScmCredentialsNotSupported;
            },
            .Gssapi => { // GSSAPI
                return error.GssapiNotSupported;
            },
            .Sspi => { // SSPI
                return error.SspiNotSupported;
            },
            else => {
                return error.UnknownAuthMethod;
            },
        }
    }
};
