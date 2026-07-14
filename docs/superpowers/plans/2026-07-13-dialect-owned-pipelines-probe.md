# Dialect-Owned Pipelines Probe — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `ImagePipe.Dialect.Native` — the first inverted, self-contained Plug pipeline (probe subset of the native URL dialect) — alongside the untouched framework stack, extracting core stage helpers and the first contract kits demand-driven, and produce the probe's measured exit-criteria report.

**Architecture:** The dialect is literally a Plug that owns its whole request chain: verify signature → parse to a canonical request → resolve source identity → negotiate → build representation identity (key/ETag/Vary via a new core `Representation` builder) → conditional check → cache lookup → fetch/decode through new core brackets → plan geometry inline in the display frame (reusing `Lowering`/`ResizePlanning`/`Chain` — no resolver strategies, no `Directive`, no markers) → terminal (streamed image encode, or a complete-body BlurHash) → cache write → deliver. Two stress riders: an ordered-planning spike (test-only) and the pixel-tapping terminal with terminal-aware decode planning.

**Tech Stack:** Elixir, Plug, Vix/libvips via the `image` dependency (bumped 0.69 → 0.71 for `Image.Blurhash`/`Image.Lqip.Css`), ExUnit + StreamData, Boundary, NimbleOptions. All commands run through `mise exec -- …`.

**Specs (read before any task):**
- `docs/superpowers/specs/2026-07-13-dialect-owned-pipelines-design.md` — architecture, responsibility split, enforcement model, probe rules and exit criteria. Cited below as **[pipelines]**.
- `docs/superpowers/specs/2026-07-12-native-url-dialect-design.md` — the wire grammar, option vocabulary, semantics, signing, probe subset. Cited below as **[native]**.

## Global Constraints

- **Parallel stacks.** The framework path (`ImagePipe.Plug`, `Parser.*`, `Request.*`, `Resolver`, `Renderer`) is not modified beyond widening core exports the probe needs. No dialect migrates. New core modules are additions; existing framework call paths keep their behavior (pinned by the existing suite, including the imgproxy + TwicPics differential suites on the default `mix test` lane).
- **Dependency direction (acid test).** `ImagePipe.Dialect.Native → core` only. Core never names the dialect; the dialect never reaches into `Parser.*`, `Request.*` internals, `Resolver`, or `Renderer`. Enforced by Boundary + architecture tests (Task 2).
- **Probe subset only** [native §Probe subset]: `w`, `h`, `fit`, `enlarge`, `crop`, `region`, `anchor`, `focus`, `blur`, `trim`, `pad`, `bg`, `then`, `output` (`image` + `blurhash`), `format`, `q`, `src`, `src64`, signing + `expires`, presets only as far as canonicalization testing needs. Nothing else parses (unknown key ⇒ 400). No `dpr`/`zoom`/`extend`/`rotate`/`flip`/`orient` in the probe (defaults apply: `dpr=1`, `orient=auto`).
- **Demand-driven extraction.** A helper graduates to core only because a probe task needs it. Duplication inside the dialect first is allowed and sometimes chosen deliberately (the delivery session/producer, Task 15).
- **TDD.** Every task starts from failing tests. Wire-level tests make real `Dialect.Native.call/2` requests and assert user-visible contracts.
- **Safety boundaries preserved**: all parse/validation failures return before source identity resolution, cache access, or source fetch; signature failures (403) before parsing; `max_body_bytes` enforced inside fetch, `max_input_pixels` inside decode.
- **Telemetry discipline** (AGENTS.md): the dialect reuses the standard stage names. Any new event or new span metadata key must update, in the same task: `ImagePipe.Telemetry.Logger` lists/rendering, `Telemetry.Trace.Capture` `@span_stages`/`@oneshot_stages`/`@safe_keys`, `docs/telemetry.md`, and tests for both surfaces.
- Gates before finishing: `mise run precommit`. Worktree quirks: run everything via `mise exec -- …`; if the toolchain misbehaves prepend `$(mise where elixir)/bin` to `PATH`; a dangling `.credo.exs` symlink breaks `mix format --check-formatted`.
- Commit after every green task. Do not run `mix imgproxy.gen_sources` or re-bake differential fixtures in this plan.

---

## Design Reference (read before any task)

### The visible chain (target shape of `Native.call/2`)

```elixir
def call(conn, config) do
  with {sig, signed_path} = Path.split_signature(conn),                # raw byte split ONLY — no lexing
       {:ok, key_index} <- Signature.verify(sig, signed_path, config), # 403 before ANY parsing/decoding
       {:ok, lexed} <- Path.extract(conn),                             # full lexing, spans, decoding — post-verify
       {:ok, request} <- Parser.parse(lexed, config),                  # canonical %Native.Request{} | {:invalid, diagnostics}
       :ok <- check_expires(request),                                  # 404 on past expires
       {:ok, plan_source} <- Source.translate(request.source, config),
       {:ok, resolved} <- ImagePipe.Source.resolve(plan_source, config, source_runtime_opts),
       {:ok, negotiation} <- negotiate(conn, request, config),         # selection + vary? + policy_material (Task 10 owns the shape)
       representation = ImagePipe.Representation.build(resolved.identity, Identity.material(request, negotiation, conn, config)) do
    if Conditional.not_modified?(conn, representation.etag),
      do: send_304(conn, representation),
      else: serve(conn, request, resolved, negotiation, representation, config)
  else
    {:error, ...} -> Errors.send(conn, ...)                            # dialect-owned status mapping
  end
end

defp serve(conn, request, resolved, negotiation, representation, config) do
  case Cache.lookup_entry(representation.cache_key, config) do
    {:hit, entry} -> deliver_cache_hit(conn, entry, representation, config)
    _miss_or_disabled -> generate(conn, request, resolved, negotiation, representation, config)
  end
end
```

`generate/6` branches on the terminal: `:image` → streamed encode via the dialect-owned delivery session (Task 15); `:blurhash` → complete body (Task 17). Both run fetch/decode through the core brackets (Task 12).

### New core surfaces introduced by this plan

| Module | Boundary | What |
| --- | --- | --- |
| `ImagePipe.Representation` (+ `.IdentityMaterial`) | new top-level boundary, deps `[ImagePipe.Cache, ImagePipe.MaterialDigest]` | `build(source_identity, material) → %Representation{cache_key :: Cache.Key.t(), etag, vary}`; core execution-identity injection; typed `storage_inputs` helper. Accepts only pre-fetch material — no API exists that builds key/ETag from fetched bytes. |
| `ImagePipe.Cache.lookup_entry/2` | widening of `ImagePipe.Cache` | Key-first lookup: `lookup_entry(%Key{}, opts) :: {:hit, Entry.t()} \| {:miss, %Key{}} \| {:miss, %Key{}, {:cache_read, term()}} \| :disabled`, `[:cache, :lookup]` span, fail-open on read errors — same semantics as the framework's Plan-coupled `lookup/4`, minus the Plan. |
| `ImagePipe.Response.Conditional` | widening of `ImagePipe.Response` | Pure `not_modified?(conn, etag)` — If-None-Match parsing + weak-entity comparison extracted (duplicated, framework untouched) from `Request.HTTPCache`'s private helpers. |
| `ImagePipe.Source.with_fetched/3` | widening of `ImagePipe.Source` | Bracket: resolve→fetch span, `wrap_response/2` limits, error normalization `{:source, _}`, guaranteed no leaked stream on non-local exit. |
| `ImagePipe.Decode` | new top-level boundary, deps `[ImagePipe.Error, ImagePipe.Format, ImagePipe.Plan, ImagePipe.Source, ImagePipe.Telemetry, ImagePipe.Transform]` | `with_image(resolved, opts, decode_request_fun, fun)` bracket: fetch (via `Source.with_fetched`) → format sniff → header geometry → caller-supplied `%DecodePlanner.Request{}` → sequential open with shrink → `max_input_pixels` → seeded `Transform.State` + `%SourceGeometry{}`. Failures normalize to `{:decode, _}` (→ 415) / `{:input_limit, _}` (→ 413). Logic duplicated from `Request.Processor` (framework untouched). |
| `ImagePipe.Transform.SourceGeometry` | widening of `ImagePipe.Transform` | `%SourceGeometry{storage_dimensions, display_dimensions, pending_orientation, source_format}` + `planning_frame(geometry, auto_rotate?) :: {w, h}` [pipelines §Source-dependent planning]. |
| `ImagePipe.Transform.DecodePlanner.Request` + `DecodePlanner.open_options_for/5` | widening of `ImagePipe.Transform` | Defunctionalized decode-plan input (no semantic op chain needed): `%Request{resize_target, crop_extent, trim?, terminal_reduction}`. Terminal-aware shrink (#377). Existing `open_options/5` untouched. |
| `ImagePipe.Output.Policy.identity_selection/1` | widening of `ImagePipe.Output` | Public pure pre-fetch selection over an exported `%Policy{}`: `{:explicit, format} \| {:auto_head, format} \| :source_negotiated`. Owned by core so dialect identity cannot drift from what `Policy.resolve/2` encodes — pinned by an agreement property test (Task 15). |
| `ImagePipe.Output.Policy.identity_material/1` | widening of `ImagePipe.Output` | Public canonical keyword of the **effective, config-resolved** byte-affecting policy, read off the same `%Policy{}` that later drives `resolve/2` and encode: quality, `default_quality`, format_qualities, quality_search (canonicalized) + `quality_search_offsets`, max_bytes, strip_metadata, keep_copyright, color_profile, hdr, flatten_background, encoder_options. Deliberately EXCLUDES `mode`/`modern_candidates`/`headers` — negotiation enters identity only as the selection outcome. Identity therefore describes the effective policy after any host configuration is applied, not merely the parsed URL policy. |
| `ImagePipe.Output.Terminal.Blurhash` | widening of `ImagePipe.Output` | The shared terminal computation [pipelines §Design principles 4]: `compute(image) :: {:ok, String.t()} \| {:error, term}` (4×3, fixed sRGB/tone-mapped pixel space) + `identity() :: {:blurhash, 1}` for representation material. |
| `ImagePipe.ContractKit.CacheKey` / `ImagePipe.ContractKit.RequestSafety` | `test/support` only | `use`-macros generating the contract tests [pipelines §Enforcement model, layer 4]. |

### Native module map (all new files)

```
lib/image_pipe/dialect/native.ex                      ImagePipe.Dialect.Native — Boundary + Plug (init/1, call/2, the chain)
lib/image_pipe/dialect/native/config.ex               init-time config validation (NimbleOptions), raises
lib/image_pipe/dialect/native/value.ex                micro-syntax parsers (pure)
lib/image_pipe/dialect/native/path.ex                 raw path → sig / spanned segments / source tail
lib/image_pipe/dialect/native/option_spec.ex          declarative option table (probe subset)
lib/image_pipe/dialect/native/parser.ex               segments → validated groups → canonical request
lib/image_pipe/dialect/native/request.ex              canonical structs: Request, Request.Group, Request.Output
lib/image_pipe/dialect/native/diagnostic.ex           structured errors (byte spans into the raw path)
lib/image_pipe/dialect/native/diagnostic_renderer.ex  caret display (bounded)
lib/image_pipe/dialect/native/presets.ex              minimal preset expansion
lib/image_pipe/dialect/native/signature.ex            HMAC verify-before-parse, ordered key list
lib/image_pipe/dialect/native/source.ex               source string → ImagePipe.Plan.Source
lib/image_pipe/dialect/native/identity.ex             Identity.material/4 → Representation.IdentityMaterial
lib/image_pipe/dialect/native/negotiation.ex          %Negotiation{selected, vary?, policy_material, policy}
lib/image_pipe/dialect/native/pipeline.ex             groups → ops → Chain, inline measure steps, flush
lib/image_pipe/dialect/native/delivery.ex             dialect-owned session/producer → %Response.PreparedStream{}
lib/image_pipe/dialect/native/errors.ex               dialect-owned status mapping + diagnostic body
```

Tests mirror under `test/image_pipe/dialect/native/`, wire tests in `test/image_pipe/dialect/native_wire_test.exs` (+ per-topic wire files as listed per task).

### Canonical request structs (exact; later tasks depend on these names)

```elixir
defmodule ImagePipe.Dialect.Native.Request do
  @enforce_keys [:groups, :output, :source]
  defstruct groups: [], output: nil, source: nil, expires: nil
  # groups  :: [Request.Group.t()]  — `then` order, ≥ 1
  # output  :: Request.Output.t()
  # source  :: String.t()           — the decoded source string (src) / decoded src64 payload
  # expires :: pos_integer() | nil  — gate, not identity
end

defmodule ImagePipe.Dialect.Native.Request.Group do
  defstruct trim: nil,      # :auto | {color_rgb, tolerance :: number}
            region: nil,    # {x, y, w, h}     each :: {:px, number} | {:pct, number}
            crop: nil,      # {w, h}           each :: {:px, number} | {:pct, number}
            guide: nil,     # {:anchor, atom} | {:anchor_smart} | {:focus, fx, fy}  (fx/fy 0.0–1.0)
            resize: nil,    # %{w: :auto | pos_integer, h: :auto | pos_integer,
                            #   fit: :contain | :cover | :cover_down | :stretch | :auto,
                            #   enlarge: boolean}
            blur: nil,      # float ≥ 0 (0.0 = Tier-1 identity, canonicalized to nil — see below)
            pad: nil,       # {top, right, bottom, left} px integers ≥ 0
            bg: nil         # {r, g, b, alpha :: float 0.0–1.0}
end

defmodule ImagePipe.Dialect.Native.Request.Output do
  defstruct terminal: :image,   # :image | :blurhash
            format: nil,        # nil (negotiate) | :avif | :webp | :jpeg | :png | :jpeg_xl
            quality: nil        # nil | 1..100
end
```

Canonicalization rules the parser must apply (property-tested in Task 5): within a group option order is irrelevant (struct fields make this structural); Tier-1 identity values (`blur=0`) normalize to the absent field; equivalent spellings normalize (`fff` ≡ `ffffff` ≡ `white` → the same `{255,255,255}` tuple; ratio never applies in the subset); **semantic defaults normalize to the concrete default value** (equality is the property, and it keeps the struct types nil-free): with a resize present, absent `fit` and explicit `fit=contain` both canonicalize to `fit: :contain`; with a guide consumer present, absent guide and explicit `anchor=center` both canonicalize to `guide: {:anchor, :center}` — so `/w=800` and `/fit=contain/w=800` yield equal `%Native.Request{}` (and later, identical identity) [native §Geometry semantics defaults]. The canonical value is pure data — no PIDs/refs/conn state [pipelines §Design principles 2].

### Representation identity (exact contract)

```elixir
defmodule ImagePipe.Representation.IdentityMaterial do
  @enforce_keys [:representation, :storage_only, :dialect_behavior, :vary_header_names]
  defstruct @enforce_keys
  # representation    :: keyword()            — canonical byte-affecting data, incl. the
  #                                             normalized negotiation outcome (the selection),
  #                                             never a raw header value
  # storage_only      :: keyword()            — cachebuster + configured storage-vary values
  # dialect_behavior  :: {module(), pos_integer()}
  # vary_header_names :: [String.t()]         — HTTP header names only
end

defmodule ImagePipe.Representation do
  @enforce_keys [:cache_key, :etag, :vary]
  defstruct @enforce_keys
  @core_execution_epoch 1   # successor of the transform key-data version for this stack

  @spec build(source_identity :: keyword(), IdentityMaterial.t()) :: t()
  # cache_key = %ImagePipe.Cache.Key{} over
  #   [representation_schema: 1, core_epoch: @core_execution_epoch,
  #    dialect: {module, epoch}, source_identity: ..., representation: ...,
  #    storage_only: ...]
  # etag = ~s("ipr1-" <> digest)  over the same data MINUS storage_only
  # vary = material.vary_header_names
  @spec storage_inputs(Plug.Conn.t(), [{:header, String.t()} | {:cookie, String.t()}]) ::
          {storage_only :: keyword(), vary_header_names :: [String.t()]}
  # headers contribute value→storage_only AND name→vary; cookies value→storage_only only.
  # Header names are normalized case-insensitively (lowercased), deduplicated, and
  # both outputs are deterministically ordered — identity material and Vary must not
  # depend on config list order or spelling.
end
```

Both digests go through `ImagePipe.MaterialDigest`. Dialects never concatenate key material. Negotiation enters as the selected variant (e.g. `{:image, :avif}` — the Task 10 selection outcome), never the raw `Accept` value [pipelines §Enforcement model 2].

### Native identity table (drives Task 10; verbatim from [native §Canonical form and identity])

| Input | Category |
| --- | --- |
| transform groups | `representation` |
| terminal: `:image`, or the terminal computation's identity (`Output.Terminal.Blurhash.identity()` → `{:blurhash, 1}`) | `representation` |
| the **effective output policy** — `Output.Policy.identity_material(policy)` over the same `%Policy{}` that later drives `Policy.resolve/2` and encode (carries `q` and, crucially, the effective defaults for quality/metadata/color/HDR/flatten/encoder options, so a default change — constructor or future host config — rides identity via the material, not luck) [native §identity table: "parsed output policy"] | `representation` |
| the selection outcome (`{:image, format}` from explicit `format` or negotiation head, or `:source_negotiated`; nothing for a fixed terminal) | `representation` |
| configured storage-vary values (`storage_inputs` config) | `storage_only` |
| source | separate `source_identity` (from `Source.Resolved`) |
| signature, matched key index, `expires` | neither (gates) |
| — (`cb`, `debug`, `filename`, `attachment` are outside the probe subset) | — |

### DecodePlanner typed request (Task 12)

```elixir
defmodule ImagePipe.Transform.DecodePlanner.Request do
  defstruct resize_target: nil,       # {w, h} display-frame px extent of the FIRST resize, or nil
            crop_extent: nil,         # {w, h} display-frame px crop extent before that resize, or nil
            trim?: false,             # a trim precedes the first resize → no shrink (dims redefined)
            terminal_reduction: nil,  # {w, h} terminal working frame (blurhash → {32, 32}), or nil
            required_extent: nil      # {w, h} MINIMUM loaded display-frame extent that must survive
                                      # decode — a floor, not a target (the ordered spike's preflight
                                      # speaks this field; forcing it into resize_target would misstate
                                      # semantics). Shrink is capped so loaded dims stay ≥ this floor.
end
```

`open_options_for(%Request{}, source_format, {src_w, src_h}, exif_quarter_turn? \\ false, auto_rotate? \\ false) :: keyword()` — always `[access: :sequential, fail_on: :error]` plus jpeg `shrink:`/webp `scale:` computed with the same math as today's `open_options/5` (crop-extent `MinNonZero` bound, block-IDCT powers of two): `trim?` → no shrink; `resize_target` present → it governs; else `terminal_reduction` governs (the #377 case: `/output=blurhash` with no resize still shrinks on load); neither → no shrink from those inputs. Independently, `required_extent` caps the chosen shrink so loaded dims never fall below the floor (applies whichever input governed). Quarter-turn axis swap identical to today.

### Toolkit facts (verified against the code, 2026-07-13; each task re-verifies its own call sites)

- `Chain.execute(state, ops, opts)` — **state first** — → `{:ok, State.t()} | {:error, {:transform_error | :materialize_error, term()}}`; per-op `[:transform, :operation]` spans; auto-materializes before ops whose `requires_materialization?/1` is true (`Trim`, `Rotate`).
- Semantic constructors + lowering (the display→storage compensation the dialect must NOT reimplement): `ImagePipe.Plan.Operation.resize/4 | crop_guided/4 | crop_region/5 | padding/5 | trim/1 | blur/1` build validated semantic structs. `NeutralResolver.resolve(shape, nil, plan_op) :: {[executable_ops], continuation}` and `NeutralResolver.continue(tag, {w, h}, shape, nil)` are directly callable, stateless (`nil` state), and own the whole deferred-orientation policy (resize-with-pending → compensated tail + `%Flush{}`), trim pending classes, and ±1 measure handling — the continuation is plain data (`{:advance, shape, nil} | {:measure, tag, nil}`, post-#451). Verified mechanics: `ResizePlanning.lower/3` (via `Lowering`) returns a flat `[resize | tail]` list whose tail `%Crop{}` resolves its rect against the *live* image at execute time — measured dims feed only the shape advance (`Crop.resolved_box_dims/3`), never a re-parameterization of the tail op. `Lowering`, `ResizePlanning`, `NeutralResolver` are all exported from `ImagePipe.Transform`.
- `SourceShape`: `@enforce_keys [:width, :height, :frame]` + `pending_orientation`, `decode_shrink`; `seed/1` starts `frame: :storage`. `PendingOrientation.from_exif/2`, `display_dims/2`, `identity?/1`, `quarter_turn?/1`. Flush op: `%Transform.Operation.Flush{}`.
- `NeutralResolver.resolve_mode/2` is public — the promoted `fit=auto` fill-vs-fit rule (#448); the dialect calls it rather than restating the rule.
- Encode/negotiate: dialect builds a `%Plan.Output{}` (fields: `mode: :automatic | {:explicit, fmt}`, `quality: :default | {:quality, n}`, rest defaults) → `Output.Policy.from_output_plan(conn, output, opts)` → `Policy.ensure_capable/2` → (post-decode) `Policy.resolve(policy, source_format)` → `Output.Clamp.clamp` → `Output.Encoder.stream_output(vips_image, %Output.Resolved{}, opts)` → `{:ok, enumerable, content_type, search_meta}`. `Policy.automatic_headers/0` supplies `{"vary","Accept"}`.
- Cache: adapter callbacks `get/2`, `open_sink/3`, `write_chunk/3`, `commit_sink/2`, `abort_sink/2`; coordinator `Cache.open_sink(%Key{}, %Output.Resolved{}, opts)` already takes a prebuilt key; `Cache.lookup/4` is Plan-coupled (hence `lookup_entry/2`). Sink is fail-open.
- Delivery: `%Response.PreparedStream{}` (`@enforce_keys [:first_chunk, :content_type, :headers, :next, :cancel, :resolved_output]`) and `Response.Sender.send_result/3` shapes `{:ok, {:cache_entry, entry, %Plan.Response{}, %CacheHeaders{}, hit_debug}}` / `{:ok, {:prepared_stream, prepared, %Plan.Response{}, %CacheHeaders{}}}` are exported and reusable; `%CacheHeaders{representation_headers, headers, etag}`. Client disconnect: `Sender` calls `prepared_stream.cancel.()`.
- Errors: `Response.ErrorStatus.resolve_status/2` + `classify/1` give the normalized taxonomy; the dialect owns final status mapping [pipelines §A dialect].
- Signing template: `Parser.Imgproxy.Signature` — `:crypto.mac(:hmac, :sha256, key, payload)`, `Plug.Crypto.secure_compare/2`, unpadded url-b64. Native differs: no salts, ordered `keys` list, MAC over the raw mount-relative path after the sig segment, exactly 43 chars.
- Wire-test rig: `conn(:get, path) |> Dialect.Native.call(Dialect.Native.init(opts))`; sources via `ImagePipe.SourceTest.RootHTTPAdapter` with `req_options: [plug: OriginImage]`; instrumented `OriginShouldNotFetch`, `CountingOriginImage`, `CacheProbe` (test/support) for reject-never-touches-source and cache-order assertions; oriented EXIF fixtures via `OrientedFrameOrigin`/`Orientation1TwinOrigin`.
- Architecture test: `test/image_pipe/architecture_boundary_test.exs` keeps a `@boundary_files` registry and exact `assert_boundary_deps/exports`; the "parser output stays semantic" grep must NOT be extended to the dialect directory (deliberate reversal [pipelines §Seam map]).

### Decisions locked here (reviewers: challenge these, implementers: don't relitigate)

1. **Terminal choice: `blurhash`** (4×3 components fixed, `Image.Blurhash`, working frame ≈32px for the decode hint). `lqip` lands post-probe.
2. **`on_inert_option`:** probe implements the default `:reject` only. The `:ignore` mode + its telemetry event land post-probe (avoids new telemetry surface during the probe). Config key exists and accepts only `:reject` (raise on `:ignore` with "not yet implemented").
3. **Presets minimal:** named single-group presets + `default` preset, **group-scoped options only**, strict precedence chain, unknown-preset 400, cache-key transparency. Override families, disable pruning, request-scoped preset keys, and multi-group presets land post-probe.
4. **`pad` fill:** transparent `{0,0,0,0.0}`; a `bg` in the same group flattens after padding (stage 21). Encode-time flatten covers opaque formats.
5. **Delivery duplication:** the dialect gets its own simplified session/producer (`Native.Delivery`) modeled on `Request.SourceSession`/`Producer`, producing a `%Response.PreparedStream{}`. Generalizing the framework's Producer is post-probe (recorded in the core-exports report instead).
6. **`q` maps to `%Plan.Output{quality: {:quality, n}}`**; autoquality/`format-q`/encoder options are outside the subset, so `quality_search: :none` and defaults apply.
7. **Signing config:** `keys: ["<hex>", ...]` (ordered, first signs), no salts. `sig=` on a keyless instance is a 400 (unknown-segment diagnostic with a specific message), keys configured + missing/invalid sig → 403 terse body.
8. **Resize-intent inertness:** resize intent = at least one concrete (non-`auto`) px dimension. `fit` and `enlarge` require it; a lone or doubled `auto` dimension is inert (400). Extends the spec's Tier-2 table where it is silent; reflect into the spec post-probe.
9. **Terminal computations are core toolkit** (`Output.Terminal.Blurhash.compute/1` + `identity/0`); the identity tuple enters `representation`, so terminal behavior changes reach key + ETag.
10. **Identity reads the effective output policy**, not just `q`: `Output.Policy.identity_material/1` + `identity_selection/1` over the SAME `%Policy{}` that later drives `resolve/2` and encode — core-owned, so dialect identity cannot drift from encode behavior, and any future host policy knob rides identity automatically.
11. **Task 14 is transitional (Choice A):** the probe tests dialect-owned request orchestration over the retained neutral geometry compiler; mirror/continuation collapse is a separate post-probe decision informed by report section 7.

### Fixed stage order within a group (probe subset of [native §Pipeline groups])

trim(3) → region/guided crop(4) → resize(5) → cover result crop(6) → blur(7) → pad(20) → bg flatten(21). A non-image terminal's internal reduction runs after the last group.

---

### Task 1: Bump `image` 0.69 → 0.71 in isolation

The two terminal computations delegate to `Image.Blurhash` and `Image.Lqip.Css` (landed in image 0.71.0). Bump alone, prove the differential suite is clean on the bump alone, commit alone — any pixel drift must be attributable to this dep change and nothing else.

**Files:**
- Modify: `mix.exs` (line 144: `{:image, "~> 0.69"}` → `{:image, "~> 0.71"}`)
- Modify: `mix.lock` (via mix)

**Interfaces:**
- Produces: `Image.Blurhash.encode/2` and `Image.Lqip.Css.encode/1` available to Task 17.

- [ ] **Step 1: Bump the requirement**

In `mix.exs` change `{:image, "~> 0.69"},` to `{:image, "~> 0.71"},`.

- [ ] **Step 2: Update the lock**

Run: `mise exec -- mix deps.update image`
Expected: lock moves to `image 0.71.0` (transitives may follow). If vix recompiles and `.jxl` tests later fail, rebuild vix with `VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS` (Homebrew libvips) — see memory note.

- [ ] **Step 3: Verify the delegates exist**

Run: `mise exec -- mix run -e 'true = function_exported?(Image.Blurhash, :encode, 2); true = function_exported?(Image.Lqip.Css, :encode, 1); IO.puts("ok")'`
Expected: `ok`. (Adjust arity assertion to what 0.71 actually exports; record the real arities for Task 17.)

- [ ] **Step 4: Full suite on the bump alone**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`
Expected: green, including `imgproxy_differential_conformance_test.exs` and `twicpics_differential_conformance_test.exs`. If a differential fixture regresses, STOP — diagnose per `test/support/image_pipe/test/imgproxy_differential/README.md` (skew vs structural) before touching tolerances; do not re-bake.

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock
git commit -m "deps: bump image 0.69 -> 0.71 (Image.Blurhash, Image.Lqip.Css)"
```

---

### Task 2: Dialect skeleton, Boundary, architecture tests

**Files:**
- Create: `lib/image_pipe/dialect/native.ex`
- Create: `lib/image_pipe/dialect/native/config.ex`
- Modify: `test/image_pipe/architecture_boundary_test.exs` (registry + new describe block)
- Test: `test/image_pipe/dialect/native_test.exs`

**Interfaces:**
- Produces: `ImagePipe.Dialect.Native.init/1` (validates config, raises on invalid), `call/2` (returns 501 "not implemented" for now on any path — replaced task by task), Boundary declaration below.

```elixir
defmodule ImagePipe.Dialect.Native do
  use Boundary,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Decode,            # added in Task 12 (comment out until then)
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Representation,    # added in Task 9 (comment out until then)
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: []

  @behaviour Plug
end
```

Note the deliberate absences: `ImagePipe.Parser`, `ImagePipe.Request`, `ImagePipe.Resolver`, `ImagePipe.Renderer`, `ImagePipe.Config`.

Config schema (NimbleOptions, `Native.Config.validate!/1`, raise on invalid): `keys :: [String.t()]` (hex, default `[]`), `presets :: %{String.t() => String.t()}` (default `%{}`), `on_inert_option :: :reject`, `storage_inputs :: [{:header, String.t()} | {:cookie, String.t()}]` (default `[]`), plus the shared runtime keys the toolkit consumes, validated by delegating: `ImagePipe.Cache.validate_config!/1`, `ImagePipe.Source.validate_config!/1`, and defaults for `max_body_bytes` (10_000_000), `max_input_pixels` (40_000_000), `telemetry_prefix`, `auto_avif`/`auto_webp`/`auto_jpeg_xl`, `format_order`.

- [ ] **Step 1: Write failing tests** — `init/1` raises on unknown option and non-hex key; `init/1` returns validated config for `[]`; `call/2` on any GET returns 501; architecture test additions:
  - registry entry `ImagePipe.Dialect.Native => "lib/image_pipe/dialect/native.ex"` in `@boundary_files`
  - `assert_boundary_deps(dialect_native, [...])` exactly as above (minus the two commented-out boundaries until their tasks land)
  - core-never-names-dialect: extend the `@parser_forbidden_globs` mechanism with a dialect grep — zero references to `ImagePipe.Dialect` in plug/request/source/response/cache/output/plan/transform/parser globs ("a dialect must be removable without changing the core")
  - the "parser output stays semantic" grep must not cover `lib/image_pipe/dialect/**` (assert the glob list, or simply that the new files don't trip it)
- [ ] **Step 2: Run tests, verify failure** (`mise exec -- mix test test/image_pipe/dialect/native_test.exs test/image_pipe/architecture_boundary_test.exs`)
- [ ] **Step 3: Implement skeleton + config validation**
- [ ] **Step 4: Green + `mise exec -- mix compile --warnings-as-errors` (Boundary check runs at compile)**
- [ ] **Step 5: Commit** — `feat(dialect): ImagePipe.Dialect.Native skeleton + boundary + architecture rules`

---

### Task 3: Value micro-syntax (`Native.Value`)

Pure parsers for [native §Value micro-syntax], returning `{:ok, value} | {:error, reason_atom}` (span attachment is the caller's job). One function per shape; exact behaviors:

- `number/1`: plain decimal, optional sign where the option allows it (callers pass allowed range).
- `length/1`: bare number → `{:px, n}`; `pct` suffix → `{:pct, n}`; anything else error. `80p` is an error.
- `dimension/1`: positive integer px or the keyword `auto`.
- `fraction/1`: 0.0–1.0 inclusive decimal.
- `color/1`: 3/6-digit bare hex or one of the 16 CSS basic names → `{r, g, b}`; no `#`.
- `pad_shorthand/1`: CSS 1–4 value px shorthand → `{top, right, bottom, left}` integers ≥ 0.
- `csv/3`: comma list with fixed arity range, element parser per position.
- Flags: bare = true; `key=false` = false; `key=true` = error `:true_spelled_bare` [native §Booleans].

**Files:** Create `lib/image_pipe/dialect/native/value.ex`; Test `test/image_pipe/dialect/native/value_test.exs`.

- [ ] **Step 1: Failing tests** — table-driven cases per parser: valid, invalid, boundary (0, negative, `0`-not-sentinel: `blur=0` parses as 0.0; `pixelate=0` style out-of-range errors don't apply in subset), all 16 color names, hex normalization (`fff` → `{255,255,255}`), pad shorthand expansion (1/2/3/4 values, CSS rules).
- [ ] **Step 2: Verify failure**  → **Step 3: Implement** → **Step 4: Green** → **Step 5: Commit** — `feat(dialect): native value micro-syntax parsers`

---

### Task 4: Path lexer (`Native.Path`)

Raw request path → structured, byte-spanned segments. Inputs come from `conn.request_path`/`conn.script_name` (raw, not `path_info`) [native §Byte-level contract].

**Interfaces (produces) — two surfaces, because verification must precede ALL parsing [native §Signing: "verify first, parse second, with zero scanning"]:**

```elixir
@spec split_signature(Plug.Conn.t()) :: {sig :: String.t() | nil, signed_path :: String.t()}
# RAW byte inspection only: strip the mount prefix (conn.script_name) from
# conn.request_path as a string prefix; if the first segment starts with "sig="
# return its value and the raw remainder from the following "/" to end of path;
# else {nil, whole_mount_relative_path}. NO segment validation, NO percent
# handling, NO source search, NO diagnostics — this runs before verification.

@spec extract(Plug.Conn.t()) ::
        {:ok, %{segments: [{raw :: String.t(), span}],   # option/then segments, spans into the raw path
                source: {:src | :src64, raw_tail :: String.t(), span}}}
        | {:error, [Diagnostic.t()]}   # Diagnostic defined in Task 6; until then a plain map with :reason and :span
# span :: {byte_offset, byte_length} into the mount-relative raw path
# Full lexing — called only AFTER Signature.verify succeeds (the chain enforces
# the order; a test in Task 8 pins it via the duplicate-slash case). It skips a
# leading sig segment internally but does NOT return signature data — the raw
# prefix has exactly one interpreter, split_signature/1.
```

Mount-prefix caveat (document in `Native`'s `@moduledoc` and test): `conn.script_name` is Plug's decoded segment list, not a byte-exact raw prefix, so stripping it from `conn.request_path` is byte-exact only when the mount path is canonical unescaped ASCII. `init/1` receives options, not a conn, so this CANNOT be an init-time check — validate at **runtime** (at the top of `call/2`/`split_signature/1`): a `script_name` segment that round-trips unequal through percent-encoding is host misconfiguration → raise (500-class), never a client 400. State in the moduledoc that non-canonical/escaped mount paths are unsupported in v1; a config-supplied raw mount prefix is the future escape hatch.

Rules (each a test): non-empty query string → error; `sig=` only valid first; `src`/`src64` terminal (missing → error, never a source guess); `src` tail percent-decoded exactly once, malformed escapes → error; `src64` exactly one unpadded url-b64 segment (embedded `/` or `=` → error); percent escapes in option segments → error; empty segments (duplicate slashes) and dot segments → error. For `split_signature/1`: pure split behavior on signed/unsigned/duplicate-slash/garbage paths — it must never error and never allocate diagnostics.

**Files:** Create `lib/image_pipe/dialect/native/path.ex`; Test `test/image_pipe/dialect/native/path_test.exs`.

- [ ] **Step 1: Failing tests** — the rule list above plus span precision (offsets computed against the raw path with the mount prefix stripped) and a StreamData property: for arbitrary safe source strings, `src` percent-encode → extract → decode round-trips; same for `src64` (`Base.url_encode64(s, padding: false)`).
- [ ] **Step 2: Verify failure** → **Step 3: Implement** → **Step 4: Green** → **Step 5: Commit** — `feat(dialect): native path lexer with byte spans`

---

### Task 5: Option table, group validation, canonical request

**Files:**
- Create: `lib/image_pipe/dialect/native/option_spec.ex`, `lib/image_pipe/dialect/native/request.ex`, `lib/image_pipe/dialect/native/parser.ex`
- Test: `test/image_pipe/dialect/native/parser_test.exs`, `test/image_pipe/dialect/native/canonical_property_test.exs`, `test/image_pipe/dialect/native/option_spec_test.exs`

**Interfaces:**
- Consumes: `Native.Path.extract/1`, `Native.Value.*`.
- Produces: `Native.Parser.parse(lexed, config) :: {:ok, Native.Request.t()} | {:error, {:invalid_request, [Diagnostic.t()]}}` (consumes Task 4's lexed map — `Parser` never touches the conn; `Path` owns all raw-path/HTTP concerns); `Native.Parser.parse_option_fragment(string, config) :: {:ok, group_options} | {:error, [Diagnostic.t()]}` — a narrow surface parsing ONE source-free, `then`-free, **group-scoped-only** option group over the same segment/value machinery (a request-scoped key in a fragment is an error; Task 7's preset validation and expansion consume this; config validation must not recursively invoke the full request parser); and `Native.OptionSpec.all/0 :: [%OptionSpec{}]`.

`%OptionSpec{key, scope (:group | :request), value (parser fun or :flag), stage, default, prerequisites, conflicts, identity (:representation | :gate), terminal_applicability, summary, examples}` — one struct per probe-subset option (`w h fit enlarge crop region anchor focus blur trim pad bg output format q expires preset`), driving key lookup, scope/duplicate validation, value dispatch, terminal-applicability rejection, and the completeness test ("every option declares all fields plus ≥ 1 example") [native §Architecture, option schema]. The table drives mechanical concerns only; complex semantics stay ordinary code.

Validation passes (order matters; each produces accumulated diagnostics, Task 6 carries them):
1. per-segment: known key, value parse (spans: key for unknown, value for invalid).
2. groups: split on `then`; empty group (leading/trailing/doubled) → error.
3. scope/duplicates: group-scoped twice in a group → error (every span participates); request-scoped twice anywhere → error.
4. cross-option over successfully parsed values only (derivative suppression [native §Error diagnostics]): Tier-3 exclusives `focus`+`anchor`, `crop`+`region`; Tier-2 inertness (subset rows): **resize intent := at least one concrete (non-`auto`) px dimension among `w`/`h`**; `anchor`/`focus` need a consumer (`crop`, or `fit ∈ {cover, cover-down, auto}` with resize intent), `enlarge` needs resize intent, `fit` needs resize intent (a lone `fit=cover` is inert → 400), a lone or doubled `auto` dimension without a concrete partner (`w=auto` alone, `w=auto/h=auto`) is inert → 400, and `format`/`q` with a non-image `output` are Tier-2 rejects (the spec's terminal-applicability table marks them inert). The `fit`/`auto`-dimension rows extend the spec's Tier-2 table where it is silent — locked probe decisions, consistent with its strict-inertness philosophy; reflect them into the spec's table post-probe.
5. Tier-1 identity canonicalization: `blur=0` → field absent.

- [ ] **Step 1: Failing example tests** — a happy path per option; the spec's worked examples (`/w=800/src/images/cat.jpg`, `/fit=cover/w=300/h=400/focus=0.25,0.75/format=webp/src/...`, `/crop=600,400/anchor=smart/w=300/src/...`, `/w=500/then/trim=fff/src/...`, `/crop=80pct,60pct/src/...`, `/w=32/output=blurhash/src/...`) asserting the exact canonical structs; every 400 rule above with its diagnostic reason; `key=true` → error.
- [ ] **Step 2: StreamData properties + default-spelling examples** — (a) order-insensitivity: any permutation of a group's segments yields an equal `%Native.Request{}`; (b) canonicalization stability: parse → equal on re-parse of a canonically-spelled URL; (c) color spelling equivalence; (d) semantic-default equivalence examples: `/w=800` ≡ `/fit=contain/w=800`, `/crop=600,400` ≡ `/crop=600,400/anchor=center` — equal canonical structs.
- [ ] **Step 3: Verify failure** → **Step 4: Implement** (OptionSpec table first, then parser passes) → **Step 5: Green** → **Step 6: Commit** — `feat(dialect): native option table, validation passes, canonical request`

---

### Task 6: Diagnostics (`Native.Diagnostic` + renderer)

**Files:** Create `lib/image_pipe/dialect/native/diagnostic.ex`, `lib/image_pipe/dialect/native/diagnostic_renderer.ex`; Test `test/image_pipe/dialect/native/diagnostic_test.exs`, `test/image_pipe/dialect/native/diagnostic_renderer_test.exs`. Modify `parser.ex`/`path.ex` to emit `%Diagnostic{}` uniformly.

**Interfaces:**

```elixir
defmodule ImagePipe.Dialect.Native.Diagnostic do
  @enforce_keys [:reason, :message, :spans]
  defstruct @enforce_keys
  # reason  :: atom()                      — stable, tests match on it
  # message :: String.t()                  — one-line label
  # spans   :: [{byte_offset, byte_length}] — ≥ 1; multi-span for duplicates/exclusive pairs
end
# Renderer: render(raw_path, [Diagnostic.t()]) :: iodata()   — the caret display
```

Bounds (constants, each tested): max option segments per request (64), max collected diagnostics (16, then a "further errors omitted" line), max echoed path bytes (2048, truncate with marker), max rendered body bytes (8192) [native §Error diagnostics, bounded work].

- [ ] **Step 1: Failing tests** — accumulation (two independent errors both reported); derivative suppression (`/w=invalid/enlarge/...` reports only the invalid width — `enlarge`'s prerequisite is present-but-invalid, so no inertness diagnostic); multi-span underline for a duplicate key; the spec's caret-rendering example reproduced byte-exact; every cap.
- [ ] **Step 2: Verify failure** → **Step 3: Implement** → **Step 4: Green** → **Step 5: Commit** — `feat(dialect): accumulated spanned diagnostics + bounded caret renderer`

---

### Task 7: Presets (minimal)

**Files:** Create `lib/image_pipe/dialect/native/presets.ex`; Test `test/image_pipe/dialect/native/presets_test.exs`. Modify `config.ex` (validate preset strings parse at `init/1` — a config-time raise, they are host config), `parser.ex` (expansion before validation passes).

Semantics [native §Presets, trimmed to probe]: presets are native-dialect option strings restricted to **group-scoped transform options** (no `then`, no `preset`, no `src`, no request-scoped keys — a deliberate probe trim: the spec allows request-scoped keys in presets via the quality override family, which lands post-probe with the families), parsed via `Native.Parser.parse_option_fragment/2` (Task 5) both at `init/1` validation time and at expansion time; `preset=<name>` request-scoped; expansion order `default` preset < named presets in URL order < explicit URL options, per-key displacement across levels, normal duplicate rule within a level; unknown preset → 400; preset names never reach the canonical request (test: same URL with/without an overridden-away preset yields equal `%Native.Request{}` — cache-key transparency then follows from Task 10 for free).

- [ ] Steps: failing tests (precedence chain, unknown preset, config-time raise on an invalid preset string, transparency property) → implement → green → commit — `feat(dialect): minimal native presets with strict precedence`

---

### Task 8: Signing + `expires` (`Native.Signature`)

**Files:** Create `lib/image_pipe/dialect/native/signature.ex`; Test `test/image_pipe/dialect/native/signature_test.exs`.

**Interfaces (produces):**

```elixir
@spec verify(sig_segment :: String.t() | nil, signed_path :: String.t(), config) ::
        {:ok, key_index :: non_neg_integer() | nil}
        | {:error, :missing_signature | :invalid_signature | :signature_without_keys}
# {:ok, nil} = legitimately unsigned (no keys configured, no sig present);
# {:ok, index} = verified with that key. One shape — the chain's
# `{:ok, key_index} <- verify(...)` never needs a special unsigned branch,
# and `:sig_key_index` metadata receives the value verbatim.
@spec sign(path :: String.t(), config) :: String.t()   # first key; for tests and URL helpers
```

Rules, each a test [native §Signing, §Byte-level contract]: inputs come from `Path.split_signature/1` (Task 4's raw pre-parse split — `verify/3` must be callable without any lexing having run); MAC = HMAC-SHA256 over the raw bytes after the sig segment (from the following `/` to end of path, query excluded, mount-relative); unpadded url-b64, exactly 43 chars, non-canonical encodings rejected; ordered key list, first signs, each tried with `Plug.Crypto.secure_compare/2`; keys configured + missing/invalid → `:missing_signature`/`:invalid_signature` (→ 403, terse body, no spans); no keys + `sig=` present → `:signature_without_keys` (→ 400); no keys + no sig → `{:ok, nil}`. The matched key index is returned by `verify/3`; the `[:parse]` span that carries it as `:sig_key_index` stop metadata is wired in Task 15 (which also owns the `Trace.Capture` `@safe_keys` addition, `docs/telemetry.md`, and the capture test — this task only tests the return value). Property: sign → verify round-trip over arbitrary option paths. Ordering test: a signed path containing a duplicate slash **verifies** (MAC over the raw bytes as sent) and only then 400s at parse (empty segment) — 400, never 403 [native §Byte-level contract]. `expires` (request-scoped option from Task 5): past unix timestamp → 404 gate in the chain; not identity material.

- [ ] Steps: failing tests → implement → green → commit — `feat(dialect): native signing (ordered keys, verify-before-parse) + expires gate`

---

### Task 9: Core identity surfaces — `Representation`, `Cache.lookup_entry/2`, output-policy identity, terminal identity

All the core identity plumbing lands here, with focused tests, BEFORE anything consumes it (Task 10 reads all of these; Task 15/17 consume, never introduce).

**Files:**
- Create: `lib/image_pipe/representation.ex`, `lib/image_pipe/representation/identity_material.ex`, `lib/image_pipe/output/terminal/blurhash.ex` (identity-only in this task: `@spec identity() :: {:blurhash, 1}` — Task 17 adds `compute/1`)
- Modify: `lib/image_pipe/cache.ex` (add `lookup_entry/2`), `lib/image_pipe/output/policy.ex` (add public `identity_selection/1` + `identity_material/1` per the Design Reference table — `identity_selection/1` refactors the private `resolve_before_source_fetch/1` decision), `lib/image_pipe/dialect/native.ex` (uncomment the `ImagePipe.Representation` dep)
- Modify: `test/image_pipe/architecture_boundary_test.exs` (registry + deps/exports for the new boundary)
- Test: `test/image_pipe/representation_test.exs`, `test/image_pipe/cache/lookup_entry_test.exs`, `test/image_pipe/output/policy_identity_test.exs`

The policy-identity tests live here, decoupled from streaming: the **encode-agreement property** (for every policy shape and source format, when `identity_selection/1` returns a concrete format, `Policy.resolve(policy, source_format)` encodes exactly that format), `identity_material/1` field coverage incl. the effective-default rule (two policies differing only in `default_quality` → different material), and the mode/candidates/headers exclusions.

(`Representation.build/2` itself is category-agnostic and just digests what it's given.)

Implement exactly the Design Reference contract. Key/ETag/Vary derivations are core-owned; the one-way property is structural: `build/2` accepts only `source_identity` (keyword material) + `%IdentityMaterial{}` — there is no function anywhere that accepts fetched bytes. `lookup_entry/2` mirrors `lookup/4`'s adapter dispatch, `[:cache, :lookup]` span, and fail-open read-error → miss behavior (share private helpers inside `cache.ex` where trivial; do not change `lookup/4`'s signature or behavior).

- [ ] **Step 1: Failing tests** —
  - same material → equal key hash and ETag (determinism)
  - a `storage_only` change (e.g. cachebuster analog) changes the key, NOT the ETag
  - a `representation` change changes both
  - a `dialect_behavior` epoch bump changes both; the `@core_execution_epoch` constant is present in key data (assert on `key.data`)
  - `vary` echoes `vary_header_names` and nothing else; `storage_inputs/2` classifies header→(value: storage_only, name: vary) and cookie→(value: storage_only, no vary)
  - property: for arbitrary material keywords, ETag never varies with `storage_only`
  - `lookup_entry/2`: disabled (no `:cache` opt) → `:disabled`; miss; hit via a stub adapter; read error → `{:miss, key, {:cache_read, _}}` (fail-open)
- [ ] **Step 2: Verify failure** → **Step 3: Implement** → **Step 4: Green + boundary compile** → **Step 5: Commit** — `feat(core): Representation builder (key/ETag/Vary from categorized identity material) + Cache.lookup_entry/2`

---

### Task 10: Native identity material (`Native.Identity`)

**Files:** Create `lib/image_pipe/dialect/native/identity.ex`, `lib/image_pipe/dialect/native/negotiation.ex`; Test `test/image_pipe/dialect/native/identity_test.exs`.

**Interfaces:**
- Consumes: `%Native.Request{}`, the Task 9 identity surfaces, `Representation.storage_inputs/2`.
- Produces the negotiation value type (new file `lib/image_pipe/dialect/native/negotiation.ex`; Task 15's `negotiate/3` later constructs it):

```elixir
defmodule ImagePipe.Dialect.Native.Negotiation do
  @enforce_keys [:selected, :vary?, :policy_material]
  defstruct [:selected, :vary?, :policy_material, :policy]
  # selected        :: {:image, Output.format() | :source_negotiated} | {:terminal, :blurhash}
  # vary?           :: boolean()          — {:terminal, _} is always false
  # policy_material :: keyword()          — Output.Policy.identity_material/1; [] for terminals
  # policy          :: Output.Policy.t() | nil — THE struct that later drives resolve/2 and
  #                    encode; carried so the one-%Policy{} invariant is structural, not prose.
  #                    Identity code reads only :selected/:policy_material — never :policy.
end
```
- Produces: `Native.Identity.material(request, negotiation, conn, config) :: Representation.IdentityMaterial.t()`; `Native.Identity.plan_output(request) :: %Plan.Output{}` (mode from `format` presence, `quality` from `q`, all other fields constructor defaults — Task 15's negotiate builds its `%Policy{}` from this; if a host output-policy config knob is ever added, it is applied here/in `from_output_plan`, and identity follows automatically via `identity_material/1`); `@dialect_epoch 1` exposed as `{ImagePipe.Dialect.Native, 1}`.

Composition per the identity table in the Design Reference. The `representation` keyword must be built from the canonical request + negotiation outcome only (groups + terminal identity + `policy_material` + selection outcome) — a test asserts `expires`/signature never appear in it; `conn` contributes only via `storage_inputs`.

- [ ] **Step 1: Failing tests** —
  - two spellings of the same group (permuted options) → identical material (composes with Task 5's property)
  - different `Accept` headers selecting the same format → identical material; different selected formats → different `representation`; two no-modern-candidate headers (`Accept: image/jpeg` vs no header) → identical material via the `:source_negotiated` sentinel (Task 15's normalization rule)
  - automatic negotiation puts the name `"Accept"` in `vary_header_names` (when `negotiation.vary?`); explicit format and the blurhash terminal put nothing there
  - explicit `format` → selection is `{:image, format}` regardless of `Accept`
  - blurhash terminal: selection is `{:terminal, :blurhash}`; `Output.Terminal.Blurhash.identity()` enters `representation` (no image selection outcome does); an `:image`-vs-`:blurhash` request differs
  - output-policy material present: two requests differing only in `q` differ in `representation`; the material carries the effective-default policy fields even when no output option is spelled (assert on the material keyword); two hand-built `%Policy{}` variants differing only in `default_quality` yield different `representation` and different ETags (the effective-policy rule — no host knob exposes this on the wire today, so it is pinned at the unit level)
  - `expires`, sig data: never in any category
  - configured `storage_inputs` header: in key, not ETag, name in vary (integration with Task 9)
- [ ] **Steps 2–5:** verify failure → implement → green → commit — `feat(dialect): native identity material composition`

---

### Task 11: Core `DecodePlanner.Request` + `open_options_for/5`

**Files:** Create `lib/image_pipe/transform/decode_planner/request.ex`; Modify `lib/image_pipe/transform/decode_planner.ex`; Test `test/image_pipe/transform/decode_planner_request_test.exs`.

Implement exactly the Design Reference contract, refactoring the shrink math into private helpers shared by both entry points — `open_options/5`'s observable behavior is pinned by `test/image_pipe/decode_planner_test.exs` (run it before and after).

- [ ] **Step 1: Failing tests** — parity: for a chain equivalent to `{resize_target, crop_extent}`, `open_options_for` returns exactly what `open_options` returns (table over jpeg/webp/png, both quarter-turn values); `trim?: true` → no shrink; terminal-only: `%Request{terminal_reduction: {32, 32}}` on a 3200×2400 jpeg → `shrink: 8` (the #377 guard: a tiny terminal frame still informs load shrink); resize beats terminal hint when both present; `required_extent` floor caps a deeper shrink (e.g. terminal hint wants `shrink: 8` but `required_extent: {1600, 1200}` allows only `shrink: 2`); no inputs → no shrink keys.
- [ ] **Steps 2–5:** verify failure → implement → green (including the untouched `decode_planner_test.exs`) → commit — `feat(core): typed decode-plan request with terminal-aware shrink`

---

### Task 12: Core fetch/decode brackets + `SourceGeometry`

**Files:**
- Create: `lib/image_pipe/decode.ex`, `lib/image_pipe/transform/source_geometry.ex` (no `Decode.Decoded` wrapper — the bracket callback receives `State` + `SourceGeometry` directly; an unused stage struct would violate the typestate-restraint principle [pipelines §Enforcement 2])
- Modify: `lib/image_pipe/source.ex` (add `with_fetched/3`), `lib/image_pipe/transform.ex` (export `SourceGeometry`), architecture test (new `Decode` boundary registry + deps), `lib/image_pipe/dialect/native.ex` (uncomment the `ImagePipe.Decode` dep)
- Test: `test/image_pipe/decode_test.exs`, `test/image_pipe/transform/source_geometry_test.exs`, `test/image_pipe/source/with_fetched_test.exs`

**Interfaces (produces):**

```elixir
# Source
@spec with_fetched(Source.Resolved.t(), runtime_opts :: keyword(),
        (Source.Response.t() -> result)) :: result | {:error, {:source, term()}}

# Transform.SourceGeometry
@enforce_keys [:storage_dimensions, :display_dimensions, :pending_orientation, :source_format]
@spec planning_frame(t(), auto_rotate? :: boolean()) :: {pos_integer(), pos_integer()}
# auto_rotate? true → display_dimensions; false → storage_dimensions

# Decode
@spec with_image(Source.Resolved.t(), opts :: keyword(),
        decode_request_fun :: (SourceGeometry.t() -> DecodePlanner.Request.t()),
        (Transform.State.t(), SourceGeometry.t() -> result)) ::
        result | {:error, {:source, term()} | {:decode, term()} | {:input_limit, term()}}
# opts MUST include auto_rotate?: boolean() — the EXIF policy is the CALLER's
# (dialect's) choice, never baked into this core primitive; core owns only the
# compensation. Native passes true (probe subset has no `orient`); a future
# `orient=none` or another dialect passes false.
```

`with_image/4` internals (duplicated from `Request.Processor`, which stays untouched — it is a **two-open** flow: header open, then shrink re-open): fetch via `with_fetched` ([:source, :fetch] span comes from the existing `Source.fetch/3`); format detection — note `Request.SourceFormat` (loader-name → format classification) lives in the forbidden `Request` boundary, so duplicate that small classification into the `Decode` boundary (e.g. `Decode.SourceFormat`) and record the duplication in Task 21.6; header open for stored dims + EXIF orientation; enforce `max_input_pixels` against stored **header** dims; build `%SourceGeometry{}` (display dims via `PendingOrientation.display_dims/2`); call `decode_request_fun` → `DecodePlanner.open_options_for` (Task 11); sequential re-open with those options; seed `%Transform.State{}` (image, source_dimensions, pending_orientation via `PendingOrientation.from_exif(orientation, auto_rotate?)` — second arg is a positional boolean taken from `opts[:auto_rotate?]`, not a keyword — decode_shrink, telemetry_opts) — mirror the Executor/Processor seeding so `Chain` and the flush behave identically. Materialization/decode failures normalize `{:decode, _}`; the bracket owns cleanup on non-local exit (the vips handle is GC-managed; the contract is: no stream left half-consumed on error paths, errors normalized, spans closed).

- [ ] **Step 1: Failing tests** — `SourceGeometry.planning_frame/2` for orientations 1/6/8 both auto_rotate values; `with_image` happy path from `RootHTTPAdapter` + `OriginImage` (state usable by `Chain.execute` with a Resize); oversized pixels → `{:error, {:input_limit, _}}`; corrupt body → `{:error, {:decode, _}}`; source 404 → `{:error, {:source, _}}`; decode_request_fun receives correct geometry (EXIF-oriented fixture: display ≠ storage); `auto_rotate?: false` on the same fixture seeds a non-rotating pending orientation (policy is the caller's, mirror `PendingOrientation.from_exif/2`'s false clause); shrink actually applied (jpeg fixture, decode_request resize_target half-size → loaded dims halved, `state.decode_shrink` set).
- [ ] **Steps 2–5:** verify failure → implement → green (arch test updated) → commit — `feat(core): Source.with_fetched + Decode.with_image brackets, SourceGeometry`

---

### Task 13: Native source translation (`Native.Source`)

**Files:** Create `lib/image_pipe/dialect/native/source.ex`; Test `test/image_pipe/dialect/native/source_test.exs`.

**Interfaces:** `translate(source_string, config) :: {:ok, Plan.Source.t()} | {:error, {:invalid_source, reason}}` — relative path → `%Plan.Source.Path{segments: [...]}`; `http(s)://` → `%Plan.Source.URL{}`; anything else → error (probe scope; scheme forms per host config are post-probe). Own code — no imports from `Parser.Imgproxy.Source` [native §Sources: "never another dialect's translation code"]. Then `ImagePipe.Source.resolve/3` consumes the result unchanged.

- [ ] Steps: failing tests (path segments split/decoded, URL parse incl. the encoded-query example `https://example.com/cat.jpg%3Fv%3D2` arriving already-decoded from Task 4 as `...?v=2`, empty source error) → implement → green → commit — `feat(dialect): native source translation to Plan.Source`

---

### Task 14: Geometry planner + group execution (`Native.Pipeline`)

The heart of the inversion: ordinary sequential code from canonical groups to executed pixels.

**Files:** Create `lib/image_pipe/dialect/native/pipeline.ex`; Test `test/image_pipe/dialect/native/pipeline_test.exs` (unit: op emission), `test/image_pipe/dialect/native/pipeline_pixel_test.exs` (pixel: executed against decoded fixtures).

**Interfaces:**
- Consumes: `%Native.Request{}` groups, `%Transform.State{}` + `%SourceGeometry{}` (Task 12), `Plan.Operation` constructors, `NeutralResolver.resolve/3` + `continue/4` + `resolve_mode/2` (stateless direct calls), `Chain.execute/3`, `%Transform.Operation.Flush{}`.
- Produces:
  - `decode_request(request, geometry) :: DecodePlanner.Request.t()` — the dialect's preflight: display-frame first-resize target (fit-adjusted), crop extent before it, `trim?`, terminal reduction (`{32, 32}` for blurhash).
  - `run(state, geometry, request, opts) :: {:ok, State.t()} | {:error, {:transform, term()}}` — executes all groups then the flush boundary.

Per group, in the fixed stage order, the dialect builds each stage's semantic op (`Plan.Operation` constructors — note they take **tagged** values: dimensions as `{:px, n}`, focus fractions as `{:ratio, num, den}` via `tagged_crop_guide`'s `{:focal, …}` form, pad sides as `{:px, n ≥ 0}`, `blur/1` rejects `0` which Task 5 already canonicalized away; guide from `anchor`/`focus`, `smart` → `:smart`; `fit=auto` resolved via `NeutralResolver.resolve_mode/2` against the current display-frame shape; `pct` lengths resolved by the dialect against the current display dims) and then runs one visible per-op loop, maintaining `{state, shape :: SourceShape.t()}` (seed the shape from the decoded state the way `Executor.execute_pipeline/4` does — verify the seeding fields at implementation time):

```elixir
defp run_op(state, shape, plan_op, opts) do
  {ops, continuation} = NeutralResolver.resolve(shape, nil, plan_op)
  with {:ok, state} <- Chain.execute(state, ops, opts),
       do: follow(state, shape, continuation, opts, _depth = 0)
end

# Interprets the retained core compiler's closed continuation type GENERICALLY:
# `continue/4` may return a further {ops, continuation} stage (the contract is
# recursive), so don't assume one measure → one advance-tail. Defensive depth
# cap (@max_continuation_depth 4) — exceeding it is a core-contract bug, crash.
# Implementation caution: recursion is only sound if the continuation carries
# everything a further measurement needs while `pre_shape` stays the pre-op
# shape. At implementation time, inspect EVERY reachable `continue/4` return;
# if a recursively emitted measurement would need a NEW pre-stage shape that
# the continuation does not encode, do not guess — handle the actual closed
# finite shapes explicitly, or widen the core continuation data to carry its
# required shape. The depth cap bounds damage; it does not make an
# underspecified state transition correct.
defp follow(state, _pre_shape, {:advance, shape, nil}, _opts, _depth), do: {:ok, state, shape}

defp follow(state, pre_shape, {:measure, tag, nil}, opts, depth) when depth < @max_continuation_depth do
  dims = live_dims(state)                              # Vix header read, no pixel work
  case NeutralResolver.continue(tag, dims, pre_shape, nil) do
    {%SourceShape{} = shape, nil} -> {:ok, state, shape}
    {tail_ops, continuation} ->
      with {:ok, state} <- Chain.execute(state, tail_ops, opts),
           do: follow(state, pre_shape, continuation, opts, depth + 1)
  end
end
```

`NeutralResolver.resolve/3` + `continue/4` are called as plain stateless toolkit functions — no `ImagePipe.Resolver` facade, no strategy registration, no `%Plan{}`, no carried state (`nil` everywhere; a non-nil state or a deeper stage shape is a bug → crash). This reuses core's deferred-orientation policy, trim pending classes, cover staged tails, and ±1 measure handling wholesale; the cover result-crop tail executes unchanged (its `%Crop{}` resolves against the live image), measured dims only advance the shape.

**Transitional scope — stated honestly.** This geometry path removes the `Resolver` facade, strategy selection/registration, `Directive`, markers, and `%Plan{}`/`Plan.Pipeline` — but deliberately **retains** the semantic `Plan.Operation` structs, `SourceShape`, the `{ops, continuation}` vocabulary, and the neutral lowering as a core geometry compiler. The probe therefore tests *dialect-owned request orchestration over a retained neutral geometry compiler*; it does NOT yet demonstrate that the operation mirror or the continuation vocabulary can die. Rationale: direct executable-op assembly would force the dialect to own the deferred-orientation flush/compensation policy — exactly the #146 leak the orientation exit criterion (Task 19) forbids — unless that policy is first promoted into a dialect-callable core helper, which is post-probe work. Task 21 must (a) count `Plan.Operation`, `SourceShape`, continuation tags, and executable ops as **retained concept families** in the hop/concept comparison, and (b) include a short direct-lowering feasibility assessment (what a core "geometry compiler" API would need to expose for the mirror to collapse) as a named report subsection.

After the last group: flush boundary — if `shape.pending_orientation` is non-identity emit `%Flush{}` through `Chain`, else clear (mirror `Executor.flush_boundary/4`; streaming fast path preserved). The dialect never touches storage-frame values; all compensation happens inside `NeutralResolver`/`Lowering`/`ResizePlanning`/flush [pipelines §Source-dependent planning].

- [ ] **Step 1: Failing unit tests** — `follow/5` exercises **every continuation tag reachable by the probe's operations** (`:trim`, `:resize`, `{:resize_tail, _}`, `{:resize_flush_tail, _}` — enumerate against `NeutralResolver.continue/4`'s clauses at implementation time) and crashes past the depth cap; then, for a fixed `SourceGeometry`, assert the exact executable op sequences emitted per group for: plain `w=800`; `fit=cover/w=300/h=400/focus=…` (resize + result crop with `{:fp, …}` gravity); `crop=600,400/anchor=smart/w=300`; `region=10,20,100,200`; pct crops resolved against current display dims; `w=500/then/trim=fff` (group boundary: trim runs on post-resize dims — the cheap-trim contract); pad+bg emission order.
- [ ] **Step 2: Failing pixel tests** — decode a real fixture through Task 11's bracket and assert output dimensions for contain/cover/cover-down/stretch/auto; cover result-crop dims exact at ±1-prone sizes; trim-after-resize produces the small trim (assert via dimensions), `decode_request/2` preflight values for each case.
- [ ] **Steps 3–6:** verify failure → implement → green → commit — `feat(dialect): inline geometry planner and group executor`

---

### Task 15: Pipeline assembly — image terminal, streaming, cache write, wire tests

**Files:**
- Create: `lib/image_pipe/dialect/native/delivery.ex`, `lib/image_pipe/dialect/native/errors.ex`
- Modify: `lib/image_pipe/dialect/native.ex` (replace the 501 stub with the chain per the Design Reference sketch, MINUS the conditional-GET check and cache-hit branch — those land in Task 16; here every request is a generate/stream miss with cache write)
- Modify: `lib/image_pipe/telemetry/trace/capture.ex` (`@safe_keys` + `:sig_key_index`), `docs/telemetry.md`
- Test: `test/image_pipe/dialect/native_wire_test.exs`, a Capture test for the new metadata key

**Telemetry ownership (this task):** the dialect emits the standard `[:request]` span around `call/2` and the `[:parse]` span around split → verify → lex → parse (stop metadata carries `:sig_key_index` from Task 8's verify return, nil when unsigned), using `Telemetry.span/4` + `Telemetry.telemetry_opts/1`. These are existing stage names — no Logger/Capture *subscription* changes; only the `@safe_keys` metadata allowlist entry, its Capture test, and the `docs/telemetry.md` line (per the AGENTS telemetry sync rule). Task 18's kit asserts the spans fire.

**Interfaces:**
- `negotiate(conn, request, config)`: blurhash terminal → `%Negotiation{selected: {:terminal, :blurhash}, vary?: false, policy_material: [], policy: nil}`. Image terminal → `Native.Identity.plan_output(request)` (Task 10) → `Output.Policy.from_output_plan/3` + `ensure_capable/2` → `Output.Policy.identity_selection(policy)` + `identity_material(policy)` (both Task 9 core functions — consumed here, never reimplemented). **One-`%Policy{}` invariant, now structural:** the `%Negotiation{}` carries `policy: policy`, and generation calls `Policy.resolve(negotiation.policy, source_format)` and encodes from that resolved output — the policy is never rebuilt from the request or config after negotiation. Continuity test: build a request whose policy carries a non-default field (e.g. `q=42` → `quality: {:quality, 42}`) and assert the SAME value is visible in both `negotiation.policy_material` and the `%Output.Resolved{}` that reaches the encoder. Selection rule:
  - `{:explicit, format}` → selection `{:image, format}`, `vary?: false`;
  - `{:auto_head, format}` (non-empty `modern_candidates` head — the format that will actually be encoded) → `{:image, format}`, `vary?: true`;
  - `:source_negotiated` (empty candidates) → the fixed sentinel — **never** a concrete source-derived format, which is unknowable pre-fetch. Sound because the eventual jpeg-vs-png divergence is a deterministic function of `source_identity` + groups + core epoch, all already in the identity. `vary?: true`.
  Add an **agreement property test**: for every policy shape and source format, when `identity_selection/1` returns a concrete format, `Policy.resolve(policy, source_format)` encodes exactly that format — the guarantee that identity and encode cannot diverge. Normalize to the **single selected format only** — do NOT carry the candidate list into `representation`. The framework's `HTTPCache.accept_material/3` keys the whole candidate list; that is the old behavior this design deliberately replaces ("two headers that both negotiate AVIF share a cache entry and an ETag" [pipelines §Enforcement 2]) — do not mirror it. Acceptance: the contract-kit `same_selection` cases, including the no-modern bucket (Task 18).
- `Native.Delivery.stream(conn_owner_pid, build_fun, representation, response_meta, config) :: {:ok, %Response.PreparedStream{}} | {:error, term}` — **monitor-based, no OTP supervisor** (modeled on `Request.SourceSession`/`Producer`, simplified: no custom-render branch, no detector identity). The dialect must NOT reuse `Request.SourceSessionSupervisor`, and must NOT add a child to `application.ex` (core naming the dialect breaks the acid test). Monitor direction matters — `spawn_monitor` from the owner watches the CHILD only; owner-death detection requires the child to monitor back (the framework precedent is `SourceSession`, which does `Process.monitor(owner)` at `source_session.ex:84`). Topology:
  - conn owner → monitors the coordinator (teardown visibility for tests) and holds the `%PreparedStream{}` next/cancel closures;
  - coordinator/session → **`Process.monitor(conn_owner_pid)`**, owns the cache sink, cancels the producer on owner `:DOWN`;
  - producer → linked/monitored by the coordinator, stays inside the fetch/decode brackets, owns the lazy image + encoder enumerable.
  Owner-kill lifecycle test (kill the conn-owner process, never call `cancel/0`): coordinator receives owner `:DOWN`; producer is halted; encoder enumeration stops; the sink aborts; bracket cleanup runs exactly once; both child processes terminate (`Process.monitor` + `assert_receive {:DOWN, …}`, no sleeps). This proves disconnect detection itself — not merely that the explicit `cancel` closure works. Runs `build_fun` (fetch→decode→transform→encode via `Encoder.stream_output/3`) in the producer, first chunk back, `Cache.open_sink(representation.cache_key, resolved_output, config)` + incremental `write_chunk`/`commit_sink`/`abort_sink` interleave, owner-DOWN → halt + abort. **Bracket-containment invariant** [pipelines §Design principles 1, streaming corner case]: the producer process enters `Source.with_fetched` and `Decode.with_image` and its chunk-pump loop runs **inside** both callbacks until encoder EOF or cancellation — only encoded chunks cross the process boundary; the lazy vips image and the encoder `Enumerable` never escape the brackets (a `build_fun` that returns the enumerable outward for someone else to pull is a bug: the brackets would exit while later chunks still reference their resources). Lifecycle test: instrument the bracket cleanup (a probe hook or a temp-resource sentinel) and assert cleanup has NOT run after prepare and after the first chunk, and HAS run exactly once after EOF and after mid-stream cancellation — stronger than observing eventual producer termination. Ownership table (feeds the exit-criteria report): producer owns the vips image + source stream; the session owns the sink; the `%PreparedStream{}` `cancel` closure is the one public teardown; cleanup idempotent [pipelines §Design principles 1, streaming corner case].
- `Native.Errors.send(conn, error, config)` — dialect-owned mapping: `{:invalid_request, diags}` → 400 `text/plain` rendered diagnostics; `{:missing_signature | :invalid_signature, _}` → 403 terse; `:expired` → 404; source/decode/limit/encode errors → statuses via `Response.ErrorStatus.classify/1` defaults. `ErrorStatus` is NOT currently exported from the `Response` boundary — this task adds it to `ImagePipe.Response`'s `exports:` and updates the arch test's `assert_boundary_exports(response, …)` list (same move Task 16 makes for `Conditional`).
- Delivery reuses `Response.Sender.send_result/3` with `{:ok, {:prepared_stream, prepared, %Plan.Response{}, cache_headers}}` where `cache_headers = %Response.CacheHeaders{etag: representation.etag, representation_headers: vary_headers, headers: []}` (verify field composition against `Sender` expectations at implementation time).

- [ ] **Step 1: Failing wire tests** (each a named test; rig per Design Reference):
  - `GET /w=64/src/images/cat.jpg` → 200, image body, decoded dims 64×?, `content-type` per negotiation
  - different selection: `Accept: image/avif` vs no `Accept` → different content types and different ETags, both `Vary: Accept`
  - same selection, different spellings: `Accept: image/avif` vs `Accept: image/avif,image/webp` (both select avif) → equal ETag and equal captured cache key
  - `/format=webp/...` → webp, **no** `Vary`
  - `/format=jpeg/q=42/...` differs in bytes from `/format=jpeg/q=90/...` (explicit lossy format so quality reliably alters bytes; representation identity carries q)
  - cache write on miss: one request → `CacheProbe` sees `:cache_lookup` (miss) then `:cache_put`; two semantically equivalent (permuted-option) URLs produce the **same captured key**. (Served-from-cache reuse asserts land in Task 16, where the hit branch exists.)
  - 400 paths (unknown key, bad value, duplicate, exclusive pair, empty group, query string) → `refute_received :origin_fetch` + `refute_received :cache_lookup` (instrumented adapters)
  - signature matrix: keys configured {missing, invalid, valid, second-key valid}; keyless + `sig=` → 400
  - `expires` past → 404 before fetch
  - client-disconnect cancellation: monitor-based assertion that the producer/session terminate and the sink aborts when the conn process dies mid-stream (use `Process.monitor` + DOWN, never sleep; scope telemetry asserts with a unique `telemetry_prefix` per the test guidelines)
- [ ] **Steps 2–4:** verify failure → implement chain + delivery + errors → green → commit — `feat(dialect): native pipeline assembly — streamed image terminal end-to-end`

---

### Task 16: Conditional GET + cache hit + 304-before-fetch

**Files:** Create `lib/image_pipe/response/conditional.ex`; Modify `lib/image_pipe/dialect/native.ex` (wire `Conditional.not_modified?/2` + hit delivery); Test `test/image_pipe/response/conditional_test.exs`, extend `native_wire_test.exs`.

`Response.Conditional.not_modified?(conn, etag)`: GET/HEAD only; parse If-None-Match (comma list, weak prefixes; a bare `*` does NOT match here — mirror `HTTPCache.if_none_match?/2` semantics; duplicate the ~25 private lines, framework untouched; add `Conditional` to the Response boundary exports + arch test). Also expose `Conditional.if_none_match_wildcard?(conn)`: RFC 9110 §13.1.2 says `*` → 304 once a current representation is *proven* to exist — pre-fetch nothing is proven, so the chain proceeds on `*`, but the **cache-hit branch must re-check the wildcard** (mirroring `runner.ex`'s hit-path check) and send 304 instead of the entry.

- [ ] **Step 1: Failing tests** — unit: exact/weak/multi-tag/wildcard/no-header matrix for both functions. Wire: request → capture ETag → conditional GET with `OriginShouldNotFetch` + `CacheProbe` → 304, empty body, `refute_received :origin_fetch`, `refute_received :cache_lookup` (304 evaluated **before** cache lookup — stricter and cheaper than the framework, which is fine: the contract is before-fetch); cache **hit** delivery (second non-conditional request) → 200 served from the stored entry with correct headers + ETag (`CacheProbe`: one `:cache_put` total, second request is a `:cache_lookup` hit with no `:origin_fetch`); a semantically permuted URL is served from the same cached entry (moved here from Task 15 — the hit branch now exists); If-None-Match on a hit → 304; `If-None-Match: *` → 200 on a cold cache but 304 on a warmed cache (the wildcard hit-path rule above).
- [ ] **Steps 2–4:** implement → green → commit — `feat(dialect): conditional GET before fetch + cache-hit delivery; core Response.Conditional`

---

### Task 17: BlurHash terminal (pixel-tapping, complete body)

**Files:** Create `lib/image_pipe/output/terminal/blurhash.ex` (the core terminal computation — shared terminals are toolkit functions [pipelines §Design principles 4]); Modify `lib/image_pipe/dialect/native/pipeline.ex` (terminal wiring), `lib/image_pipe/dialect/native.ex` (complete-body generate branch), `lib/image_pipe/cache.ex` + `lib/image_pipe/cache/sink.ex` + `lib/image_pipe/cache/entry.ex` (complete-body widening below), `lib/image_pipe/dialect/native.ex` cache-hit branch from Task 16 (below); Test `test/image_pipe/output/terminal/blurhash_test.exs`, `test/image_pipe/dialect/native/blurhash_test.exs`, `test/image_pipe/cache/complete_body_sink_test.exs`, extend `native_wire_test.exs`.

Semantics [native §Terminal contracts]: after all groups + flush, reduce internally (working frame ≈32px: emit a final contain-resize to fit 32×32 via the same lowering path), then hand the reduced image to core `Output.Terminal.Blurhash.compute/1`, which owns: normalization to the **fixed terminal pixel space** — sRGB, tone-mapped, independent of the decoded image's color profile (a fixed conversion, not an option; byte-affecting for the hash) — and `Image.Blurhash.encode(image, x_components: 4, y_components: 3)` (exact arity/signature recorded in Task 1). `Output.Terminal.Blurhash.identity() :: {:blurhash, 1}` is what Task 10 already puts in `representation` — the terminal behavior version therefore genuinely reaches key + ETag (bump the tuple's integer when the computation changes). Body = the BlurHash string; `content-type: text/plain; charset=utf-8`; **no** `Vary`; `format` and `q` with a non-image `output` are Tier-2 rejects (parse-time, via Task 5's terminal-applicability rules; parser tests live there) — this task adds the wire-level cases. Identity: terminal identity + groups in `representation`; no image selection outcome present (test in `identity_test.exs`). Delivery: complete body — no producer; respond via `Plug.Conn.send_resp/3` with ETag/CL headers (`Sender`'s `{:rendered, …}` shape does JSON negotiation — not a fit; keep dialect-owned send here and note it in the exports report).

**Complete-body cache write requires a scoped core widening** — the sink and entry are image-format-coupled at three verified points: `Sink.open` derives content type via `Format.mime_type!(resolved_output.format)` (raises for non-image), `Entry.Metadata` stores an image `output_format`, and `Entry.validate_content_type` rejects anything that doesn't map back to an image format — so a text body cannot pass through `Cache.open_sink(%Key{}, %Output.Resolved{}, opts)` today. Widen (files: `lib/image_pipe/cache.ex`, `lib/image_pipe/cache/sink.ex`, `lib/image_pipe/cache/entry.ex`): a `Cache.open_sink/3` clause accepting `{:complete_body, content_type :: String.t()}` in place of the `%Output.Resolved{}`, and a **tagged representation in the entry metadata** — `representation: {:image, output_format} | {:complete_body, content_type}` (do NOT overload the image-format field with a fake atom; the framework keeps producing the `{:image, _}` variant unchanged, preserving parallel-stack behavior) — plus the matching `Entry` validation branch. **Task 16's cache-hit delivery branch must also be extended here**: a `{:complete_body, _}` entry is sent as a plain complete body with its stored content type (it must not flow through image-entry delivery that assumes an encoder output). Tests: entry round-trip with `text/plain; charset=utf-8`; a warmed blurhash entry served on hit with the right content type; fail-open preserved on sink errors; existing image-entry validation unchanged. Record the widening in Task 21.6.
Decode planning: `decode_request/2` returns `terminal_reduction: {32, 32}` composed with any user resize (resize still governs when present).

- [ ] **Step 1: Failing tests** — unit: known fixture → BlurHash string is stable and plausibly shaped (`^[0-9A-Za-z#$%*+,\-.:;=?@\[\]^_{|}~]+$`, length for 4×3); pixel-space invariance: for a wide-gamut/ICC-profiled source and its sRGB twin (reuse the color-management test sources — check `SourceInventory` `consumers` before touching any), assert the terminal-normalized reduced frames are pixel-close first; require blurhash **string** equality only if the frames prove byte-identical (rounding in the profile conversion may legitimately differ by ±1/channel — don't write a brittle hash-equality assertion); decode-plan assertion: blurhash with no resize on a large jpeg gets `shrink` > 1 (ties Task 11's #377 guard to the wire). Wire: `GET /w=32/output=blurhash/src/images/cat.jpg` → 200, `text/plain; charset=utf-8`, no `Vary`, ETag present; conditional GET → 304 before fetch; cached: second request served from cache (CacheProbe order); transforms-affect-terminal: `/blur=5/output=blurhash/...` differs from plain (pixels reach the terminal through the shared transform prefix); `q=50` + blurhash → 400 inert; `format=webp` + blurhash → 400 inert.
- [ ] **Steps 2–4:** implement → green → commit — `feat(dialect): blurhash pixel-tapping terminal with terminal-aware decode planning`

---

### Task 18: Contract kits (`CacheKey`, `RequestSafety`)

**Files:** Create `test/support/image_pipe/contract_kit/cache_key.ex`, `test/support/image_pipe/contract_kit/request_safety.ex`; Test `test/image_pipe/dialect/native_contract_test.exs` (the `use` site).

Shape [pipelines §Enforcement model 4]: each kit is a `use`-macro generating ExUnit tests against a dialect module, parameterized by a small test-facing behaviour the using module implements:

```elixir
defmodule ImagePipe.ContractKit.CacheKey do
  # use ImagePipe.ContractKit.CacheKey, dialect: ImagePipe.Dialect.Native
  @callback equivalent_requests(base_opts :: keyword()) :: {[path :: String.t()], opts :: keyword()}
  # ≥ 2 paths that MUST share cache key + ETag
  @callback format_negotiation_cases(base_opts :: keyword()) ::
              %{same_selection: [{path, accept_a, accept_b}], different_selection: [{path, accept_a, accept_b}],
                explicit_format: [{path, accept}], fixed_content_type: [path]}
  @callback storage_only_case(base_opts :: keyword()) :: {path, opts_with_storage_input, header_or_cookie_variants}
end
```

Generated CacheKey cases: equivalent requests → same key + same ETag (via `CacheProbe` key capture + response ETag); same-selection Accept pairs → same key/ETag, `Vary: Accept` present; different-selection → different; explicit format ignores Accept + no Vary; fixed-content-type terminal → no Vary; storage-only variants → different keys, same ETag. The native `use` site MUST supply: at least one `same_selection` pair from the **no-modern bucket** (`Accept: image/jpeg` vs no header — the `:source_negotiated` sentinel is load-bearing there), and the semantic-default `equivalent_requests` pairs (`/w=800` vs `/fit=contain/w=800`; `/crop=600,400` vs `/crop=600,400/anchor=center`).

```elixir
defmodule ImagePipe.ContractKit.RequestSafety do
  @callback rejectable_requests(base_opts :: keyword()) :: [{path, expected_status :: 400..499}]
  @callback valid_request(base_opts :: keyword()) :: path
end
```

Generated RequestSafety cases: every rejectable request → expected status AND `refute_received :origin_fetch` / `:cache_lookup` / `:cache_put` (instrumented adapters wired by the kit); valid request + If-None-Match of its own ETag → 304 with no fetch; telemetry stage naming: a valid request emits `[:request]`/`[:parse]` start/stop under a kit-owned unique `telemetry_prefix` (per the telemetry test guideline).

- [ ] Steps: write the kits + the native `use` site with its callback implementations (paths drawn from earlier wire tests) → run → green → commit — `test: ContractKit.CacheKey + ContractKit.RequestSafety, applied to Dialect.Native`

---

### Task 19: Orientation-invariance matrix

**Files:** Test `test/image_pipe/dialect/native/orientation_matrix_test.exs`.

Matrix [pipelines §exit criteria]: EXIF orientation {1, 6, 8} × operations {`region=…` explicit crop, `crop=…,…/anchor=top-left`, `fit=cover/w=…/h=…/focus=…`, plain `w=…` resize} — auto-rotate is always on in the native dialect (no `orient` in subset; assert the fixed policy). The exit criterion's `auto-rotate off` arm is not exercisable end-to-end for that reason; it is validated only at the core level (`SourceGeometry.planning_frame(geometry, false)` unit tests, Task 12) — record this in the Task 21.4 report as a documented subset limitation, not a silent reduction. Assertions, per cell:
1. **Semantic-intent invariance**: the dialect's emitted semantic ops (Task 14's unit surface) are identical for the same display-frame source regardless of storage orientation (use the orientation-1 twin fixtures: same display content, different storage frames — `Orientation1TwinOrigin`).
2. **Pixel invariance**: wire-level responses for twin sources are pixel-close (reuse the differential `PixelCompare` support helper).
3. **Shrink correctness**: decode shrink computed against storage axes (quarter-turn swap) while planning used display axes — assert via `decode_request/2` + resulting dims for orientation 6.

- [ ] Steps: failing tests → (fix any leaks this exposes in Tasks 11/12/14 — this test is the probe's #146 regression net) → green → commit — `test(dialect): orientation-invariance matrix (display-frame planning, core compensation)`

---

### Task 20: Ordered-planning spike (test-only)

**Files:** Create `test/support/image_pipe/ordered_spike/pipeline.ex` (`ImagePipe.Test.OrderedSpike.Pipeline`, not compiled into `lib/`); Test `test/image_pipe/ordered_spike_test.exs`.

A synthetic TwicPics-like ordered interpreter [pipelines §The probe]: a command list like `[{:resize_w, 500}, {:crop_rel, 0.5, 0.5}, {:resize_w, 200}]` evaluated left-to-right with carried local state `%{dims: {w, h}}` — per command: compute executable op against *current measured* dims → `Chain.execute` → measure → update state. Plus `preflight/2`: walk the same command list purely over header dims, propagating a **minimum safe loaded extent** — equivalently a **maximum safe shrink factor** (the direction matters: when uncertain the preflight must demand MORE loaded pixels, never fewer; "conservative" always means less shrink). Relative ops propagate the requirement; absolute ops reset it; unknown-until-measured ops (a trim analog) collapse it to "no shrink". Output shape: `%{minimum_loaded_width: pos_integer, minimum_loaded_height: pos_integer}` (or `:no_shrink`), carried into `DecodePlanner.Request` via the `required_extent` floor field — NOT via `resize_target`, whose output-box-target semantics would be misstated. That the ordered spike needs its own field is itself probe evidence (is the typed request Native-shaped or toolkit-shaped?) — record it in the Task 21 report.

- [ ] **Step 1: Failing tests** — interpreter correctness (dims after each command over a fixture, both orientations); preflight soundness property (StreamData over random command lists: decode with preflight shrink → final pixel dims equal the no-shrink run's — note this pins **geometry soundness only**, not perceptual equivalence: equal final dims can conceal over-shrunk source detail, acceptable for the synthetic geometry-only command set and stated as a limitation in the report); a documented case where no useful bound exists (leading trim) → preflight yields no shrink, and the test records the measured cost delta (decode dims full vs potential) via an assertion on the plan, not wall time.
- [ ] **Step 2:** implement → green.
- [ ] **Step 3:** Write the spike findings into the probe report (Task 21): does dialect-local ordinary code suffice without a callback seam (expected: yes — the interpreter is a plain `Enum.reduce`); the decode-bound answer with the preflight rules and their failure cases.
- [ ] **Step 4: Commit** — `test: ordered-planning spike — local interpreter + conservative decode preflight`

---

### Task 20b: Error-path and ownership matrix wire tests

(Numbered `20b` to keep existing cross-references stable; it runs between Tasks 20 and 21. This is implementation work deliberately pulled OUT of the report task — establishing injection seams may reshape `Native.Delivery`, and that must not happen inside a documentation task.)

**Files:** Modify `test/image_pipe/dialect/native_wire_test.exs` (or a dedicated `native_error_paths_test.exs`), plus whatever injection seams the tests demand (stub encoder via an `Encoder`-shaped seam or a corrupt-output fixture, failing `CacheProbe` variants, an origin that dies mid-body).

One named wire test per matrix row, each asserting status/behavior AND cleanup ownership (monitor-based, no sleeps, unique `telemetry_prefix` where telemetry is asserted): fetch failure; client disconnect during fetch; decode rejection (415); transform failure after partial work; encoder failure after the first streamed chunk (chunked 200 already sent — assert the stream halts, the sink aborts, brackets clean up once); cache-lookup failure (fail-open → generated response); cache-write failure (fail-open → response still delivered, sink aborted); producer cancellation; response-already-sent. Rows already covered by T15/T16 tests (disconnect, 400-before-fetch, owner-kill) are referenced, not duplicated.

- [ ] Steps: write the failing tests row by row → build the injection seams → green → commit — `test(dialect): error-path and ownership matrix, test-backed row by row`

---

### Task 21: Probe report, core-exports list, final gates

**Files:**
- Create: `docs/superpowers/reports/2026-07-dialect-owned-pipelines-probe-report.md`
- Modify: `docs/telemetry.md` (only if any telemetry surface changed — Task 8's `sig_key_index` at minimum)
- Test: none new (this task runs and records)

Report sections (each an exit criterion [pipelines §Exit criteria]):
1. **Hop-count/concept-count comparison**: the same request (`/w=800/src/images/cat.jpg` and its imgproxy equivalent) traced through both stacks — enumerate hops (module→module transitions) and concept families; baseline from `docs/execution_flow.md` (~14 hops / ~8 families) vs the native chain, counted from the code as built. **Count honestly**: `Plan.Operation`, `SourceShape`, the `{ops, continuation}` vocabulary, and executable ops are RETAINED concept families in the native path (Task 14's transitional scope) — the comparison must not claim the operation mirror collapsed.
2. **Change-locality benchmark**: for (a) add a transform option (`sharpen`), (b) add a pixel-tapping terminal (`lqip`), (c) change cache-key material — record per stack: modules touched, layers crossed, tests updated, per-dialect duplication. Derive by enumerating the concrete files each change touches in each stack (desk exercise, written as file lists — no implementation).
3. **Error-path/ownership matrix**: rows = fetch failure, client disconnect during fetch, decode rejection, transform failure after partial work, encoder failure after first chunk, cache-lookup failure, cache-write failure, producer cancellation, response-already-sent; columns = observed status/behavior, cleanup owner, error-translation owner, per stack. Every row is **recorded from Task 20b's tests** — this task adds no test or implementation work; if a row has no green test, that is a Task 20b gap to fix first. Include the ownership answers: who owns the source session after encode preparation, who closes it on completion, who aborts on disconnect, who finalizes/aborts the sink, encoder-fails-after-first-chunk behavior.
4. **Orientation-invariance matrix**: summarize Task 19's results.
5. **Ordered spike**: Task 20's findings + the decode-bound answer, with the measured cost recorded where no bound exists.
6. **Core-exports list**: every core module/function the probe consumed (grep the dialect + kits for `ImagePipe.` references), grouped: pre-existing exports, exports widened (`SourceGeometry`, `DecodePlanner.Request`/`open_options_for`, `Conditional`, `ErrorStatus`, `lookup_entry`, `Policy.identity_selection`/`identity_material`, the complete-body sink/entry variant, `with_fetched`, `Output.Terminal.Blurhash`), new boundaries (`Representation`, `Decode`), and duplicated-not-extracted (delivery session/producer, Processor decode internals + `Decode.SourceFormat`, conditional-match logic) — the draft of the real toolkit surface, with a recommendation per duplicate (extract / keep duplicated / N/A).
7. **Direct-lowering feasibility** (required by Task 14's transitional scope): what a dialect-callable core "geometry compiler" API would need to expose — above all the deferred-orientation flush/compensation policy — for the `Plan.Operation`/`Transform.Operation` mirror and the continuation vocabulary to actually die; recommendation for the post-probe decision. Explicitly list the probe's **transitional dependencies** here: the dialect's direct use of `%Plan.Output{}` construction, `Policy.identity_material/1`'s coupling to the `%Policy{}` struct shape, the `DecodePlanner.Request` field set (is it Native-shaped or toolkit-shaped — see the spike's `required_extent` evidence), and the retained continuation vocabulary.

- [ ] **Step 1:** Fill sections 1–7 (all matrix rows read from Task 20b's green tests — a missing row goes back to Task 20b, not into this task).
- [ ] **Step 2:** `mise run precommit` — full gate green.
- [ ] **Step 3:** Cross-check every [pipelines §Exit criteria] bullet against this plan's artifacts; note any gap in the report explicitly rather than silently.
- [ ] **Step 4: Commit** — `docs: dialect-owned pipelines probe report (hop count, change locality, error ownership, exports)`

---

## Self-review notes (kept for reviewers)

- **Spec coverage check**: exit criteria map — end-to-end native requests (T15–T17), ContractKit.CacheKey + RequestSafety (T18), hop-count (T21.1), change-locality (T21.2), error-path completeness + ownership (T15/T21.3), orientation matrix (T19), ordered spike + decode question (T20), core-exports list (T21.6). Probe-subset grammar (T3–T8), canonicalization property (T5), signing byte contract (T8), identity table (T9–T10), source-dependent planning + preflight (T11–T14), pixel-tapping terminal + terminal hint (T11/T17), `then` groups incl. cheap-trim (T5/T14/T15).
- **Known open verification points, deliberately deferred to implementation time** (each flagged in its task): exact `Image.Blurhash.encode` arity and the sRGB/tone-map conversion calls (T1/T17); `Sender`/`CacheHeaders` field composition for dialect-built headers (T15); Executor state-seeding parity in `Decode.with_image` (T12); encoder-failure injection seam for the error-path matrix (T21.3).
- **Resolved during plan review** (do not reopen): the core output-identity surfaces (`identity_selection/1`, `identity_material/1`, `Terminal.Blurhash.identity/0`) are all introduced with focused tests in T9 — T10/T15/T17 consume, never introduce; pre-fetch selected-format identity = explicit format / candidate head / `:source_negotiated` sentinel, single format only, never the candidate list; the one-`%Policy{}` invariant is structural — `%Native.Negotiation{}` carries the policy, generation calls `Policy.resolve(negotiation.policy, source_format)`, pinned by a continuity test (T10/T15, Decision 10); `verify/3` returns `{:ok, key_index | nil}` — one success shape, unsigned = `{:ok, nil}` (T8); cover staged tails execute unchanged, measured dims only advance the shape, and the dialect drives `NeutralResolver.resolve/3` + `continue/4` directly as stateless toolkit calls through a generic depth-capped `follow/5` — an explicitly transitional geometry scope (T14, Decision 11); signature verification runs on a raw `split_signature/1` byte split before ANY lexing, and the full lexer returns no signature data (T4/T8); the mount-prefix canonicality check is a RUNTIME host-misconfiguration raise, never an `init/1` check (which has no conn) and never a client 400 (T4); presets parse through `parse_option_fragment/2` and are group-scoped-only in the probe (T5/T7, Decision 3); `auto_rotate?` is a required caller-supplied option of `Decode.with_image`, and there is no `Decode.Decoded` wrapper (T12); the `[:request]`/`[:parse]` spans and the `sig_key_index` telemetry surface belong to T15; the delivery producer pumps chunks INSIDE the fetch/decode brackets — lazy resources never escape, pinned by a bracket-cleanup lifecycle test — and the coordinator monitors the conn owner (`Process.monitor`, the `SourceSession` precedent; `spawn_monitor` alone watches the wrong direction), pinned by an owner-kill test (T15); error-path matrix rows are test-backed in the dedicated T20b, not in the report task; the ordered spike's floor rides `DecodePlanner.Request.required_extent`, not `resize_target` (T11/T20); the complete-body cache write uses a tagged entry-metadata variant and extends T16's hit path (T17); `If-None-Match: *` honored on the cache-hit path only (T16); cache-reuse wire asserts live in T16, T15 asserts key equality + write only.
- **Not in this plan (post-probe, recorded here so nobody "helpfully" adds them)**: `lqip`, `dpr`/`zoom`/`extend`/`rotate`/`flip`/`orient`/effects beyond blur, `cb`, `filename`/`attachment`/`debug`, `format-q`/`autoquality`/`max-bytes`/encoder options, `meta`/`profile`/`hdr`, `on_inert_option: :ignore` + its telemetry event, preset families/pruning/multi-group/request-scoped preset keys, a configured raw mount prefix for non-canonical mount paths, machine-readable error bodies, `docs/native_url_api.md`, fiddle integration, framework migration of any dialect, publishing contract kits.
