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
endpoint, needs input color management, or has a byte-level parity obligation
to a real upstream product.

imgproxy is the right second dialect for one reason above all: **it already has
a regression net that compares against real imgproxy output.** ~163 differential
fixtures pixel-compare against a pinned `darthsim/imgproxy` bake, and 149
wire-conformance tests assert status/headers/pixels through real `call/2`
requests. Both are black-box and stack-agnostic. Inverting the internals
underneath them turns them into a byte-parity proof that the inversion
preserved behavior — evidence no amount of internal review can supply.

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
| D3 | **Extraction A fully unifies — `Request.SourceSession` migrates too.** | The stated payoff and the probe's §6d headline finding. Reads "byte-frozen" as observable-output-frozen, not no-refactor; the framework's *machinery* keeps serving IIIF/TwicPics with identical output. De-risked by D2 keeping the framework arm green. |
| D4 | **Spec both phases; implement phase 1 now.** | Phase 1 is already ~25–30 TDD tasks. Designing the end state gives the duplication a dated exit without a 50-task branch. |
| D5 | **Carry handled as a local; the `{:effective, …}` marker dies.** | See below — the marker is provably pure redundancy once the dialect owns both emit and run. |

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
      → check_expires                        (404 gate)
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

### 1. The carry

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

Fallback when no resize ran: `carry.effective_padding_scale || dpr_from_request`
— parse-time known, so no marker is needed to carry it.

**Unreferenced by the dialect as a result:** `ImagePipe.Resolver`, `rewrap/2`,
strategy selection/registration, `Directive`, and `{:effective, …}`.

**Retained**, per the brief and the probe's transitional scope: the
`Plan.Operation` / `Transform.Operation` mirror, `NeutralResolver`,
`SourceShape`, and the `{ops, continuation}` measure vocabulary. imgproxy is
declarative, so ordered planning is not exercised (that is a later TwicPics
inversion — and note the probe found `required_extent` mechanically inert for
ordered dialects, needing a shrink-*driving* field first).

### 2. Stage order

Eight stages, not native's six, copied from `plan_geometry/1`:

```
trim → orientation → crop → resize → effects → canvas → padding → background
```

Group threading, the single-seed/single-flush `SourceShape`, the `overlay/2`
sync rule, and the `follow/5` measure driver transfer unchanged from native.

### 3. The color preamble (G4)

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
   reason. **`Request.SourceSession` + its `Producer` migrate onto it** (D3);
   the framework's extra concerns (custom-render branch, detector identity)
   become `build_fun` variations, not a fork.

   **Risk, explicitly sequenced:** the framework force-kills on cancel; the
   probe's primitive graceful-halts. An **audit task runs first** to determine
   whether any framework test depends on force-kill timing. If one does, it is
   surfaced as a finding, not silently changed. The G6 caveat (cleanup is
   exactly-once for the streamed case, best-effort with a ~1s force-kill
   backstop for a slow single synchronous encode) carries forward into the
   primitive's moduledoc.

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
  `key.ex:219`, with no response fields). Pinned by an explicit test rather than
  left as a coincidence.

## Errors

`Dialect.Imgproxy.Errors` mirrors `Native.Errors`, with imgproxy's protocol
mapping:

| Condition | Status |
|---|---|
| invalid / unsupported / malformed signature | **403** |
| `expires` elapsed | **404** |
| parse / validation failure | **400** |
| core stage errors | via `Response.ErrorStatus.classify/1` — source → 502, decode → 415, transform → 422 |

This is the design's "core does not own protocol status mapping" clause: the
same stage error is a 404 here and something else in IIIF.

## Testing

### The regression net (D2)

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

### Untouched in phase 1

The ~300 white-box parser tests (`test/parser/imgproxy/**`,
`test/parser/imgproxy_test.exs`) keep testing the still-alive `Parser.Imgproxy`.
They neither block nor validate the dialect.

## Documentation sync

Per AGENTS.md's conformance-doc rule, the axis affected is **stage/order** — no
surface or behavioral/pixel change is intended (that is exactly what the net
proves).

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

Telemetry: the dialect emits the same standard stage names as native
(`[:request]`, `[:parse]`, …), so no Logger or `Trace.Capture` list changes are
expected. Any new metadata key must be added to **both** surfaces per the
telemetry guidelines.

## Phase 2 — retirement (specified, not implemented)

1. Delete the `Parser.Imgproxy` tree (parser, `plan_builder`, `resolver`,
   `info_renderer`, `parsed_request`, and the copied grammar's originals).
2. Port the ~300 white-box tests onto `Dialect.Imgproxy.*` internals — largely
   module renames, since the grammar moved rather than changed.
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
3. **The dual-run wire suite is green on both arms** (149 × 2).
4. `ContractKit.CacheKey` + `ContractKit.RequestSafety` pass against the dialect.
5. The orientation matrix passes **including the auto-rotate-OFF arm** (G1
   closed, recorded as such).
6. The error-path matrix passes.
7. `Request.SourceSession` runs on `ImagePipe.Delivery`; the force-kill audit is
   recorded either way.
8. Boundary + architecture tests enforce the acid test.
9. `mise run precommit` green with `PATH="$(mise where elixir)/bin:$PATH"` (the
   Homebrew 1.19.3 shadow false-reds `mix dialyzer` on pre-existing framework
   specs).
10. The support matrix's stage/order rows are synced.
