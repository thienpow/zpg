const std = @import("std");
const Query = @import("query.zig").Query;
const types = @import("types.zig");
const RequestType = types.RequestType;

pub const Transaction = struct {
    query: *Query,
    active: bool,

    pub fn begin(query: *Query) !Transaction {
        try query.conn.sendMessage(@intFromEnum(RequestType.Query), "BEGIN", true);
        _ = try query.protocol.processSimpleCommand();
        return Transaction{ .query = query, .active = true };
    }

    pub fn commit(self: *Transaction) !void {
        if (!self.active) return error.NoActiveTransaction;
        try self.query.conn.sendMessage(@intFromEnum(RequestType.Query), "COMMIT", true);
        _ = try self.query.protocol.processSimpleCommand();
        self.active = false;
    }

    pub fn rollback(self: *Transaction) !void {
        if (!self.active) return error.NoActiveTransaction;
        try self.query.conn.sendMessage(@intFromEnum(RequestType.Query), "ROLLBACK", true);
        _ = try self.query.protocol.processSimpleCommand();
        self.active = false;
    }
};
