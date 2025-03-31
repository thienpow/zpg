### Quick start

Check out the [Documentation](https://thienpow.github.io/zpg/#quick-start)

### Testing `zpg`

Check out the [tests/pool.zig](https://github.com/thienpow/zpg/blob/main/tests/pool.zig) for an example of how `zpg` handles connection pooling and query execution with structs.

To run the test suite and verify the library's functionality, use the following commands:

```bash
cd ~/your-dev-path/zpg
zig build test --summary all
```

This will execute all tests, including those for connection pooling (see `tests/main.zig` for an example), and provide a summary of the results.

## Strengths of `zpg`

### **Struct-Based Query Execution**
- Unlike clients that return generic tuples or `[]anytype`, `zpg` directly maps results to predefined Zig structs.
- This allows **zero-cost conversion** from DB rows to usable data.

### **Efficient Connection Pooling**
- `zpg` provides a built-in connection pooling mechanism (`ConnectionPool` + `PooledConnection`).
- **Traditional clients** (libpq, Rust’s tokio-postgres) often rely on external connection poolers (like `pgbouncer`).
- `zpg` **bundles** this inside the client, reducing external dependencies.

---

## **How It Compares to Other Clients**

| Feature            | `zpg` (Zig)  | `libpq` (C) | `tokio-postgres` (Rust) | SQLAlchemy (Python ORM) |
|--------------------|-------------|-------------|-------------------------|-------------------------|
| **Performance**   | ✅ Very High | ✅ High | ✅ High | ❌ Slower (ORM Overhead) |
| **Memory Usage**  | ✅ Low (No GC) | ⚠️ Depends on usage | ⚠️ Moderate (Heap allocations) | ❌ High (Dynamic models) |
| **Type Safety**   | ✅ Zig Structs | ❌ Manual handling | ✅ Compile-time SQL checks (sqlx) | ❌ Dynamic objects |
| **Connection Pool** | ✅ Built-in | ❌ External (pgbouncer) | ✅ Managed (tokio-postgres) | ❌ ORM-managed |
| **Parsing Overhead** | ✅ Minimal (Direct Structs) | ❌ Manual parsing | ⚠️ Some abstraction | ❌ High (ORM Reflection) |

---

## **Potential Improvements for `zpg`**

1.  **Binary Protocol Performance Bottleneck:** Investigate and reduce the latency in QueryEx.execute, specifically the ~40ms delay between sending a Bind command and receiving the BindComplete response from PostgreSQL. This delay can impact throughput in high-frequency scenarios. Notably, Query.execute, which uses the Simple Text query protocol, does not exhibit this issue.
2.  **Robustness with Large Messages:** Enhance handling of large data transfers (query results or parameters) to prevent potential issues caused by fixed-size buffers. Consider implementing dynamic buffering or message chunking.
3.  **Implement Asynchronous Query Execution:** Introduce non-blocking, asynchronous query execution (e.g., using async/await patterns). This would allow `zpg` to perform database operations without blocking the calling thread, improving concurrency and responsiveness.
4.  **Flexible Result Set Mapping:** Simplify the process of mapping query results to application structs, especially for complex queries (like JOINs or views) with dynamic column sets. Explore automatic mapping based on column names fetched from PostgreSQL metadata, reducing the need for manual struct definitions for every query variant.

---

## **Final Verdict**
✅ **zpg is an excellent choice** if you want a **low-level, high-performance** PostgreSQL client **without ORM bloat**. It gives **fine-grained control, type safety, and direct struct-based queries** while being more efficient than C-based `libpq` or Rust's `tokio-postgres`.
