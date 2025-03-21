### Testing `zpg`
To run the test suite and verify the library's functionality, use the following commands:

```bash
cd ~/your-dev-path/zpg
zig build test --summary all
```

This will execute all tests, including those for connection pooling (see `tests/pool.zig` for an example), and provide a summary of the results.

### Planned Features
For a full-fledged PostgreSQL driver, `zpg` could be extended to include:

- Support for array types
- Support for JSON/JSONB
- ~~Support for timestamp and interval types~~ (currently deferred)
- Support for network types (`inet`, `cidr`)
- Binary format support for more efficient data transfers

These enhancements aim to broaden `zpg`’s compatibility with PostgreSQL’s rich type system and optimize performance.

### About `zpg`
`zpg` is a native PostgreSQL client library written in Zig, designed for direct, efficient interaction with PostgreSQL databases. Unlike traditional ORMs that add layers of parsing or data cloning, `zpg` provides a low-level interface, giving developers fine-grained control over database operations while minimizing overhead. It leverages Zig’s performance and safety features to deliver a robust driver for systems programming.

Key highlights:
- **Struct-based Queries**: Use Zig structs to define queries and map results, as seen in `tests/pool.zig`, without the abstraction of an ORM.
- **Connection Pooling**: Efficiently manage database connections (demonstrated in `tests/pool.zig`).
- **No Extra Parsing**: Direct data access reduces latency and memory usage compared to ORM-based solutions.

Check out the [tests/pool.zig](https://github.com/thienpow/zpg/blob/main/tests/pool.zig) file for an example of how `zpg` handles connection pooling and query execution with structs.
