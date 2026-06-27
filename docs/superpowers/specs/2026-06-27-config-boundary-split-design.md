# Spec: Split plan/output config into a neutral `ImagePipe.Config` boundary + dialect parity overlays

**Issue:** #418 — Split plan/output config into a neutral `ImagePipe.Config` boundary + dialect parity overlays
**Follow-up to:** #413 / PR #417 (neutral `Metric.target_range`/`direction`)
**Date:** 2026-06-27
**Status:** Approved design, ready for implementation planning

## Goal

Lift the product-neutral plan/output configuration out of the imgproxy adapter into a new
neutral `ImagePipe.Config` boundary, so the plan/output layer is host-tunable from one schema
and a drop-in provider (or ImagePipe's native request API) inherits sensible defaults **without
refactoring the imgproxy / IIIF / TwicPics adapters**. Each dialect's vendor-matching values
become a sparse **parity overlay** merged on top of the neutral defaults.

This establishes the extension seam ahead of the consumer, deliberately (per the drop-in-provider
principle). It is **not** a bug fix — every value is single-sourced today, so the lift is
behavior-preserving except for the one explicitly-flagged `jxl_effort` divergence (which is also
byte-neutral today; see §4/§7).

## Settled constraints (from #418, not relitigated here)

1. New `ImagePipe.Config` boundary, dep'd by `Parser.*`, `Output`, `Request` (no upward deps). It
   owns every product-neutral plan/output tunable + ImagePipe's default values + the shared value
   range checks (which use `Metric.target_range/1`). Metric-scoped (`target`, `allowed_error`) and
   search-wide (`min`/`max`/`format_*`/`max_resolution`) knobs are all keys in the *one* schema.
2. Seed neutral defaults with today's values → zero behavior change; the imgproxy overlay is empty
   today.
3. The imgproxy adapter keeps only its dialect-only keys (`signature`,
   `source_url_encryption_key`, `base64_url_includes_filename`, `source_schemes`, `presets`) + a
   parity overlay. Resolution chain: `neutral defaults → dialect overlay → host config → URL arg`
   (first three merge once at init; URL stays per-request).
4. `Metric` (intrinsic `target_range`/`direction`) stays — those are mathematical facts. Only
   tunable *defaults* move. The clean line is **intrinsic-fact vs tunable-default**.

## Decisions settled during brainstorming

- **`jxl_effort` default = 7, imgproxy overlay empty.** Neutral default `7` = libvips `jxlsave`
  default = today's bytes (zero behavior change). The imgproxy overlay stays empty in cut 1;
  `jxl_effort: 4` is the documented future byte-parity lever. The ImagePipe-7-vs-imgproxy-4
  divergence is documented in the support matrix. No differential re-bake.
- **Output reads the `jxl_effort` default from Config.** `Plan.Output.jxl_effort` is optional
  (`nil` = unset); Output's policy resolution fills it from `Config.default(:jxl_effort)`. This
  gives the native-API seam real teeth (a hand-built Plan inherits the neutral effort) and gives
  the `Output → Config` dep a genuine caller. `Request → Config` is declared as the permitted seam
  with no cut-1 caller (Boundary allows unused `deps:`).

## Grounding (verified against the codebase)

- The imgproxy adapter already *is* a single NimbleOptions schema (`@imgproxy_schema`,
  `lib/image_pipe/parser/imgproxy.ex:63-150`) commingling neutral tunables with dialect-only keys,
  with the layered map-merge already implemented (`merge_map_defaults/1`, `imgproxy.ex:208-212`).
  This is "split the existing schema," not invent new homes.
- Neutral tunables to move: `quality`, `format_quality`, `strip_metadata`, `keep_copyright`,
  `strip_color_profile`, `preserve_hdr`, `smart_crop_face_detection`, `auto_rotate`, and the
  `autoquality_*` family (`method`, `target`, `min_quality`, `max_quality`, `allowed_error`,
  `format_min_quality`, `format_max_quality`, `max_resolution`, `max_iterations`).
- New tunable: `jxl_effort` (1–9). ImagePipe sets no JXL effort today — `jxl_vix_suffix/1`
  (`lib/image_pipe/output/encoder.ex:179-182`) emits only `Q=`/`distance=`, so JXL inherits
  libvips `jxlsave`'s default effort (7).
- `Metric` lives at `ImagePipe.Plan.Output.QualitySearch.Metric`
  (`lib/image_pipe/plan/output/quality_search/metric.ex`): `target_range/1` (`:ssimulacra2 →
  {0,100}`, `:butteraugli → {0.0,25.0}`) and `direction/1`. No state struct.
- Boundary 0.10.4 does **not** flag declared-but-unused `deps:` — its `unused_dirty_xref`
  diagnostic targets the separate `dirty_xrefs:` list (`deps/boundary/lib/boundary/checker.ex:342`,
  `.../compile/boundary.ex:379`). So `Request → Config` may be declared ahead of its caller.
- Existing boundary deps: `Parser → [Format, Plan, Renderer]`; `Output → [Format, Plan,
  Telemetry]`; `Request → [Debug, Error, Format, MaterialDigest, Plan, Cache, Source, Output,
  Response, Renderer, Telemetry, Transform]`; `Plan → [Format]`. No `ImagePipe.Config` exists yet.

## Architecture

### Data flow today (unchanged shape)

```
host opts (imgproxy: [...])
  → Parser.Imgproxy.validate_options!/1   (init: validate + resolve neutral+dialect)
  → Options.parse / PlanBuilder           (URL args + resolved config → ImagePipe.Plan)
  → ImagePipe.Plan.Output                  (resolved intent)
  → Output.Policy.from_output_plan/resolve (per-request format negotiation → Output.Resolved)
  → Output.Encoder                         (encode/search; jxl_vix_suffix)
```

The neutral values flow into the Plan at parse time. `Config` sits below `Parser`, `Output`, and
`Request` as the shared owner of neutral defaults, schema, and range checks.

### Component 1 — `ImagePipe.Config` (new)

`lib/image_pipe/config.ex`:

```elixir
defmodule ImagePipe.Config do
  use Boundary, deps: [ImagePipe.Format, ImagePipe.Plan], exports: []
  alias ImagePipe.Plan.Output.QualitySearch.Metric
  # ...
end
```

**Owns** (all lifted verbatim from `imgproxy.ex`):

- Neutral default module attributes: `@default_quality 80`, `@default_auto_rotate true`,
  `@default_strip_metadata true`, `@default_keep_copyright true`, `@default_strip_color_profile
  true`, `@default_preserve_hdr false`, the autoquality scalars (`@default_autoquality_method
  :none`, `min 70`, `max 80`, `max_resolution 0`, `max_iterations 6`), the per-format/per-metric
  maps (`@default_format_quality %{webp: 79, avif: 63, jpeg_xl: 77}`,
  `@default_autoquality_format_min %{avif: 60, jpeg_xl: 45}`, `@default_autoquality_format_max
  %{avif: 65, jpeg_xl: 80}`, `@default_autoquality_target %{}`, `@default_autoquality_allowed_error
  %{}`), **plus the new `@default_jxl_effort 7`**.
- The neutral NimbleOptions schema (types + `default:`) for: `quality`, `format_quality`,
  `strip_metadata`, `keep_copyright`, `strip_color_profile`, `preserve_hdr`,
  `smart_crop_face_detection`, `auto_rotate`, and the `autoquality_*` family.
- **`jxl_effort` is the one schema entry that carries NO `default:`** — only `type: {:in, 1..9},
  required: false`. NimbleOptions *always* injects `default:` for an absent key, which would defeat
  the pass-through-`nil` contract (§Component 2 / §Component 4). The default value `7` lives solely
  in `@default_jxl_effort` and is surfaced via `Config.default(:jxl_effort)`.
- The shared range checks: `validate_quality_config!`, `validate_autoquality_brackets!`, the
  per-metric target check (leaning on `Metric.target_range/1` for the metric bands) and the
  allowed-error check. **Only the `target` check uses `Metric.target_range/1`**; `allowed_error`
  has no metric band — it keeps today's non-negativity-only check, restricted to
  `:ssimulacra2`/`:butteraugli` (no `:size`).
- The map-merge generalization of `merge_map_defaults/1`.

**Public API:**

- `schema/0 :: NimbleOptions.t()` — the neutral schema.
- `keys/0 :: [atom()]` — the neutral keys (adapters split neutral vs dialect opts with it).
- `default/1 :: term()` — the neutral default for a key (Output calls `default(:jxl_effort)`).
- `resolve!/2 :: (keyword(), keyword()) -> keyword()` — validate + apply the three-layer chain +
  range checks; returns concrete neutral values. Raises `ArgumentError` on invalid input.

`deps: [Format, Plan]` is downward-only (Plan deps only Format → no cycle). Exports nothing —
adapters call public functions; no struct crosses the boundary.

### Component 2 — Resolution / merge model

The chain `neutral defaults → dialect overlay → host config → URL arg`. The first three merge once
at init inside `Config.resolve!/2`; the URL layer stays per-request in the parser (unchanged).

`resolve!(host, overlay)` layers in order `defaults ← overlay ← host`:

- **scalar keys**: presence-based last-writer-wins — fold the layers with
  `Keyword.get(layer, key, acc_value)` (or a `Keyword.has_key?` check), **not** `value || acc`.
  Several lifted keys are booleans whose default is `true` (`auto_rotate`, `strip_metadata`,
  `keep_copyright`, `strip_color_profile`) and one is `false` (`preserve_hdr`); an `||` chain would
  silently discard a host-set `false` and collapse it to the default. Today's code already resolves
  presence-based (`Keyword.get(opts, :strip_metadata, @default)`, `imgproxy.ex:468`) — preserve
  that semantics exactly.
- **map keys** (`format_quality`, `autoquality_format_min_quality`,
  `autoquality_format_max_quality`, `autoquality_target`, `autoquality_allowed_error`):
  `Map.merge/2` onto the accumulated map, generalizing today's `merge_map_default` so a sparse
  override keeps the other formats' values across *all three* layers.

After layering, NimbleOptions type-validates the merged result and the lifted range checks run on
the **effective merged** values (checks see what resolution sees, as today). `resolve!` is
**idempotent** — re-running on an already-resolved keyword is a no-op — so both the
`validate_options!` and direct-parse paths funnel through it without double-applying.

**`jxl_effort` exception:** validated-if-present but **not** defaulted by `resolve!` — it passes
through host-set-or-absent. Its default is applied downstream by Output (§4, Component 4). Every
other neutral key keeps today's "defaulted at the config boundary" behavior, so the lift is
byte-for-byte behavior-preserving. `jxl_effort` is the deliberate worked example of an
*optional-at-Plan* knob whose default the consumer resolves; the existing knobs remain
parser-defaulted (this asymmetry is intentional and is the forward-preferred direction, not a
migration of the existing keys).

### Component 3 — imgproxy adapter (`ImagePipe.Parser.Imgproxy`)

Keeps **only** dialect keys in a shrunk `@dialect_schema`:

```elixir
@dialect_keys [:signature, :source_url_encryption_key, :base64_url_includes_filename,
               :source_schemes, :presets]

# Sparse parity overrides on top of neutral defaults. EMPTY today
# ("imgproxy parity == neutral defaults"); `jxl_effort: 4` is the documented
# future byte-parity lever, intentionally not set here.
defp imgproxy_overlay, do: []
```

`validate_options!` composition (`validate_imgproxy_options!/1`):

```elixir
{neutral, rest}    = Keyword.split(imgproxy_opts, Config.keys())
{dialect, unknown} = Keyword.split(rest, @dialect_keys)
unknown == [] or raise ArgumentError,
  "invalid imgproxy config: unknown keys #{inspect(Keyword.keys(unknown))}"

dialect = dialect |> NimbleOptions.validate!(@dialect_schema)
                  |> normalize_signature_and_encryption()   # existing dialect normalization
neutral = Config.resolve!(neutral, imgproxy_overlay())

Keyword.merge(neutral, dialect)
```

Neutral owns neutral rules; the adapter orchestrates and owns dialect rules (signature + source
encryption normalization stay in the adapter). Unknown-key rejection moves from NimbleOptions'
combined-schema behavior to the explicit `unknown` bucket — equivalent guarantee.

`request_defaults/1` (direct-parse path) routes its neutral subset through `Config.resolve!/2`,
deleting the duplicated default-application block (`imgproxy.ex:465-517`). Idempotency makes both
paths agree: if `validate_options!` ran, the stored opts are already resolved and `resolve!` is a
no-op; if not (direct parse), `resolve!` applies the defaults.

### Component 4 — `jxl_effort` end-to-end

- **`ImagePipe.Plan.Output`** (`lib/image_pipe/plan/output.ex`): add field `jxl_effort: nil`
  (`1..9 | nil`; nil = "use neutral default"). Update `@type t`. Moduledoc note: optional-at-Plan,
  consumer-resolved default (contrast the always-resolved `quality` etc.).
- **imgproxy parser → `PlanBuilder.output_plan/1`**: thread host-set `jxl_effort` (or `nil`) into
  `Plan.Output.jxl_effort`. No URL token — imgproxy `effort` is env-only — so no grammar change.
- **`Output.Policy`** (`from_output_plan` / `resolve`): effective effort =
  `plan_output.jxl_effort || Config.default(:jxl_effort)` (= 7). This is Output's genuine `Config`
  reference.
- **`Output.Resolved`** (`lib/image_pipe/output/resolved.ex`): add `jxl_effort: 1..9` (always
  concrete).
- **`Output.Encoder`** (`encoder.ex`): thread the resolved effort into both suffix shapes:
  - quality path: `.jxl[Q=N,effort=E]`; the `:default` quality case becomes `.jxl[effort=E]`.
  - native-distance path: `.jxl[distance=D,effort=E]`.

  The `:default` suffix becomes `.jxl[effort=7]` — **byte-identical** to today's `.jxl` because
  libvips `jxlsave` default effort *is* 7 (on the pinned libvips 8.18.2). Zero behavior change; the
  only divergence is from imgproxy's 4, documented in §7.

  **Threading is NOT a free field-read** — the leaf suffix builders take no `Resolved`. Concretely:
  - `jxl_vix_suffix/1` → `jxl_vix_suffix/2` (gains an `effort` arg).
  - `encode_jxl_buffer/2` → `/3` and `encode_jxl_distance/2` → `/3` (each gains an `effort` arg;
    they have only `image` + quality/distance in scope).
  - The `NativeJxlSearch` internal chain (`run/3` → `native_jxl_butteraugli/_` → `native_encode/_`
    → `native_descend/_` → `encode_jxl_distance`) currently **drops** `resolved`; carry
    `resolved.jxl_effort` (or `resolved`) down from `run/3`.
  - Call sites that already pattern-match `%Resolved{}` and *can* field-read: `encode_to_buffer/3`
    (search-leg encodes) and **`lazy_output/5`** — the **non-search** top-level JXL delivery path
    (`encoder.ex:67-78`, `encode_jxl_buffer(finalized, quality)`). **`lazy_output/5` MUST be
    threaded too** — it is the primary path for a plain JXL request; without it a default JXL
    request emits `.jxl[Q=N]` (libvips-default effort) while the search path emits effort=7, and the
    "byte-identical at 7" claim only holds because both paths end at effort 7. Add `jxl_effort` to
    its `%Resolved{}` pattern.
  - **Intentionally excluded:** `Output.Capabilities`' `.jxl` can-encode probe (`capabilities.ex`)
    stays plain — it is a capability check, not a delivery encode. Note this so a reviewer doesn't
    "fix" it.

### Component 5 — Cache key + ETag

`jxl_effort` changes which bytes get stored, so it is **storage identity** and must enter both the
cache key and the ETag — the exact precedent the `max_resolution`/per-format-clamp comment
establishes (`cache/key.ex:152-157`). The output key data is enumerated field-by-field
(`output_plan_data/2` `:automatic` + `:explicit` clauses, and the conn-variant `output_data/3`,
`key.ex:86-150`), so the field is **not** auto-included — add `jxl_effort: output.jxl_effort` to all
three. Confirm the ETag derives from this same canonical output data (it shares the plan material),
so the one edit covers both; if not, mirror it on the ETag path.

Omitting it would let a host `7→4` config change serve stale effort-7 bytes via a `304`/cache hit.

`jxl_effort` has **no URL form** (host-config only), so within a single deployment its Plan value is
uniform across all requests: a deployment either always has `nil` (effort unset) or always has the
host's explicit value. The `nil`-vs-explicit-`7` distinction (different key bytes, identical output)
therefore **cannot co-occur** in one deployment — there is no real cache split, and the key may
carry the raw Plan value (`nil` or concrete) without canonicalizing `nil → 7`. (The Plan boundary
can't reach `Config.default` anyway — `Plan` deps only `Format`; `Config` deps `Plan`. So `nil`
stays `nil` in the key, which is correct here.) Greenfield: reshape the key data in place; do not
bump a key data version.

**Drift guard (in scope).** Adding `jxl_effort` to the hand-enumerated `output_plan_data/2`/
`output_data/3` is exactly the step that is easy to forget for the *next* byte-affecting tunable.
Add a `Plan.Output` struct-field completeness test: every `Plan.Output` field is either present in
the canonical output key data **or** on an explicit, rationale-carrying excluded list (e.g.
`quality_search_offsets`, if it is in fact subsumed by the resolved search). The test fails when a
new field is added without a key decision — making the omission loud forever.

**Ownership note (deliberately deferred to a follow-up).** The real asymmetry is that **operations**
self-describe their key projection via `Plan.KeyData.data/1` (Plan boundary), while `Plan.Output`
is the lone artifact hand-enumerated inside `Cache.Key`. The clean fix is to relocate Output's
*intrinsic* byte-affecting projection onto `Plan.KeyData.data(%Output{})` (the request-negotiation
context — `auto_*`, `modern_candidates`, `mode` — stays in `Cache.Key`, since it is not a pure
function of the struct), colocating the field-vs-key decision with the model the way operations
already do. That is a behavior-neutral Cache/Plan refactor orthogonal to this Config split, so it is
**out of scope here** and tracked as a focused follow-up issue. This spec keeps the minimal
enumeration addition + the drift guard.

### Component 6 — Boundary wiring + architecture tests

- New `ImagePipe.Config` boundary, `deps: [Format, Plan]`, `exports: []`.
- Add `Config` to the `deps:` of the **top-level `ImagePipe.Parser`** boundary, `Output`, and
  `Request`.
  - **The genuine Config caller is `ImagePipe.Parser.Imgproxy`** (the adapter), a child
    sub-boundary of `ImagePipe.Parser`. Boundary unions a boundary's own deps with its ancestors'
    when checking references (`with_ancestors(... .deps)`, `checker.ex:294`), so declaring `Config`
    on the top-level `Parser` lets the adapter call `Config.*` **without** adding `Config` to the
    adapter's own `deps:`. This matches the issue's "`Parser.*`" framing and hands the same seam to
    the IIIF/TwicPics adapters for free (they may use neutral defaults later without a wiring
    change). Do **not** add `Config` to the imgproxy/IIIF adapters' own `deps:`.
  - Output gets a genuine caller (`Config.default(:jxl_effort)` in policy resolution). `Request →
    Config` is declared as the permitted seam with no cut-1 caller (verified Boundary-safe: unused
    `deps:` are not flagged).
- `test/image_pipe/architecture_boundary_test.exs`: register `ImagePipe.Config` in
  `@boundary_files`; assert its exact `deps`/`exports`; assert `Config` does **not** depend up into
  `Parser`/`Output`/`Request`/adapters; extend the dep assertions for the **top-level**
  `ImagePipe.Parser`, `Output`, and `Request` boundaries to include `Config`. **Leave the
  imgproxy/IIIF/TwicPics adapter dep assertions unchanged** (they reach Config via the ancestor and
  their own `deps:` stay Config-free).

## Error handling

- `Config.resolve!/2` raises `ArgumentError` with neutral, product-neutral messages on invalid
  config (out-of-range quality, inverted brackets, unknown metric, out-of-band target). These are
  init-time/configuration failures — raises are the right boundary behavior (per the architecture
  guidelines: reserve raises for invalid initialization/configuration).
- The imgproxy adapter raises its own `ArgumentError` (imgproxy-prefixed) for dialect-key failures
  and the unknown-key bucket; Config's neutral errors propagate as-is. Per the test guidelines, we
  do not pin exact private error strings — tests assert that invalid config is rejected, not the
  wording.
- Runtime (per-request) behavior is unchanged: `jxl_effort` is a concrete value by the time it
  reaches the encoder; no new runtime error paths.

## Testing

- **Config unit** (`test/image_pipe/config_test.exs`): three-layer precedence (default ← overlay ←
  host); **a host-set boolean `false`/`true` override survives** (e.g. `strip_metadata: false`,
  `preserve_hdr: true`) — the regression guard for the presence-based-vs-`||` resolution; map-merge
  keeps untouched formats across all layers; range-check rejections (quality 1..100, inverted
  effective brackets, per-metric target band via `Metric.target_range`, non-negative allowed_error);
  `resolve!` idempotency; `jxl_effort` validated-but-not-defaulted (absent → absent, not `7`);
  `default/1`. Add StreamData property coverage for merge precedence + idempotency across input
  shapes (including booleans).
- **Adapter composition**: unknown-key rejection; neutral+dialect merge; the direct-parse path
  (opts **not** run through `validate_options!`) applies neutral defaults correctly. Frame this
  **behaviorally** (does the direct-parse path produce correct resolved values) rather than as a
  `validate_options!`-vs-direct-parse "they agree" identity — both funnel through `resolve!` after
  the refactor, so an "old path == new path" assertion is a post-migration parity pin and is
  forbidden (per CLAUDE.md "Tests not to write"). Relocate the existing imgproxy config tests that
  move with the keys; leave **no** parity pins behind.
- **`jxl_effort` wire/pixel** (`imgproxy_wire_conformance_test.exs` or a focused output test): an
  imgproxy JXL request decodes/encodes byte-identically at the default (effort 7) — covering **both**
  the non-search `lazy_output/5` path and a search path; a host `jxl_effort: 4` override produces
  different bytes; the native-distance JXL path carries effort. Assert the suffix shape at the
  encoder boundary.
- **Cache key/ETag** (extend `cache/key` tests): a `jxl_effort` change yields a different key + ETag
  (no stale `304`); `jxl_effort` is present in the canonical output key data.
- **`Plan.Output` key-data drift guard** (Component 5): a completeness test asserting every
  `Plan.Output` field is in the canonical output key data or on an explicit excluded-with-rationale
  list. Fails loudly when a future byte-affecting field is added without a key decision.
- **Boundary** test as Component 6.
- Gates: `mise run precommit` (format, compile --warnings-as-errors, credo --strict, test). The
  imgproxy differential suite runs on the default `mix test` lane and stays green with no re-bake
  (JXL bytes unchanged).

## Documentation — `docs/imgproxy_support_matrix.md`

- **Surface axis** (Configuration options section): note the neutral plan/output tunables now live
  in `ImagePipe.Config`, with **"imgproxy parity == neutral defaults today"** (empty overlay); add
  a `jxl_effort` row (host config, range 1–9).
- **Behavioral axis** (Save/encode row, currently "effort still has no ImagePipe knob" — matrix
  line 149): update to record the new knob and the **divergence** — ImagePipe default **7** vs
  imgproxy **4** (`IMGPROXY_JXL_EFFORT`, `vips/config.go`) — with the empty-overlay rationale and
  `jxl_effort: 4` as the future byte-parity lever. Attribute the `7` to **libvips' current
  `jxlsave` default** (not a hard ImagePipe invariant) so the "seed 7 = byte-neutral" claim stays
  re-checkable across libvips upgrades. This edit **must land in the same change** so "empty
  overlay" is never misread as "ImagePipe JXL output matches imgproxy today" — it does not: once
  both are wired, ImagePipe ships effort 7 and imgproxy 4, so the bytes differ.

## Out of scope / non-goals

- Not a bug fix; no internal drift exists today. This is the extension seam.
- The grammar lexer's URL-token bounds (`:target_float` 100.0, `:target_distance` 25.0) are a
  separate dialect-URL-token concern.
- Migrating the existing neutral defaults (quality, autoquality, …) to consumer-resolved
  application like `jxl_effort` — `jxl_effort` is the lone worked example; the rest stay
  parser-defaulted.
- IIIF / TwicPics adapter changes — the whole point is they need none.
- **Relocating `Plan.Output`'s cache-key projection** out of `Cache.Key`'s hand-enumeration onto
  `Plan.KeyData.data(%Output{})` (matching the operations pattern) — a behavior-neutral Cache/Plan
  refactor orthogonal to the Config split. Tracked as a focused **follow-up issue**; this spec adds
  only the `jxl_effort` enumeration entry + the `Plan.Output` field drift guard (Component 5).

## Execution recommendation

Roughly-mechanical schema split plus one threaded tunable; tasks form a sequential dependency
chain across a few shared files (`config.ex`, `parser/imgproxy.ex`,
`parser/imgproxy/plan_builder.ex`, `plan/output.ex`, `output/policy.ex`, `output/resolved.ex`,
`output/encoder.ex`, the architecture test, the support-matrix doc). Lean toward **inline TDD
execution + one final parallel review of the complete diff** over subagent-per-task: the handoffs
would add overhead without parallelism, and incremental TDD catches the parser→Plan→Output
threading bugs faster than per-task review round-trips. The final review must include a
**compatibility reviewer** focused on observable imgproxy behavior (against the local checkout at
`/Users/hlindset/src/imgproxy` and docs at `/Users/hlindset/src/imgproxy-docs`), since this touches
the imgproxy config surface and `jxl_effort` is a behavioral divergence.

## Plan-review cycle (per AGENTS.md, before implementation)

Run a parallel subagent review of this spec with disjoint lenses; at least one **must** focus on
observable imgproxy compatibility (config surface + `jxl_effort`). Apply accepted feedback, rerun
doc checks, and commit the reviewed spec before any code.
