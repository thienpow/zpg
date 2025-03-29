### Testing `zpg`

Check out the [tests/pool.zig](https://github.com/thienpow/zpg/blob/main/tests/pool.zig) file for an example of how `zpg` handles connection pooling and query execution with structs.

To run the test suite and verify the library's functionality, use the following commands:

```bash
cd ~/your-dev-path/zpg
zig build test --summary all
```

This will execute all tests, including those for connection pooling (see `tests/pool.zig` for an example), and provide a summary of the results.

## Detailed Type Documentation

Learn how ZPG handles PostgreSQL’s advanced data types with our comprehensive guides. Each document provides in-depth explanations and examples for integrating these types into your Zig structs.

- [Decimal](https://github.com/thienpow/zpg/blob/main/docs/decimal.md) - Handle precise numeric values like account balances with ZPG’s decimal support.
- [Enum](https://github.com/thienpow/zpg/blob/main/docs/enum.md) - Map PostgreSQL ENUM types to Zig enums for type-safe status fields.
- [Interval](https://github.com/thienpow/zpg/blob/main/docs/interval.md) - Work with time durations like subscription periods using ZPG’s interval handling.
- [Timestamp](https://github.com/thienpow/zpg/blob/main/docs/timestamp.md) - Manage date and time fields with precision, including timezone support.
- [UUID](https://github.com/thienpow/zpg/blob/main/docs/uuid.md) - Utilize PostgreSQL UUIDs for unique identifiers in your Zig application.
- [Array](https://github.com/thienpow/zpg/blob/main/docs/array.md) - Leverage PostgreSQL arrays to manage collections of data, such as lists or sets, in your Zig application.
- [more...](https://github.com/thienpow/zpg/blob/main/src/field/) - composite, geometric, money, net, search...

### Planned Features
For a full-fledged PostgreSQL driver, `zpg` could be extended to include:

- Hook to Streaming Response

These enhancements aim to broaden `zpg`’s compatibility with PostgreSQL’s rich type system and optimize performance.


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

1.  Binary protocol hit bottlenect at Bind(fast) --> postgres(delay 40ms) --> BindComplete
2.  Potential fragility with large messages due to fixed buffers.

3. **Support for Asynchronous Queries**
   - Right now, `zpg` executes queries synchronously.
   - Adding **async** (event-driven I/O) would allow non-blocking DB operations (like `tokio-postgres` in Rust).

4. **Automatic Struct Mapping for Complex Queries**
   - Some queries return dynamic column sets (`JOIN` queries, custom views).
   - Right now, users must define exact structs manually.
   - Consider adding **auto-detection of column names** based on PostgreSQL metadata.

---

## **Final Verdict**
✅ **zpg is an excellent choice** if you want a **low-level, high-performance** PostgreSQL client **without ORM bloat**. It gives **fine-grained control, type safety, and direct struct-based queries** while being more efficient than C-based `libpq` or Rust's `tokio-postgres`.
