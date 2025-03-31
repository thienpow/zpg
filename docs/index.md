---
layout: default
title: Home
---

# Welcome to zpg

`zpg` is a native PostgreSQL client library for the Zig programming language. It aims to provide a robust, efficient, and easy-to-use interface for interacting with PostgreSQL databases, supporting both simple and extended query protocols, connection pooling, transactions, and a variety of data types.

## Features

*   **Connection Management:** Direct connections and thread-safe connection pooling.
*   **Query Protocols:** Supports both Simple and Extended query protocols.
*   **Prepared Statements:** Efficient execution of pre-compiled queries.
*   **Data Types:** Mapping for common PostgreSQL types (Numerics, Strings, Date/Time, UUID, JSON/JSONB, Geometric, Network, Bit, Arrays, Composite, etc.).
*   **Transactions:** Standard `BEGIN`, `COMMIT`, `ROLLBACK` support.
*   **Authentication:** SCRAM-SHA-256 SASL authentication.
*   **TLS/SSL:** Secure connections using TLS.
*   **Row-Level Security:** Support for setting session variables for RLS policies.

## Installation

Add `zpg` as a dependency to your `build.zig.zon` file (details depend on your project setup and dependency management approach).

```zig
// Example entry in build.zig.zon (adjust path/URL/hash as needed)
.zpg = .{
    .url = "https://github.com/your_username/zpg/archive/refs/tags/v0.1.0.tar.gz", // Or git dependency
    .hash = "...", // Replace with actual hash
},
```

Then, add the package to your `build.zig`:

```zig
// In build.zig
const zpg_dep = b.dependency("zpg", .{
    .target = target,
    .optimize = optimize,
});

exe.addModule("zpg", zpg_dep.module("zpg"));
```

## Quick Start

```zig
const std = @import("std");
const zpg = @import("zpg");

const User = struct {
    id: i64,
    username: []const u8,

    pub fn deinit(self: User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // 1. Configure Connection
    const config = zpg.Config{
        .host = "127.0.0.1",
        .port = 5432,
        .username = "postgres",
        .database = "zui", // Your database name
        .password = "postgres", // Your password
        .tls_mode = .disable, // Or .prefer / .require
    };

    // 2. Initialize Connection Pool
    var pool = try zpg.ConnectionPool.init(allocator, config, 3); // Pool of 3 connections
    defer pool.deinit();

    // 3. Get a Pooled Connection
    var pconn = try zpg.PooledConnection.init(&pool, null); // null for no RLS context
    defer pconn.deinit(); // Automatically returns the connection to the pool

    // 4. Create a Query object
    var query = pconn.createQuery(allocator);
    defer query.deinit();

    // 5. Run a simple SELECT query
    const result = try query.run("SELECT id, username FROM users WHERE id = 1", User);

    // 6. Process Results
    switch (result) {
        .select => |users| {
            defer allocator.free(users); // Free the result slice
            std.debug.print("Found {d} user(s):\n", .{users.len});
            for (users) |user| {
                defer user.deinit(allocator); // Free user's allocated fields
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
             defer {
                 for(plan) |row| row.deinit(allocator);
                 allocator.free(plan);
             }
            std.debug.print("Explain plan received.\n", .{});
            // Process plan rows
        }
    }
}
```

End of doc here.
