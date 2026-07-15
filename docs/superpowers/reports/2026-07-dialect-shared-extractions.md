# Dialect inversion — shared-utility extractions (post-probe design note)

**Status:** proposal, post-probe
**Date:** 2026-07-15
**Relations:** follows `2026-07-dialect-owned-pipelines-probe-report.md` (§6d,
§2) and `2026-07-13-dialect-owned-pipelines-design.md` (Design Principle 1;
the "à la carte skeleton" decision).

## Why

The probe measured the per-dialect duplication of the inverted pattern
(native dialect, 4,113 lib lines):

- **Grammar** (~2,700 lines) — parser/lexer/option table/signing/diagnostics.
  Necessarily per-dialect; *not* duplication.
- **Chain + glue** (~1,300 lines) — the visible `call/2` chain, config schema,
  identity composition, source translation, error→status. Structurally
  similar across dialects; duplicated **on purpose** (the design refuses a
  shared orchestrator-with-callbacks — that would rebuild the framework).
- **Delivery lifecycle** (~700 lines: `Native.Delivery` + `Coordinator` +
  `Producer`) — a **mechanical mirror** of `Request.SourceSession`/`Producer`.
  Neutral streaming lifecycle, nothing dialect-specific. **This is genuine,
  retirable duplication.**

Two demand-driven extractions retire the *real* duplication without
reintroducing the choke-point framework. Neither is an orchestrator: both are
either a lifecycle-owning **primitive** (endorsed by Design Principle 1,
alongside `Source.with_fetched`/`Decode.with_image`) or pure **data/validation**
(a config schema fragment). Do each when the second dialect inverts.

---

## Extraction A — core streaming-delivery primitive (~700 lines/dialect)

**Move** the monitor-based session/producer out of the dialect into core, so
every dialect *and* the framework consume one implementation.

### Proposed surface

New boundary `ImagePipe.Response.Delivery` (deps: `[Cache, Decode, Source,
Output, Response, Telemetry]`), or a widening of `ImagePipe.Response`:

```elixir
@spec stream(
        owner_pid :: pid(),
        build_fun :: (chunk_sink :: (iodata() -> :ok) -> :done | {:error, term}),
        opts :: keyword()
      ) :: {:ok, Response.PreparedStream.t()} | {:error, term}
```

- `owner_pid` — the conn owner; the coordinator `Process.monitor`s it (owner
  death ⇒ graceful producer halt).
- `build_fun` — the dialect's per-request work (fetch → decode → transform →
  encode), run **inside** the producer, **inside** the `Source.with_fetched`
  and `Decode.with_image` brackets. It receives a `chunk_sink` closure and
  pushes encoded chunks through it; it must never return a lazy stream/image
  outward.
- `opts` — `cache_key`, `resolved_output` (for the sink), `telemetry_opts`,
  cancellation config.

Returns a `%Response.PreparedStream{}` the caller hands to `Response.Sender`.

### Invariants the primitive MUST preserve (pinned by Task 15's Opus review)

1. **Monitor direction:** coordinator does `Process.monitor(owner_pid)` (not
   `spawn_monitor` from the owner — that watches the wrong way).
2. **Bracket containment:** the chunk-pump loop runs *inside* both brackets
   until encoder EOF/cancel; only encoded chunks cross the process boundary;
   the lazy vips image + encoder `Enumerable` never escape.
3. **Cleanup exactly once, graceful:** owner-down / explicit cancel / normal
   EOF all unwind through the producer's `try/…/after` so bracket cleanup +
   sink abort fire exactly once. (Graceful halt, not force-kill, so `after`
   always runs; a ~1s backstop force-kills a wedged single synchronous encode
   — carry this caveat forward.)
4. **Cache sink ownership:** the coordinator owns the sink
   (`open_sink`/`write_chunk`/`commit_sink`/`abort_sink`), fail-open.
5. **No supervisor / no `application.ex` child** — monitor-based, so a dialect
   still can't force core to name it.

### Migration

- `Native.Delivery.stream/5` becomes a thin adapter over
  `Response.Delivery.stream/3` (or is deleted, calling it directly).
- **The framework's `Request.SourceSession`/`Producer` migrate onto the same
  primitive** — this is the real payoff: one streaming implementation, two
  callers today, N later. The framework's extra concerns (custom-render
  branch, detector identity) become `build_fun` variations, not a fork.
- The complete-body (BlurHash/LQIP) path stays a dialect-owned `send_resp`
  (no producer) — the primitive is for the streamed-encoder path only.

### Risks / open questions

- The framework `SourceSession` currently *force-kills* on cancel; the probe's
  primitive *graceful-halts*. Unifying means the framework adopts graceful
  halt — verify no framework test depends on the force-kill timing.
- `build_fun`'s exact signature (does it own the encoder loop, or does the
  primitive drive it given an `Enumerable`?) — the probe keeps the loop inside
  `build_fun` to guarantee containment; keep that.
- Whether this is a new boundary or a `Response` widening — new boundary keeps
  `Response` from gaining `Decode`/`Source` deps.

---

## Extraction B — shared config-schema fragment (~40 lines/dialect)

**Move** the common *runtime* option keys + their validation delegation into a
shared fragment, so each dialect's `Config` adds only its dialect-specific keys.

### Proposed surface

A pure-data helper (NOT a `use`-macro that injects control flow):

```elixir
defmodule ImagePipe.Dialect.SharedConfig do
  # The runtime keys every inverted dialect threads into the core toolkit.
  @spec runtime_schema() :: NimbleOptions.schema()   # cache, sources,
  #   max_body_bytes, max_input_pixels, telemetry_prefix,
  #   auto_avif/webp/jpeg_xl, format_order — with their :type/:default

  @spec validate_runtime!(keyword()) :: keyword()    # delegates :cache ->
  #   Cache.validate_config!, :sources -> Source.validate_config!, validates
  #   the rest; raises on invalid. Returns the normalized shared keys.
end
```

A dialect's `Config.validate!/1` then:

```elixir
def validate!(opts) do
  {shared, dialect} = Keyword.split(opts, SharedConfig.keys())
  shared = SharedConfig.validate_runtime!(shared)
  dialect = validate_dialect_keys!(dialect)   # keys, presets, on_inert_option, ...
  Keyword.merge(shared, dialect)
end
```

### Guardrail (why this is NOT the forbidden skeleton)

This shares **validation of shared keys** — data, not orchestration. It does
NOT own the request chain, dispatch stages, or provide override hooks. Each
dialect still writes its own visible `call/2`. The line the design draws is
"no shared orchestrator with callbacks"; a schema fragment is on the safe side
of it (same category as `Cache.validate_config!` already being shared).

### Migration

- `Native.Config` keeps its dialect-specific schema (`keys`, `presets`,
  `on_inert_option`, `storage_inputs`) and delegates the shared block.
- Net: ~40 fewer lines of copy-pasted schema per new dialect, and a single
  place to add a new shared runtime knob (e.g. a future `dpr` default or a
  host output-policy config) so it lands for all dialects at once.

---

## Sequencing

1. **When the second dialect inverts** (imgproxy is the natural next — it
   forces both extractions and re-uses the differential suite as a black-box
   regression net), do B first (trivial), then A (the payoff).
2. A is also justifiable *proactively* if committing to the full migration,
   since it unifies the framework's own `SourceSession`.
3. Neither blocks the probe merge; both are follow-ups.
