---
layout: default
title: TLS/SSL Connections
---

# TLS/SSL Connections

`zpg` supports establishing secure connections to PostgreSQL using TLS/SSL. Configuration is handled through the `zpg.Config` struct.

## Configuration

The primary setting is `tls_mode`:

*   **`tls_mode`**: `zpg.config.TLSMode` (Default: `.prefer`)
    *   Determines how TLS is negotiated.
    *   **`.disable`**: No TLS is used. Fails if the server requires TLS.
    *   **`.prefer`**: Attempts a TLS handshake. If the server supports it (`S` response), TLS is used. If the server doesn't (`N` response), the connection proceeds unencrypted.
    *   **`.require`**: Attempts a TLS handshake. If the server supports it (`S` response), TLS is used. If the server *doesn't* support it (`N` response), the connection fails (`error.TLSRequiredButNotSupported`). Fails also if the TLS handshake itself fails for other reasons.

```zig
const config_no_tls = zpg.Config{
    // ... other settings ...
    .tls_mode = .disable,
};

const config_prefer_tls = zpg.Config{
    // ... other settings ...
    .tls_mode = .prefer, // Default
};

const config_require_tls = zpg.Config{
    // ... other settings ...
    .tls_mode = .require,
};
```

## Server Certificate Verification (Basic)

Currently, the built-in `tls.zig` implementation **disables server certificate and hostname verification** by default:

```zig
// Inside src/tls.zig initClient function
const options = tls.Client.Options{
    .host = .no_verification, // <<< Hostname verification disabled
    .ca = .no_verification,   // <<< CA verification disabled
    // ...
};
```

This is convenient for development environments, especially with self-signed certificates, but is **insecure for production**.

**For production use, you would typically:**

1.  **Modify `src/tls.zig`:**
    *   Change `.host` to `.verify` to enable hostname verification.
    *   Change `.ca` to `.system` (to use system CA store) or `.file` (to use a specific CA file).
2.  **Provide CA Information (if needed):**
    *   Set `config.tls_ca_file` to the path of your CA certificate bundle if using `.ca = .file`.

```zig
// Example for requiring TLS with verification (after modifying tls.zig)
const config_secure = zpg.Config{
    .host = "prod.db.example.com",
    .username = "prod_user",
    // ... other settings ...
    .tls_mode = .require,
    // Assuming tls.zig now uses .ca = .file when tls_ca_file is set
    .tls_ca_file = "/path/to/ca-bundle.crt",
};
```

## Client Certificate Authentication

TLS client certificate authentication can be configured using:

*   **`tls_client_cert`**: `?[]const u8` (Path to the client certificate file, PEM format).
*   **`tls_client_key`**: `?[]const u8` (Path to the client private key file, PEM format).

Both must be provided if client certificate authentication is used. The underlying TLS implementation (`std.crypto.tls`) needs to be configured to load and use these files during the handshake. The current basic `tls.zig` doesn't explicitly load these, so modifications would be needed there as well for full client cert support.

```zig
const config_client_cert = zpg.Config{
    // ... other settings ...
    .tls_mode = .require,
    .tls_client_cert = "/path/to/client.crt",
    .tls_client_key = "/path/to/client.key",
    .tls_ca_file = "/path/to/ca.crt", // Usually needed with client certs too
};
```
