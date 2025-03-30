const std = @import("std");
const Query = @import("query.zig").Query;
const types = @import("types.zig");
const RequestType = types.RequestType;
const RLSContext = @import("rls.zig").RLSContext;

pub const Transaction = struct {
    query: *Query,
    active: bool,

    pub fn begin(query: *Query, rls_context: ?*const RLSContext) !Transaction {
        _ = try query.run("BEGIN", types.Empty);

        // Apply local settings if context is provided
        if (rls_context) |ctx| {
            var it = ctx.settings.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const value = entry.value_ptr.*;

                // Similar escaping and command building as in applyRLSContext, but use SET LOCAL
                var escaped_value = std.ArrayList(u8).init(query.allocator); // Use query's allocator
                defer escaped_value.deinit();
                for (value) |char| {
                    if (char == '\'') try escaped_value.appendSlice("''") else try escaped_value.append(char);
                }

                // Use SET LOCAL
                const set_sql = try std.fmt.allocPrint(query.allocator, "SET LOCAL \"{s}\" = '{s}'", .{ key, escaped_value.items });
                defer query.allocator.free(set_sql);

                std.debug.print("Applying local RLS: {s}\n", .{set_sql});
                const result = try query.run(set_sql, types.Empty);
                if (!result.success) {
                    // If setting local fails, we should probably rollback immediately
                    _ = query.run("ROLLBACK", types.Empty) catch {}; // Best effort rollback
                    return error.RLSContextError;
                }
            }
        }

        return Transaction{ .query = query, .active = true };
    }

    pub fn commit(self: *Transaction) !void {
        if (!self.active) return error.NoActiveTransaction;
        const result = try self.query.run("COMMIT", types.Empty);
        self.active = false;
        if (!result.success) return error.CommitFailed;
    }

    pub fn rollback(self: *Transaction) !void {
        if (!self.active) return error.NoActiveTransaction;
        const result = try self.query.run("ROLLBACK", types.Empty);
        self.active = false;
        if (!result.success) return error.RollbackFailed; // Or a more specific error
    }
};
