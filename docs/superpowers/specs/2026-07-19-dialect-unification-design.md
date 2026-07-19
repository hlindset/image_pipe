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
| U3 | The behaviour has six required callbacks (`validate_config!`, `parse`, `prepare`, `decode_request`, `execute`, `render_error`) and two optional hooks; everything else rides `%Dialect.Resolved{}` as values. | Coarse phases, not mid-execution hooks. Values-not-callbacks is what keeps the contract from regrowing the leaky framework T8 warned about. |
| U4 | The runner may branch only on `Resolved` fields and neutral core structs — never on dialect identity, never via dialect-specific flags. | The "pile of conditionals" failure mode arrives incrementally; this is the review-enforceable line against it. |
| U5 | Product ordering stays wholly inside the dialect's `execute` (its Pipeline); the runner has no ordering concept. | Preserves T8's *reason* while overturning its conclusion. |
| U6 | The behaviour is public and documented: declarative tier (`use ImagePipe.Dialect.Declarative`, implement `parse/2 -> %Plan{}`) and ordered tier (implement the full behaviour). | Deliberate T13 reversal (user decision). This is a request-lifecycle SDK, not the rejected per-operation mid-execution SDK: no `Resolver`, no `Directive`, no `:deferred`, no Plan markers; `NeutralResolver` stays core-internal. |
| U7 | IIIF is re-expressed as `ImagePipe.Dialect.IIIF` on the declarative base; `ImagePipe.Parser` (behaviour and dispatch) is deleted. | One user; its three callbacks survive as the Declarative contract. |
| U8 | The runner unifies conditional-GET on the `Representation` + `Response.Conditional` mechanism; `Request.HTTPCache` is deleted. IIIF's ETag and cache-key values change. | One identity mechanism; the dialect one is stricter (pre-fetch 304 structurally). Greenfield: behavior-level round-trip is the contract, literal values are not (user decision). |
| U9 | Native gains the `internal_cache: :disabled` handling it is missing, with new wire coverage. | Deliberate bug fix surfaced by this analysis, not silent drift. |
| U10 | The framework stack — `ImagePipe.Request.{Runner, Processor, HTTPCache, DeliveryBuild, Options}` — is deleted after IIIF migrates. | Zero users remain; keeping it would preserve the second model this design exists to remove. |
| U11 | `ImagePipe.Renderer` survives as the declarative base's non-image-terminal contract (`render: {:custom, mod, params}` becomes a `{:render, fun}` terminal). | IIIF `info.json` needs it; ordered dialects never see it. |
| U12 | Per-dialect wire, differential, and telemetry suites gate every phase; no fixture, verdict, or tolerance changes. Deliberate deltas are exactly U8 and U9, plus IIIF's telemetry event set (below). | The inversion's own evidence discipline, reused. |

## The contract

```elixir
defmodule ImagePipe.Dialect do
  @callback validate_config!(keyword()) :: keyword()
  # Init-time. Splits on SharedConfig.keys/0, delegates the shared subset to
  # SharedConfig.validate_runtime!/1, validates its own keys, raises on error.

  @callback parse(Plug.Conn.t(), config :: keyword()) ::
              {:ok, request :: term(), parse_meta :: map()}
              | {:redirect, pos_integer(), String.t()}
              | {:error, term()}
  # Wrapped in the [:parse] span by the runner; covers exactly what each
  # dialect's parse span covers today (imgproxy extract→verify→split→parse;
  # Native verify→lex→parse, parse_meta carries :sig_key_index; TwicPics
  # Path→Manipulation→RequestBuilder; IIIF classify→resolve-id→grammar).
  # The request term is opaque to the runner.

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

  @callback debug_info(ImagePipe.Dialect.DebugContext.t()) ::
              ImagePipe.Debug.Info.t() | nil
  # Optional, default nil. TwicPics is the only implementor. DebugContext
  # carries geometry, decode shrink, negotiation, resolved output, the final
  # image, encoder search metadata, and stage timings the runner measures.
end
```

### `%ImagePipe.Dialect.Resolved{}`

Values, not callbacks — this is what keeps the behaviour at six required
callbacks:

```elixir
%Resolved{
  request: term(),                # opaque; threaded to decode_request/execute
  source: source_ref,             # a Plan source reference; runner calls Source.resolve
  negotiation: %Dialect.Negotiation{},  # promoted from the three identical copies
  identity_material: material,    # dialect-ordered identity material
  response_meta: %Plan.Response{},# delivery presentation; rides the request, never the cache entry
  operations: [atom()],           # semantic names for the [:transform, :execute] span start
  auto_rotate?: boolean(),
  debug?: boolean(),              # already gated by the dialect on its config opt-in
  terminal: :image | {:render, render_fun}
}
```

`%ImagePipe.Dialect.Negotiation{selected, vary?, policy_material, policy}` is
the promoted dialect negotiation-outcome struct. (It is distinct from the
existing `ImagePipe.Output.Negotiation`, an Accept-parsing helper module with
no struct; that module is unchanged.)

`render_fun.(resolved_source, config) -> {:ok, content_type, iodata()} |
{:error, reason}` is the whole non-image-terminal contract. imgproxy `/info`
(header decode + `InfoRenderer`), Native blurhash (inline pipeline +
`Blurhash.compute`), and IIIF `info.json` (via `ImagePipe.Renderer`) all fit
as closures; the runner owns the shared complete-body lifecycle around them.

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
  ├─ Representation.build(source.identity, identity_material, byte_identity)
  ├─ Conditional.not_modified?(conn, etag) → 304          ← before any fetch,
  │                                                          decode, encode, or
  │                                                          cache read
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
  │        [:transform, :execute] span → dialect.execute
  │        → Output.Negotiate.negotiate_output → Clamp.clamp_with_telemetry
  │        → materialize_for_delivery
  │        → [:encode] span, first-chunk pull → pump)
  │      (on_bracket_exit test seam preserved; rescue/catch → {:transform, _})
  ├─ terminal {:render, fun} → shared complete-body path:
  │    {:complete_body, ct} cache hit (wildcard-INM checked) → send
  │    else fun.(resolved_source, config) → fail-open cache write → send
  └─ every terminal [:send]-wrapped; errors → dialect.render_error;
     [:request] stop metadata via classify_error / Telemetry.request_result
```

Notes:

- The 304-before-any-side-effect invariant becomes structural: it is the
  runner's spine, written once, instead of a discipline each dialect
  re-implements.
- The negotiated policy's headers ride delivery failures, as today.
- `pipeline_opts` (`:supports_hdr?` from `Policy.supports_hdr?`) is computed
  by the runner from `resolved.negotiation.policy` and the plan output the
  negotiation was built from; the conservative `false` default is preserved
  where the format is only known post-transform.
- `result_limits`/`min_limit` (host limits clamped against per-format encoder
  limits) move into the runner — one copy.
- Timing capture for `debug_info` (decode/transform/encode microseconds) is
  measured by the runner only when the dialect implements the hook, and handed
  over via `DebugContext`.

## The declarative base

```elixir
defmodule ImagePipe.Dialect.IIIF do
  use ImagePipe.Dialect.Declarative

  def parse(conn, config), do: ...      # {:ok, %Plan{}} | {:redirect, 303, url} | {:error, r}
  def render_error(conn, reason, config), do: ...
  def validate_config!(opts), do: ...
end
```

`ImagePipe.Dialect.Declarative` implements the behaviour for Plan-producing
dialects:

- `prepare`: `Transform.validate_prefetch_safe_plan`, the
  `detector_required` capability gate, negotiation from `plan.output`,
  Plan-derived identity material, `debug?` from `Plan.Response`, terminal
  selection (`render: :image` vs `render: {:custom, mod, params}` →
  `{:render, fun}` through `ImagePipe.Renderer`).
- `execute`: the fixed neutral driver (`Transform.execute_plan`).
- `decode_request`: the neutral decode preflight.

This is not a second lifecycle. Same behaviour, same runner, same mount, and
the runner never branches on which base produced the `Resolved`. The
ordered/declarative distinction is a fact about who owns the transform stage —
already established as irreducible by inversion decision T2.

`ImagePipe.Parser` is deleted. `parse_boolean/1` moves to a `Dialect` helper.
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
the shared subset, and validates its own keys. `ImagePipe.Request.Options`
is deleted with the framework stack. `ImagePipe.Dialect.*` modules stop
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
- The `[:http_cache, :prepare]` and `[:http_cache, :conditional, :match]`
  telemetry events (die with HTTPCache).
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
| `Processor` (fetch → peek → format gate → header open → pixel limit → shrink-planned sequential open) | `ImagePipe.Decode.with_image/4` — existing core, a recorded line-for-line duplicate of this flow (same reject families, error taxonomy, `[:source, :fetch_decode]` span) | pick the surviving twin |
| `Processor` (`process_decoded_source`, `materialize_for_delivery`) | runner build phase (span + materialize backstop, consolidated from the three identical dialect copies) + `Declarative.execute` = `Transform.execute_plan` | consolidation |
| `Runner` (cache dispatch, timed lookup, wildcard-INM on hit, `Delivery.stream`, policy headers on failure) | runner serve phase, built from the dialect chains' shared `serve`/`deliver_hit`/`generate` (the fourth copy) | consolidation |
| `Runner.with_detector_identity/2` | `Declarative.prepare` (Plan-derived detector identity folded into identity material, mirroring imgproxy/TwicPics) | move into the base |
| `Runner` custom-render dispatch + `RenderRunner` | runner `{:render, fun}` terminal (consolidated from the imgproxy `/info` / Native blurhash mirrors); `Declarative`'s render_fun bridges to `ImagePipe.Renderer` | consolidation + bridge |
| `HTTPCache` (`prepare`, `etag_material`, `evaluate_conditional`) | existing `Representation.build` + `Response.Conditional` + `CacheHeaders.from_representation`; NEW: the Declarative base's Plan→identity-material derivation (the analogue of each dialect's `Identity.material`) | mechanism swap — the source of accepted deltas U8 and the `[:http_cache, :*]` event removal |
| `DeliveryBuild` (`build_fun`, `resolve_output`, `encode_first_chunk`, `effective_limits`) | runner `build_fun` — the verbatim `build_and_pump` the dialects share; `Output.Negotiate.negotiate_output` (existing core); the dialects' `result_limits` (the more complete version — clamps against per-format encoder limits) | consolidation |
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
3. **IIIF telemetry surface.** The `[:http_cache, :*]` events disappear;
   IIIF requests emit the dialect-shaped span set (`[:request]`, `[:parse]`,
   `[:transform, :execute]`, `[:encode]`, `[:send]`, `[:output, :negotiate]`,
   cache one-shots). Per the AGENTS.md sync rules, the same change updates:
   the default Logger's subscription lists and any `message/3`/`level_for/3`
   clauses touching removed events; `Trace.Capture`'s `@span_stages` /
   `@oneshot_stages` (cross-checked against the Logger's lists);
   `docs/telemetry.md`; and both surfaces' tests.
4. **IIIF mount config.** `parser: ImagePipe.Parser.IIIF, iiif: [...]`
   becomes `dialect: ImagePipe.Dialect.IIIF` with flat keys.

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
  mounts and serves (the public-contract smoke test).

## Phasing (implementation plan will detail)

- **Phase A**: promote the contract pieces (`Dialect` behaviour, `Resolved`,
  `Negotiation`, `DebugContext`), build the runner in `ImagePipe.Plug` from
  the dialect chain shape, and port **Native** first (smallest; carries the
  U9 fix). The framework parser path coexists untouched during A–B.
- **Phase B**: port imgproxy (endpoint split, `/info` render terminal,
  ResponseMeta) and TwicPics (debug_info hook, delivery debug flag).
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
