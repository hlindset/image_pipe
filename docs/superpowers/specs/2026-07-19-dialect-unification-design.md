# Dialect unification: one contract, one mount

Date: 2026-07-19
Status: approved design, pre-implementation-plan

## Problem

After the TwicPics inversion (PR #468), ImagePipe has two parallel request
models:

1. **The framework parser stack.** A host implements `ImagePipe.Parser`
   (`parse/2 -> %ImagePipe.Plan{}`), mounts `ImagePipe.Plug` with `parser: X`,
   and the Plug owns the lifecycle: parse → validate → source resolve →
   conditional-GET → cache → fixed neutral driver → encode → deliver.
   `ImagePipe.Parser.IIIF` is the only user.
2. **Self-contained dialect Plugs.** `ImagePipe.Dialect.{Imgproxy, Native,
   TwicPics}` are standalone Plugs mounted directly with flat config. Each
   reassembles the same lifecycle by hand from core boundaries.

The inversion chose this deliberately (decisions T8 "no generic dialect
runner" and T13 "no public dialect-pipeline SDK" in
`2026-07-17-twicpics-dialect-inversion-design.md`). This design overturns
those two decisions on new evidence and collapses ImagePipe to one way to
write and mount a dialect.

## Evidence: the lifecycle is already one observable control flow

T8's stated reason was "Native, imgproxy, and TwicPics share lifecycle nouns
but not one observable control-flow contract." Reading the three `call/2`
bodies at the current head contradicts that at the lifecycle altitude:

- `build_and_pump` — the `with` chain `run_transform → resolve_output → clamp
  → materialize_for_delivery → encode_first_chunk → pump` — is verbatim
  identical in `dialect/imgproxy.ex` and `dialect/native.ex`; TwicPics differs
  only by `Timing.measure` wrappers and a debug-info build.
- `serve → deliver_hit / generate`, the hit-path `If-None-Match: *` check,
  `send_not_modified`, `send_with_span`, and the `[:request]` / `[:parse]` /
  `[:transform, :execute]` / `[:encode]` / `[:send]` span scaffolding are
  near-verbatim in all three.
- The three dialect `Negotiation` structs are copies of one struct, built by
  the same `Policy.from_output_plan → ensure_capable → identity_selection`
  sequence.
- The product-specific behavior never touches the shared chain: imgproxy's
  signature/`exp` gates and endpoint split, and Native's `then` grouping, live
  entirely in the parse/pre-fetch phase; TwicPics's shadow optimizer and
  PointFlow live entirely inside `Pipeline.run`. Product **ordering** — the
  thing T8 rightly refused to encode as callbacks — appears in the shared
  lifecycle zero times.
- The two non-image terminals (imgproxy `/info`, Native blurhash) mirror
  *each other*: same `{:complete_body, ct}` cache path, same wildcard check,
  same `send_complete_body`, same fail-open `write_complete_body_cache`.

The cost of hand-mirroring is also already live: core sources (S3/HTTP with
`internal_cache: :auto`) can resolve `internal_cache: :disabled`. The
framework Runner, imgproxy, and TwicPics honor it (skip cache lookup and
write, `nil` cache key). Native's `serve` does not — it unconditionally looks
up and writes the cache for a source whose bytes carry no stable identity.
File-level ExDNA suppression (the exact concern of issue #457) hid the drift.

## Decisions

| ID | Decision | Reason |
| --- | --- | --- |
| U1 | One coarse request-lifecycle contract, `ImagePipe.Dialect`, replaces both request models. | The post-parse lifecycle is empirically one observable control flow; hand-mirroring it four times already produced a live drift bug. |
| U2 | `ImagePipe.Plug` becomes the single mount interface and the lifecycle runner: `plug ImagePipe.Plug, dialect: Module, <flat config>`. | "One way to mount" is literal, not cosmetic; the runner owns the neutral spine once. |
| U3 | The behaviour has six required callbacks (`validate_config!`, `parse`, `prepare`, `decode_request`, `execute`, `render_error`) and one optional hook; everything else rides `%Dialect.Resolved{}` as values. | Coarse phases, not mid-execution hooks. Values-not-callbacks is what keeps the contract from regrowing the leaky framework T8 warned about. |
| U4 | The runner may branch only on `Resolved` fields and neutral core structs — never on dialect identity, never via dialect-specific flags. | The "pile of conditionals" failure mode arrives incrementally; this is the review-enforceable line against it. |
| U5 | Product ordering stays wholly inside the dialect's `execute` (its Pipeline); the runner has no ordering concept. | Preserves T8's *reason* while overturning its conclusion. |
| U6 | The behaviour is public and documented: declarative tier (`use ImagePipe.Dialect.Declarative`, implement `parse_plan/2 -> %Plan{}` — a distinct name because the macro owns the behaviour's `parse/2`) and ordered tier (implement the full behaviour). | Deliberate T13 reversal (user decision). This is a request-lifecycle SDK, not the rejected per-operation mid-execution SDK: no `Resolver`, no `Directive`, no `:deferred`, no Plan markers; `NeutralResolver` stays core-internal. |
| U7 | IIIF is re-expressed as `ImagePipe.Dialect.IIIF` on the declarative base; `ImagePipe.Parser` (behaviour and dispatch) is deleted. | One user; its three callbacks survive as the Declarative contract (`parse_plan/2`, `render_error/3`, `validate_config!/1`). |
| U8 | The runner unifies conditional-GET on the `Representation` + `Response.Conditional` mechanism; `Request.HTTPCache`'s identity mechanics are deleted. IIIF's ETag and cache-key values change. | One identity mechanism; the dialect one is stricter (pre-fetch 304 structurally). Greenfield: behavior-level round-trip is the contract, literal values are not (user decision). |
| U8b | `Request.HTTPCache`'s header-generation policy (generated `Cache-Control: public, max-age=31536000, immutable`; Set-Cookie / `Vary: *` / host-Cache-Control suppression rules; the `http_cache:` mode option with the per-source `:inherit` override) and three of the four `[:http_cache, :*]` events (`prepare`, `conditional.match`, `fallback.no_store`) are **promoted to a core policy module** applied by the runner between `Representation.build` and the conditional gate (its ETag suppression must be able to veto the 304, as today), gated by a `Resolved.http_cache` value: `:generated` (the Declarative base — IIIF keeps its exact headers and events) or `:dialect_owned` (the three ordered dialects — byte-identical current behavior, no additive events). The fourth event, `[:http_cache, :cache_hit, :headers]`, already lives in the shared `Response.Sender` cache-entry delivery, fires for every dialect's hits today, and stays there. | The policy is behavior IIIF has that the dialects don't (gated by the CDN wire suite); deleting it would be an unplanned observable delta. Gating on a `Resolved` value keeps U4. Ordered dialects opting into generated headers later (e.g. imgproxy's upstream TTL-driven `Cache-Control`) is separate compat-reviewed work. |
| U9 | Native gains the `internal_cache: :disabled` handling it is missing, with new wire coverage. | Deliberate bug fix surfaced by this analysis, not silent drift. |
| U10 | The framework stack — `ImagePipe.Request.{Runner, Processor, HTTPCache, DeliveryBuild, Options}` — is deleted after IIIF migrates. | Zero users remain; keeping it would preserve the second model this design exists to remove. |
| U11 | `ImagePipe.Renderer` survives as the declarative base's non-image-terminal contract: `render: {:custom, mod, params}` becomes a `{:render, %RenderTerminal{}}` terminal carrying the render fun, the content-type `offers`, and cacheability (`cache: :none` for IIIF — preserving its per-request ld+json Accept negotiation, `Vary`, and no-internal-cache behavior via `Sender`'s `{:rendered, …}` delivery; `cache: :complete_body` for imgproxy `/info` and Native blurhash). | IIIF `info.json` needs offers negotiation and is uncached today; the ordered dialects' render terminals cache complete bodies. Presentation is never stored. |
| U12 | Per-dialect wire, differential, and telemetry suites gate every phase; no fixture, verdict, or tolerance changes. Deliberate deltas are exactly the enumerated observable-deltas list below — nothing else may differ. | The inversion's own evidence discipline, reused. |
| U13 | Debug-header restoration (#462) rides the unification: the runner owns a **default neutral `Debug.Info` builder** fed from `DebugContext` (timings, `Decode`-collected source facts, negotiation/output facts, `Resolved.operations`, cache hit/miss debug), and `allow_debug_headers` moves to `SharedConfig`. imgproxy's already-parsed `debug?` flag rides `Resolved.debug?` and its `X-ImagePipe-*`/`Server-Timing` headers return in Phase B, closing #462. The default builder runs unconditionally and its `Debug.Info` is stored with the cache entry (today's hit-replay contract). The `debug_info` hook demotes to an optional enrichment override; TwicPics ports onto the runner default, which means its debug responses gain the source-fact headers — a deliberate enumerated delta (see observable delta 5). | The inversion lost the threading because each chain had to hand-thread it; restoring pre-unification is disposable work, post-unification is a double port. Every TwicPics debug fact is neutral, so one runner builder replaces per-dialect threading. The flag stays identity-excluded (never moves key/ETag). |

## The contract

```elixir
defmodule ImagePipe.Dialect do
  @callback validate_config!(keyword()) :: keyword()
  # Init-time. Splits on SharedConfig.keys/0, delegates the shared subset to
  # SharedConfig.validate_runtime!/1, validates its own keys, raises on error.

  @callback parse(Plug.Conn.t(), config :: keyword()) ::
              {parse_result, span_stop_metadata :: map()}
            when parse_result:
                   {:ok, request :: term()}
                   | {:redirect, pos_integer(), String.t()}
                   | {:error, term()}
  # Wrapped in the [:parse] span by the runner; covers exactly what each
  # dialect's parse span covers today (imgproxy extract→verify→split→parse;
  # Native verify→lex→parse; TwicPics Path→Manipulation→RequestBuilder; IIIF
  # classify→resolve-id→grammar). The request term is opaque to the runner.
  # The dialect shapes the span's stop metadata for BOTH outcomes — the
  # per-dialect differences are deliberate and documented in the chains
  # (Native's ok-metadata carries :sig_key_index while its error metadata
  # deliberately omits the error tag; imgproxy/TwicPics tag their errors) —
  # so a single runner-built metadata map cannot reproduce them.

  @callback prepare(Plug.Conn.t(), request :: term(), config :: keyword()) ::
              {:ok, ImagePipe.Dialect.Resolved.t()} | {:error, term()}
  # Everything else decidable before any side effect: gates (exp/expires,
  # pre-fetch geometry assembly, detector capability), source translation,
  # negotiation, identity material (detector identity folded in), response
  # meta, terminal selection. Runs outside the parse span, matching today's
  # span boundaries.

  @callback decode_request(request :: term(), SourceGeometry.t()) ::
              DecodePlanner.Request.t()
  # Shrink-on-load preflight (each dialect's existing Pipeline.decode_request).

  @callback execute(State.t(), SourceGeometry.t(), request :: term(),
                    opts :: keyword()) ::
              {:ok, State.t()} | {:error, term()}
  # The transform stage only: Pipeline.run for ordered dialects, the fixed
  # neutral driver for declarative ones. Runs inside the decode bracket the
  # runner owns, wrapped in the [:transform, :execute] span. The runner
  # threads :supports_hdr? into opts (computed from the negotiation policy).

  @callback render_error(Plug.Conn.t(), reason :: term(), config :: keyword()) ::
              Plug.Conn.t()
  # Status vocabularies (403/400/404/422) are irreducibly per-dialect.

  @callback classify_error(reason :: term()) :: atom()
  # Optional. Maps a reason to the [:request] span's :result atom; the default
  # is ImagePipe.Telemetry.request_result/1 (today's per-dialect
  # outcome_result fallbacks).
end
```

This listing is the contract as it stands after Phase B; see the per-phase
addendum at the end of this document for the deltas and contract widenings
each phase introduced.

### `%ImagePipe.Dialect.Resolved{}`

Values, not callbacks — this is what keeps the behaviour at six required
callbacks:

```elixir
%Resolved{
  request: term(),                # opaque; threaded to decode_request/execute
  source: source_ref,             # a Plan source reference; runner calls Source.resolve
  negotiation:
    {:ok, %Dialect.Negotiation{}, %Representation.IdentityMaterial{}}
    | {:error, term()},
                                  # DEFERRED, COUPLED result. Identity
                                  # material cannot exist without a
                                  # successful negotiation (all three
                                  # dialect identity builders consume the
                                  # struct), so the pair succeeds or fails
                                  # together — no placeholder material is
                                  # representable. prepare never fails on
                                  # negotiation; the runner unwraps the
                                  # result AFTER Source.resolve, preserving
                                  # today's error precedence (all three
                                  # ordered dialects resolve the source
                                  # first, then negotiate — a bad source
                                  # must keep beating an incapable output
                                  # format)
  response_meta: %Plan.Response{},# delivery presentation; rides the request, never the cache entry
  operations: [atom()],           # semantic names for the [:transform, :execute] span start
  auto_rotate?: boolean(),
  debug?: boolean(),              # already gated by the dialect on its config opt-in
  http_cache: :generated | :dialect_owned,  # U8b: generated cache-header policy participation
  terminal: :image | {:render, %RenderTerminal{}}
}
```

**Staged introduction.** This listing is the END-STATE shape. Fields whose
dispatching code lands in Phase C are introduced in Phase C, not before:
`http_cache` arrives with the promoted header-policy module (U8b), and
`RenderTerminal`'s `cache`/`offers` arrive with the `:none`/`Sender`-rendered
delivery (U11) — Phase A ships `Resolved` without `http_cache` and a
fun-only `RenderTerminal`, so no phase's public type advertises semantics
its runner does not implement. Widening a struct with new fields alongside
their dispatching code is additive; this is an unreleased greenfield
library, so no versioned-contract or migration machinery is warranted.

`%ImagePipe.Dialect.Negotiation{selected, vary?, policy_material, policy,
plan_output}` is the promoted dialect negotiation-outcome struct.
`plan_output` (a `%Plan.Output{}` or nil) is the neutral output plan the
negotiation was built from — carried so the runner can compute
`Policy.supports_hdr?` without reaching into the opaque request (today each
dialect derives it from its own request in `pipeline_opts`). (The struct is
distinct from the existing `ImagePipe.Output.Negotiation`, an Accept-parsing
helper module with no struct; that module is unchanged.)

`%RenderTerminal{}` is the whole non-image-terminal contract, values only:

```elixir
%RenderTerminal{
  fun: (resolved_source, config -> {:ok, content_type, iodata()} | {:error, term()}),
  offers: [{content_type, [accepted_types]}],  # per-request Accept negotiation
                                               # (IIIF ld+json); [] = none
  cache: :complete_body | :none                # imgproxy /info and Native
                                               # blurhash cache complete
                                               # bodies; IIIF info.json is
                                               # uncached today and stays so
}
```

(`offers` and `cache` are Phase C fields — see the staged-introduction note
under `Resolved` above; Phase A's struct is fun-only with the complete-body
delivery implied.)

The runner owns both existing render deliveries, selected by these values:
`cache: :complete_body` runs the shared complete-body lifecycle
(`{:complete_body, ct}` cache hit with wildcard-INM check, generate, fail-open
write) consolidated from the imgproxy-`/info`/Native-blurhash mirrors;
`cache: :none` + `offers` runs `Sender`'s `{:rendered, …}` delivery, which
negotiates the content type against the CURRENT request's `Accept` and stamps
`Vary` — preserving IIIF `info.json`'s ld+json negotiation, its
no-internal-cache behavior, and its wildcard semantics exactly. Presentation
(offers/negotiated type) is never stored; only bytes and the canonical
content type are.

### The anti-leak rule (U4)

Stated in the behaviour's moduledoc and enforced in review: the runner
branches only on `Resolved` fields and neutral core structs. It never names a
dialect and never accepts a dialect-specific option. A future need that cannot
be expressed as a new `Resolved` value with a sensible default belongs in the
dialect, not the runner.

## The runner (`ImagePipe.Plug`)

```
init: dialect = Keyword.fetch!(opts, :dialect)
      dialect.validate_config!(rest of opts)
call:
  Telemetry.Trace.maybe_extract_inbound → CORS.maybe_register → [:request] span
  ├─ OPTIONS → CORS.send_options; non-GET/HEAD → 405
  ├─ [:parse] span → dialect.parse
  │    {:redirect, status, location} → Sender.send_redirect
  ├─ dialect.prepare → %Resolved{}
  ├─ Source.resolve(resolved.source, config, config)     (identity only, no bytes)
  ├─ unwrap resolved.negotiation →                        (a negotiation error
  │    {negotiation, identity_material}                    surfaces HERE — after
  │                                                        source resolve, as in
  │                                                        all three dialects)
  ├─ Representation.build(source.identity, identity_material, byte_identity)
  ├─ http_cache :generated → apply promoted header policy (U8b) — may
  │                          SUPPRESS the ETag (mode :disabled, Set-Cookie,
  │                          Vary: *, host no-store), exactly as
  │                          HTTPCache.prepare does today
  ├─ Conditional.not_modified?(conn, effective_etag) → 304 ← before any fetch,
  │    (:generated → the policy-effective CacheHeaders     decode, encode, or
  │     etag, nil when suppressed → proceed;               cache read
  │     :dialect_owned → representation.etag, identical
  │     to today since no dialect suppresses)
  ├─ serve:
  │    internal_cache :disabled → skip lookup and write, nil cache key
  │    :enabled → Cache.lookup_entry (timed)
  │       hit  → If-None-Match:* → 304, else deliver stored entry
  │              (response_meta from the CURRENT request, never the entry)
  │       miss → generate
  ├─ terminal :image →
  │    Delivery.stream(build_fun, cache_key, response_meta) where build_fun =
  │      Decode.with_image(resolved_source, auto_rotate?,
  │                        dialect.decode_request, fn state, geometry →
  │        produce_stream/…:                    (runs in Delivery.Producer;
  │          [:transform, :execute] span → dialect.execute      the name
  │          → Output.Negotiate.negotiate_output                replaces the
  │          → Clamp.clamp_with_telemetry                       dialects'
  │          → materialize_for_delivery                         build_and_pump)
  │          → [:encode] span, first-chunk pull → hand off to delivery)
  │      (on_bracket_exit test seam preserved; rescue/catch → {:transform, _})
  ├─ terminal {:render, %RenderTerminal{}} →
  │    cache :complete_body → shared complete-body path:
  │      {:complete_body, ct} cache hit (wildcard-INM checked) → send
  │      else fun.(resolved_source, config) → fail-open cache write → send
  │    cache :none → fun.(resolved_source, config) →
  │      Sender {:rendered, ct, body, offers, headers} (per-request Accept
  │      negotiation + Vary; no cache read or write — IIIF info.json today)
  └─ every terminal [:send]-wrapped; errors → dialect.render_error;
     [:request] stop metadata via classify_error / Telemetry.request_result
```

Notes:

- The 304-before-any-side-effect invariant becomes structural: it is the
  runner's spine, written once, instead of a discipline each dialect
  re-implements.
- The promoted header policy (U8b) runs between `Representation.build` and
  the conditional gate — its ETag suppression must be able to veto the 304,
  exactly as `HTTPCache.prepare` feeds `evaluate_conditional` today. It owns
  three of the four `[:http_cache, :*]` events (`prepare`,
  `conditional.match`, `fallback.no_store`); the fourth,
  `[:http_cache, :cache_hit, :headers]`, is emitted by the shared
  `Response.Sender` cache-entry delivery, already fires for every dialect's
  hits today, and stays in `Sender`. `:dialect_owned` skips the policy —
  the ordered dialects' current header and event surface is unchanged.
- The negotiated policy's headers ride delivery failures, as today.
- `pipeline_opts` (`:supports_hdr?` from `Policy.supports_hdr?`) is computed
  by the runner from the unwrapped negotiation's `policy` and `plan_output`
  fields — the struct carries the output plan precisely so the runner never
  reaches into the opaque request; the conservative `false` default is
  preserved where the format is only known post-transform.
- `result_limits`/`min_limit` (host limits clamped against per-format encoder
  limits) move into the runner — one copy.
- The default debug builder runs UNCONDITIONALLY on every generation
  (timings, `Decode`-collected facts, output facts) and the resulting
  `Debug.Info` is stored with the cache entry — matching today's contract
  where facts are collected and stored even while `allow_debug_headers` is
  off, so a later hit can replay them once the flag is enabled (pinned by
  `debug_headers_wire_test.exs`). Only header *rendering* is gated, at
  delivery time.

## The declarative base

```elixir
defmodule ImagePipe.Dialect.IIIF do
  use ImagePipe.Dialect.Declarative

  def parse_plan(conn, config), do: ... # {:ok, %Plan{}} | {:redirect, 303, url} | {:error, r}
  def render_error(conn, reason, config), do: ...
  def validate_config!(opts), do: ...
end
```

`ImagePipe.Dialect.Declarative` implements the behaviour for Plan-producing
dialects:

- `prepare`: `Transform.validate_prefetch_safe_plan`, the
  `detector_required` capability gate, negotiation from `plan.output`,
  Plan-derived identity material, `debug?` from `Plan.Response`, terminal
  selection (`render: :image` vs `render: {:custom, mod, params}` → a
  `{:render, %RenderTerminal{cache: :none, offers: …}}` through
  `ImagePipe.Renderer` — see U11).
- `execute`: the fixed neutral driver (`Transform.execute_plan`).
- `decode_request`: the neutral decode preflight.

This is not a second lifecycle. Same behaviour, same runner, same mount, and
the runner never branches on which base produced the `Resolved`. The
ordered/declarative distinction is a fact about who owns the transform stage —
already established as irreducible by inversion decision T2.

`ImagePipe.Parser` is deleted; its `parse/2` survives as the Declarative contract's `parse_plan/2` (distinct name — the `use` macro implements the behaviour's `parse/2`/`prepare/3` on top of it). `parse_boolean/1` moves to a `Dialect` helper.
IIIF's nested `iiif: [...]` config flattens to the flat key style every other
dialect uses.

## Config and mount

One mount shape:

```elixir
plug ImagePipe.Plug,
  dialect: ImagePipe.Dialect.Imgproxy,
  sources: [...], cache: ..., signature: ..., presets: [...], ...
```

`ImagePipe.Dialect.SharedConfig` keeps its exact role: each dialect's
`validate_config!` splits the flat list on `SharedConfig.keys/0`, delegates
the shared subset, and validates its own keys. One key moves in:
`allow_debug_headers` (today TwicPics-private) becomes shared (U13), since
the debug capability is now runner-owned. `ImagePipe.Request.Options` is
deleted with the framework stack. `ImagePipe.Dialect.*` modules stop
implementing `Plug`.

## Boundary graph

- `ImagePipe.Dialect` (top-level boundary): the behaviour, `Resolved`,
  `Negotiation`, `Declarative`, `DebugContext`, `SharedConfig`, shared
  helpers. Exports exactly those.
- `ImagePipe.Plug` → neutral core (`Cache`, `Config`, `Decode`, `Delivery`,
  `Error`, `Format`, `Output`, `Plan`, `Representation`, `Response`,
  `Source`, `Telemetry`, `Transform`) + `ImagePipe.Dialect`. It never names a
  concrete dialect; dispatch is the config-supplied module atom, the same
  pattern as today's parser dispatch.
- `ImagePipe.Dialect.{Imgproxy, Native, TwicPics, IIIF}` → `ImagePipe.Dialect`
  + neutral core. Never another dialect, never `ImagePipe.Plug`, never
  `ImagePipe.Request` (deleted).
- Architecture tests re-pin these directions. The syntax-aware rule rejecting
  `%Plan{}` construction inside ordered dialects stays; IIIF (declarative) is
  exempt by construction since Plan production is its contract.

## Revisiting T8 and T13

- **T8 preserved in reason, overturned in conclusion.** The reason — a shared
  runner must not encode product ordering as callbacks or conditionals —
  holds and is codified as U4/U5: ordering lives wholly inside `execute`, and
  the runner has no ordering concept. The conclusion ("no generic dialect
  runner") rested on the premise that the dialects share nouns but not one
  observable control flow; the evidence section shows the premise is false at
  the lifecycle altitude, and the Native cache-disable drift shows the
  premise's cost.
- **T13 deliberately reversed** (user decision): the coarse behaviour is a
  public dialect SDK — but a request-lifecycle SDK, not the per-operation
  mid-execution SDK T13 rejected. Nothing from the retired geometry-strategy
  vocabulary returns: no `ImagePipe.Resolver`, no `Plan.resolver`, no
  `Directive`, no `:deferred`, no dialect markers on shared Plan structs.
  `NeutralResolver` remains core-internal; dialects still may not depend on
  `Transform.Lowering` or `Transform.ResizePlanning`.
- **T2/T3 unchanged**: ordered step streams and pipeline-local focus carry
  stay inside each dialect's Pipeline.

## Deletions

- `ImagePipe.Request.{Runner, Processor, HTTPCache, DeliveryBuild, Options,
  RenderRunner, SourceFormat}` and the `ImagePipe.Request` boundary. See the
  replacement map below.
- `ImagePipe.Parser` behaviour, dispatch, and `Parser.IIIF`'s parser shape
  (reborn as `Dialect.IIIF`).
- The lifecycle mirrors in `dialect/{imgproxy,native,twic_pics}.ex` (each
  module shrinks to parse/prepare/decode_request/execute/render_error plus its
  existing submodules).
- The `[:http_cache, :*]` telemetry events do **not** die: three
  (`prepare`, `conditional.match`, `fallback.no_store`) move with the
  promoted header policy (U8b) and keep their names, and
  `[:http_cache, :cache_hit, :headers]` stays where it already is (the
  shared `Response.Sender`, firing for every dialect's cache hits today) —
  so the default Logger's `@http_cache_oneshot` list, `Trace.Capture`'s
  stage lists, and `docs/telemetry.md` need only pointer updates, not
  removals. Under `:dialect_owned` the three policy events simply never
  fire, matching today.
- The whole-file ExDNA ignores for `dialect/imgproxy.ex` and
  `dialect/native.ex` (and pipeline files where the mirror moved into the
  runner) — restoring the visibility issue #457 asked for. Remaining
  definition-level suppressions are re-audited; most disappear. `decode.ex`'s
  file-level ExDNA disable and its "deliberate duplication of Processor"
  annotation are removed — the duplication ends because the Request copy dies.

### Replacement map for `ImagePipe.Request.*`

Almost nothing is written from scratch: the dialect inversion already built
the replacements as *recorded* parallel copies in core (`decode.ex`'s header
comment says so explicitly), and the unification picks the dialect-path copy
as the survivor of each pair.

| Deleted | Replaced by | Nature |
| --- | --- | --- |
| `Processor` (fetch → peek → format gate → header open → pixel limit → shrink-planned sequential open) | `ImagePipe.Decode.with_image/4` — existing core, a recorded line-for-line duplicate of this flow (same reject families, error taxonomy, `[:source, :fetch_decode]` span). NEW: `source_debug_facts` collection (and its `[:debug, :collect, :error]` one-shot) moves here — see the observability audit | pick the surviving twin |
| `Processor` (`process_decoded_source`, `materialize_for_delivery`) | runner build phase (span + materialize backstop, consolidated from the three identical dialect copies) + `Declarative.execute` = `Transform.execute_plan` | consolidation |
| `Runner` (cache dispatch, timed lookup, wildcard-INM on hit, `Delivery.stream`, policy headers on failure) | runner serve phase, built from the dialect chains' shared `serve`/`deliver_hit`/`generate` (the fourth copy) | consolidation |
| `Runner.with_detector_identity/2` | `Declarative.prepare` (Plan-derived detector identity folded into identity material, mirroring imgproxy/TwicPics) | move into the base |
| `Runner` custom-render dispatch + `RenderRunner` | runner `{:render, %RenderTerminal{}}` terminal: the `cache: :complete_body` path consolidates the imgproxy-`/info`/Native-blurhash mirrors; the `cache: :none` path reuses `Sender`'s existing `{:rendered, …}` offers-negotiated delivery (IIIF); `Declarative`'s render fun bridges to `ImagePipe.Renderer`, whose `run` gains RenderRunner's `[:render]` span | consolidation + bridge |
| `HTTPCache` identity mechanics (`etag_material`, `evaluate_conditional`) | existing `Representation.build` + `Response.Conditional` + `CacheHeaders.from_representation`; NEW: the Declarative base's Plan→identity-material derivation (the analogue of each dialect's `Identity.material`) | mechanism swap — the source of accepted delta U8 |
| `HTTPCache` header-generation policy (generated `Cache-Control`, suppression rules, `http_cache:` mode + per-source `:inherit`, the `prepare`/`conditional.match`/`fallback.no_store` events) | promoted to a core policy module applied by the runner under `Resolved.http_cache == :generated`, ordered before the conditional gate (U8b); `[:http_cache, :cache_hit, :headers]` stays in `Response.Sender` where it already fires for all dialects | move, not deletion — IIIF's headers and events preserved; ordered dialects unaffected |
| `DeliveryBuild` (`build_fun`, `resolve_output`, `encode_first_chunk`, `effective_limits`) | the runner's `produce_stream` (the verbatim `build_and_pump` chain the dialects share, renamed — it produces the response stream inside `Delivery.Producer`); `Output.Negotiate.negotiate_output` (existing core); the dialects' `result_limits` (the more complete version — clamps against per-format encoder limits) | consolidation |
| `Options` | existing `SharedConfig.validate_runtime!` + per-dialect `validate_config!`; framework-only keys IIIF keeps (e.g. `allow_debug_headers`) move into `Dialect.IIIF`'s schema | consolidation |
| `SourceFormat` | `Decode.SourceFormat`, its existing twin | pick the surviving twin |

The only genuinely new logic in the whole deletion is the Declarative base's
Plan→`Resolved` derivation (identity material, negotiation from
`plan.output`, detector identity, render bridge, debug-facts plumbing for
IIIF's debug headers): the framework's per-request *decisions* re-expressed
in the contract's vocabulary. All *machinery* is shared or already exists.

## Observable deltas (exhaustive)

Everything not listed here is gated to remain byte-identical per dialect by
the existing wire, differential, and telemetry suites — no fixture, verdict,
or tolerance changes.

1. **Native `internal_cache: :disabled` fix (U9).** A Native mount with a
   source resolving `:disabled` no longer reads or writes the internal cache.
   New wire coverage lands with the fix.
2. **IIIF identity values (U8).** ETag strings and cache keys change with the
   move to `Representation`. Round-trip conditional-GET behavior (304 on
   matching `If-None-Match`, pre-fetch), `Vary` behavior, and storage
   separation are preserved and asserted behaviorally.
3. **IIIF telemetry surface.** The `[:http_cache, :*]` events are preserved
   (they move with the promoted policy, U8b); what changes is the span shape:
   IIIF requests emit the dialect-shaped set (`[:request]`, `[:parse]`,
   `[:transform, :execute]`, `[:encode]`, `[:send]`, `[:output, :negotiate]`,
   the dialect-path cache/decode spans) in place of the framework-only
   `[:cache, :lookup]` span shape. Per the AGENTS.md sync rules, the same
   change updates: the default Logger's subscription lists and any
   `message/3`/`level_for/3` clauses touching changed events;
   `Trace.Capture`'s `@span_stages` / `@oneshot_stages` (cross-checked
   against the Logger's lists); `docs/telemetry.md`; and both surfaces'
   tests.
4. **IIIF mount config.** `parser: ImagePipe.Parser.IIIF, iiif: [...]`
   becomes `dialect: ImagePipe.Dialect.IIIF` with flat keys.
5. **imgproxy debug headers restored (U13, closes #462).** Under
   `allow_debug_headers: true` (now a `SharedConfig` key) and the signed
   `debug:1` option, imgproxy responses regain `X-ImagePipe-*` and
   `Server-Timing` headers, built by the runner's default neutral builder.
   The flag remains identity-excluded. The fiddle's imgproxy mount re-enables
   `allow_debug_headers` and the debug-trigger injection in the same change
   (demo-sync rule), and `docs/debug_headers.md` is updated. Native gains the
   *capability* but has no trigger in its grammar — choosing one (e.g. an
   out-of-band `?debug=1` like IIIF's, or a grammar option) is a
   dialect-surface decision tracked as a follow-up issue, not part of this
   work. IIIF debug headers are reproduced exactly (gated). TwicPics debug
   responses gain the source-fact headers the uniform default builder
   collects (`source-size`, `color-space`, `icc`, bit depth, alpha,
   orientation). Six facts are collected, but a nil fact renders no header
   (`Debug.Headers` rejects nils — e.g. an image without an EXIF
   orientation header adds no `source-orientation`), so the added-header
   count is per-image: the `beach.jpg` fixture gains five. The current
   TwicPics test pins three of these as absent; those pins flip to
   presence assertions as part of the port. Every other TwicPics debug
   header is reproduced exactly.
6. **Negotiation-capability check timing (declarative path only).** The
   framework runs `Policy.ensure_capable` only after a cache miss
   (`Runner.process_prepared_stream`); the unified runner surfaces a
   negotiation error right after source resolution, before any cache access.
   For the ordered dialects this is exactly today's order (they negotiate in
   their pre-cache chain); for IIIF it moves the incapable-output failure
   earlier — same status, but observable to a cache spy. The
   source-vs-negotiation error precedence itself is preserved for all
   dialects by the deferred-negotiation unwrap in `Resolved`.

### Observability audit (framework path vs. unified runner)

A full diff of the framework path's emission surface against the runner's,
so nothing is lost silently. **No loss** — shared or mirrored emitters cover:
`[:source, :resolve]` / `[:source, :fetch]` (Source), `[:source,
:fetch_decode]` (`Decode.with_image` mirrors Processor's span and metadata),
`[:cache, :lookup]` (`Cache.lookup_entry` emits it with the same shapes as
`Request.Runner`'s private copy) plus all cache write/admission events,
`[:transform, :execute]` (runner) / `[:transform, :operation]` (shared
`Chain`) / `[:transform, :materialize]` / input-color-management / detect
events, `[:output, :negotiate]` / `[:output, :clamp]`, `[:encode]` and the
encode-search events, `[:deliver]`, `[:send]`, and `[:http_cache, :*]`
(U8b).

Three items need deliberate handling:

1. **Debug-header source facts.** `Processor.source_debug_facts/3` collects
   six facts (`source_bytes`, `source_color_space`, `source_icc?`,
   `source_bit_depth`, `source_alpha?`, `source_orientation`) that
   `DeliveryBuild` puts on `Debug.Info` → `X-ImagePipe-*` headers.
   `Decode.with_image` collects none of them today, and no ordered dialect
   populates those six fields. Fix: the collection moves into
   `Decode.with_image` (which holds the header image and input at the right
   moment) and feeds the runner's uniform default debug builder (U13):
   IIIF's `?debug=1` headers are preserved field-for-field, and TwicPics
   debug responses gain the source-fact headers (observable delta 5).
2. **The `[:render]` span.** Emitted today by `Request.RenderRunner` only.
   Fix: the span emission moves into the `ImagePipe.Renderer.run` facade, so
   the Declarative render bridge keeps it for IIIF `info.json`; imgproxy
   `/info` and Native blurhash don't use the facade and keep their current
   (span-free) render surface.
3. **`[:debug, :collect, :error]`** (best-effort fact-collection failure
   one-shot) moves to `Decode` with the collection in item 1.

The remaining IIIF-only shape deltas under delta 3, enumerated precisely:
the `[:request]` and `[:parse]` span start metadata lose the framework's
`parser:`/`request_method` keys (the dialect shape is `%{}`), and the parse
error stop metadata becomes *richer* — the framework's `wrap_parser_error`
double-wrap reduces every parse failure's `error:` tag to the constant
`:error`, a quirk the dialect chains deliberately did not copy.

## Testing

- **Gates per phase**: `mise run precommit` plus the per-dialect wire,
  differential (imgproxy + TwicPics), and telemetry suites. Ported dialects
  must pass their existing suites unchanged (deltas above excepted).
- **Runner unit tests** replace `Request.Runner`/`Processor` tests where the
  behavior survives (conditional gate ordering, cache hit/miss/disabled,
  wildcard INM only on hit, render-terminal cache path, error fan-out).
  Post-migration parity pins are deleted per the test guidelines.
- **Architecture tests**: new boundary pins (Plug → Dialect; dialects never
  each other/Plug/Request), retained no-`%Plan{}`-in-ordered-dialects rule.
- **New coverage**: Native disabled-cache wire test (U9); a Declarative-base
  wire test proving a minimal host `use ImagePipe.Dialect.Declarative` module
  mounts and serves (the public-contract smoke test); imgproxy debug-header
  wire coverage mirroring `debug_headers_wire_test.exs`'s contract on the
  dialect surface, including the identity-exclusion assertion (debug vs plain
  request share one cache entry and ETag) — the #462 acceptance test.

## Phasing (implementation plan will detail)

- **Phase A**: promote the contract pieces (`Dialect` behaviour, `Resolved`,
  `Negotiation`, `DebugContext`), build the runner in `ImagePipe.Plug` from
  the dialect chain shape, and port **Native** first (smallest; carries the
  U9 fix). The framework parser path coexists untouched during A–B.
- **Phase B**: port imgproxy (endpoint split, `/info` render terminal,
  ResponseMeta; debug headers return via the runner default builder, closing
  #462 — fiddle mount and `docs/debug_headers.md` updated in the same change)
  and TwicPics (ports onto the runner's default debug builder; its debug wire
  tests gate exact reproduction apart from the delta-5 source-fact
  additions, whose absence pins flip to presence assertions).
- **Phase C**: `Declarative` base, `Dialect.IIIF`, delete
  `ImagePipe.Request.*` and `ImagePipe.Parser`, telemetry surface sync
  (Logger + Capture + docs), docs rewrite.

Docs rewritten in C: `execution_flow.md` (one spine), `custom_parser_guide.md`
→ custom **dialect** guide (declarative and ordered tiers; the "no public
SDK" section deleted), `cdn-http-cache.md` and `debug_headers.md` mount
examples, `telemetry.md`, AGENTS.md boundary-direction lines and the
namespace guidelines that name `ImagePipe.Parser.*`/`ImagePipe.Request.*`.

## Risks and controls

- **Runner accretes conditionals over time.** Control: U4 is a named review
  rule; new runner branches must cite the `Resolved` field or neutral struct
  they dispatch on.
- **Span-boundary drift breaks telemetry gates.** Control: the parse/prepare
  split exists precisely to keep today's `[:parse]` span coverage; telemetry
  suites gate each ported dialect.
- **IIIF migration silently changes behavior beyond U8/deltas.** Control:
  IIIF wire + CDN-cache wire suites run against the dialect form before the
  framework stack is deleted; only enumerated deltas may differ.
- **The public behaviour is mistaken for a stability promise on internals.**
  Control: the custom dialect guide states the contract is the behaviour +
  `Resolved`; core internals behind the runner remain private.
- **Recreating the geometry SDK by drift.** Control: the contract has no
  per-operation hooks; any proposal to add one fails U3/U5 by construction
  and must instead follow the marker-accretion rule in AGENTS.md.

## Per-phase addenda (deltas and contract widenings beyond the original lists)

Implementation-time deltas and typed-contract widenings discovered while
porting each phase, recorded here so Phase C's Declarative base is built
against an accurate contract listing rather than the pre-implementation
lists above (U12).

### Phase A (`docs/superpowers/plans/2026-07-19-dialect-unification-phase-a.md`)

Three deltas the Phase A plan enumerates on its own:

- **(a) Native `internal_cache: :disabled` fix** (Task 9). Restates
  exhaustive delta 1 above (U9); cited here because Phase A's plan
  enumerates it independently of this design doc.
- **(b) Cache entries for Native now store a `Debug.Info` unconditionally**
  (Task 6), ahead of any dialect implementing a debug trigger — mandated by
  U13's build-and-store discipline. Internal only: Native has no debug
  grammar trigger, so the stored entry is never rendered (see observable
  delta 5's Native debug-trigger follow-up above).
- **(c) `[:debug, :collect, :error]` and the per-request source-fact
  collection become reachable on the imgproxy/TwicPics decode paths**
  through the shared `Decode` module (Task 2), which now owns the
  collection `Request.Processor` used to own privately. The default Logger
  and `Trace.Capture` already subscribe to the event name and no suite
  gates it — the delta is the code path becoming reachable, not a new event
  name.

### Phase B (`docs/superpowers/plans/2026-07-20-dialect-unification-phase-b.md`)

Five deltas from the plan's own "Enumerated observable deltas" list with no
counterpart in this design's original list:

- **Delta 3 — delivery-error policy headers become runner-owned** (Task 1).
  The runner stamps `negotiation.policy.headers` onto the conn before
  `render_error` on `Delivery.stream` failures only, mirroring the dialect
  chains exactly. Native gains `Vary: Accept` on an image-terminal delivery
  failure under automatic output — behavior it never had; imgproxy/TwicPics
  are byte-identical to their current `Errors.send/4` headers.
- **Delta 4 — the `[:request]` stop result honors the mid-stream send
  override for every dialect** (Task 6 Step 1). Promoted from TwicPics'
  `request_stop_metadata/2`: when `Response.Sender` stamps
  `:image_pipe_send_result` on a committed 200 whose stream then fails, the
  request span's stop `result` becomes `:processing_error` instead of
  `:ok`. TwicPics is unchanged (already pinned by its `:streamed_error`
  scenario); Native/imgproxy pick up the override telemetry-only. Task 10
  gates this for imgproxy with a `[:request]` stop assertion in the
  existing "streamed error after preparation" scenario
  (`test/image_pipe/imgproxy_telemetry_contract_test.exs`), mirroring
  TwicPics' pin instead of resting on an absence claim.
- **Delta 6 — imgproxy's `[:parse]` span brackets the endpoint split**
  (Task 3). `Path.split_endpoint` moves inside the runner's span.
  Timing-only; span metadata shapes unchanged.
- **Delta 8 — imgproxy's returned conn path for `/info`** (Task 4). Parsing
  still verifies the signature over the prefix-stripped path, but the
  shared runner returns the original conn, so `conn.request_path` retains
  `/info/...` instead of the legacy stripped path. HTTP status, headers,
  and body remain unchanged.
- **Delta 10 — post-transform crashes render 500-class for every dialect,
  and the transform-execute span's exception boundary converges** (Task 6
  Step 2 rationale; Task 7 Step 3 pin). Each dialect now rescues its own
  `execute/4` pipeline run rather than relying on the runner's broad
  `produce_stream` rescue; transform crashes stay 422 everywhere
  (unchanged), but an unexpected exception in a shared post-transform stage
  (clamp / materialize / encode-first-chunk) shifts imgproxy/Native from
  422 to 500-class — TwicPics, which already rescued only its own pipeline,
  is unchanged. A further consequence found during implementation
  (recorded by Task 10): because each dialect's transform rescue now lives
  *inside* `execute/4`, the `[:transform, :execute]` span always closes
  with a normal `:stop` carrying `%{result: :processing_error, …}` for
  Native and imgproxy, where previously a pipeline raise escaped the span
  and produced an `:exception` event instead. This converges all three
  dialects onto TwicPics' long-standing span behavior. The wire status is
  unchanged (still 422 for transform crashes), but telemetry handlers —
  including the default Logger and the OTel trace capture — observe a
  different event shape, so it is a real, previously unenumerated delta.

### Typed-listing widenings (`Resolved`, `RenderTerminal`)

This design's typed listings for `%Resolved{}` and `%RenderTerminal{}`
(above, "The contract") predate three Phase B additions. None changes
U4/U5/U6 — each widens an already-declared field or adds a value type
carried unchanged through the existing dispatch surface, not new dispatch
surface itself:

- **`Resolved.negotiation` accepts a zero-arity thunk**
  (`(-> negotiation_result())`), not only the literal result tuple (Task
  1). The runner invokes the thunk only after
  `ImagePipe.Source.resolve/3` succeeds, letting a dialect defer
  negotiation until runtime geometry is known. imgproxy (Task 3) and
  TwicPics (Task 6) both use the thunk form; Native still supplies the
  tuple directly.
- **`RenderTerminal` gains `charset: :default | nil`** (Task 3), defaulting
  to `nil` so Native stays byte-identical. imgproxy's `/info` sets
  `charset: :default` to preserve `application/json; charset=utf-8`.
- **A new `ImagePipe.Dialect.Failure` struct**
  (`%Failure{phase: :parse, reason: term()}`, Task 6) wraps a lifecycle
  failure with the phase that produced it, for a dialect whose error
  rendering or telemetry classification depends on provenance rather than
  reason alone. The runner passes it unchanged to `classify_error/1` and
  `render_error/3`, unwrapping only for the telemetry error tag. TwicPics
  is the only current producer (its parse failures). `phase` is typed
  `:parse` — the only value any producer constructs or any clause matches
  today (`lib/image_pipe/dialect/failure.ex`); widen it if and when a
  second phase's provenance genuinely needs to ride the wrapper.

### U4 wording widening

The Phase B plan's Global Constraints record a widening of U4's literal
wording, which names only `Resolved` fields and neutral core structs: the
runner may also branch on shared conn-private state stamped by neutral
core, specifically `:image_pipe_send_result` (stamped by the shared
`Response.Sender`, read by `ImagePipe.Plug.DialectRunner` at the
`[:request]` and `[:send]` stop-metadata sites). This is neutral in
substance — no dialect stamps or reads it — so it does not reopen U4's
anti-leak rule; it is recorded here because the rule's original wording did
not anticipate a conn-private channel.

### The `debug_info/1` hook (U13 contingency resolved)

U13 proposed `c:ImagePipe.Dialect.debug_info/1` as an optional enrichment
override, explicitly contingent: "dropped from the contract if the ports
confirm nobody needs it." Phase B ports the last two ordered dialects
(imgproxy, TwicPics); combined with the already-ported Native and the test
fixture dialect (`test/support/image_pipe/test/runner_fixture_dialect.ex`),
every dialect implementation in the tree has now been checked, and none
implements it. Per U13's own contingency, Task 10 deletes the callback from
`ImagePipe.Dialect` and the `function_exported?(dialect, :debug_info, 1)`
probe from `ImagePipe.Plug.DebugBuilder.build/2`, which now calls the
default builder directly (`build/1`, dropping the now-unused `dialect`
argument). This removes a runtime callback-presence probe for trusted
internal dispatch, in line with AGENTS.md's "call the callback directly and
let missing callbacks raise" rule for impossible internal misuse. The
sibling probe in the runner's error classification
(`function_exported?(dialect, :classify_error, 1)`) is deliberately NOT
touched: `classify_error/1` has real optionality — a host dialect (or the
test fixture dialect) may legitimately omit it and fall back to
`ImagePipe.Telemetry.request_result/1` — so its probe stays a load-bearing
optionality check, not a workaround for impossible misuse.
