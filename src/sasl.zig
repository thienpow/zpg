const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const Connection = @import("connection.zig").Connection;
const types = @import("types.zig");
const Error = types.Error;
const RequestType = types.RequestType;
const ResponseType = types.ResponseType;
const AuthType = types.AuthType;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

// SASL SCRAM-SHA-256 Implementation
pub const SASL = struct {
    allocator: Allocator,
    conn: *Connection,
    client_nonce: ?[]u8 = null,
    scram_salt: ?[]u8 = null,
    scram_iterations: ?u32 = null,
    scram_auth_msg: ?[]u8 = null,

    // Initialize SASL
    pub fn init(allocator: Allocator, conn: *Connection) SASL {
        return SASL{
            .allocator = allocator,
            .conn = conn,
        };
    }

    pub fn deinit(self: *SASL) void {
        if (self.client_nonce) |nonce| {
            self.allocator.free(nonce);
            self.client_nonce = null;
        }
        if (self.scram_salt) |salt| {
            self.allocator.free(salt);
            self.scram_salt = null;
        }
        if (self.scram_auth_msg) |msg| {
            self.allocator.free(msg);
            self.scram_auth_msg = null;
        }
    }

    // Send client-first-message for SCRAM-SHA-256
    pub fn sendScramClientFirst(self: *SASL, mechanism: []const u8) !void {
        const nonce = try generateNonce(self.allocator);
        self.client_nonce = nonce;

        const client_first = try std.fmt.allocPrint(self.allocator, "n,,n={s},r={s}", .{ self.conn.config.username, nonce }); // Keep n,, here
        defer self.allocator.free(client_first);

        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();
        try payload.writer().writeAll(mechanism);
        try payload.writer().writeByte(0);
        try payload.writer().writeInt(i32, @intCast(client_first.len), .big);
        try payload.writer().writeAll(client_first);

        try self.conn.sendMessage(@intFromEnum(RequestType.PasswordMessage), payload.items, false);
    }

    // Handle SCRAM challenge and final steps
    pub fn handleScramChallenge(self: *SASL, password: []const u8) !void {
        var buffer: [1024]u8 = undefined;
        const msg_len = try self.conn.readMessage(&buffer);
        var fbs = std.io.fixedBufferStream(buffer[0..msg_len]);
        const reader = fbs.reader();

        const response_type: ResponseType = @enumFromInt(try reader.readByte());
        if (response_type != ResponseType.AuthenticationRequest) return error.ProtocolError;

        _ = try reader.readBytesNoEof(4); // Skip length
        const auth_type = try reader.readInt(i32, .big);
        if (auth_type != 11) return error.ProtocolError;

        const server_first_len = msg_len - 9;
        const server_first = buffer[9 .. 9 + server_first_len];

        var salt: ?[]u8 = null;
        var iterations: ?u32 = null;
        var server_nonce: ?[]const u8 = null;
        var parts = std.mem.splitSequence(u8, server_first, ",");
        const decoder = std.base64.standard.Decoder;
        while (parts.next()) |part| {
            if (std.mem.startsWith(u8, part, "r=")) {
                server_nonce = part[2..];
            } else if (std.mem.startsWith(u8, part, "s=")) {
                const salt_b64 = part[2..];
                const salt_len = try decoder.calcSizeForSlice(salt_b64);
                salt = try self.allocator.alloc(u8, salt_len); // Line 234
                _ = try decoder.decode(salt.?, salt_b64);
            } else if (std.mem.startsWith(u8, part, "i=")) {
                iterations = try std.fmt.parseInt(u32, part[2..], 10);
            }
        }

        if (salt == null or iterations == null or server_nonce == null) {
            if (salt) |s| self.allocator.free(s);
            return error.InvalidServerResponse;
        }

        // Free salt on any exit (error or success)
        defer if (salt) |s| self.allocator.free(s);

        const client_final = try self.computeScramFinal(password, salt.?, iterations.?, server_first, server_nonce.?);
        defer self.allocator.free(client_final);
        try self.conn.sendMessage(@intFromEnum(RequestType.PasswordMessage), client_final, false);

        try self.handleScramFinal();
    }

    // Send client-final-message
    fn sendScramClientFinal(self: *SASL, client_final: []const u8) !void {
        // Simply call sendMessage directly with the client_final data
        try self.conn.sendMessage(@intFromEnum(RequestType.PasswordMessage), client_final, false);
    }

    // Handle server-final-message
    fn handleScramFinal(self: *SASL) !void {
        var buffer: [1024]u8 = undefined;
        const msg_len = try self.conn.readMessage(&buffer);
        var fbs = std.io.fixedBufferStream(buffer[0..msg_len]);
        const reader = fbs.reader();

        const response_type: ResponseType = @enumFromInt(try reader.readByte());
        switch (response_type) {
            .AuthenticationRequest => {
                _ = try reader.readBytesNoEof(4); // Skip length
                const auth_type: AuthType = @enumFromInt(try reader.readInt(i32, .big));
                if (auth_type != .SaslContinue) return error.ProtocolError;

                const remaining_len = msg_len - 5;
                const server_final = try reader.readAllAlloc(self.allocator, remaining_len);
                defer self.allocator.free(server_final);

                if (!std.mem.startsWith(u8, server_final, "v=")) {
                    return error.InvalidServerResponse;
                }
                const server_signature_b64 = server_final[2..];
                const decoder = std.base64.standard.Decoder;
                const expected_len = try decoder.calcSizeForSlice(server_signature_b64);
                if (expected_len != 32) {
                    return error.InvalidServerResponse;
                }

                var server_signature: [32]u8 = undefined;
                try decoder.decode(&server_signature, server_signature_b64);

                // Compute expected ServerSignature
                const salt = self.scram_salt orelse return error.MissingScramData;
                const iterations = self.scram_iterations orelse return error.MissingScramData;
                const auth_msg = self.scram_auth_msg orelse return error.MissingScramData;
                const password = self.conn.config.password orelse return error.MissingPassword; // Unwrap here

                var salted_password: [Sha256.digest_length]u8 = undefined;
                try std.crypto.pwhash.pbkdf2(&salted_password, password, salt, iterations, HmacSha256);
                var server_key: [HmacSha256.mac_length]u8 = undefined;
                HmacSha256.create(&server_key, "Server Key", &salted_password);
                var expected_signature: [HmacSha256.mac_length]u8 = undefined;
                HmacSha256.create(&expected_signature, auth_msg, &server_key);

                if (!std.mem.eql(u8, &server_signature, &expected_signature)) {
                    return error.ServerSignatureMismatch;
                }

                // Clean up SCRAM state
                self.allocator.free(salt);
                self.scram_salt = null;
                self.allocator.free(auth_msg);
                self.scram_auth_msg = null;
                self.scram_iterations = null;
            },
            .ErrorResponse => {
                return error.AuthenticationFailed;
            },
            else => {
                return error.ProtocolError;
            },
        }
    }

    // Compute SCRAM client-final-message (simplified)
    fn computeScramFinal(self: *SASL, password: []const u8, salt: []u8, iterations: u32, server_first: []const u8, server_nonce: []const u8) ![]u8 {
        var salted_password: [Sha256.digest_length]u8 = undefined;
        try std.crypto.pwhash.pbkdf2(&salted_password, password, salt, iterations, HmacSha256);

        var client_key: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(&client_key, "Client Key", &salted_password);

        var stored_key: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(&client_key, &stored_key, .{});

        const client_nonce = self.client_nonce orelse return error.NoClientNonce;
        const client_first_bare = try std.fmt.allocPrint(self.allocator, "n={s},r={s}", .{ self.conn.config.username, client_nonce });
        defer self.allocator.free(client_first_bare);
        self.scram_auth_msg = try std.fmt.allocPrint(self.allocator, "{s},{s},c=biws,r={s}", .{ client_first_bare, server_first, server_nonce });

        var client_signature: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(&client_signature, self.scram_auth_msg.?, &stored_key);

        var client_proof: [HmacSha256.mac_length]u8 = undefined;
        for (client_key, client_signature, 0..) |ck, cs, i| {
            client_proof[i] = ck ^ cs;
        }

        // Store salt and iterations
        self.scram_salt = try self.allocator.dupe(u8, salt);
        self.scram_iterations = iterations;

        const encoder = std.base64.standard.Encoder;
        const proof_b64_len = encoder.calcSize(client_proof.len);
        const proof_b64 = try self.allocator.alloc(u8, proof_b64_len);
        _ = encoder.encode(proof_b64, &client_proof);

        const result = try std.fmt.allocPrint(self.allocator, "c=biws,r={s},p={s}", .{ server_nonce, proof_b64 });
        self.allocator.free(proof_b64);
        return result;
    }

    // Generate a random nonce
    fn generateNonce(allocator: std.mem.Allocator) ![]u8 {
        var nonce: [24]u8 = undefined;
        std.crypto.random.bytes(&nonce);

        // Calculate the size of the Base64-encoded output
        const encoded_size = std.base64.standard.Encoder.calcSize(nonce.len);
        const encoded = try allocator.alloc(u8, encoded_size);

        // Encode the nonce into the allocated buffer
        _ = std.base64.standard.Encoder.encode(encoded, &nonce);

        return encoded;
    }
};
