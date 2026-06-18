# Cache Bug Trio Design

**Issues**: #181, #183, #184
**PR scope**: one PR, three independent fixes

---

## Bug #181 — ETag missing detector identity

### Problem

`plug.ex` calls `HTTPCache.prepare(conn, plan, resolved_source, opts)` with raw opts, so
`etag_material/4` sees `detector_identity: nil` and produces a stable ETag. Later,
`Runner.run` enriches opts via `put_detector_identity(opts, plan)` only for the internal
cache key. After a detector/model swap the key changes (fresh bytes stored) but the ETag
does not — conditional GET clients and CDNs receive `304 Not Modified` against the old
rendition indefinitely.

### Fix

Extract `put_detector_identity/2` from its private scope in `Runner` into a public
`Runner.with_detector_identity(opts, plan)`. Call it in `plug.ex` before `HTTPCache.prepare`
and thread the enriched opts through to `Runner.run`. Remove the inner call from
`run_with_cache_config` — one resolution, one source of truth.

**Changed files**

- `lib/image_pipe/request/runner.ex` — make `put_detector_identity` public as
  `with_detector_identity/2`; remove its call from `run_with_cache_config`
- `lib/image_pipe/plug.ex` — call `Runner.with_detector_identity(opts, plan)` after
  `validate_detector_capability` and before `HTTPCache.prepare`; pass enriched opts
  throughout `do_call_with_plan`

### Tests

`test/image_pipe/request/http_cache_test.exs`:

- Detect/face-assist plan with `detector_identity: {"MyDetector", "v2"}` in opts produces a
  different ETag than the same plan with no detector identity.
- Non-detect plan is unaffected (ETag identical regardless of `detector_identity` in opts).

---

## Bug #183 — Raising adapter fails closed

### Problem

Tuple errors from host-implementable `ImagePipe.Cache` callbacks are handled everywhere,
but raises are not caught at any call site. Three paths are exposed:

1. `Cache.get_configured` → `adapter.get/2` raise propagates out of `Runner.run` → 500.
2. `Sink.do_write_chunk` → `adapter.write_chunk/3` raise crashes the `SourceSession`
   GenServer mid-chunk; the client receives a truncated body.
3. `Sink.emit_commit_result` → `adapter.commit_sink/2` raise propagates through
   `Telemetry.span` (which re-raises after emitting the `:exception` event); the
   client receives a truncated body even though every byte was already sent successfully.
4. `Sink.abort_adapter` → `adapter.abort_sink/2` raise propagates through cleanup paths
   that would otherwise emit telemetry cleanly.

### Fix

Add `rescue` at each adapter call site. Translate exceptions into the existing
tuple-error paths so downstream handling is unchanged.

**`Cache.get_configured`** — rescue around `adapter.get(key, cache_opts)`; translate
exception to `{:miss, key, {:cache_read, exception}}`.

**`Sink.do_write_chunk`** — rescue around `adapter.write_chunk(sink.state, chunk,
sink.adapter_opts)`; translate exception to the existing `{:error, reason}` branch
(abort, log, emit `stage_error`).

**`Sink.emit_commit_result`** — rescue the lambda body *inside* the `Telemetry.span`
call so the span emits `:stop` with error metadata (not the `:exception` event).
Translate exception to `commit_stop_metadata({:error, exception}, sink)`. `Sink.commit/2`
still returns `:ok` — the fail-open contract is preserved.

**`Sink.abort_adapter`** — rescue around `adapter.abort_sink(sink.state, sink.adapter_opts)`;
translate exception to `{:error, exception}`.

**Changed files**

- `lib/image_pipe/cache.ex` — rescue in `get_configured`
- `lib/image_pipe/cache/sink.ex` — rescue in `do_write_chunk`, `emit_commit_result`,
  `abort_adapter`

### Tests

`test/image_pipe/cache_test.exs` (or a dedicated `cache_raise_test.exs` if it keeps the
existing file focused):

Use an inline raising adapter module defined in the test. Two scenarios:

1. `adapter.get/2` raises → `Cache.lookup/4` returns `{:miss, key, {:cache_read, exception}}`
   (not a raise).
2. `adapter.commit_sink/2` raises after full successful drain → `Sink.commit/2` returns `:ok`
   (no raise); the caller receives the complete response body.

---

## Bug #184 — Cache-hit path overwrites host-set content-disposition

### Problem

`Sender.send_cache_entry/5` runs content-disposition *after* `merge_delivery_headers` /
`reject_existing_conn_headers`:

```
cacheable_headers → merge_delivery_headers (reject step runs here) → delivery_headers appends content-disposition
```

The host's pre-set `content-disposition` is dropped by the reject step, but then
ImagePipe's value is unconditionally appended afterwards — host loses.

On the miss (stream) path, content-disposition is included in `PreparedStream.headers`
*before* `merge_delivery_headers` runs, so the reject step correctly honours the host
value.

### Fix

Compute content-disposition before the merge step in `send_cache_entry`. Fold it into
the headers list passed to `merge_delivery_headers` so the reject step handles it the
same way as any other delivery header.

Replace the two-stage `with` (`delivery_headers` call) with:

```elixir
with {:ok, entry_headers} <- Entry.cacheable_headers(entry.headers),
     {:ok, content_disposition} <- Response.content_disposition(response, entry.content_type) do
  merged = merge_delivery_headers(conn, entry_headers ++ [{"content-disposition", content_disposition}], prepared)
  send_normalized_cache_entry(conn, entry, merged)
end
```

Delete `delivery_headers/3` — its only call site is the `send_cache_entry` `with` chain
being restructured; no other path calls it.

**Changed files**

- `lib/image_pipe/response/sender.ex` — restructure `send_cache_entry/5`

### Tests

`test/image_pipe/cdn_http_cache_wire_test.exs` (or imgproxy wire conformance test):

Wire-level test using `ImagePipe.call/2` with a host plug that pre-sets
`content-disposition: attachment; filename="custom.jpg"`. Make two requests to the same
URL (first a miss, second a hit). Assert that both responses carry the host-set
`content-disposition` value unchanged.
