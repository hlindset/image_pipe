# Request controls

[All processing options](../processing.md) · [URLs and presets](../urls.md)

Request controls apply to the whole request. In Elixir, pass them to
`ImagePipe.new/1` or `ImagePipe.new(config, options)`.

| URL | Elixir | Purpose |
| --- | --- | --- |
| `filename=photo` | `filename: "photo"` | Response filename stem; ImagePipe adds the output extension |
| `attachment` | `attachment: true` | Download disposition; false selects inline |
| `cb=release-2` | `cachebuster: "release-2"` | Select a new cache storage entry |
| `expires=2000000000` | `expires: 2_000_000_000` | Positive Unix timestamp in seconds |
| `debug` | `debug: true` | Request diagnostic headers, subject to mount permission |

`filename` and `cb` accept nonempty ASCII letters, digits, dots, underscores,
and hyphens. They do not accept percent escapes.

## Downloads

```text
/w=1200/format=jpeg/filename=beach/attachment/src/photos/beach.jpg
```

The response suggests `beach.jpg`. Text placeholders receive `.txt`; info
receives `.json`. Delivery settings apply on cache hits too and leave stored
bytes and ETags unchanged. A 304 response omits `Content-Disposition`.

For direct Elixir calls, `filename`, `attachment`, and `debug` do not affect
the result. `ImagePipe.write/4` uses its explicit destination path and does
not infer output format from its extension.

## Expiry and storage identity

Expired requests fail before source fetch or cache access. A request remains
valid at its exact expiry second. Configure [signing](../urls.md#signing-and-expiry)
to authenticate the expiry and processing options.

`cb` changes the storage key while preserving the ETag for byte-identical
output. It is separate from source revisions and HTTP freshness. See
[HTTP caching](../cdn-http-cache.md) for conditional requests and validators.

## Debugging

Debug headers require both request `debug` and mount
`allow_debug_headers: true`. See [debug headers](../debug_headers.md) for
the available fields and disclosure policy.
