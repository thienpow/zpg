/// A PostgreSQL client library for Zig, providing connection management,
/// query execution, and result handling.
pub const version = "0.1.0";

pub const Connection = @import("connection.zig").Connection;
pub const Query = @import("query.zig").Query;
pub const Config = @import("config.zig").Config;
pub const ConnectionPool = @import("pool.zig").ConnectionPool;
pub const PooledConnection = @import("pool.zig").PooledConnection;
pub const Transaction = @import("transaction.zig").Transaction;
pub const Param = @import("param.zig").Param;

pub const types = @import("types.zig");
pub const field = @import("field/mod.zig");

/// The primary error set for the PostgreSQL client library.
pub const Error = types.Error;
