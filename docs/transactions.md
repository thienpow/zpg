---
layout: default
title: Transactions
---

# Transactions

`zpg` provides support for database transactions using the `zpg.Transaction` struct, allowing you to group multiple SQL statements into a single atomic unit.

## Basic Usage

Transactions are typically managed using `Transaction.begin()`, `tx.commit()`, and `tx.rollback()`. It's crucial to ensure that `rollback()` is called if `commit()` is not reached, often achieved using `defer`.

```zig
const std = @import("std");
const zpg = @import("zpg");

// Assume 'pconn' is an initialized PooledConnection
var query = pconn.createQuery(allocator);
defer query.deinit();

// Begin the transaction
var tx = try zpg.Transaction.begin(&query, null); // null RLS context
// Ensure rollback on error or early return
defer if (tx.active) tx.rollback() catch |err| {
    std.debug.print("Rollback failed: {}\n", .{err});
};

// Perform operations within the transaction using tx.query
_ = try tx.query.run("INSERT INTO accounts (name, balance) VALUES ('Alice', 1000)", zpg.types.Empty);
_ = try tx.query.run("UPDATE products SET stock = stock - 1 WHERE id = 123", zpg.types.Empty);

// If all operations succeed, commit the transaction
try tx.commit(); // Sets tx.active to false

// The defer will now do nothing since tx.active is false
```

## Key Methods

*   **`Transaction.begin(query: *Query, rls_context: ?*const RLSContext)`**: Starts a new transaction by sending `BEGIN`. If an `RLSContext` is provided, it applies the settings using `SET LOCAL` within the transaction scope. Returns a `Transaction` instance.
*   **`tx.commit()`**: Commits the active transaction by sending `COMMIT`. Sets `tx.active` to `false`.
*   **`tx.rollback()`**: Rolls back the active transaction by sending `ROLLBACK`. Sets `tx.active` to `false`.
*   **`tx.query`**: A pointer (`*Query`) back to the query object associated with the transaction. Use this to execute statements *within* the transaction.
*   **`tx.active`**: A boolean indicating if the transaction is currently active (i.e., `COMMIT` or `ROLLBACK` has not yet been successfully called).

## Transactions with RLS Context

You can apply Row-Level Security settings specifically for the duration of a transaction by passing an `RLSContext` to `Transaction.begin()`. These settings are applied using `SET LOCAL` and will be automatically discarded when the transaction ends (either by `COMMIT` or `ROLLBACK`).

```zig
var rls_ctx = zpg.RLSContext.init(allocator);
defer rls_ctx.deinit(allocator);
try rls_ctx.put(allocator, "app.user_id", "123");
try rls_ctx.put(allocator, "app.tenant_id", "tenant-a");

// Begin transaction WITH RLS context
var tx = try zpg.Transaction.begin(&query, &rls_ctx);
defer if (tx.active) tx.rollback() catch {};

// Queries executed via tx.query will now operate under
// the 'app.user_id' = '123' and 'app.tenant_id' = 'tenant-a' settings.
// Example: An RLS policy might use current_setting('app.user_id')
_ = tx.query.run("INSERT INTO user_data (data) VALUES ('Sensitive data')", ...);

try tx.commit();
// The SET LOCAL settings are automatically cleared upon commit/rollback.
```

This is useful for ensuring that all operations within a transaction adhere to the RLS policies defined for a specific user or context, without affecting the underlying connection's session state after the transaction completes.
