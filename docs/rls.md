---
layout: default
title: Row-Level Security (RLS)
---

# Row-Level Security (RLS) Support

`zpg` provides helpers to work with PostgreSQL's Row-Level Security (RLS) features, primarily by managing session configuration variables that your RLS policies can use.

## RLS Context (`zpg.RLSContext`)

The `zpg.RLSContext` struct holds key-value pairs representing session settings relevant to your application's RLS logic (e.g., the current user ID, tenant ID).

```zig
const std = @import("std");
const zpg = @import("zpg");

var rls_ctx = zpg.RLSContext.init(allocator);
defer rls_ctx.deinit(allocator);

// Add settings relevant to your RLS policies
try rls_ctx.put(allocator, "app.user_id", "12345");
try rls_ctx.put(allocator, "app.tenant_id", "acme-corp");
try rls_ctx.put(allocator, "app.role", "editor");
```

**Key Methods:**

*   `init(allocator)`: Creates an empty RLS context.
*   `put(allocator, key, value)`: Adds or updates a setting. It takes ownership of *copies* of the key and value. Keys undergo basic validation to prevent injection of disallowed characters.
*   `deinit(allocator)`: Frees all keys and values stored in the context.

## Applying RLS Context

RLS context is typically applied when acquiring a connection from the pool or when beginning a transaction.

### With Connection Pool

Pass the `RLSContext` when initializing a `PooledConnection` or calling `pool.get()`:

```zig
// Get a connection and apply RLS settings for the session
var pconn = try zpg.PooledConnection.init(&pool, &rls_ctx);
defer pconn.deinit(); // RLS settings are reset when connection is returned

var query = pconn.createQuery(allocator);

// Queries executed here will have the 'app.user_id', 'app.tenant_id', etc.,
// settings available via current_setting() for RLS policies.
const result = try query.run("SELECT * FROM user_specific_data", MyData);
```

**How it works:**

1.  When `PooledConnection.init()` (or `pool.get()`) is called with an `RLSContext`, the pool first **resets** any previous RLS settings on the acquired connection using `RESET ALL`.
2.  It then iterates through the `rls_ctx.settings` and executes `SET SESSION "key" = 'value'` for each entry.
3.  When `PooledConnection.deinit()` (or `pool.release()`) is called, the pool executes `RESET ALL` again to clean up the session settings before returning the connection to the idle pool.

### With Transactions

Pass the `RLSContext` to `Transaction.begin()` to apply settings locally for that transaction only:

```zig
var tx = try zpg.Transaction.begin(&query, &rls_ctx);
defer if (tx.active) tx.rollback() catch {};

// Queries executed via tx.query run with settings applied via SET LOCAL.
// These settings only last for the duration of the transaction.
_ = try tx.query.run("INSERT INTO user_logs (message) VALUES ('Action performed')", ...);

try tx.commit();
// SET LOCAL settings are automatically discarded on COMMIT or ROLLBACK.
```

## Example RLS Policy

Your PostgreSQL RLS policies would then use the `current_setting()` function to access these variables:

```sql
-- Example Policy in PostgreSQL
CREATE POLICY user_can_access_own_data ON my_table
    FOR SELECT
    USING (user_id = CAST(current_setting('app.user_id', true) AS INTEGER));
    -- The ', true' makes current_setting return NULL if the setting is missing,
    -- preventing errors if the context wasn't set.

ALTER TABLE my_table ENABLE ROW LEVEL SECURITY;
ALTER TABLE my_table FORCE ROW LEVEL SECURITY; -- Recommended for safety
```

When `zpg` executes a query with the `app.user_id` set in the `RLSContext`, this policy will automatically filter rows based on that setting.
