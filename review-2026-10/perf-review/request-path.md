# Performance review: request path

Scope: Plug entry and runner, URL lexing/signing/parsing, plan and output-policy building, format negotiation, cache headers, response delivery, and telemetry/tracing overhead. Reviewed at `main` 84eeac2. No code was changed.

## How this was measured

The cloud container can't reach hex.pm, so the full app and its deps (Plug, Vix, Bandit) could not be built. Elixir 1.19 / OTP 28 came from the Nix cache (the repo pins 1.20 / OTP 29). The numbers come from:

- `image_pipe_url`'s real parser modules (`API.Path`, `API.Parser`, `API.OptionSpec`, `Plan.*`), compiled standalone. `Color`, `NimbleOptions` and `Boundary` were stubbed. Colour-value parsing is therefore not measured, and nothing else on these paths uses the stubs.
- Isolated scripts that copy the exact code shape where the real module needs Plug or Vix (trace `Capture.classify`, keyword-config ops, cache body reads).

Absolute numbers are from a 4-vCPU container. Read them as relative. End-to-end request timing was not possible here.

## Candidates, ranked by expected payoff

### 1. Parse does the option pass twice, and the first result is usually discarded

- **Where:** `image_pipe/lib/image_pipe/plug/request.ex:46-49` calls `Parser.preset_names(lexed)` (`image_pipe_url/lib/image_pipe/api/parser.ex:71-75`). That runs the full `parse_options/1`: value parsing for every segment, group splitting, and duplicate detection. Then `Presets.for_request/2` (`image_pipe/lib/image_pipe/presets.ex:22-29`) returns the static map without using the names whenever `:preset_lookup` is unset, which is the default. `Parser.parse/2` then runs `parse_options/1` again.
- **Measured (real parser code):**

  | URL | `Path.extract` | `preset_names` (wasted) | `Parser.parse` | total today |
  |---|---|---|---|---|
  | `/w=300/h=200/fit=cover/format=webp/q=80/src/…` | 6.0 µs | 12.7 µs | 22.5 µs | 43.7 µs |
  | 3 groups, 8 options, `%20` in src | 9.5 µs | 26.7 µs | 53.2 µs | 109.2 µs |

- **Fix:** only compute names when a lookup is configured (`case config[:preset_lookup]` before calling `preset_names`). Or return the parsed occurrences from one pass and feed them to `parse/2`, which also helps the lookup case.
- **Impact:** about 30% less parse CPU (13–27 µs per request). It matters most for 304s and cache hits, where parsing is a large share of the non-I/O work.

### 2. Cache-hit body delivery: three passes over the file in BEAM instead of one `sendfile`

The "Performance: sources and caching" review already covers this (item 3 and the `:raw` note in `perf-review/sources-and-caching.md`). Delivery numbers to support it:

- **Where:** `cache/file.ex:10-46` (non-`:raw` open, verify pass, rewind, send pass) and `response/sender.ex:131-160` (`send_chunked` with 64 KB `chunk/2` calls).
- **Measured:**

  | body | today | `:raw`, same two passes | `:raw`, send pass only | SHA-256 alone |
  |---|---|---|---|---|
  | 50 KB | 197 µs | 117 µs | 42 µs | 87 µs |
  | 300 KB | 593 µs | 397 µs | 81 µs | 372 µs |
  | 2 MB | 3,570 µs | 2,771 µs | 326 µs | 1,993 µs |

  The send-pass column still copies through BEAM. `Plug.Conn.send_file/5` uses kernel `sendfile` under Bandit and Cowboy, so it would be cheaper still.
- **Delivery-side fix:** keep `content-length`, but send through `send_file(conn, 200, path, 0, size)`. If integrity checking stays, a middle option is to hash while streaming and abort the connection on a mismatch, which the abort path already does for failed streams (`plug/runner.ex:44-65`). That gives one pass instead of two. The cost is that a corrupt entry becomes a dropped connection instead of a silent regenerate.
- **Caveat:** `send_file` reopens by path. An eviction or replace between verify and send would serve a different file or fail after headers. Pinning the inode (hold the fd, or hard-link as input pinning already does) avoids that.

### 3. Miss-path streaming is lock-step, one message round trip per encoder chunk

- **Where:** `delivery/producer.ex:101-120` pulls exactly one chunk per `{:next, …}` request. `response/sender.ex:282-315` writes each chunk to the socket before asking for the next. Nothing coalesces chunks (`delivery/stream_pull.ex:28` forwards any non-empty binary).
- **Reasoning (not measured here, Vix unavailable):** libvips targets flush in small buffers, on the order of 8 KB. A 300 KB output would then be about 40 producer round trips and about 40 chunked writes, and encoding chunk N+1 never overlaps writing chunk N.
- **Fix:** in `pump_loop`, keep pulling until about 64 KB has accumulated (or `:done`) before replying. Optionally prefetch one chunk ahead so encode and socket write overlap. The first chunk stays small so time-to-first-byte doesn't change.
- **Impact:** inferred. Several times fewer messages and syscalls on large outputs. It should be validated with a counter of chunks per response before committing.

### 4. Cache headers are computed twice on every 200, and `[:http_cache, :prepare]` fires twice

- **Where:** `plug/runner.ex:122` (`serve_context`) and again at `:141` (`serve_output`). Both call `context_headers/3`, which runs `CachePolicy.generate/6` plus both limit passes and emits the `[:http_cache, :prepare]` one-shot each time (`response/cache_policy.ex:74-84`).
- **Fix:** compute once. Recompute in `serve_output` only when `output.degraded?` is true, or apply the degraded `no_store` downgrade to the headers already built.
- **Impact:** small CPU, a few µs. It also halves a duplicated telemetry event that metrics handlers would double-count. Worth flagging to the request-handling bug hunt as well.

### 5. Request cookies are parsed on every request even when nothing reads them

- **Where:** `plug/runner.ex:102` calls `Plug.Conn.fetch_cookies/1` unconditionally. Only `Execution.Inputs.storage_material/2` (`execution/inputs.ex:79`) reads cookies, and only for `storage_inputs: [{:cookie, _}]`.
- **Fix:** fetch cookies only when the mount's `storage_inputs` names a cookie.
- **Impact:** inferred. The cost scales with the `Cookie` header. Image mounts on a first-party domain often receive several KB of analytics cookies, so this is likely a few to tens of µs.

### 6. Small, cheap cleanups (low impact, only bundle with other work)

| item | where | measured |
|---|---|---|
| `Telemetry.telemetry_opts/1` does `Keyword.take` over the whole resolved config (about 80 keys) at every span call site, about 10 per request | `telemetry.ex:365` | 1.5 µs per call. Computing the prefix once per request saves about 15 µs |
| `OptionSpec.fetch/1` is a linear `Enum.find` over 70 specs, run twice per segment today (see #1) | `api/option_spec.ex:688` | 2.4 µs vs 0.26 µs for 5 keys with a compile-time map |
| src percent-escape check uses a module-attribute regex | `api/path.ex:33,303` | 1.5 µs vs 0.17 µs for a binary scan |
| Response header merge is O(n²) with repeated `String.downcase` | `response/sender.ex:370-425` | n is about 10, so a few µs at most |
| Default Logger handler builds the message string before `Logger.log`, so it is built even when the level is filtered out | `telemetry/logger.ex:145-158` | only matters when attached. Move the build inside the fn |

## Checked and not worth changing

- **Signature verification** (`security/signature.ex`): one HMAC-SHA256 per configured key, constant-time compare. About 1–2 µs.
- **Format negotiation** (`output/negotiation.ex`, `output/request_policy.ex`): capabilities come from `:persistent_term` and the Accept parse is tiny.
- **Instance mount resolve** (`plug/config.ex:77`): `:persistent_term` read plus a `Keyword.merge` with a 3-key mount list.
- **Span tracer overhead** (`telemetry/trace/capture.ex`): about 1 µs per event (0.33 µs classify, 0.66 µs `Map.take` against 84 safe keys), and only when attached. A precomputed event→name map would make classify about 0.01 µs, but at roughly 15–40 events per request that is noise next to image work.
- **Representation digests** (`material_digest.ex`): two SHA-256 over a few KB of `term_to_binary`, single-digit µs.

## Suggested order

1 and 4 are small, safe and test-first friendly. 2 belongs with the caching review's fix. 3 needs a chunk-count measurement on a real build first. 5 is a one-line guard.
