# imgproxy dialect phase 2 — wave 1 (§B gap closure) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every framework-vs-dialect divergence (spec items B1–B6) while the dual-run parity net is alive, driving the wire suite's framework-only gates to zero — the precondition for wave 2's `Parser.Imgproxy` retirement.

**Architecture:** Each item adds a config seam and/or emission site to `ImagePipe.Dialect.Imgproxy` (and `Dialect.Native` where the gap is shared), reusing exported core modules (`Response.CORS`, `Response.Sender`, `Output.Clamp`, `Output.Policy`, `Transform.*`) — no new boundary edges. Telemetry parity (B3) prefers relocating span emission into shared core seams so all three stacks emit from one site.

**Tech Stack:** Elixir, Plug, NimbleOptions, `:telemetry`, ExUnit dual-run suites.

**Spec:** `docs/superpowers/specs/2026-07-16-imgproxy-dialect-phase2-design.md`. Wave 2 (§A retirement) and wave 3 (C1) get their own plan after this wave lands.

## Global Constraints

- **Toolchain:** run every mix command as `export PATH="$(mise where elixir)/bin:$PATH" && mix …`. Plain `mise exec -- mix` hits a Homebrew Elixir 1.19.3 shadow and false-fails (including `mix dialyzer`).
- **Un-gate first (RED), then fix (GREEN).** Removing a `if @stack == :framework` gate *is* the RED evidence. A formerly-gated case that is GREEN on the dialect arm before its fix means the gap analysis was wrong — **stop and escalate**, unless the plan step explicitly marks that case expected-GREEN with a reason.
- **Trust real code over this plan's prose.** If a cited line, signature, or metadata shape contradicts the tree, the tree wins — escalate the contradiction to the orchestrator; do not silently work around it.
- **No differential re-bake.** `git status test/support/image_pipe/test/imgproxy_differential/` must stay clean. A differential failure is a dialect bug, never a fixture problem.
- **Never commit `fiddle/mix.lock`** (carries a pre-existing unrelated modification).
- **No state-mutating git** beyond your own `git add <named files>` + `git commit` (no stash/checkout/reset — worktrees share one stash stack).
- **Conformance docs move with behavior:** each task updates `docs/imgproxy_support_matrix.md` in the same commit as the behavior it changes.
- **No cache-key epoch bump** (spec P7): reshape `Identity` material in place; `@dialect_epoch` stays `{ImagePipe.Dialect.Imgproxy, 1}`.
- **Telemetry tests must use a private `telemetry_prefix`** (AGENTS.md test guidelines) — never assert on default-prefix events in async tests.
- The dual-run wire suite is `test/image_pipe/imgproxy_wire_conformance_test.exs`; "un-gate" means deleting the `if @stack == :framework do … end` wrapper (keeping the body) so the block runs on both arms. The dialect arm receives opts through `translate_opts/1` (drops `:parser`, hoists the `:imgproxy` sublist); top-level keys like `detector:`, `allow_origin:`, `max_result_*`, `output_capabilities:` pass through unchanged, so once the dialect config accepts a key, no harness change is needed.

---

### Task 1: B6 — `output_capabilities` config seam (SharedConfig)

**Files:**
- Modify: `lib/image_pipe/dialect/shared_config.ex` (`@keys` ~line 38, `@validated_option_keys` ~52, `@options_schema` ~62)
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs:2887-2929, 2956-2986, 2996-3024` (un-gate)
- Test: existing un-gated wire cases + `test/image_pipe/dialect/shared_config_test.exs` (if present; else the config validation is exercised through the wire cases and each dialect's config test)

**Interfaces:**
- Produces: `SharedConfig` accepts `output_capabilities` — an optional map `%{format_atom => boolean}` , **no default** (absent key preserves `Output.Capabilities`' real-probe semantics, capabilities.ex:37-41). Both dialect configs inherit it via `SharedConfig.keys()`.
- Consumed by: shared core reads it from opts at `Output.Negotiation` (negotiation.ex:51) and `Output.Policy.ensure_capable/2` (policy.ex:194); both dialects already pass `config` there (imgproxy.ex:432, native.ex:240).

- [ ] **Step 1: Un-gate the six capability wire cases.** In `imgproxy_wire_conformance_test.exs`, delete the three `if @stack == :framework do` wrappers at :2887, :2956, :2996 (keep the bodies; delete the gate-reason comments that describe the gate itself, per the remove-cleanly rule).

- [ ] **Step 2: Run to verify RED on the dialect arm only.**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/imgproxy_wire_conformance_test.exs 2>&1 | tail -20`
Expected: the six cases FAIL on the `Dialect` module arm with `ArgumentError: unknown ImagePipe.Dialect.Imgproxy option(s): [:output_capabilities]` (raised from `Config.validate!/1`); framework arm stays green.

- [ ] **Step 3: Add the key to SharedConfig.** In `shared_config.ex`, append `:output_capabilities` to `@keys` and `@validated_option_keys`, and add to `@options_schema`:

```elixir
output_capabilities: [
  type: {:map, :atom, :boolean},
  required: false
]
```

No default. (nimble_options 1.1.1 supports `{:map, k, v}`; precedent in this repo at `lib/image_pipe/config.ex:25`.)

- [ ] **Step 4: Run the un-gated cases to verify GREEN on both arms.**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS on both arms. If any of the six still fails on the dialect arm, the failing call site isn't receiving config — trace whether `Policy.from_output_plan/3`, `Policy.ensure_capable/2`, or `Encoder` on that path drops opts, and thread `config` through (escalate if it needs a signature change beyond adding an opts pass-through).

- [ ] **Step 5: Sync docs + commit.** In `docs/imgproxy_support_matrix.md` § Dialect-stack divergences, remove/narrow the `output_capabilities`-related framework-only-verification notes (grep the section for `output_capabilities`).

```bash
git add lib/image_pipe/dialect/shared_config.ex test/image_pipe/imgproxy_wire_conformance_test.exs docs/imgproxy_support_matrix.md
git commit -m "B6: output_capabilities config seam for both dialects"
```

---

### Task 2: B4 — host `max_result_*` config keys

**Files:**
- Modify: `lib/image_pipe/dialect/shared_config.ex` (schema)
- Modify: `lib/image_pipe/dialect/imgproxy.ex:123-131` (delete `@default_max_result_*` + comment), `:744-764` (`build_and_pump` clamp call), `:793-806` (`result_limits`)
- Modify: `lib/image_pipe/dialect/native.ex:102-108` (delete constants), `:479` (clamp call), `:518-524` (`result_limits`)
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs:3663-3676, 3700-3759, 3769-3883` (un-gate)

**Interfaces:**
- Produces: `SharedConfig` validates `max_result_width`/`max_result_height`/`max_result_pixels` (`:pos_integer`, defaults `8_192`/`8_192`/`40_000_000` — the framework's exact defaults, `Request.Options` options.ex:11-13).
- Produces: `Dialect.Imgproxy.result_limits/2` — `(format, config) :: %{max_width: pos_integer, max_height: pos_integer, max_pixels: pos_integer}`; `Dialect.Native` equivalent reads config **and gains the encoder-min it lacks today**.

- [ ] **Step 1: Un-gate the clamp/result-cap blocks** at :3663 (the `@clamp_opts` attribute), :3700 (3 cases), :3769 (5 cases). **Clamp-telemetry deferral:** five of these cases `assert_received` the `[:output, :clamp]` event (:3714, :3738, :3800, :3827, :3868), each binding `scale`/`meta` consumed by a group of follow-up assertions — the dialect emits that event in Task 7, not here. Wrap each `assert_received` **plus its dependent assertion group** in a runtime `if @stack == :framework do … end` inside the test body (NOT comment-out markers — this keeps the framework's only clamp-emission pins live through the Task 2→7 window, and Task 12's `@stack == :framework` grep is the mechanical backstop against forgetting them). The three `refute_received` clamp cases (:3757, :3846, :3880) need no gating — vacuously correct on the dialect arm until Task 7, still meaningful on the framework arm. Status/pixel assertions run on both arms now.

- [ ] **Step 2: Verify RED** (dialect arm: `unknown … option(s): [:max_result_width, …]`).

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/imgproxy_wire_conformance_test.exs 2>&1 | tail -20`

- [ ] **Step 3: Add the three keys to SharedConfig's schema:**

```elixir
max_result_width: [type: :pos_integer, default: 8_192],
max_result_height: [type: :pos_integer, default: 8_192],
max_result_pixels: [type: :pos_integer, default: 40_000_000]
```

(plus `@keys`/`@validated_option_keys` entries). Then in `dialect/imgproxy.ex`: delete the `@default_max_result_*` attributes and their "no such keys yet" comment (:123-131); change `result_limits/1` to:

```elixir
defp result_limits(format, config) do
  %{max_dimension: encoder_dimension, max_pixels: encoder_pixels} =
    Encoder.encoder_limit(format)

  %{
    max_width: min_limit(Keyword.fetch!(config, :max_result_width), encoder_dimension),
    max_height: min_limit(Keyword.fetch!(config, :max_result_height), encoder_dimension),
    max_pixels: min_limit(Keyword.fetch!(config, :max_result_pixels), encoder_pixels)
  }
end
```

and update the call at `build_and_pump` (:755) to `result_limits(resolved_output.format, config)`. In `dialect/native.ex`: same treatment — delete the constants, make its `result_limits` take `(format, config)`, and give it the same `min_limit`-vs-`Encoder.encoder_limit(format)` composition the imgproxy dialect has (native returns raw defaults today; spec P4 aligns it). Copy `min_limit/2` (`:infinity` head) if native lacks it.

- [ ] **Step 4: Verify GREEN on both arms + native suite.**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/imgproxy_wire_conformance_test.exs test/image_pipe/dialect/`
Expected: PASS. Native's encoder-min alignment is a behavior change for native above encoder limits — if a native test pinned the raw-defaults behavior, update it in this commit with the P4 rationale.

- [ ] **Step 5: Sync docs + commit.** Matrix: remove the "`max_result_*` are ignored" divergences row (§ Dialect-stack divergences); the limitScale row's mechanism note now names the config keys.

```bash
git add lib/image_pipe/dialect/shared_config.ex lib/image_pipe/dialect/imgproxy.ex lib/image_pipe/dialect/native.ex test/image_pipe/imgproxy_wire_conformance_test.exs docs/imgproxy_support_matrix.md
git commit -m "B4: host max_result_* honored by both dialects via SharedConfig"
```

---

### Task 3: B2 — CORS (`allow_origin`) for both dialects

**Files:**
- Modify: `lib/image_pipe/dialect/shared_config.ex` (schema + validator)
- Modify: `lib/image_pipe/dialect/imgproxy.ex:137-144` (`call/2`)
- Modify: `lib/image_pipe/dialect/native.ex:114` (`call/2`)
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs:1025-1077` (un-gate ONLY the first test: "image response carries Access-Control-Allow-Origin")
- Test: a focused native-dialect CORS test (add to native's wire/mount test file, e.g. `test/image_pipe/dialect/native_*_test.exs` — locate with `grep -rl "Dialect.Native.init" test/`)

**Interfaces:**
- Produces: `SharedConfig` validates `allow_origin` (optional binary; non-empty; rejects control characters — port `validate_allow_origin/1` from `Request.Options` options.ex:195-208 into SharedConfig as `@doc false def validate_allow_origin/1`).
- Produces: both dialects call `ImagePipe.Response.CORS.maybe_register(conn, config)` first thing in `call/2`, so the before-send hook stamps every exit path (success stream, errors, 304, `/info`, and Task 4's 204/405). `Response.CORS` is exported; both dialects' Boundary deps already include `ImagePipe.Response` (imgproxy.ex:62, native.ex:50) — no boundary change.
- **Parity warning (spec B2):** framework parity **verbatim** — static origin echo, no `Vary: Origin`, `Access-Control-Allow-Methods: GET, HEAD, OPTIONS` and only on OPTIONS. Upstream imgproxy sends `GET, OPTIONS` on every CORS response; that delta is a recorded deliberate divergence (matrix :522-528). Do not "fix" toward upstream.

- [ ] **Step 1: Un-gate the first CORS case** (image response carries the header). The other three cases in the describe need Task 4's method layer — leave the describe's remaining tests and the `call_imgproxy_method` helper (:4518) gated until then. This may mean splitting the `if` wrapper so only test 1 escapes it.

- [ ] **Step 2: Verify RED** on the dialect arm (`unknown … option(s): [:allow_origin]`).

- [ ] **Step 3: Implement.** SharedConfig schema:

```elixir
allow_origin: [
  type: {:custom, __MODULE__, :validate_allow_origin, []},
  required: false
]
```

```elixir
@doc false
def validate_allow_origin(origin) when is_binary(origin) and origin != "" do
  if origin =~ ~r/[[:cntrl:]]/ do
    {:error, "must not contain control characters"}
  else
    {:ok, origin}
  end
end

def validate_allow_origin(other),
  do: {:error, "expected a non-empty binary, got: #{inspect(other)}"}
```

(The sketch above is two-clause; the mirror target `Request.Options.validate_allow_origin/1` at options.ex:194-208 has **three** clauses with distinct messages — mirror the real shape, not this sketch.) In `dialect/imgproxy.ex` `call/2`, before the telemetry span, matching the framework's extract-then-register order (plug.ex:44-45):

```elixir
def call(%Plug.Conn{} = conn, config) when is_list(config) do
  Telemetry.Trace.maybe_extract_inbound(conn)
  conn = CORS.maybe_register(conn, config)
  ...
```

(add `alias ImagePipe.Response.CORS`). Mirror in `dialect/native.ex` `call/2`.

- [ ] **Step 4: Verify GREEN + every-exit-path coverage** (spec exit criterion 3 says "every dialect exit path"; the un-gated block covers only image-200 — 304/error//info stamping is framework-only today, in `cdn_http_cache_wire_test.exs:389-436`). Add dual-run (or dialect-focused) cases asserting `access-control-allow-origin` on: a **304** response (conditional GET with `allow_origin` set), a **4xx image error**, and an **`/info`** response. Add the native focused test (init with `allow_origin: "https://example.com"`, GET an image, assert `get_resp_header(conn, "access-control-allow-origin") == ["https://example.com"]`; and a no-config refutation asserting `== []`). Run the wire suite + native tests.

- [ ] **Step 5: Sync docs + commit.** Matrix: rewrite § CORS response headers (:505-517 — the "dialect stacks have no CORS handling at all" paragraph is now false) and narrow the divergences-section CORS row to Task 4's remaining method-layer piece.

```bash
git add lib/image_pipe/dialect/shared_config.ex lib/image_pipe/dialect/imgproxy.ex lib/image_pipe/dialect/native.ex test/ docs/imgproxy_support_matrix.md
git commit -m "B2: allow_origin CORS stamping on both dialects via Response.CORS"
```

---

### Task 4: B5 — OPTIONS / method layer for both dialects

**Files:**
- Modify: `lib/image_pipe/dialect/imgproxy.ex:146-151` (`route/2`)
- Modify: `lib/image_pipe/dialect/native.ex:123` (`route/2`)
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs` (un-gate the rest of :1025-1077 and the helper at :4518-4524)
- Test: native focused OPTIONS/405 tests beside Task 3's

**Interfaces:**
- Consumes: Task 3's `CORS.maybe_register` hook (stamps the 204/405).
- Produces: both dialects answer `OPTIONS` → `204` + `Allow: GET, HEAD` (+ `Access-Control-Allow-Methods` when `allow_origin` set) via `Response.CORS.send_options/2`, and any other non-GET/HEAD method → `405` + `Allow: GET, HEAD` via `Response.Sender.send_method_not_allowed/1` (`Sender` already aliased in both dialects). GET/HEAD proceed unchanged.
- Placement: **inside** the `[:request]` telemetry span, mirroring the framework (`ImagePipe.Plug.do_call/2` method heads at plug.ex:53-69 run inside `call/2`'s span). Read the framework's `[:request]` stop metadata for OPTIONS/405 (follow `send_response`/span metadata in plug.ex) and mirror the `:result` value it produces.

- [ ] **Step 1: Un-gate** the three remaining CORS/method cases and the `call_imgproxy_method/3` helper.

- [ ] **Step 2: Verify RED**: OPTIONS case fails with status 400 (dialect parses it as an image request), PUT case fails with 400-not-405.

- [ ] **Step 3: Implement** in `dialect/imgproxy.ex` — new `route/2` heads before the endpoint split:

```elixir
defp route(%Plug.Conn{method: "OPTIONS"} = conn, config) do
  {CORS.send_options(conn, config), %{result: :options}}
end

defp route(%Plug.Conn{method: method} = conn, _config) when method not in ["GET", "HEAD"] do
  {Sender.send_method_not_allowed(conn), %{result: :method_not_allowed}}
end

defp route(%Plug.Conn{} = conn, config) do
  case Path.split_endpoint(conn) do
    {:info, info_conn} -> route_info(info_conn, config)
    :image -> route_image(conn, config)
  end
end
```

(The `:options`/`:method_not_allowed` result values are the framework's own — plug.ex:59, :68.) Mirror the same heads in `dialect/native.ex`'s `route/2`.

- [ ] **Step 4: Verify GREEN** on both arms + native focused tests (OPTIONS 204 with/without CORS config; PUT 405 + Allow).

- [ ] **Step 5: Sync docs + commit.** Matrix (spec B5 doc duty): record the method-layer divergence vs upstream — imgproxy v4 answers non-GET/HEAD with `404`, no `Allow` (exact-method routing, `server/router.go:145-158`), and OPTIONS with `200` blank, no `Allow` (`OkHandler`); ImagePipe's `405`+`Allow` / `204`+`Allow` are deliberate. Make the HEAD difference explicit (upstream: blank 200; ImagePipe: processed request). Remove the OPTIONS→400 dialect-divergence row.

```bash
git add lib/image_pipe/dialect/imgproxy.ex lib/image_pipe/dialect/native.ex test/ docs/imgproxy_support_matrix.md
git commit -m "B5: OPTIONS 204 + method 405 layer on both dialects"
```

---

### Task 5: B1a — `:detector` config seam + state seeding + availability gate (imgproxy dialect only)

**Files:**
- Modify: `lib/image_pipe/dialect/imgproxy/config.ex:24-71` (`@dialect_keys`, `@dialect_schema`)
- Modify: `lib/image_pipe/dialect/imgproxy/pipeline.ex:259-266` (`run/4` seeds detector state)
- Modify: `lib/image_pipe/dialect/imgproxy.ex:403-425` (`check_detector/2` gains availability logic; classes helper)
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs:3042-3210, 3440-3462` (un-gate)

**Interfaces:**
- Produces: `Config` accepts `detector` — schema mirroring `Request.Options` options.ex:109-112: `type: {:or, [{:in, [:default, nil]}, :atom]}, default: :default` (spec P5; `:default` resolves to `Transform.Detector.Composite`, exactly the framework default). **Native does NOT take this key** (no object-detect surface — spec B1).
- Produces: `Pipeline.run/4` seeds `state.detector`/`state.detector_required` from opts (dialect config flows in via `pipeline_opts/4`, imgproxy.ex:772-778) before `condition_color`, mirroring the fields `Transform.Executor.execute` sets at executor.ex:62-67. `state.telemetry_opts` is already seeded by `Decode.with_image` (decode.ex:136-141) — do not re-seed.
- Produces: `detect_classes(operations) :: :all | nonempty_list(String.t()) | nil` helper (in `dialect/imgproxy.ex`, private) mirroring `ImagePipe.Plan.detect_classes/1`'s exact return contract (plan.ex:119-135 — bare `obj`/`"all"` guides yield `:all`, assembly.ex:750-752) over the dialect operations' `{:detect, {spec, weights}}` guides, plus a `face_assist?(operations)` sibling mirroring `Plan.face_assist?/1` over `{:smart, :face_assist}` guides (the dialect produces them — assembly.ex:703, :719) — Task 6 reuses both.
- Modifies: `check_detector/2` mirrors `ImagePipe.Plug.validate_detector_capability/2` (plug.ex:179-192): under `detector_required: true` with detection requested, reject **only when** `Transform.detector_available?(config[:detector], opts_with_classes)` is false — availability is class-dependent (the gate-triad wire case has a Composite whose face child is available and object child is not: `g:obj:face` → 200, `g:obj:car` → 422).

- [ ] **Step 1: Un-gate** the object-detection block (:3042, 8 cases) and the objw-overflow case (:3440). **Expected-GREEN carve-outs** (gate was opts-plumbing, not behavior — do not escalate): "no-geometry g:obj:car returns 200" (:3059), "no-geometry g:objw returns 200" (:3163), and the objw-overflow 4xx case (:3440) may pass immediately once the config accepts `detector:`; the pixel-bias, weight, class-filter, and gate-triad cases MUST be RED first.

- [ ] **Step 2: Verify RED** (dialect arm: `unknown … option(s): [:detector]`, then after a naive key-add the pixel cases fail on attention-fallback pixels — both stages of RED are informative; record which cases failed).

- [ ] **Step 3: Implement.** Config schema (replace the `detector_required` comment block at :57-62 — the "carries no detector" prose is now false):

```elixir
detector: [
  type: {:or, [{:in, [:default, nil]}, :atom]},
  default: :default
],
detector_required: [
  type: :boolean,
  default: false
]
```

Pipeline seeding (`pipeline.ex` `run/4`):

```elixir
def run(%State{} = state, %SourceGeometry{} = _geometry, %{pipelines: pipelines}, opts) do
  ctx = build_ctx(opts)
  state = seed_detector(state, opts)

  with {:ok, %State{} = state} <- condition_color(state, opts),
       ...
end

defp seed_detector(%State{} = state, opts) do
  %State{
    state
    | detector: Transform.resolve_detector(Keyword.get(opts, :detector, :default)),
      detector_required: Keyword.get(opts, :detector_required, false)
  }
end
```

(Check executor.ex:62-67 for the exact field set and mirror it minus `telemetry_opts`; add the `ImagePipe.Transform` alias if missing.) `check_detector/2` rewrite in `dialect/imgproxy.ex` — read plug.ex:179-192 first and port its availability logic:

```elixir
defp check_detector(operations, config) do
  case detect_classes(operations) do
    nil ->
      :ok

    classes ->
      if Keyword.get(config, :detector_required, false) and
           not Transform.detector_available?(
             Keyword.get(config, :detector, :default),
             Keyword.put(config, :classes, classes)
           ) do
        {:error, {:detector, :unavailable}}
      else
        :ok
      end
  end
end
```

with `detect_classes/1` ported from `Plan.detect_classes/1` semantics over `{:detect, {spec, _weights}}` guides (`:all` and class-list forms — read plan.ex:119-143 for the exact nil/`["face"]`/list contract and mirror it, including how `detection_requested?/1`'s current match generalizes). Delete the now-false "carries no detector" comment at imgproxy.ex:403-414 and replace with the availability-gate description.

- [ ] **Step 4: Verify GREEN on both arms**, then run the FULL dual-run + differential suites (detection touches the crop path):

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/imgproxy_wire_conformance_test.exs test/image_pipe/imgproxy_differential_conformance_test.exs test/image_pipe/dialect/`
Expected: PASS; `git status test/support/image_pipe/test/imgproxy_differential/` clean.

- [ ] **Step 5: Sync docs + commit.** Matrix: update the `g:obj` divergences row (detection now honored; the remaining framework-only bit moves to Task 6's cache-key identity).

```bash
git add lib/image_pipe/dialect/imgproxy/config.ex lib/image_pipe/dialect/imgproxy/pipeline.ex lib/image_pipe/dialect/imgproxy.ex test/image_pipe/imgproxy_wire_conformance_test.exs docs/imgproxy_support_matrix.md
git commit -m "B1a: detector seam, state seeding, availability gate in the imgproxy dialect"
```

---

### Task 6: B1b — detector identity in the cache key / ETag

**Files:**
- Modify: `lib/image_pipe/dialect/imgproxy/identity.ex:40-71` (`material/4` → `material/5`)
- Modify: `lib/image_pipe/dialect/imgproxy.ex` (`route_image` computes + threads identity; `route_info` passes `nil`)
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs:1833-1835` (`@detector_gate_opts` collapse), `:3577-3638` (un-gate)
- Test: dialect identity unit tests (locate: `grep -rl "Identity.material" test/image_pipe/dialect/`)

**Interfaces:**
- Consumes: Task 5's `detect_classes(operations)` helper.
- Produces: `Identity.material(request, negotiation, conn, config, detector_identity)` — 5-arity, `detector_identity :: term() | nil`. The term goes into the **`representation`** list (`[detector: detector_identity]` appended alongside `output_policy`), NOT `storage_only` — that placement feeds both the ETag and the cache key (representation.ex:92-100), matching the framework where detector identity is ETag material (`etag_material/4` drops only `:cache`, http_cache.ex:59-77). Always include the key (nil when no detection), mirroring `cache/key.ex:58`'s unconditional `detector:` entry.
- Produces: `route_image` computes the identity once, pre-`Representation.build`, mirroring `Runner.with_detector_identity/2` (runner.ex:194-207) **fully — including the face-assist leg**: identity is resolved when `detect_classes(operations) != nil` **or** `face_assist?(operations)` (the dialect produces `{:smart, :face_assist}` guides via the neutral `smart_crop_face_detection` config key, which its config accepts through the three-way split), with the framework's `["face"]` classes fallback. Otherwise `nil`. One resolution feeds ETag + key (the framework resolves before `HTTPCache.prepare`, plug.ex:94). `route_info` passes `nil` (info requests carry no pipelines).

- [ ] **Step 1: Restructure the identity tests' fakes for the dialect's closed config surface, then un-gate.** The gated tests (:3577-3638) inject `face_ver:`/`object_ver:` **top-level DI keys** read by the fakes' `identity/1` (:3590-3592, :609, :626). The framework's option surface is deliberately open to such extension keys (options.ex:59-63); the dialect's `Config.validate!/1` raises on any unknown key (config.ex:81-86) **by design — do not widen it**. Restructure: replace the version-DI mechanism with distinct versioned detector modules (e.g. `FaceVerFakeV1`/`FaceVerFakeV2` whose `identity/1` is constant per module, composed into per-version composites) selected via the `detector:` key both arms now accept, so `ver_opts/1` builds `[detector: composite_for(face_ver, object_ver), detector_required: false]` with no extension keys. Then collapse `@detector_gate_opts` (:1833-1835) to the same opts on both arms (`[detector: UnavailableDetector, detector_required: true]`) and un-gate the 3 cases with their helper defps.

- [ ] **Step 2: Verify RED — on the inequality assertion only.** Pre-fix, the dialect key carries no detector term, so the **mixed** case (:3616-3636, asserts keys *differ* across model versions) is the collision RED. The two *independence* cases (:3594-3613) assert key **equality** and pass vacuously pre-fix — expected-GREEN, for that stated reason (they become meaningful only post-fix, as regression guards against over-keying). For breadth, add one more inequality case (face-only request, face model v1 vs v2 → keys differ) so RED evidence isn't a single assertion.

- [ ] **Step 3: Implement** the 5-arity `material` (update both call sites in the same edit; no default-arg 4-arity — real callers are exactly two):

```elixir
def material(%Request{} = request, %Negotiation{} = negotiation, %Plug.Conn{} = conn, config, detector_identity)
    when is_list(config) do
  ...
  representation =
    [pipelines: canonical_pipelines(request.pipelines), auto_rotate: request.auto_rotate] ++
      selection_material(negotiation.selected) ++
      [
        output: canonical_output(request.output),
        output_policy: negotiation.policy_material,
        detector: detector_identity
      ]
  ...
```

In `route_image` (after `check_detector`, before `Representation.build`):

```elixir
detector_identity = detector_identity(operations, config)
```

```elixir
defp detector_identity(operations, config) do
  detect_classes = detect_classes(operations)

  if detect_classes != nil or face_assist?(operations) do
    Transform.detector_identity(
      Keyword.get(config, :detector, :default),
      Keyword.put(config, :classes, detect_classes || ["face"])
    )
  else
    nil
  end
end
```

(the exact shape of runner.ex:194-207, including the `["face"]` fallback and the nil-identity pass-through — `Transform.detector_identity/2` returning nil leaves the material's `detector:` entry nil, same as no detection)

and thread it: `Identity.material(request, negotiation, conn, config, detector_identity)`. `route_info`: `Identity.material(request, @info_negotiation, conn, config, nil)`.

- [ ] **Step 4: Verify GREEN + add the ETag half.** Every un-gated assertion is cache-key-only (`lookup_key` via `CacheProbe`); spec exit criterion 2 names the **ETag** too, and key-equality cannot detect a `storage_only` misplacement (storage_only busts the key but not the ETag). Add: (i) unit — `identity_test.exs`: `material/5` with differing `detector_identity` values yields differing `representation` (hence differing built ETag), and nil vs present differ; (ii) wire — extend the identity cases to also capture `get_resp_header(conn, "etag")` and assert it varies with the relevant model and is invariant to the irrelevant one. Run the dialect identity unit tests and update their expected material shapes (the `detector: nil` entry now appears — greenfield reshape, no epoch bump).

- [ ] **Step 5: Sync docs + commit.** Matrix: the `g:obj` row's detector-identity caveat closes; B1 is fully closed.

```bash
git add lib/image_pipe/dialect/imgproxy/identity.ex lib/image_pipe/dialect/imgproxy.ex test/ docs/imgproxy_support_matrix.md
git commit -m "B1b: detector model identity feeds the dialect cache key and ETag"
```

---

### Task 7: B3 clamp — `[:output, :clamp]` one-shot moves into the shared clamp seam

**Files:**
- Modify: `lib/image_pipe/output/clamp.ex` (emission + format/telemetry threading; revise the "knows nothing about formats" moduledoc note)
- Modify: `lib/image_pipe/request/delivery_build.ex:75, 170-186` (framework emit site delegates/deletes)
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs` (delete Task 2's runtime `if @stack == :framework` wrappers around the clamp `assert_received` groups)
- Test: framework pins stay green (`test/image_pipe/telemetry_test.exs`, `test/image_pipe/request/delivery_build_test.exs` — the edited module's unit tests, `test/image_pipe/telemetry/logger_test.exs` — clamp one-shot rendering :385-405, and the wire suite's `@clamp_telemetry_prefix` tests)

**Interfaces:**
- Produces: the `[:output, :clamp]` one-shot (`Telemetry.execute`) fires from the clamp seam whenever clamping occurred, on all three stacks. Framework event metadata stays **key-for-key identical**: measurements `%{scale:}`, metadata `%{format:, source_dimensions:, dimensions:, limits:}` (delivery_build.ex:172-186).
- Shape: `Clamp.clamp/3` (clamp.ex:33) never receives the format, and its moduledoc pins "knows nothing about formats". Thread the format + telemetry opts to the emission — either extend the clamp call (`Clamp.clamp(image, limits, format, opts)`) or add a thin `Clamp.clamp_with_telemetry/4` wrapper the three stacks call while `clamp/3` stays pure — **decide by reading the module and choosing the smaller diff**; both dialects already pass `config` at the call site (imgproxy.ex:755, native.ex:479), the framework passes its opts at delivery_build.ex:75-80. Revise the moduledoc note to match.

- [ ] **Step 1: Write the RED evidence** — delete the runtime `if @stack == :framework` wrappers Task 2 placed around the five clamp `assert_received` groups (:3714, :3738, :3800, :3827, :3868), so those assertions run on both arms. Verify they fail on the dialect arm (event never emitted) and stay green on the framework arm.

- [ ] **Step 2: Implement the move.** Emission lives with the clamp seam; `DeliveryBuild.emit_clamp_telemetry/3` is deleted and `prepare_stream`'s call site passes what the seam needs. Framework behavior byte-stable: same event name, same measurement/metadata keys and values.

- [ ] **Step 3: Verify GREEN**: the new/restored dual-run assertions pass on both arms; `telemetry_test.exs` clamp assertions pass UNCHANGED (do not edit that file — if it needs edits, the framework metadata drifted; fix the implementation instead).

- [ ] **Step 4: Update the stage-set pin**: `[:output, :clamp]` is a one-shot, not in `@framework_only` (it wasn't attached in that scenario) — verify no pin change needed by running `test/image_pipe/imgproxy_telemetry_contract_test.exs`.

- [ ] **Step 5: Commit.**

```bash
git add lib/image_pipe/output/clamp.ex lib/image_pipe/request/delivery_build.ex test/
git commit -m "B3: [:output, :clamp] emitted from the shared clamp seam on all stacks"
```

---

### Task 8: B3 shared spans — `[:output, :negotiate]` helper + `[:transform, :input_color_management]` relocation

**Files:**
- Create: shared negotiate helper in the Output boundary (e.g. `lib/image_pipe/output/negotiate.ex` or a public fn on `Output.Policy` — smallest diff that all three stacks can call; it needs telemetry opts, which `Policy.resolve/2` cannot receive today)
- Modify: `lib/image_pipe/request/delivery_build.ex:324-361` (framework `resolve_output` rewires onto the helper)
- Modify: `lib/image_pipe/dialect/imgproxy.ex:780-791` (`resolve_output` → helper)
- Modify: `lib/image_pipe/dialect/native.ex:505` (same)
- Modify: `lib/image_pipe/transform/input_color_management.ex` (span moves into `condition/2`, reading `state.telemetry_opts`), `lib/image_pipe/transform/executor.ex:90-98` (`seed_color_management` sheds its span), `lib/image_pipe/dialect/imgproxy/pipeline.ex:308-327` (delete the "No span" divergence comment — now false)
- Modify: `test/image_pipe/imgproxy_telemetry_contract_test.exs` (stage-set `@framework_only` shrinks by these two; `@shared_stages` grows)

**Interfaces:**
- Produces: one shared negotiate function enclosing **both legs** — `Policy.resolve/2` AND the `:needs_final_image_alpha` second resolution (delivery_build.ex:335-346) — inside a single `[:output, :negotiate]` span with start `%{output_mode:}` and stop metadata built from the **final** resolved output (`%{result:, output_format:}`, delivery_build.ex:348-357). Signature sketch: `negotiate_output(policy, source_format, alpha_fun, telemetry_opts) :: {:ok, resolved} | {:error, reason}` where `alpha_fun :: (-> boolean)` defers the `Image.has_alpha?` probe to the caller (framework and dialects have different image handles at that point). Error-shape ownership (the three implementations differ): the helper returns `{:error, reason}` **unwrapped**; the framework's call site keeps its `{:error, {:output, reason}}` wrap (delivery_build.ex:344) and the dialects keep their unwrapped pass-through (imgproxy.ex:788-790) — each stack's observable error shape is unchanged. Read all three current `resolve_output` implementations before fixing the signature — they must all collapse onto it without behavior change.
- Produces: `InputColorManagement.condition/2` emits the `[:transform, :input_color_management]` span itself via `state.telemetry_opts`, with stop `%{result:, working_space:, imported?:}` (executor.ex:104-112 shapes); `Executor.seed_color_management/2` stops wrapping.
- **Framework byte-stability guard:** `telemetry_test.exs:209-213` (negotiate) and `:724-757` (ICM) must pass UNCHANGED.

- [ ] **Step 1: RED evidence** — in the telemetry contract test, add `[:output, :negotiate]` and `[:transform, :input_color_management]` to `@shared_stages` (and remove from the stage-set test's `@framework_only`). Run; the dialect arm fails (stages absent).

- [ ] **Step 2: Implement** the negotiate helper + rewire three call sites; move the ICM span. `condition/2` is idempotent via `color_imported?` — ensure the span fires only when conditioning actually runs, matching the framework's per-request-once semantics (the framework gates via `seed_orientation`; the dialect calls once per request from `condition_color`).

- [ ] **Step 3: Verify GREEN — including the framework blast radius.** This task has wave 1's widest framework surface (it rewires `delivery_build.ex` and `executor.ex` serving IIIF/TwicPics too). Run: contract test both arms; `telemetry_test.exs` unchanged-green; `test/image_pipe/request/delivery_build_test.exs`; `test/image_pipe/delivery/trace_parentage_test.exs` + `test/image_pipe/telemetry/delivery_span_parentage_baseline_test.exs` (span relocation changes emission context → OTel parentage); `test/image_pipe/telemetry/trace/capture_test.exs`; `test/image_pipe/telemetry/logger_test.exs`; `test/parser/iiif_wire_test.exs` and the TwicPics suite (`test/parser/twic_pics*`) — the rewired `resolve_output` serves them; full dialect + wire suites.

- [ ] **Step 4: Commit.**

```bash
git add lib/image_pipe/output/ lib/image_pipe/request/delivery_build.ex lib/image_pipe/dialect/ lib/image_pipe/transform/ test/
git commit -m "B3: negotiate + input-color-management spans emitted from shared seams"
```

---

### Task 9: B3 materialize — delivery backstop on the dialect build path

**Files:**
- Modify: `lib/image_pipe/dialect/imgproxy.ex:744-764` (`build_and_pump`), `lib/image_pipe/dialect/native.ex:449-503` (its build path)
- Modify: `test/image_pipe/imgproxy_telemetry_contract_test.exs` (`@framework_only` loses `[:transform, :materialize]`; `@shared_stages` gains it)

**Interfaces:**
- Produces: both dialects run the framework's materialize-for-delivery backstop equivalent (`Request.Processor.materialize_for_delivery/2`, processor.ex:300-316 — read it first; the dialect's `Pipeline.run` tail already does the `stamp_carry` half, pipeline.ex:264) at the same relative position as the framework: after clamp, before encode (delivery_build.ex:76-80). The span comes for free — `Transform.Materializer` already emits it (materializer.ex:37, 83).
- Guard: the color-carry parity tests (`ImagePipe.Dialect.ColorCarryParityTest`) and the differential suite must stay green — materialization must not perturb pixels or the carry stamp.

- [ ] **Step 1: RED evidence** — add `[:transform, :materialize]` to `@shared_stages` / remove from `@framework_only`; dialect arm fails. Also add **position** assertions to the contract test's cache-miss scenario (provenance is already pinned — a plain fit-resize has no materializing op, so the span can only be the backstop — but position isn't: the framework comparison is a sorted set, and the dialect≡native sequence check can't catch a same-wrong-position landing in both dialects in one commit): assert `[:transform, :operation] :stop` precedes materialize `:start`, and materialize `:stop` precedes `[:deliver] :start` — both already hold on the framework arm, so the assertions are dual-run-safe and RED on the dialect arm now.
- [ ] **Step 2: Implement** the backstop in both dialects' build paths (likely `Materializer.flush/1` or the exact call `materialize_for_delivery` makes — mirror it, do not invent; note processor.ex:299-312 skips when `state.materialized?`).
- [ ] **Step 3: Verify GREEN** + differential suite + color-carry tests + `test/image_pipe/telemetry/trace/materialize_span_test.exs`; `git status` differential dir clean.
- [ ] **Step 4: Commit** (`git add lib/image_pipe/dialect/ test/ && git commit -m "B3: materialize delivery backstop (and span) on both dialect build paths"`).

---

### Task 10: B3 dialect-emitted spans — `[:send]`, `[:source, :fetch_decode]`, `[:transform, :execute]`, `[:encode]` (+ first-chunk force)

**Files:**
- Modify: `lib/image_pipe/dialect/imgproxy.ex` (send sites :217/:224/:246/:253/:549/:562/:698-704; `build_fun`/`build_and_pump` :724-764)
- Modify: `lib/image_pipe/dialect/native.ex` (mirror sites)
- Modify: `test/image_pipe/imgproxy_telemetry_contract_test.exs` (final `@framework_only` → `[]`; `@shared_stages` gains the four)
- Test: `test/image_pipe/dialect/imgproxy/error_paths_test.exs`, `test/image_pipe/dialect/byte_identity_cache_headers_test.exs`, full wire suite

**Interfaces:**
- `[:send]`: wrap each dialect's terminal send (`Sender.send_result` / `Errors.send` / info `send_resp` — **and Task 4's OPTIONS 204 + method 405 heads**, which the framework wraps in `[:send]` via `send_response`, plug.ex:53-69; the stage-set test's plain-GET scenario will not catch their omission) in a span with start `%{result:}` and stop `%{result:, status:}` mirroring `Plug.send_response/4` + `send_stop_metadata/2` (plug.ex:163-170, 211-216). Structure this as ONE private `send_with_span(conn, config, result_meta, fun)` helper per dialect rather than inline spans at every site. `[:deliver]` (shared `Response.Sender`) nests inside it — no ordering hazard (both run in the connection-owner process).
- `[:source, :fetch_decode]`: wrap the `Decode.with_image` call inside `build_fun` (imgproxy.ex:729-740) with the framework's start/stop shapes (`Processor.fetch_decode_validate_source_with_source_format/3`, processor.ex:60-68 + `fetch_decode_stop_metadata/1` — read for the exact keys).
- `[:transform, :execute]`: wrap the `Pipeline.run/4` call in `build_and_pump` with start `%{operations:, operation_count:}` (processor.ex:159-167 shapes — read `transform_stop_metadata/1` for stop keys). Note the dialect's operations are per-request assembled; derive the list the same way the `[:transform, :operation]` spans already see them.
- `[:encode]`: wrap `Encoder.stream_output` AND force the first chunk inside the span, mirroring `DeliveryBuild.encode_first_chunk/3` + `first_chunk/1` (delivery_build.ex:103-150 — read both before writing). **This changes when encode errors surface on the dialect path: pre-header 500 instead of mid-stream abort — the conformant direction (framework and upstream both surface pre-header).** If an error-path test pinned the mid-stream behavior for encode failures, update it deliberately in this commit with that rationale.

- [ ] **Step 1: RED** — move the four stages from `@framework_only` into `@shared_stages`; dialect arm fails on all four.
- [ ] **Step 2: Implement** in `dialect/imgproxy.ex`; verify the imgproxy arm green; then mirror in `dialect/native.ex` (the stage-set test's dialect≡native sequence equality is the cross-check — it fails if the two dialects' emission order diverges).
- [ ] **Step 3: Verify GREEN**: contract test `@framework_only == []`; stage-set sequence equality; error-path suites; `test/image_pipe/telemetry/trace/encode_span_test.exs`; full wire + differential.
- [ ] **Step 4: Commit** (`git add lib/image_pipe/dialect/ test/ && git commit -m "B3: dialect-emitted send/fetch_decode/execute/encode spans; encode forces first chunk"`).

---

### Task 11: B3 close-out — `@safe_keys`, Capture test, docs

**Files:**
- Modify: `lib/image_pipe/telemetry/trace/capture.ex:72-150` (`@safe_keys`)
- Test: `test/image_pipe/telemetry/trace/` (Capture attribute test)
- Modify: `docs/telemetry.md`, `docs/imgproxy_support_matrix.md` (§ Observability), `docs/imgproxy_dialect_phase2_backlog.md` (B3 recorded closed)

**Interfaces:**
- Produces: `@safe_keys` gains `:source_dimensions`, `:dimensions`, `:limits` (clamp) and `:working_space`, `:imported?` (ICM) — all non-sensitive (dimension tuples, a limits map, a colorspace atom, a boolean). This additively changes **framework** OTel span attributes too (the keys were dropped for the framework as well) — deliberate, per spec.
- No Logger or Capture subscription-list changes (all 8 events already listed — verified in spec).

- [ ] **Step 1: RED** — Capture test asserting the clamp one-shot's span attributes include the new keys; fails on the allowlist drop.
- [ ] **Step 2: Add the keys; GREEN.**
- [ ] **Step 3: Docs**: `docs/telemetry.md` emission-site prose for the relocated spans (clamp seam, negotiate helper, ICM, dialect send/fetch_decode/execute/encode); matrix § Observability row closes (stage-set parity); backlog B3 note.
- [ ] **Step 4: Commit** (`git add lib/image_pipe/telemetry/ test/ docs/ && git commit -m "B3: safe-keys for clamp/ICM metadata; telemetry docs synced"`).

---

### Task 12: Wave-1 exit gate

**Files:**
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs:18, 4555` (reword the gate-convention comments — the convention no longer exists)
- Modify: `docs/imgproxy_support_matrix.md` (§ Dialect-stack divergences reduced), `docs/imgproxy_dialect_phase2_backlog.md` (§B recorded closed; §A unblocked)

**Interfaces:** none — verification and doc closure.

- [ ] **Step 1: Verify zero gates.**

Run: `grep -n "@stack == :framework" test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: no `if`-gated blocks remain (any hit is a prose comment or the collapsed `@detector_gate_opts` — and after Task 6 that attribute should carry no `@stack` conditional at all; if it does, finish the collapse).

- [ ] **Step 2: Reword the two comments** (:18, :4555) to describe the current single-convention harness.

- [ ] **Step 3: Reduce the divergences section** to the three retained rows: deliberate cross-stack cache-key/ETag difference, dialect-only `/info` caching, `[:parse, :stop]` `:result`-semantics difference (stays until wave 2). Update the backlog: B1–B6 closed with commit refs; §A's "otherwise trusted" precondition met.

- [ ] **Step 4: Full gate.**

Run: `export PATH="$(mise where elixir)/bin:$PATH" && mise run precommit`
Expected: format, compile --warnings-as-errors, credo --strict, dialyzer, ExDNA, full `mix test` — all exit 0. Also: `git status test/support/image_pipe/test/imgproxy_differential/` clean; `git status fiddle/mix.lock` shows the pre-existing modification UNCOMMITTED.

- [ ] **Step 5: Commit** (`git add test/image_pipe/imgproxy_wire_conformance_test.exs docs/ && git commit -m "Wave-1 exit gate: zero framework-only wire gates; divergences reduced"`).

---

## Task dependency order

1 → 2 (SharedConfig edits stack) → 3 → 4 (needs 3's CORS hook) → 5 → 6 (needs 5's helper) → 7 → 8 → 9 → 10 (telemetry tasks are independent of 1–6 except Task 7's contingency link to Task 2, but run them in order — each edits the same pin lists) → 11 → 12.

## Self-review notes

- Spec coverage: B6→T1, B4→T2, B2→T3, B5→T4, B1→T5+T6, B3→T7–T11, wave-1 gate→T12. Doc duties folded per-task per the spec. Native lockstep in T2/T3/T4/T9/T10; excluded in T5/T6 per spec.
- The framework metadata shapes in T7–T10 cite their sources rather than inlining full maps where the plan would risk inventing keys — implementers read the cited function first (global constraint: trust real code). Where the plan does inline code, it was written against the tree at 44247e88.
