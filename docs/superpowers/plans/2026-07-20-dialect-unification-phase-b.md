# Dialect Unification Phase B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port `ImagePipe.Dialect.Imgproxy` and `ImagePipe.Dialect.TwicPics` onto the Phase A `ImagePipe.Dialect` contract + `ImagePipe.Plug` runner, restore imgproxy debug headers (closes #462), and move `allow_debug_headers` to `SharedConfig` — Phase B of `docs/superpowers/specs/2026-07-19-dialect-unification-design.md`.

**Architecture:** Both ordered dialects shrink to the six-callback contract (`validate_config!`/`parse`/`prepare`/`decode_request`/`execute`/`render_error` + optional `classify_error`), deleting their hand-mirrored lifecycle chains; their per-dialect `Negotiation` structs are replaced by the promoted `ImagePipe.Dialect.Negotiation`. imgproxy's `/info` becomes a `{:render, %RenderTerminal{}}` terminal; TwicPics' debug build is replaced by the runner's default builder. The runner gains the neutral data needed to preserve the old chains: deferred post-source negotiation, render-terminal character encoding, parse-failure provenance, dialect-selected exception boundaries, delivery-error policy headers, and the mid-stream request-result override.

**Tech Stack:** Elixir, Plug, Boundary, Vix/libvips, ExUnit. All commands via `mise exec -- …`.

## Global Constraints

- Run every mix command through `mise exec -- …` (fresh worktree: `mise trust` + `mise run setup` first; fiddle gate may need `pnpm -C fiddle/assets run build` once).
- Per-dialect observables are gated: the imgproxy and TwicPics wire, differential, and telemetry suites must pass unchanged except the deltas this plan enumerates (see **Enumerated observable deltas** below). No differential fixture, verdict, or tolerance changes.
- U4 anti-leak rule: the runner branches only on `%Resolved{}` fields, neutral core structs, and shared conn-private state — never on dialect identity. Architecture tests must reject Imgproxy/TwicPics names in the runner. (The conn-private channel is a **widening** of spec U4's literal wording, which names only `Resolved` fields and neutral core structs; `:image_pipe_send_result` is stamped by the shared `Response.Sender`, so it is neutral in substance. Task 10 records it in the spec addendum.)
- No changes under `lib/image_pipe/parser/**` or `lib/image_pipe/request/**` (the framework path and IIIF are Phase C).
- No production deployments or pre-existing cache entries exist. Phase B needs same-version miss/hit coverage, not a cache-metadata migration or identity-epoch bump.
- Subagents must not run state-mutating git commands (`stash`, `reset`, `checkout --`, `clean`) — worktrees share one stash stack.
- Commit after every task.

## Enumerated observable deltas (exhaustive for Phase B)

1. **imgproxy debug headers restored** (spec delta 5, closes #462). Under `allow_debug_headers: true` + the signed `debug:1` option, imgproxy responses regain `X-ImagePipe-*` and `Server-Timing`, built by the runner's default builder. The flag stays identity-excluded. New wire coverage (Task 5). Fiddle mount + `docs/debug_headers.md` updated (Task 8).
2. **TwicPics debug responses gain the source-fact headers** (spec delta 5). Six facts are collected; nil facts render no header. The committed `beach.jpg` fixture gains `source-size: 851508`, `source-color-space: VIPS_INTERPRETATION_sRGB`, `source-icc: true`, `source-bit-depth: 8`, and `source-alpha: false`; `source-orientation` remains absent. Every other TwicPics debug header is reproduced exactly.
3. **Delivery-error policy headers become runner-owned** (the Phase A exit-note resolution). The runner stamps `negotiation.policy.headers` onto the conn before `render_error` on `Delivery.stream` failures only. imgproxy/TwicPics: byte-identical to their current `Errors.send/4` headers. **Native** (already on the runner) gains the behavior: an image-terminal delivery failure under automatic output now carries `Vary: Accept` (no existing test pins its absence; the runner suite pins the new behavior in Task 1).
4. **`[:request]` stop result honors the mid-stream send override for every dialect.** Promoted from the TwicPics chain (`request_stop_metadata/2`): when `Sender` stamps `:image_pipe_send_result` (a committed 200 whose stream then fails), the request span's stop `result` becomes `:processing_error` instead of `:ok`. TwicPics: unchanged (pinned by `twic_pics_telemetry_contract_test.exs` `:streamed_error`). Native/imgproxy: telemetry-only delta, no suite pins the old `:ok`.
5. **Cache entries for imgproxy and TwicPics now store a `Debug.Info`** built unconditionally by the default builder (Phase A delta (b), extended). Internal for imgproxy until the host enables rendering; TwicPics already stored one.
6. **imgproxy `[:parse]` span brackets the endpoint split** (`Path.split_endpoint` moves inside the runner's span). Timing-only; span metadata shapes unchanged.
7. **Config surface:** `allow_debug_headers` becomes a `SharedConfig` key — every dialect accepts it (imgproxy previously rejected it as unknown; Native gains the capability with no grammar trigger — choosing a trigger is a tracked follow-up, not this work). An invalid value now raises the shared message (`invalid ImagePipe shared runtime options: …`) instead of the TwicPics one.
8. **imgproxy returned conn path for `/info`:** parsing still verifies the signature over the prefix-stripped path, but the shared runner returns the original conn. `conn.request_path` therefore retains `/info/...` instead of the legacy stripped path. HTTP status, headers, and body remain unchanged; a mount test pins this conn-state-only delta.
9. **Mount shape:** `plug ImagePipe.Dialect.Imgproxy, …` / `plug ImagePipe.Dialect.TwicPics, …` become `plug ImagePipe.Plug, dialect: …, <same flat config>`. `Imgproxy.init/1|call/2` and `TwicPics.init/1|call/2` no longer exist. `TwicPics.parse/2` keeps its name but returns the behaviour shape `{parse_result, span_stop_metadata}`; all direct and polymorphic callers are migrated.

10. **Post-transform crashes render 500-class for every dialect.** An unexpected exception in a shared post-transform stage (clamp / materialize / encode-first-chunk) previously rendered 422 on imgproxy/Native (the runner's broad `produce_stream` rescue) and 500-class on TwicPics (which rescued only its pipeline run). Each dialect now rescues its own `execute/4` — so transform crashes stay 422 everywhere, unchanged — and the runner no longer rescues the shared stages. imgproxy/Native shift 422 → 500-class on that path; TwicPics is unchanged. No existing test covered it; Task 7 Step 3 adds the pin. Rationale in Task 6 Step 2. A further consequence discovered during implementation: moving each dialect's transform rescue *inside* its own `execute/4` also means the `[:transform, :execute]` span now closes with a normal `:stop` carrying `%{result: :processing_error, …}` for Native and imgproxy, where previously a pipeline raise escaped the span and produced an `:exception` event. This converges them onto TwicPics' long-standing behavior. The wire status is unchanged (still 422), but telemetry handlers — including the default Logger and the OTel trace capture — see a different event, so it is a real observable delta that was not enumerated.

Everything not listed is gated to remain byte-identical by the existing suites.

## File Structure (Phase B end state)

```
lib/image_pipe/plug/dialect_runner.ex            MOD  policy headers on delivery errors; request-stop override
lib/image_pipe/dialect.ex                        MOD  + Failure export (Boundary)
lib/image_pipe/dialect/failure.ex                NEW  neutral parse/lifecycle failure provenance
lib/image_pipe/dialect/resolved.ex               MOD  deferred negotiation
lib/image_pipe/dialect/render_terminal.ex        MOD  neutral character-encoding policy
lib/image_pipe/dialect/shared_config.ex          MOD  + allow_debug_headers key (default false)
lib/image_pipe/dialect/twic_pics/config.ex       MOD  − allow_debug_headers (moved to SharedConfig)
lib/image_pipe/dialect/imgproxy.ex               MOD  chain deleted; behaviour implemented; execute/4 rescue
lib/image_pipe/dialect/imgproxy/negotiation.ex   DEL  replaced by ImagePipe.Dialect.Negotiation
lib/image_pipe/dialect/imgproxy/identity.ex      MOD  alias swap to the promoted struct
lib/image_pipe/dialect/imgproxy/errors.ex        MOD  send/4 → send/3 (headers now runner-stamped)
lib/image_pipe/dialect/imgproxy/config.ex        MOD  unified mount API docs
lib/image_pipe/dialect/native.ex                 MOD  execute/4 rescue (layered exception boundary)
lib/image_pipe/dialect/twic_pics.ex              MOD  chain deleted; behaviour implemented; build_debug deleted
lib/image_pipe/dialect/twic_pics/negotiation.ex  DEL  replaced by ImagePipe.Dialect.Negotiation
lib/image_pipe/dialect/twic_pics/identity.ex     MOD  alias swap
lib/image_pipe/dialect/twic_pics/errors.ex       MOD  send/4 → send/3
mix.exs                                          MOD  retarget debug_builder.ex ExDNA ignore comment (framework twin survives to Phase C)
test/support/image_pipe/test/runner_fixture_dialect.ex   MOD  ?format=auto (automatic output)
test/image_pipe/dialect/native_contract_test.exs MOD  delete the Mount shim; kits own the ImagePipe.Plug mount
test/support/image_pipe/contract_kit/{cache_key,request_safety}.ex  MOD  polymorphic mounts
test/support/image_pipe/test/differential/harness.ex     MOD  both dialect arms mount via ImagePipe.Plug after both ports
test/image_pipe/plug_dialect_runner_test.exs             MOD  vary-on-delivery-error pins
test/image_pipe/dialect/imgproxy/debug_headers_wire_test.exs  NEW  #462 acceptance
test/image_pipe/architecture_boundary_test.exs   MOD  imgproxy/TwicPics deps pins pruned
fiddle/lib/image_pipe_fiddle/application.ex      MOD  Plug-mode init; imgproxy allow_debug_headers: true
fiddle/lib/image_pipe_fiddle_web/imgproxy.ex     MOD  ImagePipe.Plug.call
fiddle/lib/image_pipe_fiddle_web/twic_pics.ex    MOD  ImagePipe.Plug.call
fiddle/test/image_pipe_fiddle/imgproxy_source_mounts_test.exs  MOD  ImagePipe.Plug.init
fiddle/test/image_pipe_fiddle_web/wire_test.exs  MOD  signed imgproxy debug request
docs/debug_headers.md                            MOD  imgproxy emits; mount examples; demo section; color-space example
docs/imgproxy_support_matrix.md                  MOD  debug rows (surface) AND route/2-ownership passages (stage/order)
docs/twicpics_support_matrix.md                  MOD  "self-contained Plug" architecture sentence (stage/order)
docs/imgproxy_path_api.md                        MOD  removed init/call references
docs/execution_flow.md                           MOD  direct TwicPics lifecycle reference
docs/content-aware-gravity.md                    MOD  direct imgproxy mount
docs/cache.md                                    MOD  `to: ImagePipe.Dialect.Imgproxy` forward example
docs/telemetry.md                                MOD  `to: ImagePipe.Dialect.Imgproxy` forward example
docs/cdn-http-cache.md                           MOD  `to: ImagePipe.Dialect.TwicPics` forward example
docs/operational_notes.md                        MOD  stale `_debug=1` trigger prose
docs/custom_parser_guide.md                      MOD  "transition" sentence updated
docs/superpowers/specs/2026-07-19-dialect-unification-design.md  MOD  per-phase delta + contract-widening addendum
+ per-suite test mounts swapped (enumerated in Tasks 4 and 7)
```

---

### Task 1: Runner foundations — delivery-error headers and deferred negotiation

Resolves the Phase A exit-note design question: rather than growing `render_error`'s arity, the runner stamps the negotiated policy's headers onto the conn before calling `render_error`. This mirrors the dialect chains exactly: only `Delivery.stream` failures carry them. The same task makes `Resolved.negotiation` genuinely deferred, so negotiation and detector identity still run only after source resolution.

**Files:**
- Modify: `lib/image_pipe/plug/dialect_runner.ex`
- Modify: `lib/image_pipe/dialect/resolved.ex`
- Modify: `test/support/image_pipe/test/runner_fixture_dialect.ex`
- Test: `test/image_pipe/plug_dialect_runner_test.exs`

**Interfaces:**
- Consumes: `ImagePipe.Dialect.Negotiation` (`.policy`), `ImagePipe.Output.Policy` (`.headers`, `[{"vary", "Accept"}]` for automatic mode via `Policy.automatic_headers/0`, `[]` for explicit).
- Produces: delivery-error responses carrying `negotiation.policy.headers`. Tasks 3 and 6 rely on this to shrink `Errors.send/4` to `/3` without losing the Vary-on-error behavior.
- Produces: `Resolved.negotiation` accepts either the existing result tuple or a zero-arity thunk returning that tuple. The runner invokes a thunk only after `ImagePipe.Source.resolve/3` succeeds. Native remains source-compatible; Tasks 3 and 6 use the thunk.

- [ ] **Step 1: Extend the fixture with an automatic-output mode**

In `test/support/image_pipe/test/runner_fixture_dialect.ex`:

1. Add a `parse_format/1` clause ABOVE the catch-all: `defp parse_format("auto"), do: :auto`
2. In the image `prepare/3` head, replace the `plan_output` binding:

```elixir
    plan_output =
      case request.format do
        :auto -> %Output{mode: :automatic, quality: :default}
        format -> %Output{mode: {:explicit, format}, quality: :default}
      end
```

- [ ] **Step 2: Write the failing tests**

Append to `test/image_pipe/plug_dialect_runner_test.exs` (the `Origin503` failing-origin arrangement is copied from `test/image_pipe/dialect/native_error_paths_test.exs:43-52` — define the module inline at the top of the test file, after the aliases):

```elixir
  defmodule Origin503 do
    @moduledoc false
    def init(opts), do: opts

    def call(conn, opts) do
      opts |> Keyword.fetch!(:test_pid) |> send(:origin_fetch)
      Plug.Conn.send_resp(conn, 503, "origin 503")
    end
  end
```

and the tests:

```elixir
  defp failing_origin_sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test",
         byte_identity: :strong,
         req_options: [plug: {Origin503, test_pid: self()}]}
    ]
  end

  test "a delivery failure under automatic output carries the policy's Vary header" do
    conn = get("/fix/images/beach.jpg?format=auto", opts(sources: failing_origin_sources()))

    assert_received :origin_fetch
    # The fixture renders {:source, _} as 404; the status is the fixture's
    # choice — the assertion is the header.
    assert conn.status == 404
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "a delivery failure under explicit output carries no policy headers" do
    conn = get("/fix/images/beach.jpg?format=webp", opts(sources: failing_origin_sources()))

    assert_received :origin_fetch
    assert conn.status == 404
    assert get_resp_header(conn, "vary") == []
  end
```

- [ ] **Step 3: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/plug_dialect_runner_test.exs`
Expected: the automatic-output test FAILS (`vary` is `[]` — the runner passes no headers to error rendering); the explicit test passes.

- [ ] **Step 4: Implement**

In `lib/image_pipe/plug/dialect_runner.ex`:

1. Keep the existing `ImagePipe.Output.Policy` alias.
2. In `generate/8`'s error arm, replace the whole `{:error, reason} ->` clause (deleting the Phase B note comment):

```elixir
      {:error, reason} ->
        # An Accept-negotiated response must carry the policy's headers
        # (Vary: Accept) even when delivery fails, or a shared cache may
        # serve the failure to a client whose Accept would have negotiated
        # a working outcome. Stamped on the conn — headers survive
        # send_resp — so render_error needs no headers argument. Only the
        # post-negotiation delivery failure carries them (mirroring every
        # dialect chain): resolve/negotiation errors stay bare.
        send_error(with_policy_headers(conn, negotiation), dialect, reason, config)
```

3. Add the helper next to `put_resp_headers/2`:

```elixir
  defp with_policy_headers(conn, %Negotiation{policy: nil}), do: conn

  defp with_policy_headers(conn, %Negotiation{policy: %Policy{headers: headers}}),
    do: put_resp_headers(conn, headers)
```

4. In `ImagePipe.Dialect.Resolved`, widen the `negotiation` type to the existing result tuple or `(-> result)`. In `handle_request/4`, replace the direct match on `resolved.negotiation` with `resolve_negotiation(resolved.negotiation)` after `ImageSource.resolve/3`; the helper invokes a zero-arity function and passes an already-built tuple through.

5. Extend `RunnerFixtureDialect` with a negotiation thunk that sends `:negotiation_invoked` to the test process. Add a runner test whose config makes `ImagePipe.Source.resolve/3` fail, and assert the source error response wins and `refute_received :negotiation_invoked`. Add the success counterpart asserting the thunk runs once. These pins prevent `prepare/3` from being mistaken for deferred execution.

   Reuse the existing zero-double arrangement rather than writing an adapter: `opts(sources: [])` already fails inside `Source.resolve/3` with `{:source, :missing_adapter}` (`test/image_pipe/plug_dialect_runner_test.exs:119-132`), so the new test is that same call plus the `refute_received`. (The `ImagePipe.Source` callback is `resolve/3` — `lib/image_pipe/source.ex:32` — not `resolve/2`; do not hand-roll an adapter on the wrong arity.)

6. `with_policy_headers/2`'s `%Negotiation{policy: nil}` clause: `policy: nil` is produced only by `Negotiation.terminal/1`, whose render terminal never reaches `generate/8`. Check reachability while implementing — if no image-terminal path can carry `policy: nil`, drop the clause rather than guarding an impossible shape (AGENTS.md validation guidelines).

- [ ] **Step 5: Run the runner + native suites**

Run: `mise exec -- mix test test/image_pipe/plug_dialect_runner_test.exs test/image_pipe/dialect/ && mise exec -- mix compile --warnings-as-errors`
Expected: all PASS (Native's suites pin no vary-absence on delivery errors — enumerated delta 3).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/plug/dialect_runner.ex lib/image_pipe/dialect/resolved.ex test/support/image_pipe/test/runner_fixture_dialect.ex test/image_pipe/plug_dialect_runner_test.exs
git commit -m "Preserve post-source negotiation and delivery-error policy headers (Phase B task 1)"
```

---

### Task 2: `allow_debug_headers` moves to `SharedConfig`

**Files:**
- Modify: `lib/image_pipe/dialect/shared_config.ex`
- Modify: `lib/image_pipe/dialect/twic_pics/config.ex`
- Modify: `test/support/image_pipe/test/runner_fixture_dialect.ex` (remove the stale unknown-key comment)
- Test: `test/image_pipe/dialect/shared_config_test.exs`, `test/image_pipe/dialect/twic_pics/config_test.exs`

**Interfaces:**
- Produces: `SharedConfig.keys/0` includes `:allow_debug_headers`; `validate_runtime!/1` defaults it to `false` and validates `:boolean`. Every dialect config module that splits on `SharedConfig.keys/0` (imgproxy, TwicPics, Native) accepts it from here on. The runner already reads it (`delivery_config/2`, `Keyword.get(config, :allow_debug_headers, false)`).
- The framework `Request.Options` copy (IIIF's) is untouched — Phase C deletes it.

- [ ] **Step 1: Write the failing test**

First add `:allow_debug_headers` to `shared_config_test.exs`'s exact `SharedConfig.keys/0` assertion. Then append the validation test (follow the file's existing assertion style):

```elixir
  test "allow_debug_headers defaults to false and validates as a boolean" do
    assert SharedConfig.validate_runtime!([])[:allow_debug_headers] == false
    assert SharedConfig.validate_runtime!(allow_debug_headers: true)[:allow_debug_headers] == true

    assert_raise ArgumentError, ~r/invalid ImagePipe shared runtime options/, fn ->
      SharedConfig.validate_runtime!(allow_debug_headers: "yes")
    end
  end
```

(If the file has no `SharedConfig` alias, add it; match its existing setup.)

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/dialect/shared_config_test.exs`
Expected: FAIL — `allow_debug_headers` is not defaulted (returns `nil`, and the invalid value passes through unvalidated).

- [ ] **Step 3: Implement**

In `lib/image_pipe/dialect/shared_config.ex`:
1. Add `:allow_debug_headers` to `@keys` and `@validated_option_keys`.
2. Add to `@options_schema`:

```elixir
                    allow_debug_headers: [
                      type: :boolean,
                      default: false
                    ],
```

In `lib/image_pipe/dialect/twic_pics/config.ex`: remove `:allow_debug_headers` from `@dialect_keys` and its entry from `@dialect_schema` (the shared split now claims the key first, making the dialect entry unreachable).

- [ ] **Step 4: Update the moved config-test row**

In `test/image_pipe/dialect/twic_pics/config_test.exs`, the "detector and debug options reject malformed values" test lists `allow_debug_headers: "yes"` expecting the TwicPics message. Remove that row (`config_test.exs:100`) from the `for` list — its validation now lives in `shared_config_test.exs` (Step 1). Keep the two detector rows. Add `:allow_debug_headers` to the shared-key enumeration in `shared_config_test.exs:38-70`, and rename `config_test.exs:73` `"accepts all four dialect keys"` → three keys (`storage_inputs`, `detector`, `detector_required`). The passing-value row (`:79`) and assertion (`:85`) stay verbatim — the key is still validated, now via SharedConfig. In `RunnerFixtureDialect`, update the comment that currently calls `allow_debug_headers` an unknown passthrough key.

- [ ] **Step 5: Run the config and dialect suites**

Run: `mise exec -- mix test test/image_pipe/dialect/shared_config_test.exs test/image_pipe/dialect/twic_pics/config_test.exs test/image_pipe/dialect/twic_pics/ test/image_pipe/twic_pics_wire_conformance_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS — TwicPics behavior unchanged (its `Config.validate!` splits shared keys before dialect keys, so the key resolves identically).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/dialect/shared_config.ex lib/image_pipe/dialect/twic_pics/config.ex test/image_pipe/dialect/shared_config_test.exs test/image_pipe/dialect/twic_pics/config_test.exs
git commit -m "Move allow_debug_headers to Dialect.SharedConfig (Phase B task 2)"
```

---

### Task 3: Port `ImagePipe.Dialect.Imgproxy` onto the contract

**Files:**
- Modify: `lib/image_pipe/dialect/imgproxy.ex` (chain deleted, behaviour implemented)
- Delete: `lib/image_pipe/dialect/imgproxy/negotiation.ex`
- Modify: `lib/image_pipe/dialect/imgproxy/identity.ex` (alias swap)
- Modify: `lib/image_pipe/dialect/imgproxy/errors.ex` (`send/4` → `send/3`)
- Modify: `lib/image_pipe/dialect/imgproxy/config.ex` (mount API moduledoc)
- Modify: `lib/image_pipe/dialect/render_terminal.ex` (neutral character-encoding policy)
- Modify: `lib/image_pipe/plug/dialect_runner.ex` (apply the render terminal's encoding on hit and miss)

No test edits in this task — Task 4 swaps the mounts and runs the suites. The compile gate is this task's check.

- [ ] **Step 1: Rewrite `lib/image_pipe/dialect/imgproxy.ex`**

**Keep** (verbatim unless noted): the moduledoc (rewrite the first two paragraphs to describe the contract implementation mounted via `plug ImagePipe.Plug, dialect: ImagePipe.Dialect.Imgproxy, <flat config>`; keep the "Everything decidable from the request is decided before the fetch" and "Response metadata rides the request" sections, dropping sentences that narrate `serve/7`/`call/2` internals now owned by the runner), `encrypt_source_url/3` + its doc, `@info_decode_request`, `parse_request/3`, `parse_options/2`, `parse_source/4` (both heads), `request/5` (both heads + their comments), `parse_stop_metadata/1` (both heads + comments), `check_expires/2` + `now_unix_seconds/1`, `check_geometry/1`, `check_detector/2`, `detect_classes/1`, `face_assist?/1`, `detector_identity/2`, `operation_names/1`, `source_info/2`, `build_source_info/2`, `exif_orientation/1`.

**Delete:** `@behaviour Plug` + `init/1` + `call/2`, `route/2` (all heads), `route_info/2`, `route_image/2`, `send_with_span/4`, `send_stop_metadata/2`, `request_metadata/1`, `send_not_modified/3`, `send_error/3..4`, `parse/3` (the span wrapper — replaced by the behaviour `parse/2` below), `negotiate/3` + `normalize_selection/1`, `@info_negotiation`, `@debug_info`, `serve/7` (both heads), `deliver_hit/6`, `generate/8`, `serve_info/4` (both heads), `deliver_info_hit/5`, `generate_info/5`, `write_complete_body_cache/5` (both heads), `send_complete_body/4`, `put_resp_headers/2`, `build_fun/4`, `build_and_pump/6`, `run_transform/5`, `transform_stop_metadata/1`, `encode_first_chunk/3`, `first_chunk/1`, `encode_stop_metadata/2`, `materialize_for_delivery/2`, `pipeline_opts/4`, `resolve_output/4`, `result_limits/2`, `min_limit/2`, `outcome_result/1` (renamed into `classify_error/1`), and the `import Plug.Conn` line.

**Boundary:** the `deps:` list drops `ImagePipe.Cache` and `ImagePipe.Delivery` (runner-owned now) and adds `ImagePipe.Dialect`. Final list: `[ImagePipe.Config, ImagePipe.Decode, ImagePipe.Dialect, ImagePipe.Dialect.SharedConfig, ImagePipe.Error, ImagePipe.Format, ImagePipe.Output, ImagePipe.Plan, ImagePipe.Representation, ImagePipe.Response, ImagePipe.Source, ImagePipe.Telemetry, ImagePipe.Transform]`. `exports: [SourceScheme]` stays.

**The new behaviour surface:**

```elixir
  @behaviour ImagePipe.Dialect

  alias ImagePipe.Dialect.Negotiation, as: DialectNegotiation
  alias ImagePipe.Dialect.RenderTerminal
  alias ImagePipe.Dialect.Resolved

  @impl ImagePipe.Dialect
  def validate_config!(opts), do: Config.validate!(opts)

  # The [:parse] span (runner-wrapped) now brackets the endpoint split too —
  # a pure path-prefix check; metadata shapes are unchanged (enumerated
  # delta 6). The /info conn is prefix-stripped by split_endpoint, matching
  # upstream's signature-over-the-unprefixed-path behavior; prepare/3 gets
  # the ORIGINAL conn, which is fine — it reads only headers, never the path.
  @impl ImagePipe.Dialect
  def parse(%Plug.Conn{} = conn, config) do
    result =
      case Path.split_endpoint(conn) do
        {:info, info_conn} -> parse_request(info_conn, config, :info)
        :image -> parse_request(conn, config, :image)
      end

    {result, parse_stop_metadata(result)}
  end

  @impl ImagePipe.Dialect
  def prepare(%Plug.Conn{} = conn, %Request{info?: true} = request, config) do
    with :ok <- check_expires(request, config),
         {:ok, plan_source} <- ImgproxySource.translate(request.source_path, config) do
      # /info has one fixed terminal: no format to select, nothing to vary
      # by or carry as output-policy identity material.
      negotiation = DialectNegotiation.terminal(:info)

      {:ok,
       %Resolved{
         request: request,
         source: plan_source,
         negotiation:
           {:ok, negotiation, Identity.material(request, negotiation, conn, config, nil)},
         response_meta: %PlanResponse{},
         operations: [],
         auto_rotate?: false,
         debug?: false,
         terminal: {:render, info_terminal(config)}
       }}
    end
  end

  def prepare(%Plug.Conn{} = conn, %Request{} = request, config) do
    with :ok <- check_expires(request, config),
         {:ok, operations} <- check_geometry(request),
         :ok <- check_detector(operations, config),
         {:ok, plan_source} <- ImgproxySource.translate(request.source_path, config),
         {:ok, %PlanResponse{} = response_meta} <- ResponseMeta.build(request, plan_source) do
      {:ok,
       %Resolved{
         request: request,
         source: plan_source,
         negotiation: fn -> negotiation_result(conn, request, operations, config) end,
         response_meta: response_meta,
         operations: operation_names(request),
         auto_rotate?: request.auto_rotate,
         debug?: response_meta.debug?,
         terminal: :image
       }}
    end
  end

  # The thunk is invoked by the runner only after Source.resolve. Negotiation,
  # detector callbacks, and identity construction therefore keep the chain's
  # source-before-negotiation execution and exception precedence.
  defp negotiation_result(conn, %Request{} = request, operations, config) do
    case DialectNegotiation.negotiate(conn, Identity.plan_output(request), config) do
      {:ok, negotiation} ->
        {:ok, negotiation,
         Identity.material(request, negotiation, conn, config, detector_identity(operations, config))}

      {:error, _reason} = error ->
        error
    end
  end

  defp info_terminal(_config) do
    %RenderTerminal{
      charset: :default,
      fun: fn resolved_source, config ->
        case source_info(resolved_source, config) do
          {:ok, %SourceInfo{} = info} ->
            {content_type, body} = InfoRenderer.render(info)
            {:ok, content_type, body}

          {:error, _reason} = error ->
            error
        end
      end
    }
  end

  @impl ImagePipe.Dialect
  def decode_request(%Request{} = request, geometry),
    do: Pipeline.decode_request(request, geometry)

  @impl ImagePipe.Dialect
  def execute(state, geometry, %Request{} = request, opts),
    do: Pipeline.run(state, geometry, request, opts)

  @impl ImagePipe.Dialect
  def render_error(conn, reason, config), do: Errors.send(conn, reason, config)

  # The former outcome_result/1, verbatim (keep its full comment block).
  @impl ImagePipe.Dialect
  def classify_error(:invalid_signature), do: :parser_error
  def classify_error({:invalid_signature_encoding, _signature}), do: :parser_error
  def classify_error({:unsupported_signature, _signature}), do: :parser_error
  def classify_error({:expired_request, _expires}), do: :parser_error
  def classify_error({:missing_dimensions, _resizing_type}), do: :plan_error
  def classify_error({:detector, :unavailable}), do: :plan_error
  def classify_error(reason), do: Telemetry.request_result({:error, reason})
```

Notes:
- `check_expires` still reads the validated `:clock` from config — same phase as today (post-parse).
- Prune the alias list to what the remaining code references. Remove the runner-owned cache, delivery, output-resolution, materialization, and sender aliases. Keep `ImagePipe.Transform`, `ImagePipe.Transform.DecodePlanner`, and `Vix.Vips.Image` because `detector_identity/2`, `@info_decode_request`, and `exif_orientation/1` still use them. `mix compile --warnings-as-errors` enforces exactness.
- `source_info/2` takes `(resolved, config)` and internally forces `auto_rotate?: false` — unchanged.

- [ ] **Step 2: Preserve the `/info` Content-Type parameter**

Add optional `charset: :default | nil` to `ImagePipe.Dialect.RenderTerminal`, defaulting to `nil` so Native stays byte-identical. The struct is `@enforce_keys [:fun]` + `defstruct [:fun]` today (`lib/image_pipe/dialect/render_terminal.ex:14`), so the literal edit is `defstruct [:fun, charset: nil]` — do **not** add the key to `@enforce_keys`. Thread the terminal through both render cache-hit and render-generation sends. For `:default`, call `Plug.Conn.put_resp_content_type/2`; for `nil`, keep the current three-argument call. imgproxy sets `charset: :default` as shown above. Keep the cache entry's content type bare; presentation comes from the current terminal on both hit and miss.

Run `test/image_pipe/dialect/imgproxy/info_wire_test.exs` after Task 4's mount swap and require `content-type: application/json; charset=utf-8` on both a generated response and a cache hit. The literal is already pinned on the miss path at `:131` and `:385` — do not change those. The cache-hit case only asserts `hit == miss` (`:310`), so add one literal `content-type` assertion there; a shared regression would otherwise pass by matching a wrong value on both sides.

- [ ] **Step 3: Delete the dialect Negotiation, swap Identity's alias, shrink Errors**

1. `rm lib/image_pipe/dialect/imgproxy/negotiation.ex`
2. In `lib/image_pipe/dialect/imgproxy/identity.ex`: replace `alias ImagePipe.Dialect.Imgproxy.Negotiation` with `alias ImagePipe.Dialect.Negotiation`. The `%Negotiation{}` match and the `selected`/`vary?`/`policy_material` reads compile unchanged (the promoted struct is a superset). Update the `@spec material/5` reference and **all three** "Task 17's `negotiate/3`" references — the moduledoc at `:7` and `plan_output/1`'s `@doc` at `:93` and `:94` — to name `ImagePipe.Dialect.Negotiation.negotiate/3`.

Note on `ImagePipe.Output`: after `negotiation.ex` is deleted, the only remaining mention in this boundary is moduledoc prose (`imgproxy/identity.ex:95`). Leave `ImagePipe.Output` in the `deps:` list. Boundary never reports unused `deps` (only `unused_dirty_xref`), so it is harmless — and dropping it here without also updating the Task 9 arch-test pin would desync the two. The same note applies to TwicPics in Task 6.
3. In `lib/image_pipe/dialect/imgproxy/errors.ex`: the `headers` parameter is dead (the runner stamps policy headers on the conn before `render_error` — Task 1). Change `send/4` to `send/3`: drop the `headers \\ []` default head, drop the `headers` argument from every clause and from `send_signature_error/3` → `/2` and `send_core_stage_error/4` → `/3`, and delete `put_headers/2` and the `@type header()` if now unused. Rewrite the "Negotiation headers ride the error" moduledoc section to two sentences: the negotiated policy's headers are stamped by the runner (`ImagePipe.Plug`) on delivery failures before this module renders; only post-negotiation delivery failures carry them, preserving the framework's fetch-vs-resolve Vary asymmetry.
4. Update `lib/image_pipe/dialect/imgproxy/config.ex`'s moduledoc so it names `ImagePipe.Plug.init/1` and `ImagePipe.Plug.call/2`, not the removed dialect Plug callbacks.

- [ ] **Step 4: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile. (Test suites are red until Task 4's mount swap — that is expected; do NOT run the imgproxy suites yet.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plug/dialect_runner.ex lib/image_pipe/dialect/render_terminal.ex lib/image_pipe/dialect/imgproxy.ex lib/image_pipe/dialect/imgproxy/negotiation.ex lib/image_pipe/dialect/imgproxy/identity.ex lib/image_pipe/dialect/imgproxy/errors.ex lib/image_pipe/dialect/imgproxy/config.ex
git commit -m "Port Dialect.Imgproxy onto the ImagePipe.Dialect contract (Phase B task 3)"
```

---

### Task 4: imgproxy-specific test mounts → `ImagePipe.Plug`

**Files** (from a complete direct-reference inventory, not only callback names):
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs`, `test/image_pipe/imgproxy_telemetry_contract_test.exs`
- Modify: `test/image_pipe/dialect/imgproxy_wire_smoke_test.exs`
- Modify: `test/image_pipe/dialect/imgproxy/{error_paths,info_wire,mount,orientation_matrix,resize_auto_wire,shrink_leak_wire}_test.exs`
- Modify: `test/image_pipe/dialect/byte_identity_cache_headers_test.exs`, `test/image_pipe/dialect/color_carry_parity_test.exs` (imgproxy legs)
- Modify: `test/image_pipe/dialect/imgproxy/identity_test.exs`
- Modify: `test/support/image_pipe/test/imgproxy_differential/harness.ex`

Shared polymorphic callers in `ContractKit`, `inbound_trace_test.exs`, and `test/support/image_pipe/test/differential/harness.ex` remain unchanged until Task 7, after both dialects implement the contract. Task 4 deliberately does not run those shared suites.

**Knowingly red between Task 3 and Task 7** (compile stays clean; these fail at runtime because they still call the deleted `Imgproxy.init/1|call/2`). Do not diagnose these as regressions:
- `test/image_pipe/dialect/imgproxy_contract_test.exs` (ContractKit drives `Imgproxy.init/1`)
- the `"ImagePipe.Dialect.Imgproxy"` describe in `test/image_pipe/dialect/inbound_trace_test.exs`

From Task 6 until Task 7, add `test/image_pipe/dialect/twic_pics_contract_test.exs` and every direct-mount TwicPics suite to that list.

- [ ] **Step 1: Inventory and swap every imgproxy-specific mount**

Run `rg -n "ImagePipe\\.Dialect\\.Imgproxy|Imgproxy\\.(init|call)" test/` and manually classify every executable reference. Replace callback calls with `ImagePipe.Plug.init([dialect: Imgproxy] ++ opts)` and `ImagePipe.Plug.call/2`.

In `mount_test.exs`, also change all three `Plug.Router.forward` entries from `to: ImagePipe.Dialect.Imgproxy` to `to: ImagePipe.Plug` and prepend `dialect: ImagePipe.Dialect.Imgproxy` to each `init_opts`. Add a mount assertion that the returned conn for `/info/...` retains the `/info` prefix; this pins enumerated delta 8. Do not change HTTP wire assertions.

- [ ] **Step 2: Use a temporary imgproxy-local differential mount**

Do not change shared `dialect_plug_opts/2` while TwicPics still mounts directly. Make `test/support/image_pipe/test/imgproxy_differential/harness.ex` return `{ImagePipe.Plug, ImagePipe.Plug.init(dialect: ImagePipe.Dialect.Imgproxy, sources: Shared.sources(@sources_dir))}`. `sources/1` is **private today** (`defp sources(sources_dir)`, `test/support/image_pipe/test/differential/harness.ex:58`) — change it to `def sources/1`. Task 7 removes this temporary local construction when it can switch both differential wrappers together.

Why the shared helper cannot move in Task 4: `Shared.dialect_plug_opts/2` calls `dialect.init(...)` (`differential/harness.ex:35-37`) and has exactly two callers — `imgproxy_differential/harness.ex:22` and `twicpics_differential/harness.ex:12-13`. Switching it here would break exactly one suite, `test/image_pipe/twicpics_differential_conformance_test.exs` (its `setup_all` at `:19` would call `TwicPics.validate_config!/1`, which does not exist until Task 6), plus two non-suite consumers: `mix twicpics.diagnose` (`test/support/mix/tasks/twicpics.diagnose.ex:52`) and `mix twicpics.gen_report` (`:46`). `test/image_pipe/imgproxy_differential_conformance_test.exs` is unaffected either way.

- [ ] **Step 3: Update the promoted struct seam**

In `identity_test.exs`, alias `ImagePipe.Dialect.Negotiation` and add `policy: nil, plan_output: nil` to every construction. No assertion changes.

Add an imgproxy integration test with a detector whose `identity/1` sends a message and raises, paired with a source resolver that returns an error. Assert the source error response wins and the detector callback is not invoked. This proves the Task 1 negotiation thunk preserves the old chain's source-before-detector execution, not merely returned-error ordering.

- [ ] **Step 4: Run only imgproxy-owned suites**

Run the imgproxy-specific files listed above, plus `test/image_pipe/imgproxy_wire_conformance_test.exs`, `test/image_pipe/imgproxy_telemetry_contract_test.exs`, and `test/image_pipe/imgproxy_differential_conformance_test.exs`; then run `mise exec -- mix compile --warnings-as-errors`. Do not run the whole `test/image_pipe/dialect/` directory until Task 7 migrates shared polymorphic callers.

Expected: PASS with no assertion changes beyond mount mechanics and enumerated delta 8. `/info` remains `application/json; charset=utf-8` on cache miss and hit. Telemetry and differential fixtures remain unchanged.

- [ ] **Step 5: Commit**

```bash
git add -A test/
git commit -m "Mount imgproxy-owned suites through ImagePipe.Plug dialect mode (Phase B task 4)"
```

---

### Task 5: imgproxy debug-header wire coverage (#462 acceptance)

**Files:**
- Test (create): `test/image_pipe/dialect/imgproxy/debug_headers_wire_test.exs`

**Interfaces:**
- Consumes: the ported dialect (`Resolved.debug?` from parsed `debug:1`), SharedConfig's `allow_debug_headers`, and the runner's default debug builder. Coverage includes a valid signature over a path that already contains `debug:1`; the existing tamper test remains.

- [ ] **Step 1: Write the imgproxy acceptance tests**

```elixir
defmodule ImagePipe.Dialect.Imgproxy.DebugHeadersWireTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ImagePipe.Dialect.Imgproxy
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.CountingOriginImage
  alias ImgproxyWireConformanceTest.OriginImage

  @sources [
    path:
      {RootHTTPAdapter,
       root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
  ]

  defp opts(extra \\ []) do
    ImagePipe.Plug.init(Keyword.merge([dialect: Imgproxy, sources: @sources], extra))
  end

  defp counting_sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test",
         byte_identity: :strong,
         req_options: [plug: {CountingOriginImage, test_pid: self()}]}
    ]
  end

  defp stateful_cache do
    table = :ets.new(:imgproxy_debug_cache, [:set, :public])
    {CacheProbe, store: table}
  end

  defp get(path, config) do
    ImagePipe.Plug.call(conn(:get, path), config)
  end

  defp header(conn, name) do
    case get_resp_header(conn, name) do
      [value] -> value
      [] -> nil
    end
  end

  test "a signed debug:1 request renders source facts and measured timings" do
    conn =
      get(signed_debug_path(),
        opts(
          signature: [keys: ["746573742d6b6579"], salts: ["746573742d73616c74"]],
          allow_debug_headers: true
        ))

    assert conn.status == 200
    assert header(conn, "x-imagepipe-source-format") == "jpeg"
    assert header(conn, "x-imagepipe-source-size") == "851508"
    assert header(conn, "x-imagepipe-source-color-space") == "VIPS_INTERPRETATION_sRGB"
    assert header(conn, "x-imagepipe-source-icc") == "true"
    assert header(conn, "x-imagepipe-source-bit-depth") == "8"
    assert header(conn, "x-imagepipe-source-alpha") == "false"
    assert header(conn, "x-imagepipe-source-orientation") == nil
    assert header(conn, "x-imagepipe-output-format") == "jpeg"
    assert header(conn, "x-imagepipe-cache") == "miss"

    timing = header(conn, "server-timing")
    assert is_binary(timing)
    for stage <- ~w(decode transform encode total) do
      assert timing =~ ~r/(^|, )#{stage};dur=\d+(\.\d+)?/
    end
  end

  test "debug:1 renders nothing without the mount flag, and a plain request renders nothing under it" do
    off = get("/_/debug:1/f:jpeg/plain/images/beach.jpg", opts())
    assert off.status == 200
    assert header(off, "x-imagepipe-source-format") == nil
    assert header(off, "server-timing") == nil

    plain = get("/_/f:jpeg/plain/images/beach.jpg", opts(allow_debug_headers: true))
    assert plain.status == 200
    assert header(plain, "x-imagepipe-source-format") == nil

    # The documented explicit opt-out (support matrix, `debug` extension row):
    # debug:0 under an enabled mount renders nothing. TwicPics pins its
    # counterpart at test/image_pipe/dialect/twic_pics/debug_test.exs:105.
    opted_out = get("/_/debug:0/f:jpeg/plain/images/beach.jpg", opts(allow_debug_headers: true))
    assert opted_out.status == 200
    assert header(opted_out, "x-imagepipe-source-format") == nil
    assert header(opted_out, "server-timing") == nil
  end

  test "debug:1 is identity-excluded: one cache entry, one ETag, facts replayed on the hit" do
    config = opts(allow_debug_headers: true, cache: stateful_cache(), sources: counting_sources())

    plain = get("/_/f:jpeg/rs:fill:64:64/plain/images/beach.jpg", config)
    assert plain.status == 200
    assert_received :origin_fetch
    assert header(plain, "x-imagepipe-source-format") == nil

    debug = get("/_/debug:1/f:jpeg/rs:fill:64:64/plain/images/beach.jpg", config)
    assert debug.status == 200
    refute_received :origin_fetch
    assert debug.resp_body == plain.resp_body
    assert header(debug, "etag") == header(plain, "etag")
    assert header(debug, "x-imagepipe-cache") == "hit"
    assert header(debug, "x-imagepipe-source-format") == "jpeg"
    assert header(debug, "x-imagepipe-source-size") == "851508"
    assert header(debug, "x-imagepipe-source-color-space") == "VIPS_INTERPRETATION_sRGB"
    assert header(debug, "x-imagepipe-source-icc") == "true"
    assert header(debug, "x-imagepipe-source-bit-depth") == "8"
    assert header(debug, "x-imagepipe-source-alpha") == "false"
    assert header(debug, "x-imagepipe-source-orientation") == nil
    assert header(debug, "server-timing") =~ "cache;dur="
  end
end
```

Define `signed_debug_path/0` by copying the small HMAC-SHA256 URL helper and key/salt fixture from `imgproxy_wire_conformance_test.exs` (that helper is private). Sign the path after inserting `debug:1`; do not sign a plain path and mutate it. Keep the trusted-path gating and identity-exclusion tests, and keep the existing tamper-rejection test in the conformance suite.

- [ ] **Step 2: Run**

Run: `mise exec -- mix test test/image_pipe/dialect/imgproxy/debug_headers_wire_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS. If a header is missing, the bug is in the port (Resolved.debug? not fed from `response_meta.debug?`, or the mount flag not reaching `delivery_config/2`) — fix the port, not the test.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/dialect/imgproxy/debug_headers_wire_test.exs
git commit -m "Pin imgproxy debug-header wire contract (Phase B task 5, closes #462 acceptance)"
```

---

### Task 6: Port `ImagePipe.Dialect.TwicPics` onto the contract + request-stop override

The runner change rides this task because its gate is TwicPics' own telemetry contract: the chain's `request_stop_metadata/2` honors `Sender`'s mid-stream `:image_pipe_send_result` override at the `[:request]` stop, and `twic_pics_telemetry_contract_test.exs`'s `:streamed_error` scenario pins `%{result: :processing_error, status: 200}`. The runner today would emit `:ok`.

**Files:**
- Modify: `lib/image_pipe/plug/dialect_runner.ex` (request-stop override)
- Create: `lib/image_pipe/dialect/failure.ex` (neutral failure provenance)
- Modify: `lib/image_pipe/dialect.ex` (add `Failure` to the Boundary `exports:`)
- Modify: `lib/image_pipe/dialect/native.ex`, `lib/image_pipe/dialect/imgproxy.ex` (add the `execute/4` rescue — layered exception boundary)
- Modify: `lib/image_pipe/dialect/twic_pics.ex` (chain deleted, behaviour implemented, `build_debug` copy deleted)
- Delete: `lib/image_pipe/dialect/twic_pics/negotiation.ex`
- Modify: `lib/image_pipe/dialect/twic_pics/identity.ex` (alias swap)
- Modify: `lib/image_pipe/dialect/twic_pics/errors.ex` (`send/4` → `send/3`)
- Modify: `mix.exs` (retarget the `debug_builder.ex` ExDNA ignore comment — see Step 3.4; the ignore itself **stays**)

- [ ] **Step 1: Runner request-stop override**

In `lib/image_pipe/plug/dialect_runner.ex`, `run/3`, replace the span callback body:

```elixir
    Telemetry.span(Telemetry.telemetry_opts(config), [:request], %{}, fn ->
      {conn, metadata} = route(conn, dialect, config)

      # A committed 200 whose stream then failed: the shared Sender stamps
      # :image_pipe_send_result (:processing_error), and the request span's
      # stop result must agree with the [:send] stop — promoted from the
      # TwicPics chain's request_stop_metadata/2.
      metadata =
        metadata
        |> Map.put(:result, Map.get(conn.private, :image_pipe_send_result, metadata.result))
        |> Map.put(:status, conn.status)

      {conn, metadata}
    end)
```

(Enumerated delta 4 for Native/imgproxy; no suite pins their old `:ok`.)

- [ ] **Step 2: Rewrite `lib/image_pipe/dialect/twic_pics.ex`**

**Keep:** the moduledoc (rewrite to: the dialect owns parse → prepare → ordered pipeline execution → error rendering; the shared runner in `ImagePipe.Plug` owns the lifecycle around them), `detector_identity/2`, `face_assist?/1`, `operation_names/1`.

**Delete:** `@behaviour Plug` + `init/1` + `call/2`, `request_stop_metadata/2`, `route/2` (all heads), `parse_with_span/2`, `execute/3` (the old private lifecycle one — note the behaviour's `execute/4` below is different), `send_parse_error/3`, `send_not_modified/3`, `send_error/4`, `send_with_span/4`, `serve/6` (both heads), `deliver_hit/6`, `generate/7`, `build_fun/4`, `build_and_pump/7`, `run_transform/5`, `transform_stop_metadata/1`, `encode_first_chunk/3`, `encode_stop_metadata/2`, `first_chunk/1`, `materialize_for_delivery/2`, `pipeline_opts/4`, `resolve_output/4`, `result_limits/2`, `min_limit/2`, `delivery_config/2`, and the whole debug block: `build_debug/8`, `negotiated?/1`, `output_quality/2`, `output_distance/1`, `aq_from_meta/2`, `quality_search_score/2`, `quality_search_metric/1`, `native_jxl_search?/1`. Keep `parse_stop_metadata/1` and the small `safe_transform/1` rescue/catch, moving the latter behind the new `execute/4` callback.

**Boundary:** deps drop `ImagePipe.Cache`, `ImagePipe.Debug`, `ImagePipe.Decode`, `ImagePipe.Delivery` and add `ImagePipe.Dialect` — final: `[ImagePipe.Config, ImagePipe.Dialect, ImagePipe.Dialect.SharedConfig, ImagePipe.Error, ImagePipe.Format, ImagePipe.Output, ImagePipe.Plan, ImagePipe.Representation, ImagePipe.Response, ImagePipe.Source, ImagePipe.Telemetry, ImagePipe.Transform]`. (If a submodule still references a dropped boundary the compile fails — restore that dep and note it; expected: none.)

**The new surface:**

```elixir
  @behaviour ImagePipe.Dialect

  alias ImagePipe.Dialect.Negotiation, as: DialectNegotiation
  alias ImagePipe.Dialect.Failure
  alias ImagePipe.Dialect.Resolved
  alias ImagePipe.Dialect.TwicPics.Config
  alias ImagePipe.Dialect.TwicPics.Errors
  alias ImagePipe.Dialect.TwicPics.Identity
  alias ImagePipe.Dialect.TwicPics.Manipulation
  alias ImagePipe.Dialect.TwicPics.Path
  alias ImagePipe.Dialect.TwicPics.Pipeline
  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Dialect.TwicPics.RequestBuilder
  alias ImagePipe.Error
  alias ImagePipe.Plan.Operation, as: PlanOperation
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform

  @impl ImagePipe.Dialect
  def validate_config!(opts), do: Config.validate!(opts)

  @impl ImagePipe.Dialect
  def parse(%Plug.Conn{} = conn, config) do
    result =
      with {:ok, source, manipulation} <- Path.extract(conn),
           {:ok, chain} <- Manipulation.parse(manipulation) do
        RequestBuilder.build(source, chain, config)
      end

    runner_result =
      case result do
        {:error, reason} -> {:error, %Failure{phase: :parse, reason: reason}}
        success -> success
      end

    {runner_result, parse_stop_metadata(result)}
  end

  defp parse_stop_metadata({:ok, %Request{}}), do: %{result: :ok}

  defp parse_stop_metadata({:error, reason}),
    do: %{result: :error, error: Error.tag(reason)}

  @impl ImagePipe.Dialect
  def prepare(%Plug.Conn{} = conn, %Request{} = request, config) do
    {:ok,
     %Resolved{
       request: request,
       source: request.source,
       negotiation: fn -> negotiation_result(conn, request, config) end,
       response_meta: request.response,
       operations: operation_names(request),
       auto_rotate?: request.auto_rotate,
       debug?: request.response.debug?,
       terminal: :image,
     }}
  end

  # The runner invokes this thunk only after Source.resolve. Negotiation,
  # detector callbacks, and identity construction keep their old precedence.
  defp negotiation_result(conn, %Request{} = request, config) do
    case DialectNegotiation.negotiate(conn, request.output, config) do
      {:ok, negotiation} ->
        {:ok, negotiation,
         Identity.material(request, negotiation, conn, config, detector_identity(request, config))}

      {:error, _reason} = error ->
        error
    end
  end

  @impl ImagePipe.Dialect
  def decode_request(%Request{} = request, geometry),
    do: Pipeline.decode_request(request, geometry)

  @impl ImagePipe.Dialect
  def execute(state, geometry, %Request{} = request, opts) do
    safe_transform(fn -> Pipeline.run(state, geometry, request, opts) end)
  end

  @impl ImagePipe.Dialect
  def render_error(conn, %Failure{phase: :parse, reason: reason}, config),
    do: Errors.send_parse(conn, reason, config)

  def render_error(conn, reason, config), do: Errors.send(conn, reason, config)

  @impl ImagePipe.Dialect
  def classify_error(%Failure{phase: :parse}), do: :parser_error
  def classify_error(reason), do: Telemetry.request_result({:error, reason})
```

`Failure` preserves provenance structurally, so an unknown future lifecycle reason remains a 500/`:processing_error` while an unknown parse rejection remains a 400/`:parser_error`. Do not infer provenance from a tag allowlist.

**No `exception_boundary` field — converge on the layered boundary instead** (decided; supersedes the earlier draft that carried the divergence as a `%Resolved{}` value).

Today the runner rescues around all of `produce_stream` (`dialect_runner.ex:428-432`) while TwicPics rescued only `run_transform` (`twic_pics.ex:437-443`), so an unexpected exception in a shared post-transform stage (clamp / materialize / encode-first-chunk) is a 422 `{:transform, _}` on imgproxy/Native but a 500-class delivery-session failure on TwicPics. No test pins the difference — the only transform-failure telemetry scenario uses a *returned* error (`imgproxy_telemetry_contract_test.exs:511`), not a raise.

Converge so each layer converts its own failures:

1. **Each dialect rescues its own pipeline run inside `execute/4`.** TwicPics already has `safe_transform/1`; add the same small rescue/catch to `ImagePipe.Dialect.Native.execute/4` and `ImagePipe.Dialect.Imgproxy.execute/4`, producing `{:error, {:transform, {exception, __STACKTRACE__}}}` / `{:error, {:transform, {kind, reason}}}` exactly as the runner does today. Transform crashes therefore stay 422 for every dialect — no change to any existing pin.
2. **The runner stops broadly rescuing.** Delete the `rescue`/`catch` clauses on `produce_stream/8`. An exception escaping a shared post-transform stage now propagates to the delivery session and renders 500-class, for every dialect.

Why, rather than preserving both: `%Resolved{}` is public SDK surface under U6, and a knob whose only meaning is "which historical accident do you want" is the leak U3/U4 exist to prevent — Phase C's Declarative base would have to pick a value for reasons nobody can state. It is also what AGENTS.md already prescribes ("do not rescue trusted transform callback failures"): the runner laundering raises from a trusted callback lets a dialect silently violate `execute/4`'s documented tagged-tuple contract, while a dialect rescuing its own libvips pipeline is a concrete runtime boundary. And semantically, an unexpected crash in a shared stage is our bug, not the client's — 4xx would both misattribute it and signal "do not retry".

This lands as **enumerated delta 10**. It is an intentional behavior change on a path with no existing coverage; Task 7 Step 3 adds the pin.

In the runner's error metadata, unwrap `%Failure{reason: reason}` only for `Error.tag/1`; pass the wrapper unchanged to `classify_error/1` and `render_error/3` so the dialect can act on phase.

- [ ] **Step 3: Delete the dialect Negotiation, swap Identity, shrink Errors, mix.exs**

1. `rm lib/image_pipe/dialect/twic_pics/negotiation.ex`
2. `lib/image_pipe/dialect/twic_pics/identity.ex`: `alias ImagePipe.Dialect.TwicPics.Negotiation` → `alias ImagePipe.Dialect.Negotiation`; update the `@spec`.
3. `lib/image_pipe/dialect/twic_pics/errors.ex`: `send/4` → `send/3` exactly as imgproxy's (drop the headers param from every clause and `send_core/4` → `/3`, delete `put_headers/2` and `@type header`).
4. `lib/image_pipe/dialect.ex`: add `Failure` to the Boundary `exports:` — it is `exports: [DebugContext, Negotiation, RenderTerminal, Resolved]` today (`:29`). `ImagePipe.Dialect.TwicPics` and `ImagePipe.Plug.DialectRunner` are separate boundaries referencing `%Failure{}` across the boundary line, so without this the Step-4 compile fails.
5. `mix.exs`: **keep** `"lib/image_pipe/plug/debug_builder.ex"` in `@ex_dna_ignores` and rewrite its comment to name the surviving twin:

```elixir
    # Mirrors the framework Request.DeliveryBuild debug block until Phase C
    # deletes the framework stack.
```

   The TwicPics copy is not the only twin: `lib/image_pipe/request/delivery_build.ex:201-293` carries the same block (`negotiated?/1` at `:244-245`, `quality_search_metric/1` at `:282-290`, and `native_jxl_search?/1` at `:292-293` are byte-identical to `debug_builder.ex:49-50, 98-109`), and it dies with Phase C's framework deletion, not here. Removing the ignore now fails `credo --strict`.

- [ ] **Step 4: Compile**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix credo --strict`
Expected: clean. (TwicPics suites are red until Task 7's mount swap — do not run them yet.) Credo is clean because the `debug_builder.ex` ignore was retained, not removed.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plug/dialect_runner.ex lib/image_pipe/dialect.ex lib/image_pipe/dialect/failure.ex lib/image_pipe/dialect/resolved.ex lib/image_pipe/dialect/twic_pics.ex lib/image_pipe/dialect/twic_pics/ mix.exs
git commit -m "Port Dialect.TwicPics onto the contract; promote the request-stop override (Phase B task 6)"
```

---

### Task 7: TwicPics test mounts + debug-pin flips (suites gate the port)

**Files** (direct TwicPics references plus polymorphic callers):
- Modify: `test/image_pipe/twic_pics_wire_conformance_test.exs`, `test/image_pipe/twic_pics_telemetry_contract_test.exs`, `test/image_pipe/dialect/twic_pics/{config,debug,error_paths,lifecycle,parse}_test.exs`
- Modify: `test/image_pipe/dialect/twic_pics/identity_test.exs`, `test/image_pipe/dialect/twic_pics/negotiation_test.exs` (promoted seam)
- Modify: `test/image_pipe/dialect/twic_pics/errors_test.exs` (send/3 arity, if it passes headers)
- Modify: `test/image_pipe/twicpics_differential/constellations_test.exs`, `test/support/mix/tasks/twicpics.gen_fixtures.ex` (parse-shape destructure)
- Modify: `test/support/image_pipe/contract_kit/cache_key.ex`, `test/support/image_pipe/contract_kit/request_safety.ex`
- Modify: `test/image_pipe/dialect/native_contract_test.exs` (delete the `Mount` shim — see Step 1)
- Modify: `test/image_pipe/dialect/inbound_trace_test.exs` (imgproxy **and** Native legs)
- Modify: `test/support/image_pipe/test/differential/harness.ex`, both dialect-specific differential wrappers

- [ ] **Step 1: Mount swaps**

Same shape as Task 4, e.g. `debug_test.exs`:

```elixir
  defp opts(extra \\ []) do
    ImagePipe.Plug.init(Keyword.merge([dialect: TwicPics, sources: @default_sources], extra))
  end

  defp get(path, config) do
    :get
    |> conn(path)
    |> ImagePipe.Plug.call(config)
  end
```

Apply to every `TwicPics.init`/`TwicPics.call` site the direct-reference search finds. `config_test.exs` keeps calling `Config.validate!/1` directly.

Now that both dialects implement the contract, migrate the polymorphic helpers that literal module-name searches missed:

- `ContractKit.CacheKey` and `ContractKit.RequestSafety`: initialize and call `ImagePipe.Plug` with `dialect: dialect` (`cache_key.ex:176`, `request_safety.ex:115`).
- **`test/image_pipe/dialect/native_contract_test.exs`: delete the `ImagePipe.Dialect.NativeContractTest.Mount` shim** (`:1-9`) and pass `dialect: ImagePipe.Dialect.Native` in both `use` lines (`:22-23`). The shim is an `init/1`+`call/2` wrapper that Native's kit sites pass as `dialect:`; once the kits mount `ImagePipe.Plug` themselves, the kit would call `Mount.validate_config!/1`, which does not exist — an `UndefinedFunctionError` in `setup` that Step 5's `test/image_pipe/dialect/` run would surface.
- `inbound_trace_test.exs`: this file has **two** legs — an `"ImagePipe.Dialect.Imgproxy"` describe (`:53`, passing `ImgproxyDialect` as the helper's `mod` at `:56`) and an `"ImagePipe.Dialect.Native"` describe (`:95`, already passing `ImagePipe.Plug` + `dialect: NativeDialect`). Drop `mod` from the helper (`:50`, `mod.call(conn, mod.init(init_opts))`), always mount `ImagePipe.Plug`, and move the imgproxy leg's dialect into `init_opts` as `dialect: ImgproxyDialect`. There is no TwicPics leg in this file.
- Shared differential harness: switch `dialect_plug_opts/2` to `ImagePipe.Plug`, restore both wrappers to that helper, and remove Task 4's temporary imgproxy-local construction. Its `@doc` (`differential/harness.ex:29-34`) still says "The dialect IS the plug and takes one flat keyword list, so there is no `:parser` key to pass — that is the whole point of the inversion"; that is now false — rewrite it to describe the unified `ImagePipe.Plug, dialect:` mount.

Run `rg -n "\b(dialect|mod)\\.(init|call)\\(" test/` and inspect every remaining dynamic dispatch. None may target Imgproxy or TwicPics.

- [ ] **Step 2: Direct parse callers**

`test/image_pipe/dialect/twic_pics/parse_test.exs`, `test/image_pipe/twicpics_differential/constellations_test.exs`, and `test/support/mix/tasks/twicpics.gen_fixtures.ex` call `TwicPics.parse/2` directly. Validate config with `TwicPics.validate_config!/1`, destructure `{result, _span_metadata}`, and match on `result`.

```elixir
    dialect_opts = TwicPics.validate_config!([])
    ...
    {result, _span_metadata} = TwicPics.parse(conn(:get, path), dialect_opts)
```

The parse unit helper should unwrap `%ImagePipe.Dialect.Failure{phase: :parse, reason: reason}` back to `{:error, reason}` so its grammar assertions remain about the parser. Add one direct assertion that `TwicPics.parse/2` returns the marked failure and correct span metadata.

- [ ] **Step 3: Promoted-struct/seam swaps**

- `identity_test.exs`: alias → `ImagePipe.Dialect.Negotiation`; add `plan_output: nil` (and `policy: nil` where absent) to struct constructions — the promoted struct enforces five keys where the TwicPics one enforced four.
- `negotiation_test.exs`: the module under test is deleted; the same assertions now run against the promoted seam — `ImagePipe.Dialect.Negotiation.negotiate(conn, request.output, config)`. If every assertion duplicates `test/image_pipe/dialect/negotiation_test.exs` (Phase A), delete the file instead (post-migration parity pins are deleted per the test guidelines); keep only assertions covering behavior the Phase A file lacks (e.g. TwicPics-specific `auto_avif: false` defaults interacting with `negotiate/3` — those move into the wire suite's existing `output=auto` coverage or stay here against the promoted seam).
- `errors_test.exs`: drop the headers argument from any `Errors.send/4` call (assertions on status/body unchanged; delete any test whose only subject was the headers parameter — that behavior now lives in the runner and is pinned by Task 1).
- Add provenance pins: an unknown `%Failure{phase: :parse, reason: {:future_parse_failure, :detail}}` renders 400 and classifies `:parser_error`; the same raw term as a post-parse failure renders 500 and classifies `:processing_error`. This guards against reintroducing reason-shape inference.
- Add a detector spy request whose source resolution fails. Assert the source response wins and the detector identity callback is never invoked; this verifies the Task 1 thunk through the TwicPics integration.
- Add a pre-first-chunk post-transform exception test using the existing `:image_module` seam to raise during forced clamp. Pin 500-class status/body, cache-sink abort/no commit, bracket cleanup, and request-stop result. Add the **same** test to the imgproxy and Native suites — for those two this is enumerated delta 10 (422 → 500-class), so all three dialects must be pinned together. A `Pipeline.run/4` raise stays 422 with a normal `[:transform, :execute, :stop]` for every dialect, proving each `execute/4` rescue owns only its own boundary.

- [ ] **Step 4: Flip the delta-5 absence pins**

In `test/image_pipe/dialect/twic_pics/debug_test.exs`, replace the **three** absence assertions at lines 69-71 (`source-size`, `source-color-space`, `source-icc`, all `== nil`) with these six — the last three (`source-bit-depth`, `source-alpha`, `source-orientation`) are new assertions with no current counterpart:

```elixir
      assert header(conn, "x-imagepipe-source-size") == "851508"
      assert header(conn, "x-imagepipe-source-color-space") == "VIPS_INTERPRETATION_sRGB"
      assert header(conn, "x-imagepipe-source-icc") == "true"
      assert header(conn, "x-imagepipe-source-bit-depth") == "8"
      assert header(conn, "x-imagepipe-source-alpha") == "false"
      assert header(conn, "x-imagepipe-source-orientation") == nil
```

These values come from a HEAD runtime probe of the committed fixture. Extend stored-facts replay with all five present headers and assert orientation remains absent on both miss and hit.

- [ ] **Step 5: Run the TwicPics suites**

Run: `mise exec -- mix test test/image_pipe/dialect/ test/image_pipe/twic_pics_wire_conformance_test.exs test/image_pipe/twic_pics_telemetry_contract_test.exs test/image_pipe/imgproxy_differential_conformance_test.exs test/image_pipe/twicpics_differential_conformance_test.exs test/image_pipe/twicpics_differential/ && mise exec -- mix compile --warnings-as-errors`
Expected: PASS. Both differential lanes must run because their shared mount helper changed. The `:streamed_error` scenario proves the request-stop override; the new exception tests prove TwicPics' narrower rescue boundary. No fixture, verdict, or tolerance changes.

- [ ] **Step 6: Commit**

```bash
git add -A test/
git commit -m "Mount TwicPics suites through ImagePipe.Plug; flip delta-5 debug pins (Phase B task 7)"
```

---

### Task 8: Fiddle mounts + docs (#462 closure surface)

**Files:**
- Modify: `fiddle/lib/image_pipe_fiddle/application.ex`
- Modify: `fiddle/lib/image_pipe_fiddle_web/imgproxy.ex`, `fiddle/lib/image_pipe_fiddle_web/twic_pics.ex`
- Modify: `fiddle/test/image_pipe_fiddle/imgproxy_source_mounts_test.exs`, `fiddle/test/image_pipe_fiddle_web/wire_test.exs`
- Modify: `docs/debug_headers.md`, `docs/imgproxy_support_matrix.md`, `docs/imgproxy_path_api.md`, `docs/execution_flow.md`, `docs/content-aware-gravity.md`, `docs/custom_parser_guide.md`, plus any current `docs/` or `README.md` reference the inventory finds

- [ ] **Step 1: Fiddle mounts**

In `fiddle/lib/image_pipe_fiddle/application.ex`:

`build_imgproxy_opts/0` — enable debug and init through the Plug (delete the three-line "serves no X-ImagePipe-* debug headers" comment cleanly; the flat-keyword comment stays):

```elixir
  defp build_imgproxy_opts do
    imgproxy = Application.fetch_env!(:image_pipe_fiddle, :imgproxy)

    [
      dialect: ImagePipe.Dialect.Imgproxy,
      sources: imgproxy_source_mounts(),
      # Graceful fallback: detection failures degrade to attention crop (200) rather
      # than erroring; the default Logger surfaces any detection fallback.
      detector_required: false,
      allow_debug_headers: true
    ]
    # The dialect takes one flat keyword list; the :imgproxy env sublist
    # (signature, smart_crop_face_detection) merges in at the top level.
    |> Keyword.merge(imgproxy)
    |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
    |> ImagePipe.Plug.init()
  end
```

`build_twicpics_opts/0` — same shape: prepend `dialect: ImagePipe.Dialect.TwicPics,` to the list and end with `|> ImagePipe.Plug.init()`.

Both forward wrappers (`ImagePipeFiddleWeb.Imgproxy`, `ImagePipeFiddleWeb.TwicPics`): replace `ImagePipe.Dialect.<X>.call(conn, …)` with `ImagePipe.Plug.call(conn, …)` (persistent-term lookups unchanged); update each `@moduledoc` sentence. The IIIF wrapper is untouched.

Update `imgproxy_source_mounts_test.exs` to initialize through `ImagePipe.Plug.init(dialect: ImagePipe.Dialect.Imgproxy, ...)`. Add a Fiddle wire test whose signed imgproxy preview path already contains `debug:1`; assert 200 and representative source, output, and timing headers. The generic signed-request test remains.

No `fiddle/assets` change: the imgproxy debug-trigger injection (`debugTriggerPath` signing the `debug:1`-augmented path for the preview) already ships and was inert only because the server emitted nothing.

- [ ] **Step 2: `docs/debug_headers.md`**

- **Enabling §1**: the mount example becomes the unified form:

  ```elixir
  plug ImagePipe.Plug,
    dialect: ImagePipe.Dialect.TwicPics,
    sources: [...],
    allow_debug_headers: true
  ```

  Replace the availability paragraph: debug headers are available on every mount — the dialect mounts (`ImagePipe.Plug, dialect: …`: imgproxy, TwicPics, Native) and the framework `parser:` mount (IIIF). Native currently has no per-request trigger in its grammar, so its responses render none until a trigger is chosen (follow-up issue).
- **Enabling §2**: add the imgproxy trigger bullet: **imgproxy**: the `debug:1` processing option inside the signed path, e.g. `/<signature>/debug:1/rs:fill:400:300/plain/…` (also `debug:true`; `debug:0`/`debug:false` opt out).
- **Security §**: rewrite the imgproxy note — the signature now protects a *disclosing* trigger, which is the point: an attacker cannot append `debug:1` to a signed URL. Drop "Since the imgproxy stack emits no debug headers…".
- **Demo §**: the fiddle configures imgproxy, TwicPics, and IIIF with `allow_debug_headers: true` and injects each stack's trigger (imgproxy signs a `debug:1`-augmented preview path; TwicPics `debug=1`; IIIF `?debug=1`); delete the "panel stays empty" sentence.

- [ ] **Step 3: Conformance + guide docs (surface AND stage/order axes)**

- `docs/imgproxy_support_matrix.md` — **two axes changed, per the AGENTS conformance-sync rule**:
  - *Surface*: re-verify the two debug passages. The extension row (~`:1185`) already describes the restored behavior — confirm it matches the shipped surface (signed `debug:1`, `allow_debug_headers`, identity-excluded) and refresh only if drifted; likewise the "Response headers" paragraph (~`:868`). Rewrite every `ImagePipe.Dialect.Imgproxy.init/1` reference (`:359`, `:577-579` — which adds "before `call/2` ever sees a request" — and `:609`) to `ImagePipe.Plug.init/1` delegating to `Imgproxy.validate_config!/1`.
  - *Stage/order*: the doc currently asserts imgproxy owns its own routing and chain — `:12-16` ("mount it directly as `plug ImagePipe.Dialect.Imgproxy, …`. It owns its whole request chain end to end … no `ImagePipe.Request.*`"), `:412-416` (the "three stacks" enumeration listing the dialect as a peer of `ImagePipe.Plug`), and `:425-426` / `:457` ("routed ahead of the endpoint/pipeline split (`route/2` in `imgproxy.ex`; the shared dialect runner in `ImagePipe.Plug` for Native)"). After Task 3 imgproxy has no `route/2` and *is* served by the shared runner. Rewrite these so no passage claims dialect-owned routing.
  - **Do not** flip the ⭕ marker on `IMGPROXY_ENABLE_DEBUG_HEADERS` (`:1199`) or soften the sentence disclaiming the `X-Origin-*`/`X-Result-*` contract. Upstream's flag is a server-global switch emitting a different header family; restoring ImagePipe's own per-request signed `debug:1` headers does not implement it.
- `docs/twicpics_support_matrix.md` — this **is** a compatibility-target conformance doc under the same rule. Its architecture sentence (`:3`, `:6-7`, "`ImagePipe.Dialect.TwicPics` is a self-contained Plug…") goes stale under delta 9 and needs the same-change rewrite. Its `debug=1` row (`:180`) needs **no** change: it frames `X-ImagePipe-*` as an ImagePipe extension with no TwicPics counterpart, so delta 2's five newly-present source facts make no vendor-parity claim stale. Delta 7 changes only an invalid-value error message, which this doc does not quote.
- `docs/custom_parser_guide.md`: update the Phase A transition sentence ("`ImagePipe.Dialect.Native` is the first ported example while imgproxy/TwicPics still mount directly during the transition") — all three ordered dialects now implement the behaviour and mount through `ImagePipe.Plug, dialect: …`; IIIF remains on the framework `parser:` mount until Phase C.
- Update removed API references in `docs/imgproxy_path_api.md` and `docs/imgproxy_support_matrix.md`. In `docs/execution_flow.md`, replace the direct `TwicPics.call`/"self-contained Plug" description with the unified mount; leave the full one-spine rewrite to Phase C. Refresh direct mounts in `docs/content-aware-gravity.md` and any other current guide found.
- Inventory current sources with a **bare** module search — `rg -n "ImagePipe\\.Dialect\\.(Imgproxy|TwicPics)" README.md docs fiddle`, excluding historical `docs/superpowers/plans/**` and `docs/superpowers/specs/**`. A pattern anchored on `init|call|plug ` misses the `Plug.Router` `forward … to:` form and prose references, which are live and stale:
  - `docs/cache.md:7` and `docs/telemetry.md:16` — `to: ImagePipe.Dialect.Imgproxy,`
  - `docs/cdn-http-cache.md:9` — `to: ImagePipe.Dialect.TwicPics,`
  - `docs/execution_flow.md:35-36` — `ImagePipe.Dialect.TwicPics.call` lifecycle sketch
  - `docs/twicpics_support_matrix.md:3,6-7` — "self-contained Plug"

  Then a second sweep for prose that survives a module rename: `rg -n "route/2|self-contained Plug|owns its whole request chain" README.md docs`. Historical/backlog docs (`docs/imgproxy_dialect_phase2_backlog.md`) describe past states and stay as-is. The active-source result must be empty of *mount-shape* claims after edits.
- `docs/operational_notes.md:238-241` documents a per-request `_debug=1` **query parameter** trigger that no stack uses (imgproxy replaced it with the signed `debug:1` option in #398). Correct it to the per-dialect triggers while this task is already in the debug surface.
- `docs/debug_headers.md:82` gives `srgb` as the `X-ImagePipe-Source-Color-Space` example; the emitted value is `VIPS_INTERPRETATION_sRGB` (as delta 2 and the Task 5/7 assertions pin). Fix it in the same pass.
- `docs/execution_flow.md:120` says `Imgproxy.InfoRenderer` renders `/info` "outside this dispatch point". Still true after the `{:render, %RenderTerminal{}}` move (the runner owns it, not `ImagePipe.Renderer`), but give it a wording pass since this task already opens the file.
- Run Vale over every changed current Markdown file, not a fixed subset. `git diff --name-only` may produce the list, but inspect it before invoking Vale. No new errors are allowed; if the binary is unavailable, report that explicitly.

- [ ] **Step 4: Fiddle gate**

Run: `mise run precommit:fiddle`
Expected: PASS (build assets first if the Vite manifest is missing).

- [ ] **Step 5: Commit**

```bash
git add fiddle/ docs/
git commit -m "Re-enable imgproxy debug headers in the fiddle; sync docs (Phase B task 8, closes #462)"
```

---

### Task 9: Boundaries, ExDNA audit, full gates

**Files:**
- Modify: `test/image_pipe/architecture_boundary_test.exs`
- Modify: `lib/image_pipe/dialect/imgproxy.ex`, `lib/image_pipe/dialect/twic_pics.ex` (+ their submodules) — orphaned inline `# ex_dna:disable-for-next-line` annotations

- [ ] **Step 1: Architecture-test deps pins**

In `test/image_pipe/architecture_boundary_test.exs`:
- Update the imgproxy deps pin ("dialect imgproxy boundary declaration…") to Task 3's final list; extend its `refute_boundary_deps` with `ImagePipe.Cache` and `ImagePipe.Delivery` (now runner-owned), keeping the existing refutes.
- Same for the TwicPics pin with Task 6's final list (refutes gain `ImagePipe.Cache`, `ImagePipe.Debug`, `ImagePipe.Decode`, `ImagePipe.Delivery`).
- The U4 runner-names-no-dialect pin already covers `Imgproxy|TwicPics` — no change.
- Both dialect file maps/globs are unchanged (module paths didn't move).

- [ ] **Step 2: ExDNA annotation audit**

The chain deletions removed most mirrored code. Audit and delete orphaned suppressions whose counterpart died:

```
rg -n "ex_dna:disable" lib/image_pipe/dialect/imgproxy.ex lib/image_pipe/dialect/imgproxy lib/image_pipe/dialect/twic_pics.ex lib/image_pipe/dialect/twic_pics lib/image_pipe/plug/dialect_runner.ex
```

For each hit, check whether the annotated definition still has a living twin (the runner's copy is now the only one for the lifecycle helpers). Delete annotations that no longer suppress anything real; keep ones whose twin survives (e.g. `Identity.canonical/1` exists in both identity modules). Run `mise exec -- mix credo --strict` after each removal batch — credo failing on a removed annotation means the duplication still exists; put it back and note why.

- [ ] **Step 3: Full gates**

Run: `mise run precommit && mise run precommit:fiddle`
Expected: format, compile --warnings-as-errors, credo --strict, full `mix test` (both differential lanes green, no fixture/verdict/tolerance changes), fiddle verify suite — all PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Pin Phase B boundaries; audit ExDNA annotations (task 9)"
```

---

### Task 10: Spec addendum, telemetry pin, and the `debug_info` hook decision

Three loose ends that belong to Phase B's contract, not to Phase C.

**Files:**
- Modify: `docs/superpowers/specs/2026-07-19-dialect-unification-design.md`
- Modify: `test/image_pipe/imgproxy_telemetry_contract_test.exs`
- Modify (conditionally): `lib/image_pipe/dialect.ex`, `lib/image_pipe/plug/debug_builder.ex`

- [ ] **Step 1: Record the phase deltas and contract widenings in the spec**

The spec's "Observable deltas (exhaustive)" list is the U12 contract, and it is now stale: Phase A added three deltas of its own, and Phase B adds deltas 3, 4, 6, 8, 10 (delivery-error headers, request-stop override, parse-span bracketing, `/info` conn path, layered exception boundary) with no spec counterpart. Likewise the spec's typed listings for `Resolved` and `RenderTerminal` predate Phase B's `Failure`, `charset`, and the deferred-negotiation thunk. Delta 10 (the layered exception boundary) also belongs in the addendum.

Append one section, `## Per-phase addenda (deltas and contract widenings beyond the original lists)`, with a short subsection per phase citing each item and its plan task. Phase C builds the Declarative base against these listings, so an unrecorded widening becomes a Phase C surprise.

Also record the U4 wording widening: the runner may branch on shared conn-private state stamped by neutral core (`:image_pipe_send_result`), not only on `Resolved` fields and neutral structs.

- [ ] **Step 2: Gate delta 4 instead of asserting it**

Delta 4 currently rests on an absence claim ("no suite pins the old `:ok`"), which is true — `test/image_pipe/imgproxy_telemetry_contract_test.exs:477-498` (mid-stream encode failure after a committed 200) asserts `[:deliver]`, `[:source, :fetch_decode]`, and `[:encode]` stops only. Extend that scenario with a `[:request]` stop assertion of `%{result: :processing_error, status: 200}` so the promoted override is gated for imgproxy the way `:streamed_error` gates it for TwicPics.

- [ ] **Step 3: Settle the optional `debug_info` hook**

Spec U13 says the hook "is dropped from the contract if the ports confirm nobody needs it". Phase B ports the last two ordered dialects, so the evidence is now complete: if neither imgproxy nor TwicPics implements `debug_info/1`, delete the optional callback from `ImagePipe.Dialect` and the `function_exported?(dialect, :debug_info, 1)` probe from `ImagePipe.Plug.DebugBuilder.build/2`, which then calls the default builder directly.

This also retires an AGENTS.md violation: runtime callback-presence probes are forbidden for trusted internal dispatch ("call the callback directly and let missing callbacks raise"). The same objection applies to `classify/2`'s `function_exported?(dialect, :classify_error, 1)` in the runner — but `classify_error/1` has real optionality (the fixture dialect and any host dialect may omit it), so leave it and note the asymmetry. If a reason to keep `debug_info/1` emerges during the ports, record it in the spec addendum from Step 1 instead of deleting.

- [ ] **Step 4: File the Native debug-trigger follow-up**

Delta 7 and Task 8's `docs/debug_headers.md` copy both promise the Native trigger is "tracked". Open the issue (Native gains the debug *capability* via SharedConfig but has no grammar trigger; choosing one — an out-of-band `?debug=1` like IIIF's, or a grammar option — is a dialect-surface decision) and replace the parenthetical in the doc with its number. Do not leave "follow-up issue" unresolved in shipped prose.

- [ ] **Step 5: Run and commit**

Run: `mise exec -- mix test test/image_pipe/imgproxy_telemetry_contract_test.exs test/image_pipe/dialect/ && mise run precommit`

```bash
git add -A
git commit -m "Record Phase B contract widenings; gate the request-stop override (task 10)"
```

---

## Phase B exit criteria

- `mise run precommit` and `mise run precommit:fiddle` green.
- imgproxy + TwicPics wire/telemetry/differential suites pass with no assertion changes beyond the enumerated deltas and the new provenance, exception-boundary, signed-debug, and source-fact compatibility pins.
- `lib/image_pipe/request/**`, `lib/image_pipe/parser/**`: zero diffs.
- The runner still names no dialect (architecture-test-pinned). New dispatch uses neutral `%Negotiation{}`, `%RenderTerminal{charset: ...}`, `%Failure{}`, and `conn.private[:image_pipe_send_result]` values only. No `exception_boundary` knob exists: each dialect's `execute/4` rescues its own pipeline and the runner rescues nothing.
- #462's acceptance surface is present: imgproxy debug wire coverage (Task 5), fiddle mount re-enabled, `docs/debug_headers.md` updated. The PR body carries a bare `Fixes #462` line.
- `Imgproxy.init/1`, `Imgproxy.call/2`, `TwicPics.init/1`, `TwicPics.call/2`, both dialect `Negotiation` modules, TwicPics' `build_debug` block, and the `NativeContractTest.Mount` shim no longer exist.
- The spec's per-phase addendum records every delta and contract widening Phase B introduced (Task 10), so Phase C's Declarative base is built against an accurate contract listing.
- `mix.exs` still ignores `lib/image_pipe/plug/debug_builder.ex` for ExDNA, with a comment naming the framework `Request.DeliveryBuild` twin that Phase C deletes.

Phase C (Declarative base, `Dialect.IIIF`, framework-stack deletion, `http_cache`/`RenderTerminal` cache/offers widening, telemetry-surface sync, docs rewrite) gets its own plan after Phase B merges.

**Notes for Phase C picked up here:** none new. Phase B resolves delivery-error headers, deferred negotiation, parse provenance, render charset, and the exception boundary (converged, no contract knob). The remaining staged widenings are U8b `http_cache` and U11 render `cache:`/`offers`.
