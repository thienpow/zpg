---
layout: default
title: Data Type Mapping
---

# Data Type Mapping

`zpg` provides mappings between PostgreSQL data types and Zig types, primarily within the `zpg.field` module. Handling depends on whether the Simple (`Query`) or Extended (`QueryEx`) protocol is used.

*   **Simple Protocol (`Query`):** Data is typically received from the database in *text* format. `zpg` parses this text into the target Zig type.
*   **Extended Protocol (`QueryEx`):** Data is typically received in *binary* format. `zpg` interprets the raw bytes directly into the target Zig type. This is generally more efficient and less error-prone for complex types.

**Result Structs:** When defining a Zig struct to receive query results (`SELECT`), ensure the field types in your struct match the expected data. Use optional types (`?T`) in your Zig struct for columns that can be `NULL` in the database.

## Common Mappings

| PostgreSQL Type(s)                  | Zig Type                     | `zpg.field` Type (if applicable) | Notes                                                                 |
| :---------------------------------- | :--------------------------- | :------------------------------- | :-------------------------------------------------------------------- |
| `SMALLINT`, `INT2`                  | `i16`                        | -                                |                                                                       |
| `INTEGER`, `INT`, `INT4`            | `i32`                        | -                                |                                                                       |
| `BIGINT`, `INT8`                    | `i64`                        | -                                |                                                                       |
| `SMALLSERIAL`, `SERIAL2`            | `u16`                        | `zpg.field.SmallSerial`          | Use wrapper for clarity, underlying is `u16`. Cannot be optional.     |
| `SERIAL`, `SERIAL4`                 | `u32`                        | `zpg.field.Serial`               | Use wrapper for clarity, underlying is `u32`. Cannot be optional.     |
| `BIGSERIAL`, `SERIAL8`              | `u64`                        | `zpg.field.BigSerial`            | Use wrapper for clarity, underlying is `u64`. Cannot be optional.     |
| `REAL`, `FLOAT4`                    | `f32`                        | -                                |                                                                       |
| `DOUBLE PRECISION`, `FLOAT8`        | `f64`                        | -                                |                                                                       |
| `NUMERIC(p,s)`, `DECIMAL(p,s)`     | `struct{value: i128, scale: u8}` | `zpg.field.Decimal`              | High precision decimal.                                               |
| `MONEY`                             | `struct{value: i64}`         | `zpg.field.Money`                | Represents value in cents.                                            |
| `BOOLEAN`, `BOOL`                   | `bool`                       | -                                |                                                                       |
| `TEXT`                              | `[]const u8`                 | -                                | Represents UTF-8 text.                                                |
| `VARCHAR(n)`                        | `struct{value: []const u8}` | `zpg.field.VARCHAR(n)`           | Variable-length string with limit `n`. Use `[]const u8` for unknown n. |
| `CHAR(n)`, `CHARACTER(n)`           | `[n]u8`                      | `zpg.field.CHAR(n)`              | Fixed-length, blank-padded string.                                    |
| `BYTEA`                             | `[]const u8`                 | -                                | Raw binary data.                                                      |
| `DATE`                              | `struct{year,month,day}`     | `zpg.field.Date`                 | Represents a calendar date.                                           |
| `TIME`, `TIME WITHOUT TIME ZONE`    | `struct{h,m,s,ns}`           | `zpg.field.Time`                 | Represents time of day.                                               |
| `TIMESTAMP`, `TIMESTAMP WITHOUT TIME ZONE` | `struct{seconds: i64, nano_seconds: u32}` | `zpg.field.Timestamp` | Represents a point in time (Unix epoch based).                      |
| `TIMESTAMPTZ`, `TIMESTAMP WITH TIME ZONE` | `struct{seconds: i64, nano_seconds: u32}` | `zpg.field.Timestamp` | **Note:** `zpg` reads this as UTC Timestamp. Timezone info is lost. |
| `INTERVAL`                          | `struct{months,days,us}`     | `zpg.field.Interval`             | Represents a duration.                                                |
| `UUID`                              | `struct{bytes: [16]u8}`      | `zpg.field.Uuid`                 | Universally Unique Identifier.                                        |
| `JSON`                              | `struct{data: []u8}`         | `zpg.field.JSON`                 | Stores JSON as text. Use `.parse(allocator, MyStruct)` to decode.     |
| `JSONB`                             | `struct{data: []u8}`         | `zpg.field.JSONB`                | Stores JSON in binary format. Use `.parse(allocator, MyStruct)` to decode. |
| `POINT`                             | `struct{x: f64, y: f64}`     | `zpg.field.Point`                | Geometric point.                                                      |
| `LINE`                              | `struct{a,b,c: f64}`         | `zpg.field.Line`                 | Geometric line Ax + By + C = 0.                                       |
| `LSEG`                              | `struct{start, end: Point}`  | `zpg.field.LineSegment`          | Geometric line segment.                                               |
| `BOX`                               | `struct{p1, p2: Point}`      | `zpg.field.Box`                  | Geometric rectangle.                                                  |
| `PATH`                              | `struct{points: []Point, closed: bool}` | `zpg.field.Path`       | Geometric path (open or closed).                                      |
| `POLYGON`                           | `struct{points: []Point}`    | `zpg.field.Polygon`              | Geometric polygon.                                                    |
| `CIRCLE`                            | `struct{center: Point, radius: f64}` | `zpg.field.Circle`     | Geometric circle.                                                     |
| `CIDR`                              | `struct{addr, mask, is_ipv6}` | `zpg.field.CIDR`                 | Network address (IPv4/IPv6).                                          |
| `INET`                              | `struct{addr, mask, is_ipv6}` | `zpg.field.Inet`                 | Network host address (IPv4/IPv6).                                     |
| `MACADDR`                           | `struct{bytes: [6]u8}`       | `zpg.field.MACAddress`           | 6-byte MAC address.                                                   |
| `MACADDR8`                          | `struct{bytes: [8]u8}`       | `zpg.field.MACAddress8`          | 8-byte MAC address.                                                   |
| `BIT(n)`                            | `struct{bits: []u8, len}`    | `zpg.field.BitType(n)`           | Fixed-length bit string. Use specific types like `Bit10`.             |
| `BIT VARYING(n)`, `VARBIT(n)`       | `struct{bits, len, max}`     | `zpg.field.VarBitType(n)`        | Variable-length bit string. Use specific types like `VarBit16`.       |
| `TSVECTOR`                          | `struct{lexemes: []Lexeme}`  | `zpg.field.TSVector`             | Full-text search vector.                                              |
| `TSQUERY`                           | `struct{nodes: []Node}`      | `zpg.field.TSQuery`              | Full-text search query.                                               |
| `_TEXT`, `TEXT[]` (Arrays)          | `[][]const u8`               | -                                | Array of strings.                                                     |
| `_INT4`, `INTEGER[]` (Arrays)       | `[]i32`                      | -                                | Array of integers.                                                    |
| Composite Types                     | `struct{fields: YourFields}` | `zpg.field.Composite(YourFields)`| User-defined composite types.                                         |

**Important Notes:**

*   **Arrays:** Simple arrays (`_INT4`, `_TEXT`, etc.) can often be mapped directly to Zig slices (`[]i32`, `[][]const u8`). Nested arrays or arrays of complex types require careful handling. Text format parsing relies on PostgreSQL's array literal format (`{1,2,3}`). Binary format parsing (`QueryEx`) is generally more reliable for arrays.
*   **Composite Types:** Define a Zig struct matching the fields of your PostgreSQL composite type, then wrap it with `zpg.field.Composite(YourStruct)`.
*   **`zpg.field` Types:** Many custom types in `zpg.field` have `fromPostgresText`, `fromPostgresBinary`, `toString`, and `deinit` methods. Use `fromPostgresBinary` when using `QueryEx` and `fromPostgresText` when using `Query` (or when receiving text results). Call `deinit` on instances of these types if they allocate memory (e.g., `JSON`, `Path`, `TSVector`).
*   **NULL Handling:** Remember to use optional types (`?T`) in your result structs for database columns that can be `NULL`. Non-optional fields receiving `NULL` will likely cause parsing errors. `SERIAL` types cannot be optional.
