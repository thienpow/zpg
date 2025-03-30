const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const Connection = @import("connection.zig").Connection;
const Query = @import("query.zig").Query;
const QueryEx = @import("queryEx.zig").QueryEx;
const Config = @import("config.zig").Config;
const RLSContext = @import("rls.zig").RLSContext;
const types = @import("types.zig");

/// Possible error types for connection pool operations
// pub const PoolError = error{
//     NoAvailableConnections,
//     ConnectionNotFound,
//     PoolIsFull,
//     InitializationFailed,
//     ConnectionFailed,
//     PoolClosed,
//     Timeout,
// };

/// A thread-safe connection pool for PostgreSQL connections
pub const ConnectionPool = struct {
    /// Array of all connections managed by the pool
    connections: []Connection,

    /// Memory allocator
    allocator: Allocator,

    /// Bitset tracking which connections are available (1 = available, 0 = in use)
    available_bitmap: std.DynamicBitSet,

    /// Mutex for thread safety
    mutex: Mutex,

    /// Condition variable for waiting threads
    condition: Condition,

    /// Configuration used for initializing connections
    config: Config,

    /// Whether the pool has been closed
    is_closed: bool = false,

    /// Total size of the pool
    size: usize,

    /// Number of connections currently available
    available_count: usize,

    /// Connection timeout in milliseconds (0 = no timeout)
    timeout_ms: u64 = 0,

    /// Initializes a new connection pool with the specified configuration and size
    pub fn init(allocator: Allocator, config: Config, size: usize) !ConnectionPool {
        if (size == 0) return error.InitializationFailed;

        // Allocate connections array
        const connections = try allocator.alloc(Connection, size);
        errdefer allocator.free(connections);

        // Initialize the bitmap for tracking available connections
        var available_bitmap = try std.DynamicBitSet.initFull(allocator, size);
        errdefer available_bitmap.deinit();

        // Track initialized connections for cleanup
        var initialized_count: usize = 0;
        errdefer for (connections[0..initialized_count]) |*conn| {
            conn.deinit();
        };

        // Initialize each connection
        var failed_count: usize = 0;
        for (connections, 0..) |*conn, i| {
            conn.* = Connection.init(allocator, config) catch |err| {
                std.debug.print("Connection.init failed ({}): {}\n", .{ i, err });
                failed_count += 1;
                available_bitmap.unset(i);
                continue;
            };
            initialized_count += 1;

            // Connect immediately to verify connection works
            conn.connect() catch |err| {
                std.debug.print("Connection.connect failed ({}): {}\n", .{ i, err });
                failed_count += 1;
                available_bitmap.unset(i);
                conn.deinit();
                initialized_count -= 1;
                continue;
            };
        }

        // If all connections failed, return error
        if (failed_count == size) {
            return error.InitializationFailed;
        }

        return ConnectionPool{
            .connections = connections,
            .allocator = allocator,
            .available_bitmap = available_bitmap,
            .mutex = .{},
            .condition = .{},
            .config = config,
            .size = size,
            .available_count = size - failed_count,
        };
    }

    /// Frees all resources associated with the connection pool
    pub fn deinit(self: *ConnectionPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.is_closed = true;

        // Close all connections
        for (self.connections) |*conn| {
            conn.deinit();
        }

        // Free memory
        self.allocator.free(self.connections);
        self.available_bitmap.deinit();

        // Signal any waiting threads
        self.condition.broadcast();
    }

    /// Gets an available connection, optionally applying RLS context.
    pub fn get(self: *ConnectionPool, rls_context: ?*const RLSContext) !*Connection {
        return self.getWithTimeout(self.timeout_ms, rls_context);
    }

    /// Gets an available connection with a specified timeout
    pub fn getWithTimeout(self: *ConnectionPool, timeout_ms: u64, rls_context: ?*const RLSContext) !*Connection {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed) return error.PoolClosed;

        // Wait for an available connection
        const start_time = std.time.milliTimestamp();
        while (self.available_count == 0) {
            if (timeout_ms > 0) {
                const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
                if (elapsed >= timeout_ms) {
                    return error.Timeout;
                }
                const remaining = timeout_ms - elapsed;
                const timeout_ns = remaining * std.time.ns_per_ms;
                self.condition.timedWait(&self.mutex, timeout_ns) catch {
                    return error.Timeout;
                };
            } else {
                self.condition.wait(&self.mutex);
            }

            if (self.is_closed) return error.PoolClosed;
        }

        // Find an available connection
        const index = self.findAvailableConnection() orelse return error.NoAvailableConnections;

        // Mark as unavailable
        self.available_bitmap.unset(index);
        self.available_count -= 1;

        // Check connection health and reconnect if needed
        var conn = &self.connections[index];
        if (!conn.isAlive()) {
            // Close existing connection if needed
            conn.deinit();

            // Recreate the connection
            conn.* = Connection.init(self.allocator, self.config) catch {
                // Return connection to pool and propagate error
                self.available_bitmap.set(index);
                self.available_count += 1;
                self.condition.signal();
                return error.ConnectionFailed;
            };

            // Connect to the database
            conn.connect() catch {
                // Return connection to pool and propagate error
                self.available_bitmap.set(index);
                self.available_count += 1;
                self.condition.signal();
                return error.ConnectionFailed;
            };
        }

        // --- RLS Integration START ---
        // RESET the connection state *before* applying new context
        // Use a temporary Query object to execute commands
        var temp_query = Query.init(self.allocator, conn);
        // Ignore errors during reset? Or log them? If reset fails, the connection state is uncertain.
        // Maybe force deinit/reconnect if reset fails. For now, try-catch and log.
        self.resetRLSContext(&temp_query) catch |err| {
            std.debug.print("WARN: Failed to reset RLS context on connection {}: {}\n", .{ index, err });
            // Potentially mark connection as bad and try getting another?
            // For simplicity now, proceed, but this is a risk point.
        };

        // Apply the new RLS context if provided
        if (rls_context) |ctx| {
            self.applyRLSContext(&temp_query, ctx) catch |err| {
                std.debug.print("ERROR: Failed to apply RLS context on connection {}: {}\n", .{ index, err });
                // Return the connection to the pool *after* attempting reset again
                self.resetRLSContext(&temp_query) catch {}; // Best effort cleanup
                self.available_bitmap.set(index);
                self.available_count += 1;
                self.condition.signal();
                return error.RLSContextError; // Specific error
            };
        }
        // --- RLS Integration END ---
        return conn;
    }

    /// Returns a connection to the pool
    pub fn release(self: *ConnectionPool, conn: *Connection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed) return;

        const index = self.findConnectionIndex(conn) orelse return error.ConnectionNotFound;

        // --- RLS Integration START ---
        // Reset RLS context *before* marking as available
        var temp_query = Query.init(self.allocator, conn);
        self.resetRLSContext(&temp_query) catch |err| {
            std.debug.print("WARN: Failed to reset RLS context on release for connection {}: {}\n", .{ index, err });
            // What to do here? If reset fails, the connection is potentially tainted.
            // Option 1: Log and proceed (risk).
            // Option 2: Don't return to pool, close it, try to replace later (complex).
            // Option 3: Mark as needing reset on next 'get'.
            // Let's stick with logging for now, but document the risk.
        };
        // --- RLS Integration END ---

        // If connection is in error state, recreate it
        if (conn.state == .Error) {
            // Close existing connection
            conn.deinit();

            // Recreate connection
            self.connections[index] = Connection.init(self.allocator, self.config) catch {
                // Connection failed, but we still mark it as available
                // since we can try to reconnect later when someone gets it
                self.available_bitmap.set(index);
                self.available_count += 1;
                self.condition.signal();
                return;
            };

            // Connect to database
            self.connections[index].connect() catch {
                // Connection failed, but we still mark it as available
                self.available_bitmap.set(index);
                self.available_count += 1;
                self.condition.signal();
                return;
            };
        }

        // Mark connection as available
        if (!self.available_bitmap.isSet(index)) { // Avoid double-release issues
            self.available_bitmap.set(index);
            self.available_count += 1;
            self.condition.signal(); // Signal only if a connection was actually made available
        } else {
            std.debug.print("WARN: Attempted to release connection {} which was already available.\n", .{index});
        }
    }

    /// Gets the number of available connections
    pub fn getAvailableCount(self: *ConnectionPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.available_count;
    }

    /// Gets the total connection pool size
    pub fn getSize(self: *ConnectionPool) usize {
        return self.size;
    }

    /// Sets the connection timeout in milliseconds
    pub fn setTimeout(self: *ConnectionPool, timeout_ms: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.timeout_ms = timeout_ms;
    }

    /// Finds the index of the first available connection
    fn findAvailableConnection(self: *ConnectionPool) ?usize {
        var it = self.available_bitmap.iterator(.{});
        return it.next();
    }

    /// Finds the index of a connection by pointer
    fn findConnectionIndex(self: *ConnectionPool, conn: *Connection) ?usize {
        for (self.connections, 0..) |*c, i| {
            if (c == conn) {
                return i;
            }
        }
        return null;
    }

    /// Closes and reopens all connections in the pool
    pub fn reset(self: *ConnectionPool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed) return error.PoolClosed;

        // Close all connections
        for (self.connections) |*conn| {
            conn.deinit();
        }

        // Reset bitmap and counters
        self.available_bitmap.setRangeValue(.{
            .start = 0,
            .end = self.size,
        }, true);

        var failed_count: usize = 0;

        // Recreate all connections
        for (self.connections, 0..) |*conn, i| {
            conn.* = Connection.init(self.allocator, self.config) catch {
                failed_count += 1;
                self.available_bitmap.unset(i);
                continue;
            };

            conn.connect() catch {
                failed_count += 1;
                self.available_bitmap.unset(i);
                conn.deinit();
                continue;
            };
        }

        self.available_count = self.size - failed_count;

        // Signal waiting threads
        self.condition.broadcast();

        if (self.available_count == 0) {
            return error.InitializationFailed;
        }
    }

    // Helper to apply RLS context using SET SESSION
    fn applyRLSContext(self: *ConnectionPool, query: *Query, ctx: *const RLSContext) !void {
        var it = ctx.settings.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            // Escape the value to prevent SQL injection
            // NOTE: Simple escaping (doubling quotes) might not be fully robust for all
            // possible setting values, but is common for RLS IDs.
            var escaped_value = std.ArrayList(u8).init(self.allocator);
            defer escaped_value.deinit();
            for (value) |char| {
                if (char == '\'') try escaped_value.appendSlice("''") else try escaped_value.append(char);
            }

            // Construct and run SET SESSION command
            // Using ? for allocPrint allows failure if OOM
            const set_sql = try std.fmt.allocPrint(self.allocator, "SET SESSION \"{s}\" = '{s}'", .{ key, escaped_value.items });
            defer self.allocator.free(set_sql);

            std.debug.print("Applying RLS: {s}\n", .{set_sql}); // Debug logging
            const result = try query.run(set_sql, types.Empty); // Use Empty for commands not returning data
            if (!result.success) {
                // This implies processSimpleCommand received an ErrorResponse
                std.debug.print("ERROR: Failed to execute: {s}\n", .{set_sql});
                return error.RLSContextError;
            }
        }
    }

    // Helper to reset RLS context
    fn resetRLSContext(_: *ConnectionPool, query: *Query) !void {
        // Option 1: Reset specific keys (requires tracking which keys were set)
        // Option 2: Use RESET ALL - simpler, but resets *everything*. Probably safer for pooling.
        const reset_sql = "RESET ALL";
        std.debug.print("Resetting RLS context: {s}\n", .{reset_sql});
        const result = try query.run(reset_sql, types.Empty);
        if (!result.success) {
            std.debug.print("ERROR: Failed to execute: {s}\n", .{reset_sql});
            return error.RLSResetFailed; // Specific error
        }
    }
};

/// A wrapper for automatically returning connections to the pool
pub const PooledConnection = struct {
    conn: *Connection,
    pool: *ConnectionPool,

    pub fn init(pool: *ConnectionPool, rls_context: ?*const RLSContext) !PooledConnection {
        const conn = try pool.get(rls_context);
        return PooledConnection{
            .conn = conn,
            .pool = pool,
        };
    }

    pub fn deinit(self: *PooledConnection) void {
        self.pool.release(self.conn) catch {};
    }

    pub fn connection(self: *PooledConnection) *Connection {
        return self.conn;
    }

    pub fn createQuery(self: *PooledConnection, allocator: Allocator) Query {
        return Query.init(allocator, self.conn);
    }

    pub fn createQueryEx(self: *PooledConnection, allocator: Allocator) QueryEx {
        return QueryEx.init(allocator, self.conn);
    }
};
