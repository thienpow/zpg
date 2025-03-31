---
layout: default
title: Connections
---

# Connections

`zpg` provides two ways to manage database connections: direct connections and connection pooling.

## Direct Connections (`zpg.Connection`)

A `zpg.Connection` represents a single, direct connection to the PostgreSQL server. It's suitable for simple applications or scenarios where manual connection management is preferred.

**Initialization and Connection:**

```zig
const std = @import("std");
const zpg = @import("zpg");

const allocator = std.testing.allocator; // Or your application's allocator

// 1. Create Config
const config = zpg.Config{
    .host = "127.0.0.1",
    .port = 5432,
    .username = "postgres",
    .database = "zui",
    .password = "postgres",
    .tls_mode = .disable,
};

// 2. Initialize Connection
var conn = try zpg.Connection.init(allocator, config);
defer conn.deinit(); // Ensure connection is closed

// 3. Connect to the database
try conn.connect();

// Check if connected
if (conn.isAlive()) {
    std.debug.print("Successfully connected!\n", .{});
    // ... use the connection ...
} else {
    std.debug.print("Connection failed.\n", .{});
}
```

**Key Methods:**

*   `init(allocator, config)`: Creates a `Connection` instance but does not establish the network connection yet.
*   `connect()`: Establishes the network connection and performs the authentication handshake.
*   `deinit()`: Closes the connection and frees associated resources.
*   `isAlive()`: Returns `true` if the connection state is `.Connected`.
*   `createQuery(allocator)`: Creates a `Query` object for this connection (Simple Protocol).
*   `createQueryEx(allocator)`: Creates a `QueryEx` object for this connection (Extended Protocol).

**Limitations:**

*   Direct connections are **not** inherently thread-safe. Managing a single connection across multiple threads requires external synchronization.
*   Requires manual handling of connection lifecycle, including reconnection logic if the connection drops.

## Connection Pooling (`zpg.ConnectionPool`)

`zpg.ConnectionPool` manages a pool of reusable database connections, providing thread-safe access and automatic handling of basic connection health checks and reconnections. This is the recommended approach for most applications, especially multi-threaded ones.

**Initialization:**

```zig
const pool_size = 5;
var pool = try zpg.ConnectionPool.init(allocator, config, pool_size);
defer pool.deinit(); // Closes all connections in the pool
```

### Getting Connections (`zpg.PooledConnection`)

The preferred way to work with the pool is through `zpg.PooledConnection`. This wrapper acquires a connection from the pool upon initialization and automatically returns it when `deinit` is called (typically via `defer`).

```zig
// Get a connection with default pool timeout
var pconn = try zpg.PooledConnection.init(&pool, null); // null for no RLS context
defer pconn.deinit(); // Connection automatically returned here

// Get the underlying *Connection if needed (less common)
// const raw_conn = pconn.connection();

// Create a Query or QueryEx object using the pooled connection
var query = pconn.createQuery(allocator);
defer query.deinit();

// ... execute queries using 'query' ...
try query.run("SELECT 1", zpg.types.Empty);

// pconn.deinit() is called automatically by defer
```

### Pool Management Methods

*   `init(allocator, config, size)`: Initializes the pool with a fixed number of connections.
*   `deinit()`: Closes all connections and frees pool resources.
*   `get(rls_context)`: Acquires a connection, waiting indefinitely if none are available. Applies RLS context if provided. Returns `*Connection`. Use `PooledConnection` for easier management.
*   `getWithTimeout(timeout_ms, rls_context)`: Tries to acquire a connection, waiting up to `timeout_ms`. Applies RLS context if provided. Returns `*Connection`. Use `PooledConnection` for easier management.
*   `release(conn)`: Manually returns a `*Connection` to the pool. Automatically handled by `PooledConnection.deinit()`.
*   `getAvailableCount()`: Returns the number of connections currently idle in the pool.
*   `getSize()`: Returns the total number of connections (idle + busy) the pool manages.
*   `setTimeout(timeout_ms)`: Sets the default timeout for `pool.get()`.
*   `reset()`: Closes and re-establishes all connections in the pool.

Using `PooledConnection` simplifies acquiring and releasing connections, making pool usage safer and less error-prone.
