# imgproxy dialect inversion — design

**Status:** approved direction, pre-implementation
**Date:** 2026-07-15
**Relations:** implements the migration deferred by
`2026-07-13-dialect-owned-pipelines-design.md` (§Non-goals: "Migrating
imgproxy… onto the pattern"); consumes
`2026-07-dialect-owned-pipelines-probe-report.md` (the probe's core-exports
list, gaps G1/G4/G6, §6d's extraction recommendation); executes both
extractions proposed in `2026-07-dialect-shared-extractions.md`.

## Motivation

The probe built `ImagePipe.Dialect.Native` and measured the inverted pattern:
dynamic-dispatch seams 5 → ~1, three orchestrators → one readable module. But
native is the toolkit's *easiest* consumer. It validated dialect-owned
orchestration over a retained neutral geometry compiler; it did not validate
the pattern against a dialect that carries resolver state, owns a second
endpoint, needs input color management, or has a pixel- and wire-parity
obligation to a real upstream product.

imgproxy is the right second dialect for one reason above all: **it already has
a regression net that compares against real imgproxy output.** ~163 differential
fixtures pixel-compare against a pinned `darthsim/imgproxy` bake, and 149
wire-conformance tests assert status/headers/pixels through real `call/2`
requests. Both are black-box and stack-agnostic. Inverting the internals
underneath them turns them into a pixel- and wire-parity proof that the
inversion preserved behavior — evidence no amount of internal review can
supply. A cross-arm raw-body-hash assertion (see Testing) adds encoded-byte
equality between the two stacks on top of that.

Three things imgproxy forces that native never exercised:

1. **A carried resolver strategy.** imgproxy's `Resolver` computes
   `effective_padding_scale` at the resize and consumes it at padding/canvas,
   ferried across the neutral seam by a `Padding{pixel_ratio: {:effective,
   fallback, mode}}` marker plus `ImagePipe.Resolver.rewrap/2`. Native calls
   `NeutralResolver` statelessly with `nil` carry. This is the exact vocabulary
   AGENTS.md's marker-accretion rule was written to bound, and the inversion's
   central claim — that dialect-local ordinary code replaces the strategy
   framework — is untested until a real carry runs through it.
2. **Input color management.** imgproxy's conformance requires stage 4
   `colorspaceToProcessing`. This is the probe's open gap **G4**. Native could
   live with it (correct for sRGB, diverging only for ICC/wide-gamut); imgproxy
   cannot — five differential fixtures source Display-P3 and CMYK images.
3. **A second endpoint.** `/info/` is a protocol rendering, today an
   `ImagePipe.Renderer` implementation. The design says renderer *dispatch*
   dies while protocol renderings stay dialect-owned; imgproxy is where that
   gets demonstrated.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Phase 1 copies the grammar; phase 2 retires `Parser.Imgproxy`.** | The ~3,100 lines of grammar are framework-free and could *move*, but only if the old parser dies. Copying keeps an always-green, reversible intermediate; phase 2 deletes the original and retires the copy. Duplication is real but transient and ExDNA-ignored, exactly as the probe did for its six files. |
| D2 | **The regression net dual-runs both stacks in phase 1.** | Parameterize the harness over `[Parser.Imgproxy, Dialect.Imgproxy]`. Proves dialect ≡ framework ≡ real imgproxy simultaneously, and keeps the still-shipping framework parser covered while D3 migrates `Request.SourceSession` underneath it. Phase 2 drops the framework arm for free. |
| D3 | **Extraction A targets full unification, subject to a topology audit gate.** | The stated payoff and the probe's §6d headline finding. Reads "byte-frozen" as observable-output-frozen, not no-refactor. But unification means deleting a `DynamicSupervisor` child from `application.ex` — a process-topology change, not an internals swap. Gated; see below. |
| D4 | **Spec both phases; implement phase 1 now.** | Phase 1 is already ~25–30 TDD tasks. Designing the end state gives the duplication a dated exit without a 50-task branch. |
| D5 | **Carry handled as a local; the `{:effective, …}` marker dies.** | See below — the marker is provably pure redundancy once the dialect owns both emit and run. |

### D3 in detail — the topology audit gate

**The conflict.** The framework starts sessions through
`ImagePipe.Request.SourceSessionSupervisor` (`use DynamicSupervisor`, a child
of `application.ex`). The probe's primitive uses `GenServer.start/2` —
deliberately not `start_link/2` — and is monitor-based, with the extraction
note's invariant #5 stating "No supervisor / no `application.ex` child". Full
unification therefore removes a supervised child from the application tree and
changes the framework's process topology. This is larger than the force-kill
timing delta originally identified.

**The gate.** `Request.SourceSession` migrates to `ImagePipe.Delivery` **only
if** a pre-implementation audit confirms `SourceSessionSupervisor` provides no
supported host extension point, required admission control, meaningful restart
recovery, or shutdown guarantee the monitor-owned primitive cannot preserve. If
any such dependency is found, phase 1 limits Extraction A to `Dialect.Native`
and `Dialect.Imgproxy`, the framework stays unchanged, and the exact blocker is
recorded. **The core primitive will not gain a supervised mode solely to
accommodate the retiring framework** — that would make process topology part of
a new primitive's API to preserve machinery scheduled for deletion.

Note the rationale deliberately does *not* rest on "the framework is going away
anyway". Retirement schedules slip, and that argument would license an
undocumented breaking change. The actual argument: if the supervisor carries no
behavioural contract, removing it is a simplification — and this phase has the
best comparative test setup we will ever have for proving it.

**Audit findings (already established; recorded here, re-verified by the audit
task before any code moves):**

| Question | Finding | Verdict |
|---|---|---|
| Restart recovery | `source_session.ex:55` → `restart: :temporary`; `source_session_supervisor_test.exs:215` pins "temporary sessions are not restarted after a crash before prepare" | **Pass** — supervision supplies no restart recovery |
| Admission / concurrency | `DynamicSupervisor.init(strategy: :one_for_one)` — no `max_children`, no start-failure policy | **Pass** — no admission contract |
| Host-visible surface | No public API docs; `docs/telemetry.md:860` mentions the `SourceSession → Producer` seam explanatorily; module lives in `ImagePipe.Request.*`, the boundary the design dissolves | **Pass**, doc-sync item only |
| Ownership / failure propagation | Covered by the probe's 9-row error matrix for the monitor topology | **Pass** |
| Cancellation latency | force-kill → graceful halt + ~1s backstop (G6) | **Pass**, already scoped |
| **Application shutdown** | `source_session_supervisor_test.exs:134` pins "supervisor shutdown is parent shutdown, not request owner death" | **OPEN — the one real item** |

**The open item.** The supervisor's only established guarantee is
shutdown-by-parent, distinct from owner death. Under the monitor topology
nothing links the coordinator to the application tree; during shutdown it dies
because its owner dies — plausibly the same outcome by a different mechanism,
but that must be **proven by a test, not inferred**. If it cannot be, the gate
degrades Extraction A to dialects-only.

**Sequencing (strict).** This is characterization-then-preserve, not red-green:
the guarantee already exists, so a test written after the migration could be
unconsciously shaped to whatever the new topology happens to do.

1. **Baseline first, against the untouched framework.** Write the
   application-shutdown termination test and the OTel parent-hierarchy test and
   get them **green on the current supervised topology**. This pins the
   guarantee as it exists today, before anything moves.
2. **Then migrate.** Remove `SourceSessionSupervisor`; move
   `Request.SourceSession` onto `ImagePipe.Delivery`.
3. **The same unmodified tests must still pass.** If they cannot be made to
   pass without weakening the assertion, the gate has failed: revert to the
   dialects-only branch and record the exact guarantee that blocked it.
   **Editing the baseline test to fit the new topology is the failure mode this
   ordering exists to prevent** — a changed assertion is a gate failure, not a
   passing gate.

**Consequent work if the gate passes (phase 1, part of Extraction A — not
deferred to phase 2):** delete the `SourceSessionSupervisor` module and its
`application.ex` child entry; port `source_session_supervisor_test.exs` (421
lines) to the primitive's equivalents; update `request_runner_test` and
`architecture_boundary_test`, which both reference the supervisor; update
`docs/telemetry.md:860`'s process-seam description.

**Telemetry risk (dual-run does not cover this).**
`docs/superpowers/plans/2026-06-10-otel-replay-parent-hierarchy.md` shows OTel
span parentage is replayed across process boundaries. Changing the framework's
delivery topology can shift span hierarchy, which a pixel-comparison net cannot
detect. The telemetry contract test below must therefore cover the **framework
arm after migration**, not only the dialect.

### D5 in detail — why the marker can die

Two facts, verified in the code, make this mechanical rather than aspirational:

1. **`Lowering.padding_executables/2` never reads `pixel_ratio`.** Its signature
   is `padding_executables(%PlanPadding{} = operation, scale) when
   is_number(scale)`; it reads only `top`/`right`/`bottom`/`left`/`fill`. The
   scale arrives as an argument. `canvas_executables/2` is the same shape.
2. **The mode is chosen at emit time from pure request data.**
   `plan_builder.ex:677-686`:

   ```elixir
   mode =
     if extend_operation_requested?(request) or extend_aspect_ratio_emits?(request),
       do: :canvas_preserving, else: :resize
   ```

   No runtime geometry is consulted. Only the *value* is deferred; the *mode* is
   parse-time-decidable, and the fallback is the request's own `dpr`.

So the marker exists for exactly one reason: to ferry mode + fallback from
`plan_builder` to `resolver` **across the neutral seam**. Remove the seam and it
evaporates. The dialect computes the mode locally at emit time, emits padding
through the plain 4-arity `Operation.padding/4` constructor (the one native
already uses), and passes the right carry slot to `Lowering` at run time. The
marker is never constructed.

**Finding for AGENTS.md (record, don't act on yet).** The marker-accretion rule
cites this marker as its worked example of a legitimate marker, justified by (a)
runtime-geometry-dependent, (b) per-operation/positional, (c) no product-neutral
specification. Criterion **(b) does not actually hold**: the mode depends on
request config (`extend_operation_requested?`), not on where the op sits in the
pipeline. The rule itself stays valid — TwicPics still carries a strategy — but
its illustration dies in phase 2 and must be replaced then, not now (the frozen
framework still uses it in phase 1).

## Architecture

`ImagePipe.Dialect.Imgproxy` — a self-contained Plug, `use Boundary, top_level?:
true`, deps mirroring native's (`Cache, Decode, Error, Format, Output, Plan,
Representation, Response, Source, Telemetry, Transform`) plus `ImagePipe.Config`
(the neutral output tunables native has no equivalent for) and the new
`ImagePipe.Delivery` and `ImagePipe.Dialect.SharedConfig`. It names no
`Parser.*`, `Request.*`, `Resolver`, or `Renderer`.

**Acid test:** core names no dialect; dialects name no dialect. Enforced by
Boundary plus an architecture-test entry following `Dialect.Native`'s.

### Module map

The existing ~4,900 lines sort into three piles:

| Pile | Modules | ~Lines | Phase 1 treatment |
|---|---|---|---|
| **Copy near-verbatim** | `option_grammar` (1569), `options` (574), `path` (287), `source` (259), `signature` (197), `source_encryption` (156), `presets` (97), `pipeline_request` (99), `parsed_request` (88), `percent_encoding` (45), `crop_request` (29), `effects` (27), `format` (22), `orientation` (13), `source_scheme` (8) | ~3,470 | Copy to `Dialect.Imgproxy.*`. One real edit: `ImagePipe.Parser.parse_boolean/1` → a local helper. References to `Plan.Color` / `Plan.Output.*Options` / `Plan.Response` / `Plan.Source.*` stay — those are the shared value types the Seam map keeps. |
| **Rewrite** | `plan_builder` (864), `resolver` (175) | ~1,040 | Become `Dialect.Imgproxy.Pipeline`: inline geometry with a local carry. The geometry **math** is copied verbatim; only the plumbing changes. |
| **New / mirrored** | the `imgproxy.ex` chain, `Config`, `Identity`, `Negotiation`, `Errors`, `InfoRenderer` | ~700 | Mirror native's equivalents. `info_renderer` (54) drops `@behaviour ImagePipe.Renderer`. |

`ParsedRequest` → `Dialect.Imgproxy.Request`, the canonical pre-fetch value. It
already satisfies the canonical-request contract (pure data, no PIDs/functions/
conn state), so this is largely a re-home.

Two structural notes:

- **`SourceScheme` is a host-facing behaviour** whose callback returns
  `ImagePipe.Plan.Source.t()`. Hosts implement it, so it is a public extension
  point and stays exported from the dialect boundary. Native has no equivalent.
- **The `-` pipeline separator is an ImagePipe extension, not upstream
  imgproxy** (documented in `docs/imgproxy_path_api.md`). It maps directly onto
  native's `then` groups, so the group-threading machinery transfers unchanged.

## The visible chain

`call/2` → `route/2`, one linear `with`, mirroring native's with an endpoint
branch native lacks:

```
route → Path.split_endpoint                  → {:info | :image}
      → Path.extract + Signature.verify      (403 before any parse)
      → Path.split_source → Options.parse    → %Request{}
      → check_expires                        (400 gate — see Errors)
      → Source.translate → Source.resolve    (identity, no bytes)
      → negotiate                            (image terminal only)
      → Representation.build                 (key / ETag / Vary)
      → Conditional.not_modified?            (304 before fetch)
      → serve → Cache.lookup_entry → hit | generate
```

**The `/info/` branch** happens after parse, before negotiate: it has no format
negotiation and a fixed `application/json` content type, so `vary?: false` and
no `Accept` in `Vary`. It is a complete-body response and follows native's
BlurHash precedent exactly — a dialect-owned `send_resp/3`, not `Sender`'s image
path (which assumes an encoder output). `InfoRenderer` becomes a plain
dialect-owned rendering. This is the design's "protocol renderings stay
dialect-owned" clause, and the reason renderer *dispatch* dies here rather than
being replaced.

**The `/info/` cache path**, explicitly (the chain reaches cache lookup before
the branch, so this must be stated rather than left implicit). `/info/` uses the
**complete-body** cache variant the probe added for BlurHash — the same
`Cache.open_sink(key, {:complete_body, content_type}, config)` →
`write_chunk` → `commit_sink` sequence, and the same
`%Cache.Entry{representation: {:complete_body, _}}` hit delivery via
`send_resp/3`, never `Sender`'s image path. JSON response headers are
**reconstructed from the current request**, not stored. Cache write failures
fail open exactly as the image path does. Carries probe gap **G5**:
`Cache.FileSystem` does not persist the `{:complete_body, _}` tag, so a
FileSystem-cached `/info/` result is lost across restart — fail-open and safe,
recorded not fixed.

**The image path** is native's chain: `Delivery.stream` → `build_fun` running
fetch/decode/transform/encode inside `Decode.with_image`'s bracket → `Sender`.

**One deliberate difference from native:** imgproxy's `auto_rotate` is a real
request/config option, not native's hardcoded `@auto_rotate? true`. The dialect
threads `auto_rotate?` from the request into `Decode.with_image`'s opts — which
**closes probe gap G1**: the orientation matrix's auto-rotate-OFF arm becomes
exercisable end-to-end for the first time (native's grammar has no `orient=`
escape hatch, so the probe could only validate it at core unit level).

## The Pipeline

`Dialect.Imgproxy.Pipeline` mirrors `Native.Pipeline` with three differences.

### 1. Per-pipeline scoping — imgproxy's `-` groups are NOT native's `then` groups

**This is the one place the native template must not be copied.** The two
group semantics differ, and conflating them is a parity bug:

| | Native `then` groups (`Native.Pipeline.run/4`) | imgproxy `-` pipelines (`Executor.execute_pipeline/4`) |
|---|---|---|
| `SourceShape` | seeded **once**, threaded across all groups | **re-seeded per pipeline** from `State.effective_source_dims/1` |
| Orientation flush | **once**, after the last group | **per pipeline** (`flush_boundary/4` ends each `run/5`) |
| Resolver carry | n/a (native passes `nil`) | **fresh `resolver.init()` per pipeline** (`executor.ex:150`, commented "a fresh init/0 per pipeline, spec §4.4") |

Native's single-seed/single-flush is what makes its "cheap trim" contract work
(a group-2 trim runs on group-1's executed output). imgproxy's chained
pipelines are a *full processing pass over the previous pipeline's in-memory
output* — each must end in the display frame, because a pipeline's output is
the next one's input. The dialect therefore reproduces **`execute_pipeline`'s**
shape, not `Native.Pipeline.run`'s: per pipeline, re-seed the shape, reset the
carry, run the ops, flush the boundary.

**What crosses a pipeline boundary — and what must not.** Exactly one thing
flows into the next pipeline: the **executed image / `State`**. Everything else
is per-pipeline and is rebuilt from scratch:

| Crosses the boundary | Does **not** cross (rebuilt per pipeline) |
|---|---|
| the executed image / `State` (the next pipeline's input) | `SourceShape` — re-seeded from `State.effective_source_dims/1` |
| | resolver carry — fresh `init()` |
| | pending orientation — flushed at each boundary, so each pipeline both starts and ends in the display frame |
| | `decode_shrink` / `source_dimensions` — confined to the pipeline whose decode produced them (#180) |

Carry, mode, and fallback are therefore **scoped to a single pipeline** and can
never leak into the next. Pinned by tests: a second pipeline with no resize of
its own must take its own `dpr` fallback, never the preceding pipeline's
computed scale; and an absolute crop in a later pipeline must size against that
pipeline's input, not a stale decode factor.

### 2. The carry

`run/4` threads `{state, shape, carry}` through the op reduce instead of
native's `{state, shape}`.

- At `%PlanResize{}` — compute `effective_padding_scale` and
  `canvas_preserving_padding_scale` into `carry`. The `padding_scale/4` math is
  **copied verbatim** from `resolver.ex`, including `display_source_dims/1`, the
  display-frame `max_padding_scale_without_enlarge/2`, and the unconditional
  `!Enlarge()` cap (`DprScale = min(DPR, min(wshrink, hshrink))`). Then delegate
  the op to `NeutralResolver`.
- At `%Canvas{}` / `%PlanPadding{}` — pass the appropriate carry slot to
  `Lowering.canvas_executables/2` / `padding_executables/2`, then
  `NeutralResolver.plain_advance/2` / `display_frame_advance/2`.
- Everything else — `NeutralResolver.resolve(shape, nil, op)`.

**Where the update point is, precisely.** The carry is computed inside the
resize's `resolve/3` from the **pre-resolve shape**, before any continuation is
followed — reproducing `resolver.ex:37-49` exactly. It is **never recomputed in
`continue/4`**: today's `continue/4` only `rewrap`s the carry through
(`resolver.ex:67-75`), so no `{:measure, …}` staleness window exists. The
dialect keeps that property: the carry is written at exactly one site.

**Where the mode lives after emit.** The `:resize` / `:canvas_preserving` mode
and the `dpr` fallback are derived from the `%PipelineRequest{}` and are
**pipeline-scoped values held by the dialect's own group assembly**, not fields
on the emitted operation:

```elixir
%Group{
  operations: [...],
  padding_scale_mode: :resize | :canvas_preserving,
  dpr_fallback: dpr
}
```

The information the marker used to ferry is therefore *stated*, not lost — it
simply lives in dialect-local data instead of on a shared neutral struct.
Fallback when no resize ran in **this** pipeline:
`carry.effective_padding_scale || group.dpr_fallback`.

**Unreferenced by the dialect as a result:** `ImagePipe.Resolver`, `rewrap/2`,
strategy selection/registration, `Directive`, and `{:effective, …}`.

**Retained**, per the brief and the probe's transitional scope: the
`Plan.Operation` / `Transform.Operation` mirror, `NeutralResolver`,
`SourceShape`, and the `{ops, continuation}` measure vocabulary. imgproxy is
declarative, so ordered planning is not exercised (that is a later TwicPics
inversion — and note the probe found `required_extent` mechanically inert for
ordered dialects, needing a shrink-*driving* field first).

### 3. Stage order

Eight stages, not native's six, copied from `plan_geometry/1`:

```
trim → orientation → crop → resize → effects → canvas → padding → background
```

The `overlay/2` sync rule and the `follow/5` measure driver transfer unchanged
from native. The seed/flush/carry scoping does **not** — see §1.

### 4. The color preamble (G4)

`run/4` opens with `InputColorManagement.condition(state, supports_hdr?: hdr?)`
**before the group reduce**, mirroring `Executor.execute/3`'s
`seed_color_management/2`.

Placement is settled by existing documented conformance, not invention. The
support matrix's stage-2 row states trim "inherits working-space pixels because
the input color preamble … runs before all operations — pixel-equivalent to
imgproxy calling `colorspaceToProcessing` inside `vips_trim`", and stage 4
states ImagePipe imports every profiled/wide-gamut/CMYK source "unconditionally,
before trim and all geometry — regardless of `scp`". So the preamble runs before
*all* ops including trim, despite imgproxy ordering trim at stage 2 and
`colorspaceToProcessing` at stage 4.

This requires threading a resolved `supports_hdr?` boolean
(`Format.supports_hdr?(format)` + `Plan.Output.hdr == :preserve`) from the
negotiation outcome into the pipeline — a pre-transform dependency native does
not have.

Native keeps its G4 limitation; the export merely makes closing it possible
later.

### Decode preflight

Native's shape: built from the **first pipeline only** (decode happens once);
`trim?` disables shrink-on-load; chained `-` pipelines do not inform it and are
sized against their own input.

## Core changes

All four are demand-driven by the above.

1. **Extraction B — `ImagePipe.Dialect.SharedConfig`** (own Boundary; deps
   `[Cache, Source, Format, Telemetry]`; both dialects list it). Pure data:
   `runtime_schema/0` + `validate_runtime!/1` for the shared runtime keys
   (`cache`, `sources`, `max_body_bytes`, `max_input_pixels`,
   `telemetry_prefix`, `auto_avif`, `auto_webp`, `auto_jpeg_xl`,
   `format_order`). Not a `use`-macro and not an orchestrator — the same
   category as `Cache.validate_config!` already being shared.

   **imgproxy's `Config` is a three-way split**, not native's two: shared
   runtime + `ImagePipe.Config.resolve!/2` for the neutral output tunables
   (already a shared boundary with `deps: [Plan]` — no extraction needed) + its
   own dialect keys (`signature`, `presets`, `source_schemes`,
   `source_url_encryption_key`, `base64_url_includes_filename`).

2. **Extraction A — `ImagePipe.Delivery`** (new top-level Boundary; deps
   `[Cache, Decode, Source, Output, Response, Telemetry]`). Top-level rather
   than the note's `Response.Delivery`, because the primitive needs
   `Decode`/`Source` deps that `Response` should not gain.

   Surface: `stream(owner_pid, build_fun, opts)` → `{:ok,
   Response.PreparedStream.t()} | {:error, term}`.

   **The `build_fun` contract, stated explicitly** (a bare "build_fun" is not a
   contract — a zero-arity function returning an encoder `Enumerable` would
   typecheck while letting the decode bracket close before consumption, which
   silently violates invariant #2). Taking native's proven shape as the
   specification:

   - **Arity 1.** `build_fun.(pump)`, where `pump` is supplied by `Delivery`.
   - **The primitive does not drive the encoder.** `build_fun` calls
     `pump.(stream, content_type, resolved_output)` from **inside** the
     `Source.with_fetched` + `Decode.with_image` brackets. The pump loop runs
     there until encoder EOF or cancel. This is what guarantees containment:
     only encoded chunks cross the process boundary; the lazy vips image and
     the encoder `Enumerable` never escape.
   - **Return:** `:done | {:error, term}` — never a lazy stream or image.
   - **Headers/encoder metadata** reach the coordinator via `pump`'s
     `content_type` + `resolved_output` arguments, i.e. **before** the first
     chunk, so the cache sink is opened with correct metadata.
   - **Errors** inside `build_fun` become `{:error, _}` results on the
     coordinator, which aborts the sink; after the first chunk is sent no
     status change is possible (the probe's error-matrix row 5).

   **The five invariants it must preserve** (from Task 15's Opus review, via the
   extraction note): monitor direction (`Process.monitor(owner_pid)`, not
   `spawn_monitor` from the owner); bracket containment (the pump loop runs
   inside both brackets; only encoded chunks cross the process boundary; the
   lazy vips image and encoder `Enumerable` never escape); cleanup exactly once
   via the producer's `try/after`; coordinator owns the cache sink, fail-open;
   no supervisor / no `application.ex` child.

   Consumers: **`Native.Delivery` is deleted** and native calls
   `ImagePipe.Delivery.stream/3` directly — a thin pass-through adapter would be
   a module whose only purpose is to be called through, which the design's
   survival test rejects. `Dialect.Imgproxy` calls it directly for the same
   reason. **`Request.SourceSession` + its `Producer` migrate onto it if and
   only if D3's topology gate passes**; the framework's extra concerns
   (custom-render branch, detector identity) become `build_fun` variations, not
   a fork. If the gate fails, the framework keeps its supervised session and
   Extraction A ships for the two dialects only.

   The G6 caveat (cleanup is exactly-once for the streamed case, best-effort
   with a ~1s force-kill backstop for a slow single synchronous encode) carries
   forward into the primitive's moduledoc.

   The complete-body path (BlurHash, `/info/`) stays a dialect-owned
   `send_resp/3` — the primitive is for the streamed-encoder path only.

3. **G4 — export `Transform.InputColorManagement`** as a dialect-callable
   preamble. A narrow widening of the `Transform` boundary's export list.

4. **`Lowering` / `ResizePlanning` export comment.** Currently annotated
   "exported for the in-tree imgproxy strategy only". The dialect becomes their
   second consumer; the note updates. No code change.

## Identity

`Representation.build(resolved.identity, Identity.material(request, negotiation,
conn, config))`.

- **`representation`** — canonical pipelines; `auto_rotate`; the output request
  (quality, format_qualities, max_bytes, quality_search, strip_metadata,
  keep_copyright, strip_color_profile, color_profile, preserve_hdr,
  encoder_options); the terminal (`:image` | `:info`); the negotiated selection
  outcome (image terminal only); `negotiation.policy_material`.
- **`storage_only`** — `[cachebuster: cb]` plus configured `storage_inputs`.
- **`dialect_behavior`** — `{ImagePipe.Dialect.Imgproxy, 1}`.
- **`vary_header_names`** — storage vary names, plus `"Accept"` when
  `negotiation.vary?`.

**Deliberately excluded:**

- `signature`, matched key index, and `expires` — gates, not identity (native's
  precedent).
- `source` — a separate `source_identity` passed to `Representation.build/2`.
- `response` (`filename`, `disposition`, `debug?`) — these change response
  *headers* only, never the encoded bytes. Two requests differing only in `fn:`
  produce byte-identical bodies and **must** share both a cache entry and an
  ETag. This matches `Cache.Key` today (`cache_data(cachebuster)` at
  `key.ex:219`, with no response fields).

  **Why sharing an entry is safe** (the load-bearing half): on a cache hit,
  `sender.ex:208` derives `Content-Disposition` from the **caller's**
  `%PlanResponse{}` — the *current* request — while the entry supplies only
  `content_type`. So an entry generated for `fn:a.jpg` cannot make a later
  `fn:b.jpg` request return `a.jpg`. Native passes an empty `%PlanResponse{}`
  (it has no filename); **the dialect must pass the current request's response
  meta on both the hit and miss paths**. Pinned by tests on a cache hit and on
  an `If-None-Match` request, plus a `debug?`-only pair asserting
  byte-identical encoded bodies — `debug?` is named riskily enough that it
  should not rest on prose.

**Key/ETag change across stacks is intended.** The dialect's
`dialect_behavior` differs from the framework's behavior material, so the same
URL yields a different cache key and ETag on each stack. This is correct: a
deployment mounts one dialect, and the design states cross-dialect cache-entry
sharing "dies by design". It is *not* in tension with the conformance doc's "no
behavioral/pixel change" — that phrase is scoped to AGENTS.md's imgproxy
conformance axes (surface / stage-order / pixel), not to ImagePipe's own
storage identity. ETags are opaque; a migrating client re-validates once.

## Errors

`Dialect.Imgproxy.Errors` mirrors `Native.Errors`, with imgproxy's protocol
mapping:

| Condition | Status |
|---|---|
| invalid / unsupported / malformed signature | **403** |
| `expires` elapsed | **400**, body `"invalid image request: {:expired_request, N}"` — matching the framework's generic error clause (`parser/imgproxy.ex:230-233`) and the wire suite's pin (`imgproxy_wire_conformance_test.exs:4509`). Upstream imgproxy documents 404 here; ImagePipe's 400 is a **known, documented divergence** (`docs/imgproxy_support_matrix.md:1181`), and the inversion preserves it — changing it would be a conformance change out of this migration's scope |
| parse / validation failure | **400** |
| unknown endpoint (`/unknown/…`) | **403** — `path.ex:8-14` has no unknown branch (`_ -> :image`), so any non-`/info/` path is an image request and hits signature verification first |
| core stage errors | via `Response.ErrorStatus.classify/1` — source → 502, decode → 415, transform → 422 |

`ErrorStatus.classify/1` is a reusable **default**, not a core-owned mapping:
the dialect chooses to adopt it for core stage errors and owns its own gate
mappings outright (403/400 above). That is the design's "core does not own
protocol status mapping" clause — the `expires` mapping is a dialect decision
(here 400, preserving ImagePipe's documented divergence from upstream's 404),
and IIIF maps its own gates to its spec-mandated statuses.

## Testing

### The regression net (D2)

**What the net does and does not prove.** The differential is a
tolerance-budgeted **pixel** comparison and the wire suite asserts status,
headers, and selected bodies. Together they prove **pixel parity and wire
parity** against real imgproxy — *not* encoded-byte equality, which can differ
while decoding to identical pixels. This spec therefore says "pixel/wire
parity", never "byte parity", except where raw bodies are actually compared
(below).

- **Dual-run differential** — parameterize `Harness.plug_opts/0`
  (`test/support/image_pipe/test/imgproxy_differential/harness.ex:21`) over both
  stacks; ~163 fixtures × 2. The conformance test never touches the parser — it
  builds a pure URL string — so this is one function body. **No re-bake, no
  fixture changes, no `source_inventory` changes.**
- **Dual-run wire** — parameterize `call_imgproxy/3`
  (`imgproxy_wire_conformance_test.exs:4327`). Prerequisite: normalize the 36
  inline `parser:` opt lists and the 6 sites that bypass the helper onto one
  path. The 149 assertions are stack-agnostic. One site
  (`:3881` `Imgproxy.encrypt_source_url/3`) is a test-side URL builder to
  re-home.
- **Cross-arm raw body equality** — a direct framework-vs-dialect
  `:crypto.hash(:sha256, resp_body)` assertion over a representative fixture
  set. This is *stronger* than both arms independently passing a tolerance
  budget: it proves the inversion changed nothing the encoder can see. It is
  feasible because in-process encoding is already deterministic for equal
  inputs — the wire suite relies on exactly this today
  (`:894` `second_conn.resp_body == first_conn.resp_body`, `:929`
  `default_conn.resp_body == q50_conn.resp_body`). Both arms share the encoder
  and everything downstream of `Plan.Operation`, so any inequality is a real
  divergence. Restricted to deterministic-encode fixtures; any exclusion must
  be named, not silently dropped.
- **Per-arm cache isolation** — every dual-run test (differential, wire,
  body-hash, and the cache tests themselves) runs each arm against its **own
  cache namespace or a clean store**. Keys differ by `dialect_behavior` so
  collision is already improbable, but isolation is not merely hygiene: **the
  body-hash assertion's validity depends on it.** If the arms could share a
  store, one arm could satisfy the equality by *reading the entry the other
  generated* — the assertion would pass while proving nothing about the
  dialect's own generation path. Isolation is what makes each arm independently
  generate the bytes it is compared on.

### Dialect coverage

- **Contract kits** — `ContractKit.CacheKey` + `ContractKit.RequestSafety`
  against `Dialect.Imgproxy` (already dialect-parameterized for native).
- **Orientation matrix** — imgproxy's version, **including the auto-rotate-OFF
  arm** (closes G1). Same three invariants as native's: semantic-intent
  invariance, pixel invariance, shrink correctness (storage dims for decode,
  display frame for planning).
- **Error-path matrix** — rows equivalent to native's 9. These matter more here
  because Extraction A changes delivery for *both* stacks.
- **Pipeline unit tests** — the carry (computed at resize, consumed at
  padding/canvas), marker-free padding emission, the eight-stage order, the
  color preamble.
- **Architecture boundary test** — a `Dialect.Imgproxy` entry following
  `Dialect.Native`'s (`architecture_boundary_test.exs:62`), asserting its dep
  set, its exports (`SourceScheme`), and that no core file names it.

### Planning constraint (stated up front)

**The dual-run net cannot go green until the whole dialect exists.** Per-task
TDD must therefore be unit-level red/green (grammar, pipeline carry, identity,
errors), with the net as an **integration gate at the end** — not a per-task
signal. Plans must not assume the differential suite gives incremental feedback.

### Grammar copy-fidelity (the phase-1 coverage hole, and its fix)

The wire + differential corpus exercises the grammar through URLs, but not
every parse error, alias, duplicate option, preset interaction, or
percent-encoding edge. Left alone, the copied grammar would be
production-capable in the dialect while its edge cases were only tested against
the original — and "dual-run catches copy drift" is only true for drift the
integration corpus covers.

**The tests split cleanly by what they assert:**

- **Parameterizable over the module under test (~211 tests)** —
  `option_grammar_test.exs` (66), `options_test.exs` (53), `path_test.exs`
  (45), `signature_test.exs` (20), `source_test.exs` (19),
  `source_encryption_test.exs` (8). These assert **grammar output**, not plans:
  e.g. `option_grammar_test.exs:16` asserts
  `OptionGrammar.parse("zoom:1:2") == OptionGrammar.parse("z:1:2")`. Running
  each against both the original and the copy is a direct proof of copy
  fidelity, including error paths. **Do this in phase 1.**
- **Not parameterizable (~236 tests)** — `imgproxy_test.exs` (153),
  `plan_builder_test.exs` (77), `imgproxy_property_test.exs` (6) assert
  `{:ok, %Plan{}}` (`plan_builder_test.exs:36`). The dialect has no `to_plan/2`
  and no `%Plan{}`, so these cannot be pointed at it mechanically; they keep
  testing the still-alive `Parser.Imgproxy` and are ported in phase 2.

### Mount / path semantics

Mounting a Plug directly rather than via `parser:` can change which path
representation is authoritative (`request_path` vs `path_info` vs
`script_name`; raw vs decoded), which is load-bearing for signatures,
`%2F`, `@ext`, and base64/`enc` sources.

**The copy protects us**: `path.ex` moves with its own
`parser_request_path/1` mount-prefix handling, so the dialect inherits
**imgproxy's existing semantics** — it does *not* adopt native's
`script_name` byte-prefix approach (whose moduledoc documents raising on
non-canonical mount paths). This must be pinned rather than assumed:

- root mounting and mounting below a prefix;
- `/info/` under a non-root mount;
- percent-encoded source bytes;
- query strings excluded from signed material.

### Telemetry equivalence

"No changes expected" is weaker than the rest of this spec, and the delivery
owner process changes under Extraction A. A contract test covers: image cache
miss, image cache hit, 304, `/info/`, streamed error after preparation, and
owner cancellation. It runs against **both arms**, because D3's topology change
can shift OTel span parentage that the pixel net cannot see.

**Assert semantics, not mechanism.** The test pins **stage names, stage
ordering, error stages, and semantic span parentage** — the relationships a
consumer's dashboard depends on. It must **not** pin PIDs, process structure, or
raw span counts unless those are deliberately contractual. Over-pinning
mechanism would invert the test's purpose: D3 *intends* to change process
topology, so a test coupled to process identity would report a false blocker on
the gate and force a dialects-only degradation for no observable reason.

Per the test guidelines, every telemetry assertion uses a unique private
`telemetry_prefix` — `:telemetry` handlers are global, and a default-prefix
assertion in an `async: true` test can be satisfied by another module's
emission.

## Documentation sync

Per AGENTS.md's conformance-doc rule, the axis affected is **stage/order**. No
change is intended on the **surface** or **behavioral/pixel** axes — that is
exactly what the net proves. This claim is scoped to those three imgproxy
conformance axes and says nothing about ImagePipe's own storage identity: cache
keys and ETags *do* change across stacks, deliberately (see Identity).

`docs/imgproxy_support_matrix.md` rows that name framework implementation paths
become inaccurate for the inverted stack and must be updated in the same change:

- **Stage 4** (`colorspaceToProcessing`) — "fixed preamble in
  `Executor.execute/3`" gains the dialect's `Pipeline.run/4`.
- **Stage 8** (`cropToResult`) — "reachable only through the imgproxy resolution
  strategy" becomes inaccurate once the dialect emits `down: true` without a
  strategy.
- Any row naming `Resolver` / the strategy column.

`docs/imgproxy_path_api.md` needs a mount-point note (the dialect is mounted
directly, not via `parser:`).

`docs/telemetry.md:860` describes the "request → `SourceSession` → `Producer`
process seams". If D3's gate passes, that seam is renamed to the
`ImagePipe.Delivery` primitive and the line must be updated.

Telemetry: the dialect emits the same standard stage names as native
(`[:request]`, `[:parse]`, …), so no Logger or `Trace.Capture` list changes are
expected — **asserted by the telemetry contract test above, not assumed**. Any
new metadata key must be added to **both** the Logger's subscription lists and
`Trace.Capture`'s `@span_stages`/`@safe_keys`, per the telemetry guidelines.

## Phase 2 — retirement (specified, not implemented)

1. Delete the `Parser.Imgproxy` tree (parser, `plan_builder`, `resolver`,
   `info_renderer`, `parsed_request`, and the copied grammar's originals).
2. Port the ~236 `%Plan{}`-asserting white-box tests (`imgproxy_test.exs`,
   `plan_builder_test.exs`, `imgproxy_property_test.exs`) onto the dialect's
   `%Request{}` + `Pipeline` equivalents — these need rewritten assertions, not
   renames, since the dialect has no `to_plan/2`. The ~211 grammar-module tests
   are already dual-run from phase 1 and simply drop their framework arm.
3. Drop the framework arm from both suites (D2's dual-run collapses to one).
4. Remove the ExDNA `--ignore` globs and `.credo.exs` entries for the imgproxy
   duplication.
5. Rework `imgproxy_resize_auto_test.exs` off `Request.Runner` / hand-built
   `Source.Resolved`.
6. **Retire the marker.** With its sole consumer gone, `{:effective, …}` dies
   from five core files: `plan.ex:363,392` (`requires_strategy?` loses its
   `Padding` clause), `plan/key_data.ex:209`, `plan/operation.ex:68,745,748`,
   and `plan/operation/padding.ex:13`. `ImagePipe.Resolver` itself **survives** —
   TwicPics still carries a strategy.
7. Replace AGENTS.md's marker-accretion worked example (see D5).

**Not in phase 2: the `SourceSession` supervisor cleanup.** If D3's gate passes,
`SourceSessionSupervisor`, its `application.ex` child entry, its 421-line test,
and the `docs/telemetry.md:860` seam description are all retired **in phase 1**,
as part of Extraction A — the migration is what deletes them, so deferring the
cleanup would leave a supervisor with no sessions to supervise. If the gate
fails, they are not retired at all and the framework keeps its supervised
topology indefinitely. Either way this is a D3 outcome, not phase-2 work.

## Non-goals

- Migrating TwicPics or IIIF. They keep the framework stack.
- Deleting the framework, `Plan`, `Resolver`, or `Renderer`.
- Killing the `Plan.Operation` / `Transform.Operation` mirror or the
  continuation vocabulary — probe §7's geometry-compiler API is a separate,
  later piece of work, and attempting it here would re-leak #146.
- Exercising ordered planning, or adding the shrink-driving `DecodePlanner`
  field G2 needs. imgproxy is declarative.
- Re-baking differential fixtures. Any need to re-bake is a **red flag** that
  parity broke, not a step.
- Publishing contract kits.

## Risks

- **Parity regression in the rewritten geometry.** The `plan_builder` +
  `resolver` rewrite is the only place semantics could shift. Mitigated by
  copying the math verbatim, by the dual-run differential, and by an Opus
  reviewer on every geometry/parity-critical task.
- **Extraction A destabilizing the framework.** It touches code serving IIIF and
  TwicPics. Mitigated by the pre-audit of force-kill timing dependence and by
  D2's framework arm staying green.
- **The copy drifting from the original during phase 1.** Both stacks parse the
  same grammar; a fix landing in one only is a silent divergence. Mitigated by
  the dual-run net (a divergence fails both arms differently) and bounded by
  phase 2 being planned, not hypothetical.
- **G4's `supports_hdr?` threading.** A pre-transform dependency on the
  negotiated output. If mis-threaded, 16-bit sources collapse to SDR silently.
  Pinned by the `preserve_hdr` differential/wire coverage.
- **Late integration feedback.** The net gates at the end; a systemic error
  could surface at task ~25. Mitigated by unit-level pipeline tests that pin the
  carry and stage order early.

## Exit criteria (phase 1)

1. `ImagePipe.Dialect.Imgproxy` serves real requests end-to-end: full option
   surface, `/info/`, signing + salts, `expires`, `-` pipelines, presets,
   base64/`enc`/plain sources, `@ext`, negotiation + `Vary`, ETag/304 before
   fetch, cache hit/miss, streamed delivery.
2. **The dual-run differential suite is green on both arms**, unchanged fixtures,
   no re-bake.
3. **The dual-run wire suite is green on both arms** (149 × 2), plus the
   cross-arm raw-body-hash equality set.
4. `ContractKit.CacheKey` + `ContractKit.RequestSafety` pass against the dialect.
5. The orientation matrix passes **including the auto-rotate-OFF arm** (G1
   closed, recorded as such).
6. The error-path matrix passes.
7. The ~211 grammar-module tests pass against **both** the original and the
   copy, proving copy fidelity including error paths.
8. `-` pipeline scoping is pinned: per-pipeline re-seed, per-pipeline flush, and
   a carry that never leaks into a pipeline with no resize of its own.
9. **D3's gate is resolved either way** — either `Request.SourceSession` runs on
   `ImagePipe.Delivery` with application-shutdown termination proven by test, or
   Extraction A is dialects-only with the exact blocker recorded. The core
   primitive gained no supervised mode.
10. Telemetry contract test green on both arms (stage names, ordering, error
    stages), each using a private `telemetry_prefix`.
11. Boundary + architecture tests enforce the acid test.
12. `mise run precommit` green with `PATH="$(mise where elixir)/bin:$PATH"` (the
   Homebrew 1.19.3 shadow false-reds `mix dialyzer` on pre-existing framework
   specs).
13. The support matrix's stage/order rows are synced.
