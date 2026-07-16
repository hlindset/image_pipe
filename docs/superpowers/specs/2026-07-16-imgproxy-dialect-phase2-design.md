# imgproxy dialect inversion — phase 2: gap closure, then retirement

Phase 1 (PR #458) built `ImagePipe.Dialect.Imgproxy` as a self-contained
inverted Plug running alongside the frozen framework stack, dual-running the
differential suite (162 constellations × 2 arms) and the wire suite (270 cases,
120 shared × 2 arms + 30 framework-only) at zero divergence. Phase 2 finishes
the inversion: close every recorded framework-vs-dialect divergence **while the
dual-run net is still alive**, then retire `Parser.Imgproxy` (spec decision D1
of `2026-07-15-imgproxy-dialect-inversion-design.md`) so the dialect becomes
the sole imgproxy implementation.

Inputs: `docs/imgproxy_dialect_phase2_backlog.md` (the consolidated entry
point), the phase-1 design spec §Phase 2, `docs/imgproxy_support_matrix.md`
§ Dialect-stack divergences, `.superpowers/sdd/phase1-exit-criteria.md`.

## Decisions

| # | Decision | Rationale |
| --- | --- | --- |
| P1 | **§B closes before §A. The wave-1 exit gate is zero `@stack == :framework` gates in the wire suite.** | The ~30 framework-only wire cases are the *executable spec* for every §B behavior. §A deletes the framework arm and those cases with it; done first, each §B fix would be implemented against doc prose instead of a live reference with dual-run proof. Done in §B-then-§A order, each fix un-gates its block into dual-run parity evidence — which is also the backlog's "otherwise trusted" precondition for the one-way deletion. The backlog's section order is severity order, not execution order. |
| P2 | **Trust gate for §A = §B closed + dual-run clean. No soak pause.** | User ruling. Greenfield, unreleased library: no production deployment exists to generate soak signal, so a pause is indefinite by default. The dual-run suites at full coverage are the trust evidence. |
| P3 | **B3 goes to full stage-set parity, preferring shared-core seams.** | User ruling ("full parity, before §A"). Four of the eight missing events have a ready shared seam (`Materializer`, `Clamp.clamp`, `Policy.resolve`, `InputColorManagement.condition`) — emit once, both stacks (and the framework, unchanged) light up. The other four (`[:send]`, `[:source, :fetch_decode]`, `[:transform, :execute]`, `[:encode]`) live in framework-only orchestration and are emitted by each dialect. |
| P4 | **`Dialect.Native` moves in lockstep wherever a divergence is recorded "shared with `Dialect.Native`".** | For B3 this is *mandatory*: `ImgproxyTelemetryStageSetTest` asserts strict stage-sequence equality between the two dialects, so a span added to one alone turns the pin red. For B2/B5/B6/B4 it is cheap (shared seams or small mirrors) and prevents minting a new dialect↔dialect divergence while closing a framework↔dialect one. |
| P5 | **B1's `:detector` config default is `:default` (→ `Transform.Detector.Composite`), mirroring `Request.Options` exactly.** | Same rationale the backlog records for `detector_required: false` — "the framework's exact default". A host migrating from the framework arm gets identical behavior, including the degrade-to-attention path when the Composite's optional `image_vision` dep is unavailable (`available?/1` false), which is exactly what the framework does. |
| P6 | **New item B6: the `:output_capabilities` config seam is in scope.** | Discovered during research; not in the backlog. Six wire cases gate on it alone and it co-blocks all eight of B4's clamp cases — P1's zero-gate exit is unreachable without it. The seam already exists in shared core (`Output.Capabilities` reads `:output_capabilities` from opts, capabilities.ex:37-41); the dialects only need to permit and thread the key. |
| P7 | **No cache-key epoch bump for B1's identity change.** | Adding a detector-identity term to `Identity.material/4` changes dialect cache keys and ETags for detection requests. Per the cache guidelines (greenfield): reshape the canonical key data and update tests in place; `@dialect_epoch` stays. |
| P8 | **C2 (prepare-timeout test through `stream/5`) is out of phase 2.** | It is a design question about inventing a host option, orthogonal to the inversion. No dual-run evidence is at stake — the net's retirement doesn't affect it. Stays recorded in `phase1-exit-criteria.md`. |
| P9 | **F (#457, chain-helper promotion) stays deferred to the TwicPics inversion.** | Unreachable at N=2 dialects, per the backlog. The `.credo.exs` ignore for `dialect/imgproxy.ex` survives §A. |
| P10 | **No differential re-bake.** | A differential failure during any wave is a dialect bug, never a fixture problem. `git status test/support/image_pipe/test/imgproxy_differential/` stays clean across the whole phase. |

## Wave 1 — close the divergences

Order within the wave: **B4+B6 → B2 → B5 → B1 → B3.** B4/B6 are small config
threading and bank 14 un-gates early; B5's OPTIONS answer carries CORS headers,
so B2 lands first; B1 is the largest isolated item; B3 touches shared core and
both dialects plus two pin tests, so it goes last with the most context.

Every item follows the same evidence discipline: **un-gate first (RED on the
dialect arm), then fix (GREEN on both arms).** The framework-only gate removal
*is* the RED-before evidence — a test that was green when un-gated proves
nothing and must be investigated, not celebrated. Each item also updates
`docs/imgproxy_support_matrix.md` § Dialect-stack divergences in the same
change (removing or narrowing its row) per the conformance-doc rule.

### B4 + B6 — config seams: `max_result_*` and `output_capabilities`

**Gap.** The dialect hardcodes `@default_max_result_{width,height,pixels}`
(imgproxy.ex:129-131, native.ex:106-108 — the third copy is
`Request.Options`' defaults, options.ex:11-13) and rejects
`output_capabilities` as an unknown option, where the framework honors both
(`Request.Options` options.ex:26-28, 56; enforcement via
`Request.DeliveryBuild.effective_limits/2`, delivery_build.ex:159-161).

**Fix.**
- Add `max_result_width`/`max_result_height`/`max_result_pixels`
  (`:pos_integer`, defaults 8192/8192/40_000_000) and `output_capabilities`
  to `ImagePipe.Dialect.SharedConfig` — it already owns the sibling safety
  limits `max_body_bytes`/`max_input_pixels` (shared_config.ex:41-42, 61-68),
  and both dialect configs delegate to it (imgproxy config.ex:79,88; native
  config.ex:35,43), so one change fixes both dialects. (`Request.Options`
  keeps the framework's own defaults while the framework serves IIIF/TwicPics,
  so the triplication reduces to one dialect source plus the framework's.)
  `output_capabilities`'s schema: an optional map (format → boolean),
  `required: false`, **no default** — a default would change the absent-key
  probe semantics of `Output.Capabilities` (capabilities.ex:37-41), which
  treats the key as an override seam.
- `Dialect.Imgproxy.result_limits/1` (imgproxy.ex:793-802) reads
  `Keyword.fetch!(config, :max_result_*)` instead of module attributes,
  keeping its existing `min_limit` against the encoder hard limit.
  `Dialect.Native.result_limits/0` (native.ex:518-524) does the same — **and
  gains the encoder-min it currently lacks** (it returns raw defaults today;
  aligning it is part of P4's lockstep).
- Thread `output_capabilities` from dialect config into every shared-core call
  that consults `Output.Capabilities` (negotiation via `Policy.resolve/2`,
  clamp/encoder-limit paths). The seam is opts-driven in core already;
  this is key-permitting and pass-through, no core change.

**Un-gates** (wire suite): 3 encoder-capability negotiation cases
(conformance:2887), 1 cache-variant case (:2956), 2 explicit-avif cases
(:2996), 3 encoder-limit clamp cases (:3700), 5 host-result-cap cases
(:3769) — 14 cases. The `@clamp_opts` attribute gate (:3663) dissolves.

### B2 — CORS

**Gap.** `ImagePipe.Plug` registers `Response.CORS.maybe_register/2` at the
top of `call/2` (plug.ex:45), so a before-send hook stamps
`access-control-allow-origin` on every exit path (success, errors, 304,
OPTIONS, 405). Both dialects have no CORS handling and no `allow_origin` key.

**Fix.** `Response.CORS` is already exported and both dialects' Boundary deps
include `ImagePipe.Response` (imgproxy.ex:62, native.ex:50) — direct reuse,
no boundary change:
- Add `allow_origin` to `Dialect.SharedConfig` (it is dialect-neutral, like
  the safety limits), validated as in `Request.Options` — non-empty binary,
  control-character rejection (options.ex:195-208).
- Register `CORS.maybe_register(conn, config)` once at the top of each
  dialect's `call/2` (imgproxy.ex:137-144; native.ex:114), mirroring
  plug.ex:45, so all exit paths are covered without touching each send site.

Semantics note: the framework's CORS is a single static allow-origin echo —
no wildcard matching, no `Vary: Origin` (cors.ex:15-25) — and **framework
parity verbatim is the target**, including its recorded, deliberate deltas
from upstream imgproxy (`Access-Control-Allow-Methods: GET, HEAD, OPTIONS`
only on OPTIONS, where upstream sends `GET, OPTIONS` on every CORS response;
support matrix :522-528). Do not "correct" toward upstream's methods list
mid-implementation — that would break the framework-parity wire cases.

Doc duty beyond the divergences section: the matrix's § CORS response headers
(imgproxy_support_matrix.md:505-517) states the dialect stacks "have no CORS
handling at all — no `allow_origin` config key"; B2 makes that paragraph
false and must rewrite it in the same change.

### B5 — OPTIONS / method layer

**Gap.** The dialects have no HTTP-method layer: `OPTIONS /_/…` parses as an
image request and 400s; any non-GET/HEAD flows into parsing. The framework
answers OPTIONS with `204` + `Allow: GET, HEAD` (+
`Access-Control-Allow-Methods` when `allow_origin` is set) via
`CORS.send_options/2` (plug.ex:53-60, cors.ex:33-46) and non-GET/HEAD with
`405` + `Allow` via `Sender.send_method_not_allowed/1` (plug.ex:62-69,
sender.ex:117-123).

**Fix.** An early method branch at the top of each dialect's `call/2`/`route/2`
(before `Path.split_endpoint`), reusing `Response.CORS.send_options/2` and
`Response.Sender.send_method_not_allowed/1` — both exported and in-boundary;
`Sender` is already aliased in both dialects. Depends on B2 (the 204/405 must
carry the CORS stamp, which B2's before-send hook provides).

**Un-gates:** the 4-case CORS/method describe (conformance:1025) and the
`call_imgproxy_method/3` helper gate (:4518).

Doc duty: the conformance docs currently record **no** 405 comparison
anywhere. Upstream imgproxy v4 answers a non-GET/HEAD method on an image URL
with `404` and no `Allow` header (unmatched route — exact-method routing,
imgproxy `server/router.go:145-158`), and its OPTIONS answer is `200` with a
blank body and no `Allow` (`OkHandler`); ImagePipe's `405` + `Allow` and
`204` + `Allow` are deliberate divergences that become the sole imgproxy
stack's behavior after §A. Record the method-layer divergence (and make the
HEAD difference explicit — upstream answers HEAD with a blank 200 where
ImagePipe serves it as a processed request) in the matrix in the same change.

### B1 — object-detection support

**Gap.** The dialect's grammar and assembly already produce `{:detect, {spec,
weights}}` crop guides (assembly.ex:703-752), which flow through the shared
`Transform.Chain` into `Crop.execute/2` — but `state.detector` is never
seeded, so `detect_crop/4` (crop.ex:412-419) always takes the
attention-crop fallback, and detector model identity never reaches the cache
key. The request-safety half (`detector_required` → pre-fetch 422) closed in
phase 1 and is dual-run; this item is detector *support*.

**Fix** — two threadings plus a config key; no new algorithms:
1. **Config:** add `detector` to `Dialect.Imgproxy.Config`'s `@dialect_keys` /
   `@dialect_schema` (config.ex:24-33, 35-71), schema mirroring
   `Request.Options` (options.ex:109-112): `{:or, [{:in, [:default, nil]},
   :atom]}, default: :default` (P5). **Native does not take the key**: its URL
   surface has no object-detect gravity (`anchor=smart` is plain attention,
   native/pipeline.ex:495), so the key would be dead config — P4 applies only
   where the divergence actually exists. Delete the "no `:detector` seam"
   comment at config.ex:57-62.
2. **State seeding:** the dialect's `Pipeline.run/4` / `run_pipeline`
   (pipeline.ex:259-266, 333-350) seeds `State` but omits the detector fields
   `Executor.execute` sets at executor.ex:62-67. Set `state.detector =
   Transform.resolve_detector(config[:detector])` and
   `state.detector_required` before `Chain.execute`. (`state.telemetry_opts`
   is already seeded on the dialect path — `Decode.with_image` builds `State`
   with it, decode.ex:136-141 — so the shared crop code's
   `[:transform, :detect]` spans already carry the dialect's prefix; only the
   two detector fields are unseeded.)
3. **Cache-key / ETag identity:** the dialect equivalent of
   `Runner.with_detector_identity/2` (runner.ex:194-207): compute
   `Transform.detector_identity(config[:detector], classes)` from the
   assembled operations' guides (the dialect already computes
   `detection_requested?/1` over operations for the 422 gate,
   imgproxy.ex:423-425) and fold it into `Identity.material/4`
   (identity.ex:45-71), analogous to `cache/key.ex:58`. The term goes into
   `IdentityMaterial.representation` — not `storage_only` — which is what
   makes it feed both the ETag and the cache key
   (representation.ex:92-100). That matches the framework, where detector
   identity is ETag material too (`etag_material/4` drops only `:cache` from
   the key material, http_cache.ex:59-77) — legitimately so, since a
   detector/model change alters output bytes. Face-assist counts as
   detection here exactly as `Plan.face_assist?/1` does for the framework.
   No epoch bump (P7). The identity must be computed **once** per request and
   feed both the ETag and the cache key, as the framework does by resolving
   before `HTTPCache.prepare` (plug.ex:94).

**Un-gates:** the 8-case object-detection block (conformance:3042), the
objw-weight-overflow safety case (:3440), and the 3-case detector-model-
identity cache-key block (:3577) — 12 cases. The dual-run
`@detector_gate_opts` split (:1833) collapses to identical opts on both arms.

### B3 — telemetry stage-set parity

**Gap.** The framework emits 7 stage spans no dialect does — `[:send]`,
`[:source, :fetch_decode]`, `[:transform, :execute]`,
`[:transform, :input_color_management]`, `[:transform, :materialize]`,
`[:output, :negotiate]`, `[:encode]` — and neither dialect ever emits the
`[:output, :clamp]` one-shot. Full parity (P3), both dialects in lockstep
(P4 — the stage-set pin demands it).

**Fix — shared-core seams (one emission site, all three stacks):**
- `[:output, :clamp]`: both dialects already call shared `Output.Clamp.clamp/3`
  and discard `clamp_info` (imgproxy.ex:754, native.ex:479); the framework
  emits from `DeliveryBuild.emit_clamp_telemetry/3` (delivery_build.ex:170-186).
  Move the one-shot emission into the clamp seam; the framework's emit site
  delegates or is deleted. Fires only when clamping occurred, as now. Shape
  detail: the framework's event carries `format:`, which `Clamp.clamp/3`
  never receives (clamp.ex:33 — its moduledoc pins "knows nothing about
  formats"), so the move threads the format and telemetry opts into the
  clamp call (both dialects already pass `config` there; the framework passes
  its opts) and revises that moduledoc note. The framework's event metadata
  stays key-for-key identical.
- `[:output, :negotiate]`: span moves from `DeliveryBuild.resolve_output/4`
  (delivery_build.ex:324-332) into a **shared negotiate helper** that
  encloses *both* legs of the framework's current span — `Policy.resolve` and
  the `:needs_final_image_alpha` second resolution (delivery_build.ex:335-346)
  — with stop metadata built from the final resolved output. Wrapping bare
  `Policy.resolve/2` is not the seam: it takes no opts (no telemetry prefix
  can reach it) and would change framework stop metadata on the alpha path.
  Framework byte-stability guard: telemetry_test.exs:209-213 pins the
  negotiate stop metadata (and :724-757 the input-color-management metadata)
  and must stay green unchanged.
- `[:transform, :input_color_management]`: span moves from the framework-only
  `Executor.seed_color_management/2` (executor.ex:92-94) into shared
  `InputColorManagement.condition/2`, which both dialects call directly
  (imgproxy pipeline.ex:320-327, native pipeline.ex:169).
- `[:transform, :materialize]`: already emitted by shared
  `Transform.Materializer` (materializer.ex:37, 83). The framework guarantees
  it via the delivery backstop `Processor.materialize_for_delivery/2`
  (processor.ex:300-316); the dialects go clamp → encoder with no backstop.
  Give the dialect build path the equivalent materialize backstop so the span
  (and the guarantee it represents) matches.

**Fix — dialect-emitted spans (framework-only orchestration, each dialect
mirrors):**
- `[:send]`: wrap each dialect's terminal `Sender.send_result`/`Errors.send`
  calls, with `%{result:, status:}` stop metadata mirroring
  `send_stop_metadata/2` (plug.ex:211-216). No ordering hazard: `[:deliver]`
  nests inside it in shared `Response.Sender`, and both run in the
  connection-owner process.
- `[:source, :fetch_decode]`: wrap the dialect's `Decode.with_image` fetch+
  decode path (imgproxy.ex:729-740) with the framework's stop-metadata shape.
- `[:transform, :execute]`: wrap `Pipeline.run/4` with
  `%{operations:, operation_count:}` start metadata as at processor.ex:159-167.
- `[:encode]`: wrap `Encoder.stream_output` **and force the first chunk inside
  the span**, as `DeliveryBuild.encode_first_chunk/3` does
  (delivery_build.ex:114-128). This is the one behavioral change in B3: the
  dialects currently hand a fully lazy stream to `pump`, so encode errors
  surface later and the span would otherwise measure nothing. Forcing the
  first chunk inside the span is required for honest timing and matches where
  the framework surfaces encode failures. Flagged as B3's highest-risk edit;
  the error-path wire cases and `error_paths_test.exs` must stay green on
  both arms.

**Pins and surfaces to update in the same change:**
- `ImgproxyTelemetryStageSetTest`: `@framework_only` shrinks to `[]`; the
  dialect≡native sequence-equality assertion stays and now proves lockstep.
- `imgproxy_telemetry_contract_test.exs`: `@shared_stages` grows by the new
  shared stages; the pinned-divergence prose in the moduledoc is deleted.
- Subscription surfaces need **no list changes** — all 8 events are already in
  `Telemetry.Logger`'s `@group_span_events`/`@output_oneshot` and
  `Trace.Capture`'s `@span_stages`/`@oneshot_stages` (the framework already
  emits them). But `Capture.@safe_keys` should gain the currently-dropped,
  non-sensitive metadata keys on these events: clamp's
  `:source_dimensions`/`:dimensions`/`:limits`, input-color-management's
  `:working_space`/`:imported?`. These are dropped for the framework today
  too, so adding them additively changes framework OTel span attributes as
  well — deliberate, and owned by this item. Add a Capture test per the
  telemetry guidelines.
- `docs/telemetry.md`: emission-site prose for the relocated spans;
  the support matrix § Observability row closes.

### Wave-1 exit gate

`grep -c '@stack == :framework' test/image_pipe/imgproxy_wire_conformance_test.exs`
returns only the two prose mentions — **zero gated blocks; all 30
formerly-gated cases dual-run green**, each having been RED on the dialect arm
when un-gated; the suite's gate-convention comments (conformance:18, :4555)
are reworded to match. The support matrix § Dialect-stack divergences section
retains only: the deliberate cache-key/ETag cross-stack difference,
dialect-only `/info` caching, and the `[:parse, :stop]` `:result`-semantics
difference (the framework's `[:parse]` span encloses `to_plan/2` where the
dialect's `check_geometry/1` runs after span close — no wave-1 item fixes it;
the row dies naturally in wave 2's one-stack rewrite). `mise run precommit`
green (with the `$(mise where elixir)/bin` PATH fix — plain `mise exec` hits
the Homebrew 1.19.3 shadow).

## Wave 2 — §A: retire `Parser.Imgproxy`

One-way step; lands only after the wave-1 gate (P1/P2). The `lib/` deletion is
small and self-contained; the bulk is test migration.

**Delete** (19 files): `lib/image_pipe/parser/imgproxy.ex` +
`lib/image_pipe/parser/imgproxy/**` (including `resolver.ex` — the dialect's
replacement carries the DPR/padding cap in a pipeline-local variable).
`ImagePipe.Plug` and `ImagePipe.Config` need **no code change**: the Plug is
fully parser-generic (`Keyword.fetch!(opts, :parser)`, plug.ex:72) and all
imgproxy-specific config machinery (signature, source-scheme, overlay
validation) lives inside the deleted tree. `ImagePipe.Plug` survives with two
live consumers (IIIF, TwicPics).

**Test migration** (the bulk):
- **Generic-parser re-pointing:** `plug_test.exs` (~80 occurrences of
  `parser: ImagePipe.Parser.Imgproxy`), `request_safety_test.exs`,
  `cdn_http_cache_wire_test.exs`, `telemetry_test.exs`, `cache_test.exs`,
  `request_options_test.exs`, the `telemetry/trace/*` suite — these test the
  still-shipping `ImagePipe.Plug` using imgproxy as the arbitrary parser.
  Re-point at `Parser.IIIF` or `Parser.TwicPics`; the assertions are about
  Plug behavior, not imgproxy grammar. Where a case genuinely depends on
  imgproxy grammar specifics, port it to the dialect suite instead.
- **White-box porting:** the ~236 `%Plan{}`-asserting tests
  (`imgproxy_test.exs`, `plan_builder_test.exs`, `imgproxy_property_test.exs`)
  port onto dialect `%Request{}` + `Pipeline` equivalents with **rewritten
  assertions** (the dialect has no `to_plan/2`), keeping only behavior no
  dual-run/wire/differential test already covers — per the tests-not-to-write
  rules, parity pins whose transition is complete are deleted, not ported.
- **Framework-arm drops:** the four `for {stack, suffix} <- …` suites
  (wire conformance, differential conformance, telemetry contract, grammar
  tests under `test/parser/imgproxy/`) drop the `{:framework, Framework}`
  tuple, the `:framework` dispatch clause, and the `FrameworkParser` alias;
  `translate_opts/1` flattens into the sole path.
  `imgproxy_cross_arm_body_test.exs` is **deleted whole** — its purpose is
  cross-arm comparison. The stage-set test's `stage_set_for(:framework)` case
  drops; dialect≡native equality remains.
- **Support-tree re-pointing:** `imgproxy_differential/harness.ex:21-27`
  loses its `:framework` clause; `mix imgproxy.gen_fixtures`'s
  `validate_parses!` (gen_fixtures.ex:16, 108) and
  `resolved_plan_cases.ex:24,78` repoint at the dialect.
  `source_inventory.ex` itself has no retired-module references.
- **`imgproxy_resize_auto_test.exs`** reworks off `Request.Runner` /
  hand-built `Source.Resolved` (phase-1 spec §Phase 2 item 5).
- **Architecture tests:** drop the module→file map entry
  (architecture_boundary_test.exs:88) and the `SourceScheme` export
  assertions (:136, :163). The rip-out AST matchers (:1467-1507) **stay** —
  their job is the namespace rule (core never names a concrete adapter,
  architecture_boundary_test.exs:690), and post-§A the `[:Imgproxy|_]`
  matchers usefully catch `Dialect.Imgproxy` leaking into core.

**Fiddle migration:** `build_imgproxy_opts/0`
(fiddle application.ex:84-103) drops `parser:`, hoists the `imgproxy:`
sublist to top-level (the wire suite's `translate_opts/1` transform), and
switches `ImagePipe.Plug.init/call` → `ImagePipe.Dialect.Imgproxy.init/call`
(here and in the `imgproxy.ex` web wrapper);
`imgproxy_source_mounts_test.exs:11` follows. IIIF and TwicPics mounts stay.

**Public API re-home:** `Parser.Imgproxy.encrypt_source_url/3` is documented
public API (`docs/imgproxy_path_api.md:112-117`). The dialect twin exists at
`dialect/imgproxy/source_encryption.ex:20`; give `Dialect.Imgproxy` a public
`encrypt_source_url/3` facade and update the docs.

**ExDNA / credo cleanup:** delete the transient copy-ignores in `.credo.exs`
(:159-188 list; prose :67-113) and `mise.toml` (:64-65, the `--ignore` chain
at :70) for the leaf structs, grammar modules, `Assembly`, `Config`
source-schemes, `Identity` helpers, `ResponseMeta`, `InfoRenderer` — then
**re-audit**: an entry is deleted only if the surviving file no longer
duplicates anything (some may still mirror native and need a re-justified
ignore). The #457-breadcrumbed ignores (`dialect/imgproxy.ex`,
`dialect/imgproxy/pipeline.ex`, `decode.ex`, `decode/source_format.ex`,
`native/pipeline.ex`, `response/conditional.ex`) survive (P9).

**Marker retirement** (phase-1 spec §Phase 2 item 6): `{:effective, …}` dies
from `plan.ex:363,392`, `plan/key_data.ex:209`, `plan/operation.ex:68,745,748`,
`plan/operation/padding.ex:13`. `ImagePipe.Resolver` survives (TwicPics).
Replace AGENTS.md's marker-accretion worked example (item 7).

**Docs:** reword the comment/prose references (`neutral_resolver.ex:18`,
`resize_planning.ex:9`, `config.ex:154`, the dialect files' "phase-1 copy of
the frozen…" moduledocs, and the `docs/*.md` prose list from the inventory);
update `imgproxy_support_matrix.md`'s "Two stacks serve imgproxy URLs"
section to one stack. Historical plan/spec records under `docs/superpowers/`
stay as-is.

## Wave 3 — C1: collapse the unobservable two-fallback distinction

After §A: the "padding falls back to request dpr / canvas falls back to 1.0"
distinction is unobservable (`resize_rule_requested?` includes `not
is_nil(dpr)`, so the fallback fires only when dpr is nil, where both are 1.0).
Simplify the dialect's carry to a single 1.0 fallback and correct the spec/doc
prose that describes a distinction that does not exist. Evidence: the
differential + wire suites stay green with zero pixel change (this is a
refactor, so no RED is expected — mutation evidence instead: making the
collapsed fallback return a non-1.0 value must turn dpr-nil padding/canvas
cases red).

## Out of scope

- **C2** (prepare-timeout through `stream/5`) — P8.
- **F / #457** (chain-helper promotion) — P9, rides with the TwicPics
  inversion.
- Migrating TwicPics or IIIF off the framework stack.
- Any differential fixture re-bake (P10).
- Richer CORS semantics than the framework's static echo (B2 note).

## Risks

- **B3's `[:encode]` first-chunk force** changes when encode errors surface on
  the dialect path. Mitigated by landing it as its own reviewed step with the
  error-path suites green on both arms, and by the wire suite's
  status/body assertions.
- **Un-gated tests that pass immediately.** A formerly framework-only case
  that is green on the dialect arm before its fix means the gap analysis was
  wrong somewhere — stop and investigate (it may be masking a weaker
  assertion, phase 1's most expensive bug class).
- **Generic-parser re-pointing weakening framework coverage.** IIIF/TwicPics
  don't exercise every Plug feature imgproxy did (signatures, presets,
  `/info`). Where plug_test.exs used an imgproxy-only surface, the case moves
  to the dialect suite rather than being re-pointed at a parser that can't
  express it.
- **The one-way step.** §A is deliberately last and gated (P1/P2); the
  reviewed wave-1 evidence is the rollback insurance — after §A, recovering
  the framework arm means reverting the branch, not repairing forward.

## Exit criteria (phase 2)

1. Wave-1 gate met: zero framework-only gates in the wire suite; all 30
   formerly-gated cases dual-run green with RED-before evidence per fix.
2. B1: object-guided crop pixels, class filter, objw weights, and detector
   model identity in the cache key verified on the dialect arm; detector
   identity computed once per request feeding both ETag and cache key.
3. B2/B5: CORS stamping on every dialect exit path; `OPTIONS` → 204 + `Allow`
   (+ `Access-Control-Allow-Methods` when configured); non-GET/HEAD → 405 +
   `Allow`; all dual-run.
4. B4/B6: host-set `max_result_*` and `output_capabilities` honored by both
   dialects; the dialect copies of `@default_max_result_*` are gone (single
   dialect source in `SharedConfig`; `Request.Options` keeps the framework's).
5. B3: `ImgproxyTelemetryStageSetTest`'s `@framework_only` is `[]`; dialect ≡
   native stage sequence holds; `@safe_keys` covers the newly reachable
   metadata; `docs/telemetry.md` synced.
6. §A: `lib/image_pipe/parser/imgproxy/**` deleted; all suites single-arm and
   green; fiddle serves imgproxy URLs through the dialect; ExDNA/credo
   ignores cleaned and re-audited; marker retired; `encrypt_source_url/3`
   re-homed; docs synced.
7. C1 landed with mutation evidence.
8. Differential fixtures byte-untouched across the whole phase (P10).
9. `mise run precommit` (and `precommit:fiddle` for the fiddle change) green;
   `fiddle/mix.lock`'s pre-existing modification never committed.
10. `docs/imgproxy_dialect_phase2_backlog.md` updated to record what closed
    where, and `imgproxy_support_matrix.md` § Dialect-stack divergences
    reduced to the deliberate differences only.
