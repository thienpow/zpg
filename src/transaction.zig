const std = @import("std");
const types = @import("types.zig");
const Connection = @import("connection.zig").Connection;

pub const Transaction = struct {
    conn: *Connection,
    isolation_level: types.IsolationLevel,

    pub fn begin(self: *Transaction) types.Error!void {
        _ = self;
        // Send BEGIN command
    }

    pub fn commit(self: *Transaction) types.Error!void {
        _ = self;
        // Send COMMIT command
    }

    pub fn rollback(self: *Transaction) types.Error!void {
        _ = self;
        // Send ROLLBACK command
    }
};
