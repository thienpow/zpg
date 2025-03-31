# zpg

![zpg Logo](docs/zpg-logo.svg)

**A native, high-performance PostgreSQL client library for Zig.**

`zpg` provides a robust, efficient, and type-safe interface for interacting with PostgreSQL databases directly from Zig applications. It supports essential features like connection pooling, both simple and extended query protocols, prepared statements, transactions, TLS/SSL encryption, and comprehensive data type mapping.

[![Documentation](https://img.shields.io/badge/docs-gh--pages-blue)](https://thienpow.github.io/zpg/)
<!-- Add other badges here: Build Status, License, etc. -->

## Why `zpg`?

*   🚀 **High Performance:** Designed for low overhead and efficiency, leveraging Zig's strengths. Aims to be faster than traditional C or Rust clients in many scenarios.
*   🔒 **Type Safety:** Maps database results directly to Zig structs (`struct`-based query execution), providing compile-time safety and eliminating manual parsing errors for known schemas.
*   ⚙️ **Direct Struct Mapping:** Zero-cost conversion from database rows to your application's data structures, avoiding intermediate allocations or `[]anytype` ambiguity.
*   🏊 **Built-in Connection Pooling:** Includes efficient, thread-safe connection pooling (`ConnectionPool` + `PooledConnection`) out-of-the-box, reducing the need for external poolers like `pgbouncer`.
*   🤏 **Low-Level Control:** Offers fine-grained control without the bloat of an ORM.
*   🧩 **Minimal Dependencies:** Reduces external requirements compared to solutions relying on separate pooling libraries.

## Key Features

*   **Connection Management:** Supports both direct `zpg.Connection` and thread-safe `zpg.ConnectionPool`.
*   **Query Protocols:** Implements both PostgreSQL's Simple (`Query`) and Extended (`QueryEx` - Parse/Bind/Execute) protocols.
*   **Prepared Statements:** Efficient execution of pre-compiled queries via both protocols.
*   **Data Type Mapping:** Extensive support for mapping PostgreSQL types (Numerics, Strings, Date/Time, UUID, JSON/JSONB, Geometric, Network, Bit Strings, Arrays, Composite Types, etc.) to Zig types, including NULL handling. See [Data Types Doc](https://thienpow.github.io/zpg/data_types.html).
*   **Transactions:** Standard `BEGIN`, `COMMIT`, `ROLLBACK` support via `zpg.Transaction`.
*   **Authentication:** Secure SCRAM-SHA-256 SASL authentication.
*   **TLS/SSL:** Configurable TLS/SSL encryption for secure connections.
*   **Row-Level Security (RLS):** Helpers (`zpg.RLSContext`) for setting session variables used by RLS policies.

## Installation

1.  Add `zpg` as a dependency in your `build.zig.zon`:

    ```zon
    .{
        .name = "your_project",
        .version = "0.1.0",
        .dependencies = .{
            .zpg = .{
                // Choose one:
                // Option A: Fetching from a release tarball
                .url = "https://github.com/thienpow/zpg/archive/refs/tags/vX.Y.Z.tar.gz", // Replace vX.Y.Z
                .hash = "...", // Replace with the correct hash

                // Option B: Fetching directly from Git (e.g., main branch)
                // .url = "https://github.com/thienpow/zpg/archive/main.tar.gz",
                // .hash = "...", // Replace with the hash of the commit you want
            },
        },
    }
    ```

2.  Add the `zpg` module to your executable or library in `build.zig`:

    ```zig
    const exe = b.addExecutable(.{ .name = "your_exe", .root_source_file = .{ .path = "src/main.zig" }, .target = target, .optimize = optimize });

    // Add zpg dependency
    const zpg_dep = b.dependency("zpg", .{
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("zpg", zpg_dep.module("zpg"));

    b.installArtifact(exe);
    ```

## Quick Start

This example connects to a database, retrieves a user record using the connection pool, and maps it to a Zig struct.

```zig
const std = @import("std");
const zpg = @import("zpg");

// Define a struct matching your database table structure
const User = struct {
    id: i64,          // Maps to 'id BIGINT' or similar
    username: []const u8, // Maps to 'username TEXT' or VARCHAR
    // Add other fields as needed

    // IMPORTANT: Add deinit if your struct holds allocated memory (like []const u8)
    pub fn deinit(self: User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
    }
};

pub fn main() !void {
    // 1. Setup Allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit(); // Ensure allocator cleanup

    // 2. Configure Connection Details
    const config = zpg.Config{
        .host = "127.0.0.1",      // Or your DB host
        .port = 5432,             // Default PostgreSQL port
        .username = "your_user", // Your database username
        .database = "your_db",   // Your database name
        .password = "your_password", // Your database password
        .tls_mode = .prefer,      // Or .disable, .require
        .timeout = 15_000,        // Pool wait timeout (ms)
    };
    try config.validate(); // Optional: Check config early

    // 3. Initialize Connection Pool
    // Pool size 5: creates up to 5 connections managed by the pool
    var pool = try zpg.ConnectionPool.init(allocator, config, 5);
    defer pool.deinit(); // Closes all connections and frees pool resources

    // 4. Acquire a Connection from the Pool
    // 'pconn' wraps a connection and automatically returns it on scope exit (via defer).
    // 'null' means no specific RLS context is applied here.
    var pconn = try zpg.PooledConnection.init(&pool, null);
    defer pconn.deinit(); // Returns connection to the pool

    // 5. Create a Query Object (Simple Protocol)
    // Use the pooled connection to create a query executor.
    var query = pconn.createQuery(allocator);
    defer query.deinit();

    // 6. Execute a Query and Map to Struct(s)
    // Run a SELECT query. 'User' tells zpg how to map the result rows.
    // Parameters can be embedded directly ONLY IF properly sanitized or static.
    // Use QueryEx for parameterized queries to prevent SQL injection.
    const user_id_to_find: i64 = 1;
    const sql = try std.fmt.allocPrint(allocator, "SELECT id, username FROM users WHERE id = {d}", .{user_id_to_find});
    defer allocator.free(sql);

    const result = try query.run(sql, User);

    // 7. Process the Result
    switch (result) {
        .select => |users| {
            // IMPORTANT: Free the slice returned by .select
            defer allocator.free(users);
            std.debug.print("Found {d} user(s):\n", .{users.len});

            for (users) |user| {
                // IMPORTANT: Deinitialize each struct if it has allocated fields
                defer user.deinit(allocator);
                std.debug.print(" - ID: {d}, Username: {s}\n", .{ user.id, user.username });
            }
        },
        .command => |count| {
            std.debug.print("Command affected {d} rows.\n", .{count});
        },
        .success => |ok| {
            std.debug.print("Command success: {}\n", .{ok});
        },
        .explain => |plan| {
             defer { // Ensure cleanup for explain rows
                 for(plan) |row| row.deinit(allocator);
                 allocator.free(plan);
             }
            std.debug.print("Explain plan received ({d} rows).\n", .{plan.len});
        },
    }
}
```

## Core Concepts

### Configuration (`zpg.Config`)

Connection behavior is controlled via `zpg.Config`. Key fields include:

*   `host`, `port`, `username`, `database`, `password`: Standard connection parameters.
*   `tls_mode`: `.disable`, `.prefer` (default), `.require`.
*   `timeout`: Timeout in milliseconds for acquiring a connection from the pool (default 10s).
*   `tls_ca_file`, `tls_client_cert`, `tls_client_key`: For custom TLS validation and client authentication (requires potential modification of built-in TLS handling for full verification).

See [Configuration Docs](https://thienpow.github.io/zpg/configuration.html).

### Connecting

*   **`zpg.Connection`**: Represents a single, direct connection. Suitable for simple cases but requires manual lifecycle management and is not inherently thread-safe.
    ```zig
    var conn = try zpg.Connection.init(allocator, config);
    defer conn.deinit();
    try conn.connect();
    if (conn.isAlive()) { ... }
    ```
*   **`zpg.ConnectionPool`**: Manages a pool of reusable connections. Recommended for multi-threaded applications.
    ```zig
    var pool = try zpg.ConnectionPool.init(allocator, config, pool_size);
    defer pool.deinit();
    ```
*   **`zpg.PooledConnection`**: A wrapper around a connection acquired from the pool. Automatically returns the connection when `deinit` is called (typically via `defer`). **This is the preferred way to use the pool.**
    ```zig
    var pconn = try zpg.PooledConnection.init(&pool, null); // null = no RLS context
    defer pconn.deinit(); // Connection returned automatically
    // Use pconn to create Query or QueryEx objects
    var query = pconn.createQuery(allocator);
    defer query.deinit();
    ```

See [Connections Docs](https://thienpow.github.io/zpg/connections.html).

### Querying the Database

*   **`zpg.Query` (Simple Protocol):**
    *   Sends SQL as text. Good for one-off queries.
    *   `query.run(sql, ResultStruct)`: Executes SQL and maps results to `ResultStruct`.
    *   `query.prepare(name, sql)` / `query.execute(name, params, ResultStruct)`: Simple protocol prepared statements (params sent as text).
*   **`zpg.QueryEx` (Extended Protocol):**
    *   Uses Prepare/Bind/Execute. Generally more efficient and robust for parameters and binary data.
    *   `queryEx.prepare(name, sql)`: Prepares the statement.
    *   `queryEx.execute(name, params, ResultStruct)`: Executes with binary parameters (`[]const zpg.Param`).
    ```zig
    // QueryEx Example
    var queryEx = pconn.createQueryEx(allocator);
    defer queryEx.deinit();

    _ = try queryEx.prepare("get_user", "SELECT id, name FROM users WHERE id = $1");
    const params = &[_]zpg.Param{ zpg.Param.int(@as(i64, 1)) }; // Parameter $1
    const result = try queryEx.execute("get_user", params, UserStruct);
    // Process result...
    ```

*   **Result Structs:** Define Zig structs matching your query's output columns *in order*. Use optional types (`?T`) for nullable columns. Remember to implement `deinit` if your struct contains allocated fields (e.g., `[]const u8`).
*   **Parameters (`zpg.Param`):** Use with `QueryEx.execute` (and `Query.execute`) for safe parameter passing (e.g., `zpg.Param.int(123)`, `zpg.Param.string("text")`, `zpg.Param.boolean(true)`, `zpg.Param.nullValue()`).

See [Querying Docs](https://thienpow.github.io/zpg/querying.html).

### Data Type Mapping

`zpg` maps PostgreSQL types to Zig types. `Query` typically uses text format, `QueryEx` uses binary format (often more efficient).

*   Common types like `INT`, `BIGINT`, `TEXT`, `BOOL`, `FLOAT` map directly.
*   Specialized types (`TIMESTAMP`, `UUID`, `JSONB`, `NUMERIC`, geometric types, arrays, etc.) often have corresponding `zpg.field` types or specific Zig struct representations.
*   **Use optional fields (`?T`) in your result structs for nullable database columns.**

See the detailed [Data Types Mapping Table](https://thienpow.github.io/zpg/data_types.html).

### Transactions

Group operations atomically using `zpg.Transaction`.

```zig
var tx = try zpg.Transaction.begin(&query, null); // null = no RLS context
defer if (tx.active) tx.rollback() catch {}; // Ensure rollback on failure

_ = try tx.query.run("UPDATE ...", zpg.types.Empty);
_ = try tx.query.run("INSERT ...", zpg.types.Empty);

try tx.commit(); // Commit changes
```

See [Transactions Docs](https://thienpow.github.io/zpg/transactions.html).

### TLS/SSL

Configure secure connections via `config.tls_mode`:
*   `.disable`: No TLS.
*   `.prefer` (Default): Use TLS if available, fall back to unencrypted otherwise.
*   `.require`: Require TLS; fail if unavailable or handshake fails.

**Note:** The default built-in TLS handler currently disables server certificate and hostname verification for ease of development. For production, modify `src/tls.zig` to enable verification and potentially provide CA info via `config.tls_ca_file`.

See [TLS/SSL Docs](https://thienpow.github.io/zpg/tls.html).

### Row-Level Security (RLS)

Use `zpg.RLSContext` to set session variables (e.g., `app.user_id`) that your PostgreSQL RLS policies can use via `current_setting()`. Apply context when getting a pooled connection or starting a transaction.

```zig
var rls_ctx = zpg.RLSContext.init(allocator);
defer rls_ctx.deinit(allocator);
try rls_ctx.put(allocator, "app.user_id", "user-123");

// Apply when getting connection
var pconn = try zpg.PooledConnection.init(&pool, &rls_ctx);
defer pconn.deinit(); // Context is reset automatically

// Or apply per-transaction (uses SET LOCAL)
var tx = try zpg.Transaction.begin(&query, &rls_ctx);
defer if (tx.active) tx.rollback() catch {};
// ... transaction queries ...
try tx.commit();
```

See [RLS Docs](https://thienpow.github.io/zpg/rls.html).

### Authentication

`zpg` automatically handles authentication during connection based on server requirements and `zpg.Config`.
*   **Supported:** SCRAM-SHA-256 (requires `config.username` and `config.password`).
*   **Unsupported:** Cleartext/MD5 Password, Kerberos, GSSAPI, SSPI, SCM Credentials. Connection will fail if the server only offers unsupported methods.

See [Authentication Docs](https://thienpow.github.io/zpg/authentication.html).

## Comparison with Other Clients

| Feature            | `zpg` (Zig)  | `libpq` (C) | `tokio-postgres` (Rust) | SQLAlchemy (Python ORM) |
|--------------------|-------------|-------------|-------------------------|-------------------------|
| **Performance**   | ✅ Very High | ✅ High | ✅ High | ❌ Slower (ORM Overhead) |
| **Memory Usage**  | ✅ Low (No GC) | ⚠️ Depends on usage | ⚠️ Moderate (Heap allocations) | ❌ High (Dynamic models) |
| **Type Safety**   | ✅ Zig Structs | ❌ Manual C handling | ✅ Compile-time SQL checks (sqlx) / Rust types | ❌ Dynamic objects |
| **Connection Pool** | ✅ Built-in | ❌ External (pgbouncer) | ✅ Built-in (`deadpool` / `bb8`) | ✅ ORM-managed |
| **Result Mapping** | ✅ Direct Structs (Zero-cost) | ❌ Manual parsing | ⚠️ Some abstraction | ❌ High (ORM Reflection) |
| **Dependencies**  | ✅ Minimal | ✅ System library | ✅ Requires Tokio runtime | ✅ Requires Python runtime |

## Testing `zpg`

Clone the repository and run the test suite:

```bash
git clone https://github.com/thienpow/zpg.git # Or your fork
cd zpg
zig build test --summary all
```

This executes all tests, including connection pooling and query examples (see `tests/pool.zig` and `tests/main.zig`).

## Potential Improvements

1.  **Binary Protocol Latency:** Investigate and optimize the ~40ms delay observed in `QueryEx.execute` between Bind command and BindComplete response in high-frequency use cases.
2.  **Large Message Handling:** Improve robustness for very large query results or parameters, potentially using dynamic buffering or chunking instead of fixed-size buffers.
3.  **Asynchronous Operations:** Introduce non-blocking query execution (e.g., using Zig's `async` features) for better concurrency.
4.  **Flexible Result Mapping:** Explore options for more dynamic result mapping, potentially using column name introspection, especially for complex JOINs or views where defining exact structs upfront is cumbersome.

## Contributing

Contributions are welcome! Please feel free to open issues or submit pull requests. (Add specific contribution guidelines if available).

## License

`zpg` is distributed under the **MIT License**.

---

➡️ **Explore the full [Documentation](https://thienpow.github.io/zpg/) for more details.**
