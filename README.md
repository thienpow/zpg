### Testing `zpg`

Check out the [tests/pool.zig](https://github.com/thienpow/zpg/blob/main/tests/pool.zig) file for an example of how `zpg` handles connection pooling and query execution with structs.

To run the test suite and verify the library's functionality, use the following commands:

```bash
cd ~/your-dev-path/zpg
zig build test --summary all
```

This will execute all tests, including those for connection pooling (see `tests/pool.zig` for an example), and provide a summary of the results.

### Planned Features
For a full-fledged PostgreSQL driver, `zpg` could be extended to include:

- ~~Support for array types~~ considered done?...
- Support for JSON/JSONB
- Support for network types (`inet`, `cidr`)
- Binary format support for more efficient data transfers
- Hook to Streaming Response

These enhancements aim to broaden `zpg`’s compatibility with PostgreSQL’s rich type system and optimize performance.

## Strengths of `zpg`

** Disclaimer: below is what LLMs reviewed :p

### **Minimal Overhead Compared to ORMs**
- ORMs like Prisma, SQLAlchemy, or Sequelize introduce extra layers (query builders, model abstraction, caching).
- `zpg` avoids unnecessary parsing, data cloning, and object instantiation, making it much faster and memory-efficient.
- With **struct-based queries**, you map results directly to Zig structs without ORM's dynamic reflection overhead.

### **Better than Regular PostgreSQL Clients in Performance & Safety**
- Compared to **libpq** (C-based PostgreSQL client):
  - **Lower memory fragmentation** (Zig’s allocator control helps).
  - **More explicit type safety** (avoids runtime surprises).
- Compared to **async Rust clients (tokio-postgres, sqlx)**:
  - **More deterministic memory management** (no GC, less heap allocation).
  - **No need for runtime introspection** (column metadata is mapped statically).

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

1. **Support for Asynchronous Queries**
   - Right now, `zpg` executes queries synchronously.
   - Adding **async** (event-driven I/O) would allow non-blocking DB operations (like `tokio-postgres` in Rust).

2. **Automatic Struct Mapping for Complex Queries**
   - Some queries return dynamic column sets (`JOIN` queries, custom views).
   - Right now, users must define exact structs manually.
   - Consider adding **auto-detection of column names** based on PostgreSQL metadata.

---

## **Final Verdict**
✅ **zpg is an excellent choice** if you want a **low-level, high-performance** PostgreSQL client **without ORM bloat**. It gives **fine-grained control, type safety, and direct struct-based queries** while being more efficient than C-based `libpq` or Rust's `tokio-postgres`.
