const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const Connection = @import("connection.zig").Connection;
const Query = @import("query.zig").Query;
const Config = @import("config.zig").Config;
const types = @import("types.zig");
const Error = types.Error;

/// Possible error types for connection pool operations
pub const PoolError = error{
    NoAvailableConnections,
    ConnectionNotFound,
    PoolIsFull,
    InitializationFailed,
    ConnectionFailed,
    PoolClosed,
    Timeout,
} || Error;

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
    timeout_ms: u64 = 5000,

    /// Initializes a new connection pool with the specified configuration and size
    pub fn init(allocator: Allocator, config: Config, size: usize) PoolError!ConnectionPool {
        if (size == 0) return error.InitializationFailed;

        // Allocate connections array
        const connections = try allocator.alloc(Connection, size);
        errdefer allocator.free(connections);

        // Initialize the bitmap for tracking available connections
        var available_bitmap = try std.DynamicBitSet.initFull(allocator, size);
        errdefer available_bitmap.deinit();

        // Initialize each connection
        var failed_count: usize = 0;
        for (connections, 0..) |*conn, i| {
            conn.* = Connection.init(allocator, config) catch {
                failed_count += 1;
                available_bitmap.unset(i);
                continue;
            };

            // Connect immediately to verify connection works
            conn.connect() catch {
                failed_count += 1;
                available_bitmap.unset(i);
                conn.deinit();
                continue;
            };
        }

        // If all connections failed, return error
        if (failed_count == size) {
            allocator.free(connections);
            available_bitmap.deinit();
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

    /// Gets an available connection from the pool, waiting if necessary
    pub fn get(self: *ConnectionPool) PoolError!*Connection {
        return self.getWithTimeout(self.timeout_ms);
    }

    /// Gets an available connection with a specified timeout
    pub fn getWithTimeout(self: *ConnectionPool, timeout_ms: u64) PoolError!*Connection {
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

        return conn;
    }

    /// Returns a connection to the pool
    pub fn release(self: *ConnectionPool, conn: *Connection) PoolError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed) return;

        const index = self.findConnectionIndex(conn) orelse return error.ConnectionNotFound;

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
        self.available_bitmap.set(index);
        self.available_count += 1;

        // Signal waiting threads
        self.condition.signal();
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
    pub fn reset(self: *ConnectionPool) PoolError!void {
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
};

/// A wrapper for automatically returning connections to the pool
pub const PooledConnection = struct {
    conn: *Connection,
    pool: *ConnectionPool,

    pub fn init(pool: *ConnectionPool) PoolError!PooledConnection {
        const conn = try pool.get();
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
};
