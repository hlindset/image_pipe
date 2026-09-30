# Local TLS origin fixtures

`ca.pem` is a test CA. `origin.pem` is its server certificate for `origin.test`
and `other.test`; `origin-key.pem` is the matching test-only private key.
The certificates expire in 2126. These fixtures are used only by loopback
servers in the HTTP source pinning tests. Clients explicitly trust `ca.pem`.

The server certificate deliberately excludes `wrong.test` so the suite can
verify hostname mismatch rejection without disabling certificate verification.
