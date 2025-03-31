---
layout: default
title: Configuration
---

# Configuration

Connection behavior is controlled using the `zpg.Config` struct passed during `Connection` or `ConnectionPool` initialization.

```zig
const zpg = @import("zpg");

const config = zpg.Config{
    .host = "localhost",
    .port = 5432,
    .username = "myuser",
    .database = "mydatabase",
    .password = "mypassword",
    .tls_mode = .prefer,
    .timeout = 15_000, // 15 seconds
};

// Use config to initialize a connection or pool
// var conn = try zpg.Connection.init(allocator, config);
// var pool = try zpg.ConnectionPool.init(allocator, config, 5);
```

## Config Options

The `zpg.Config` struct has the following fields:

*   **`host`**: `[]const u8`
    *   The database server hostname or IP address.
    *   *Required*. Cannot be empty.
*   **`port`**: `u16` (Default: `5432`)
    *   The port number the database server is listening on.
*   **`username`**: `[]const u8`
    *   The username to connect with.
    *   *Required*. Cannot be empty.
*   **`database`**: `?[]const u8` (Default: `null`)
    *   The name of the database to connect to. If `null`, defaults to the `username`.
*   **`password`**: `?[]const u8` (Default: `null`)
    *   The password for the user. Required for password-based authentication (like SCRAM-SHA-256).
*   **`tls_mode`**: `zpg.config.TLSMode` (Default: `.prefer`)
    *   Controls the TLS/SSL encryption behavior.
        *   `.disable`: Never use TLS. Connection fails if the server requires it.
        *   `.prefer`: Attempt TLS. If the server doesn't support it, fall back to an unencrypted connection.
        *   `.require`: Require TLS. Connection fails if TLS cannot be established.
*   **`tls_ca_file`**: `?[]const u8` (Default: `null`)
    *   Path to the Certificate Authority (CA) certificate file for verifying the server's certificate. (Currently ignored in the basic `tls.zig` implementation).
*   **`tls_client_cert`**: `?[]const u8` (Default: `null`)
    *   Path to the client's TLS certificate file (for client certificate authentication).
*   **`tls_client_key`**: `?[]const u8` (Default: `null`)
    *   Path to the client's private key file. Required if `tls_client_cert` is set.
*   **`timeout`**: `u32` (Default: `10_000`)
    *   Connection timeout in milliseconds. Used by the connection pool when waiting for an available connection. `0` means wait indefinitely.

## Validation

You can optionally call the `validate` method on a `Config` instance to check for basic configuration errors before attempting to connect:

```zig
const my_config = zpg.Config{ /* ... */ };
try my_config.validate(); // Returns an error on invalid configuration
```
