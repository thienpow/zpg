---
layout: default
title: Querying the Database
---

# Querying the Database

`zpg` provides two primary ways to execute SQL queries, corresponding to PostgreSQL's Simple and Extended query protocols.

## Query Execution Interfaces

*   **`zpg.Query` (Simple Protocol):**
    *   Sends SQL queries as plain text strings.
    *   Suitable for one-off queries or when parameter handling is done via string formatting (use with caution to avoid SQL injection).
    *   Parses results typically in text format (unless the server chooses binary).
    *   Used via `connection.createQuery(allocator)` or `pooledConnection.createQuery(allocator)`.
*   **`zpg.QueryEx` (Extended Protocol):**
    *   Uses `PREPARE`, `BIND`, `EXECUTE` steps.
    *   Supports binary transmission of parameters and results, which is generally more efficient and robust, especially for non-text data types.
    *   Requires explicit `prepare` and `execute` steps.
    *   Used via `connection.createQueryEx(allocator)` or `pooledConnection.createQueryEx(allocator)`.

**Choosing Between `Query` and `QueryEx`:**

*   Use `Query` for simple, dynamic DDL/DML, or when text-based results are sufficient.
*   Use `QueryEx` for performance-sensitive queries, queries executed repeatedly with different parameters, or when dealing with complex binary data types where text conversion is lossy or inefficient.

## Simple Query Protocol (`Query`)

The main method is `query.run()`.

```zig
const std = @import("std");
const zpg = @import("zpg");

// Assume 'pconn' is an initialized PooledConnection
var query = pconn.createQuery(allocator);
defer query.deinit();

// Example 1: SELECT query
const User = struct { id: i64, name: []const u8, /* ... deinit ... */ };
const result1 = try query.run("SELECT id, name FROM users WHERE id = 1", User);
switch (result1) {
    .select => |users| { /* process users */ },
    else => return error.UnexpectedResult,
}

// Example 2: INSERT query
const result2 = try query.run("INSERT INTO logs (message) VALUES ('Log entry')", zpg.types.Empty);
switch (result2) {
    .command => |count| std.debug.print("Inserted {d} rows\n", .{count}), // count is usually 1 for INSERT without RETURNING
    else => return error.UnexpectedResult,
}

// Example 3: CREATE TABLE query
const result3 = try query.run("CREATE TABLE new_table (col1 INT)", zpg.types.Empty);
switch (result3) {
    .success => |ok| std.debug.print("Table created: {}\n", .{ok}),
    else => return error.UnexpectedResult,
}

// Example 4: EXPLAIN query
const result4 = try query.run("EXPLAIN SELECT * FROM users", zpg.types.Empty); // Use Empty as placeholder type
switch(result4) {
    .explain => |plan_rows| { /* process zpg.types.ExplainRow slice */ },
    else => return error.UnexpectedResult,
}
```

## Extended Query Protocol (`QueryEx`)

Requires `prepare` and `execute` steps.

```zig
const std = @import("std");
const zpg = @import("zpg");

// Assume 'pconn' is an initialized PooledConnection
var queryEx = pconn.createQueryEx(allocator);
defer queryEx.deinit();

// Example: SELECT with parameters
const User = struct { id: i64, name: []const u8, /* ... deinit ... */ };

// 1. Prepare the statement
const stmt_name = "get_user_by_id";
const sql = "SELECT id, name FROM users WHERE id = $1";
const prepared = try queryEx.prepare(stmt_name, sql);
if (!prepared) return error.PrepareFailed;

// 2. Define parameters
const params = &[_]zpg.Param{ zpg.Param.int(@as(i64, 123)) };

// 3. Execute the prepared statement
const result = try queryEx.execute(stmt_name, params, User);
switch (result) {
    .select => |users| { /* process users */ },
    else => return error.UnexpectedResult,
}
```

## Parameters (`zpg.Param`)

Parameters are used primarily with the `QueryEx` interface (and `Query.execute` for simple protocol prepared statements). They allow safe and efficient passing of values to the database, preventing SQL injection and handling data type conversions correctly (especially in binary format with `QueryEx`).

```zig
const Param = zpg.Param;

const params: []const Param = &.{
    Param.int(@as(i32, 10)),          // Integer
    Param.string("hello world"),      // String (TEXT/VARCHAR)
    Param.float(@as(f64, 3.14159)),   // Floating point
    Param.boolean(true),              // Boolean
    Param.bytea(&[_]u8{ 0xDE, 0xAD }), // Binary data (BYTEA)
    Param.nullValue(),                // SQL NULL
    // ... other types like UUID, Timestamp, etc. require specific setup
    // if you want them sent as binary parameters. Often sent as strings.
};

// Pass 'params' to queryEx.execute() or query.execute()
// try queryEx.execute("my_statement", &params, MyResultStruct);
```

## Prepared Statements

Prepared statements improve performance for queries executed multiple times by allowing the database to parse, plan, and optimize the SQL query once.

*   **`Query.prepare(name, sql)`:** Uses simple protocol `PREPARE name AS sql`. Caches the statement name and command type.
*   **`QueryEx.prepare(name, sql)`:** Uses extended protocol `Parse` message. Caches the statement name and command type.
*   **`Query.execute(name, params, T)`:** Uses simple protocol `EXECUTE name (params...)`. Looks up the cached command type to process results correctly. Parameters are formatted *as text* into the `EXECUTE` string.
*   **`QueryEx.execute(name, params, T)`:** Uses extended protocol `Bind`, `Describe`, `Execute`, `Sync`. Looks up the cached command type. Parameters are sent in binary format.
*   **`Query.run("EXECUTE name ...")`:** An alternative way to run simple protocol prepared statements.
*   **Caching:** Both interfaces use `connection.statement_cache` to avoid re-preparing statements with the same name *if the intended action (SELECT/INSERT/etc.) hasn't changed*.

## Processing Results (`zpg.types.Result(T)`)

The `run` and `execute` methods return a `zpg.types.Result(T)` union, where `T` is the expected result struct type (or `zpg.types.Empty` if no specific rows are expected).

*   **`.select: []const T`**: Contains a slice of result structs for `SELECT` queries. You **must** free this slice using the allocator. If the struct `T` contains allocated fields (like `[]const u8`), you must iterate and call a `deinit` method on each struct before freeing the slice.
*   **`.command: u64`**: Contains the number of rows affected by `INSERT`, `UPDATE`, `DELETE`, or `MERGE` commands.
*   **`.success: bool`**: Indicates success (`true`) or failure (`false` during processing, though errors are usually returned as `!Result`) for commands like `CREATE`, `DROP`, `ALTER`, `COMMIT`, `ROLLBACK`, `PREPARE` (via `query.run`).
*   **`.explain: []ExplainRow`**: Contains a slice of `zpg.types.ExplainRow` structs for `EXPLAIN` queries. You need to free the slice and deinit each row.

**Result Struct Definition:**

When expecting rows (usually from `SELECT`), define a Zig struct whose fields match the columns in your query **in order**.

```zig
// SQL: SELECT user_id, email, created_at FROM accounts WHERE user_id = $1
const Account = struct {
    user_id: i64,         // Maps to user_id column
    email: []const u8,    // Maps to email column
    created_at: zpg.field.Timestamp, // Maps to created_at column

    // Necessary if struct contains allocated fields
    pub fn deinit(self: Account, allocator: std.mem.Allocator) void {
        allocator.free(self.email);
        // Timestamp doesn't allocate in this example, but other zpg.field types might
    }
};

// Usage:
// const result = try query.run("SELECT ...", Account);
// or
// const result = try queryEx.execute("get_account", &params, Account);
```

**Handling NULL:**

If a database column can be `NULL`, the corresponding field in your Zig result struct **must** be an optional type (`?T`).

```zig
const Profile = struct {
    id: i32,
    bio: ?[]const u8, // Can be NULL in the database

    pub fn deinit(self: Profile, allocator: std.mem.Allocator) void {
        if (self.bio) |b| allocator.free(b); // Free only if non-null
    }
};
```
