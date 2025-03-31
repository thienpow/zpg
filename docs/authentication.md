---
layout: default
title: Authentication
---

# Authentication

`zpg` handles the PostgreSQL authentication flow automatically during the `connection.connect()` process based on the server's requirements and the provided `zpg.Config`.

## Supported Methods

*   **SCRAM-SHA-256 (SASL):**
    *   This is the preferred and most commonly used secure password-based authentication method in modern PostgreSQL.
    *   `zpg` fully supports SCRAM-SHA-256.
    *   Requires `config.username` and `config.password` to be set.
    *   The implementation is handled in `src/auth.zig` and `src/sasl.zig`.

## Unsupported Methods

The following authentication methods advertised by PostgreSQL are **not currently supported** by `zpg` and will result in an error during connection if requested by the server:

*   Kerberos V5 (`error.KerberosNotSupported`)
*   Cleartext Password (`error.CleartextPasswordNotSupported`) - *Generally insecure and discouraged.*
*   MD5 Password (`error.Md5PasswordNotSupported`) - *Considered insecure; upgrade server auth.*
*   SCM Credentials (`error.ScmCredentialsNotSupported`) - *Used for Unix domain socket peer authentication.*
*   GSSAPI (`error.GssapiNotSupported`)
*   SSPI (`error.SspiNotSupported`) - *Windows-specific.*

## Configuration

Authentication is primarily configured via `zpg.Config`:

*   `username`: Required.
*   `password`: Required for SCRAM-SHA-256.

If the server supports multiple methods, `zpg` will attempt to use SCRAM-SHA-256 if available and a password is provided. If the server only offers an unsupported method, the connection will fail.
