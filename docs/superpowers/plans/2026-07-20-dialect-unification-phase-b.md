# Dialect Unification Phase B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port `ImagePipe.Dialect.Imgproxy` and `ImagePipe.Dialect.TwicPics` onto the Phase A `ImagePipe.Dialect` contract + `ImagePipe.Plug` runner, restore imgproxy debug headers (closes #462), and move `allow_debug_headers` to `SharedConfig` — Phase B of `docs/superpowers/specs/2026-07-19-dialect-unification-design.md`.

**Architecture:** Both ordered dialects shrink to the six-callback contract (`validate_config!`/`parse`/`prepare`/`decode_request`/`execute`/`render_error` + `classify_error`), deleting their hand-mirrored lifecycle chains; their per-dialect `Negotiation` structs are replaced by the promoted `ImagePipe.Dialect.Negotiation`. imgproxy's `/info` becomes a `{:render, %RenderTerminal{}}` terminal; TwicPics' debug build is replaced by the runner's default builder (its private copy dies). Two runner behaviors are promoted from the dialect chains, resolving the Phase A exit-note design question: (1) the negotiated policy's headers ride delivery errors (stamped on the conn before `render_error`), and (2) the `[:request]` span's stop result honors `Sender`'s mid-stream `:image_pipe_send_result` override.

**Tech Stack:** Elixir, Plug, Boundary, Vix/libvips, ExUnit. All commands via `mise exec -- …`.

## Global Constraints

- Run every mix command through `mise exec -- …` (fresh worktree: `mise trust` + `mise run setup` first; fiddle gate may need `pnpm -C fiddle/assets run build` once).
- Per-dialect observables are gated: the imgproxy and TwicPics wire, differential, and telemetry suites must pass unchanged except the deltas this plan enumerates (see **Enumerated observable deltas** below). No differential fixture, verdict, or tolerance changes.
- U4 anti-leak rule: the runner branches only on `%Resolved{}` fields and neutral core structs — never on dialect identity. The two new runner branches dispatch on `%Negotiation{policy: …}` (a `Resolved.negotiation` value) and on `conn.private[:image_pipe_send_result]` (stamped by the shared `Response.Sender`).
- No changes under `lib/image_pipe/parser/**` or `lib/image_pipe/request/**` (the framework path and IIIF are Phase C).
- Subagents must not run state-mutating git commands (`stash`, `reset`, `checkout --`, `clean`) — worktrees share one stash stack.
- Commit after every task; end commit messages with the repo's Claude trailer (`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`).

## Enumerated observable deltas (exhaustive for Phase B)

1. **imgproxy debug headers restored** (spec delta 5, closes #462). Under `allow_debug_headers: true` + the signed `debug:1` option, imgproxy responses regain `X-ImagePipe-*` and `Server-Timing`, built by the runner's default builder. The flag stays identity-excluded. New wire coverage (Task 5). Fiddle mount + `docs/debug_headers.md` updated (Task 8).
2. **TwicPics debug responses gain the source-fact headers** (spec delta 5). Six facts collected; nil facts render no header, so `beach.jpg` gains five (`source-size`, `source-color-space`, `source-icc`, `source-bit-depth`, `source-alpha`; no EXIF orientation header on that fixture). The three absence pins in `test/image_pipe/dialect/twic_pics/debug_test.exs:70-72` flip to presence assertions; every other TwicPics debug header is reproduced exactly.
3. **Delivery-error policy headers become runner-owned** (the Phase A exit-note resolution). The runner stamps `negotiation.policy.headers` onto the conn before `render_error` on `Delivery.stream` failures only. imgproxy/TwicPics: byte-identical to their current `Errors.send/4` headers. **Native** (already on the runner) gains the behavior: an image-terminal delivery failure under automatic output now carries `Vary: Accept` (no existing test pins its absence; the runner suite pins the new behavior in Task 1).
4. **`[:request]` stop result honors the mid-stream send override for every dialect.** Promoted from the TwicPics chain (`request_stop_metadata/2`): when `Sender` stamps `:image_pipe_send_result` (a committed 200 whose stream then fails), the request span's stop `result` becomes `:processing_error` instead of `:ok`. TwicPics: unchanged (pinned by `twic_pics_telemetry_contract_test.exs` `:streamed_error`). Native/imgproxy: telemetry-only delta, no suite pins the old `:ok`.
5. **Cache entries for imgproxy and TwicPics now store a `Debug.Info`** built unconditionally by the default builder (Phase A delta (b), extended). Internal for imgproxy until the host enables rendering; TwicPics already stored one.
6. **imgproxy `[:parse]` span brackets the endpoint split** (`Path.split_endpoint` moves inside the runner's span). Timing-only; span metadata shapes unchanged.
7. **Config surface:** `allow_debug_headers` becomes a `SharedConfig` key — every dialect accepts it (imgproxy previously rejected it as unknown; Native gains the capability with no grammar trigger — choosing a trigger is a tracked follow-up, not this work). An invalid value now raises the shared message (`invalid ImagePipe shared runtime options: …`) instead of the TwicPics one.
8. **Detector-identity timing:** resolved during `prepare` (pre-`Source.resolve`, only when negotiation succeeds) instead of post-resolve. `Transform.detector_identity/2` is config/model introspection with no source dependency; observable only to a detector spy on a request whose source later fails.
9. **Mount shape:** `plug ImagePipe.Dialect.Imgproxy, …` / `plug ImagePipe.Dialect.TwicPics, …` become `plug ImagePipe.Plug, dialect: …, <same flat config>`. `Imgproxy.init/1|call/2` and `TwicPics.init/1|call/2` no longer exist. `TwicPics.parse/2` keeps its name but returns the behaviour shape `{parse_result, span_stop_metadata}` — its two out-of-suite callers (gen_fixtures task, constellations test) destructure it.

Everything not listed is gated to remain byte-identical by the existing suites.

## File Structure (Phase B end state)

```
lib/image_pipe/plug/dialect_runner.ex            MOD  policy headers on delivery errors; request-stop override
lib/image_pipe/dialect/shared_config.ex          MOD  + allow_debug_headers key (default false)
lib/image_pipe/dialect/twic_pics/config.ex       MOD  − allow_debug_headers (moved to SharedConfig)
lib/image_pipe/dialect/imgproxy.ex               MOD  chain deleted; behaviour implemented
lib/image_pipe/dialect/imgproxy/negotiation.ex   DEL  replaced by ImagePipe.Dialect.Negotiation
lib/image_pipe/dialect/imgproxy/identity.ex      MOD  alias swap to the promoted struct
lib/image_pipe/dialect/imgproxy/errors.ex        MOD  send/4 → send/3 (headers now runner-stamped)
lib/image_pipe/dialect/twic_pics.ex              MOD  chain deleted; behaviour implemented; build_debug deleted
lib/image_pipe/dialect/twic_pics/negotiation.ex  DEL  replaced by ImagePipe.Dialect.Negotiation
lib/image_pipe/dialect/twic_pics/identity.ex     MOD  alias swap
lib/image_pipe/dialect/twic_pics/errors.ex       MOD  send/4 → send/3
mix.exs                                          MOD  drop debug_builder.ex ExDNA ignore (TwicPics copy gone)
test/support/image_pipe/test/runner_fixture_dialect.ex   MOD  ?format=auto (automatic output)
test/support/image_pipe/test/differential/harness.ex     MOD  dialect arm mounts via ImagePipe.Plug
test/image_pipe/plug_dialect_runner_test.exs             MOD  vary-on-delivery-error pins
test/image_pipe/dialect/imgproxy/debug_headers_wire_test.exs  NEW  #462 acceptance
test/image_pipe/architecture_boundary_test.exs   MOD  imgproxy/TwicPics deps pins pruned
fiddle/lib/image_pipe_fiddle/application.ex      MOD  Plug-mode init; imgproxy allow_debug_headers: true
fiddle/lib/image_pipe_fiddle_web/imgproxy.ex     MOD  ImagePipe.Plug.call
fiddle/lib/image_pipe_fiddle_web/twic_pics.ex    MOD  ImagePipe.Plug.call
docs/debug_headers.md                            MOD  imgproxy emits; mount examples; demo section
docs/imgproxy_support_matrix.md                  MOD  verify/refresh debug rows (surface axis)
docs/custom_parser_guide.md                      MOD  "transition" sentence updated
+ per-suite test mounts swapped (enumerated in Tasks 4 and 7)
```

---

### Task 1: Runner — negotiated policy headers ride delivery errors

Resolves the Phase A exit-note design question: rather than growing `render_error`'s arity, the runner stamps the negotiated policy's headers onto the conn before calling `render_error` — headers set on a conn survive `send_resp`, so every dialect's error renderer inherits them without signature changes. This mirrors the dialect chains exactly: only `Delivery.stream` failures carry them (a source FETCH failure varies, a source RESOLVE or negotiation failure does not — the asymmetry documented in `ImagePipe.Dialect.Imgproxy.Errors`' moduledoc).

**Files:**
- Modify: `lib/image_pipe/plug/dialect_runner.ex`
- Modify: `test/support/image_pipe/test/runner_fixture_dialect.ex`
- Test: `test/image_pipe/plug_dialect_runner_test.exs`

**Interfaces:**
- Consumes: `ImagePipe.Dialect.Negotiation` (`.policy`), `ImagePipe.Output.Policy` (`.headers`, `[{"vary", "Accept"}]` for automatic mode via `Policy.automatic_headers/0`, `[]` for explicit).
- Produces: delivery-error responses carrying `negotiation.policy.headers`. Tasks 3 and 6 rely on this to shrink `Errors.send/4` to `/3` without losing the Vary-on-error behavior.

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

1. Alias `ImagePipe.Output.Policy` (add to the alias list).
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

- [ ] **Step 5: Run the runner + native suites**

Run: `mise exec -- mix test test/image_pipe/plug_dialect_runner_test.exs test/image_pipe/dialect/ && mise exec -- mix compile --warnings-as-errors`
Expected: all PASS (Native's suites pin no vary-absence on delivery errors — enumerated delta 3).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/plug/dialect_runner.ex test/support/image_pipe/test/runner_fixture_dialect.ex test/image_pipe/plug_dialect_runner_test.exs
git commit -m "Runner stamps negotiated policy headers on delivery errors (Phase B task 1)"
```

---

### Task 2: `allow_debug_headers` moves to `SharedConfig`

**Files:**
- Modify: `lib/image_pipe/dialect/shared_config.ex`
- Modify: `lib/image_pipe/dialect/twic_pics/config.ex`
- Test: `test/image_pipe/dialect/shared_config_test.exs`, `test/image_pipe/dialect/twic_pics/config_test.exs`

**Interfaces:**
- Produces: `SharedConfig.keys/0` includes `:allow_debug_headers`; `validate_runtime!/1` defaults it to `false` and validates `:boolean`. Every dialect config module that splits on `SharedConfig.keys/0` (imgproxy, TwicPics, Native) accepts it from here on. The runner already reads it (`delivery_config/2`, `Keyword.get(config, :allow_debug_headers, false)`).
- The framework `Request.Options` copy (IIIF's) is untouched — Phase C deletes it.

- [ ] **Step 1: Write the failing test**

Append to `test/image_pipe/dialect/shared_config_test.exs` (follow the file's existing assertion style):

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

In `test/image_pipe/dialect/twic_pics/config_test.exs`, the "detector and debug options reject malformed values" test lists `allow_debug_headers: "yes"` expecting the TwicPics message. Remove that row from the `for` list — its validation now lives in `shared_config_test.exs` (Step 1). Keep the two detector rows. The passing-value assertions (`validated[:allow_debug_headers] == false` / `== true`) stay — the key still comes back through `Config.validate!/1`'s shared merge.

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
         negotiation: negotiation_result(conn, request, operations, config),
         response_meta: response_meta,
         operations: operation_names(request),
         auto_rotate?: request.auto_rotate,
         debug?: response_meta.debug?,
         terminal: :image
       }}
    end
  end

  # Deferred, coupled result (spec §Resolved): the runner unwraps it after
  # Source.resolve, preserving source-before-negotiation error precedence.
  # The detector identity is resolved only when negotiation succeeds
  # (matching the chain, where a negotiation failure never reached it) and
  # is folded into the identity material exactly as before.
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
- Prune the alias list to what the remaining code references (`Cache`, `Delivery`, `StreamPull`, `Clamp`, `Encoder`, `Negotiate`, `Policy`, `ResolvedOutput`, `Materializer`, `State`, `Representation`, `CacheHeaders`, `Conditional`, `CORS`, `Sender`, `ImageSource`, `VipsImage`… go; keep `Assembly`, `Config`, `Decode`, `Errors`, `Identity`, `InfoRenderer`, `Options`, `Path`, `Pipeline`, `PlanOperation`, `PlanResponse`, `Request`, `ResponseMeta`, `Signature`, `ImgproxySource`, `SourceEncryption`, `SourceGeometry`, `SourceInfo`, `Telemetry`, `Error`, and `VipsImage` **stays** — `exif_orientation/1` reads the header). `mix compile --warnings-as-errors` enforces exactness.
- `source_info/2` takes `(resolved, config)` and internally forces `auto_rotate?: false` — unchanged.

- [ ] **Step 2: Delete the dialect Negotiation, swap Identity's alias, shrink Errors**

1. `rm lib/image_pipe/dialect/imgproxy/negotiation.ex`
2. In `lib/image_pipe/dialect/imgproxy/identity.ex`: replace `alias ImagePipe.Dialect.Imgproxy.Negotiation` with `alias ImagePipe.Dialect.Negotiation`. The `%Negotiation{}` match and the `selected`/`vary?`/`policy_material` reads compile unchanged (the promoted struct is a superset). Update the `@spec material/5` reference and the moduledoc sentence naming "Task 17's `negotiate/3`" to name `ImagePipe.Dialect.Negotiation.negotiate/3`.
3. In `lib/image_pipe/dialect/imgproxy/errors.ex`: the `headers` parameter is dead (the runner stamps policy headers on the conn before `render_error` — Task 1). Change `send/4` to `send/3`: drop the `headers \\ []` default head, drop the `headers` argument from every clause and from `send_signature_error/3` → `/2` and `send_core_stage_error/4` → `/3`, and delete `put_headers/2` and the `@type header()` if now unused. Rewrite the "Negotiation headers ride the error" moduledoc section to two sentences: the negotiated policy's headers are stamped by the runner (`ImagePipe.Plug`) on delivery failures before this module renders; only post-negotiation delivery failures carry them, preserving the framework's fetch-vs-resolve Vary asymmetry.

- [ ] **Step 3: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile. (Test suites are red until Task 4's mount swap — that is expected; do NOT run the imgproxy suites yet.)

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/dialect/imgproxy.ex lib/image_pipe/dialect/imgproxy/negotiation.ex lib/image_pipe/dialect/imgproxy/identity.ex lib/image_pipe/dialect/imgproxy/errors.ex
git commit -m "Port Dialect.Imgproxy onto the ImagePipe.Dialect contract (Phase B task 3)"
```

---

### Task 4: imgproxy test mounts → `ImagePipe.Plug` (suites must pass unchanged)

**Files** (from `grep -rln "Imgproxy.init\|Imgproxy.call" test/`):
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs` (single site: `call_imgproxy_conn/2`)
- Modify: `test/image_pipe/imgproxy_telemetry_contract_test.exs`
- Modify: `test/image_pipe/dialect/imgproxy_wire_smoke_test.exs`
- Modify: `test/image_pipe/dialect/imgproxy/{error_paths,info_wire,mount,orientation_matrix,resize_auto_wire,shrink_leak_wire}_test.exs`
- Modify: `test/image_pipe/dialect/byte_identity_cache_headers_test.exs`, `test/image_pipe/dialect/color_carry_parity_test.exs` (their imgproxy legs)
- Modify: `test/image_pipe/dialect/imgproxy/identity_test.exs` (promoted-struct base)
- Modify: `test/support/image_pipe/test/differential/harness.ex` (`dialect_plug_opts/2`)

**Interfaces:**
- Consumes: Task 3's behaviour port; `ImagePipe.Plug.init([dialect: Module] ++ flat_opts)` / `ImagePipe.Plug.call(conn, opts)` (Phase A).

- [ ] **Step 1: Swap every mount**

Grep first — the authoritative list: `grep -rln "Imgproxy.init\|Imgproxy.call" test/`. The uniform swap, e.g. the wire conformance suite's single invocation site:

```elixir
  defp call_imgproxy_conn(%Plug.Conn{} = conn, opts) do
    ImagePipe.Plug.call(conn, ImagePipe.Plug.init([dialect: DialectImgproxy] ++ opts))
  end
```

Apply the same shape wherever a file calls `Imgproxy.init(opts)` and/or `Imgproxy.call(conn, config)` (including piped forms). Do not change any assertion.

- [ ] **Step 2: Differential harness dialect arm**

In `test/support/image_pipe/test/differential/harness.ex` replace `dialect_plug_opts/2`:

```elixir
  @doc """
  Dialect arm: `dialect` mounted through `ImagePipe.Plug`'s dialect mode over
  the same local source wiring — one flat keyword list, no `:parser` key.
  """
  def dialect_plug_opts(dialect, sources_dir) do
    {ImagePipe.Plug, ImagePipe.Plug.init(dialect: dialect, sources: sources(sources_dir))}
  end
```

`render/2` dispatches on the `{plug, opts}` pair and needs no change. (This also carries the TwicPics differential suite once Task 6 lands; until then TwicPics still has its own `init`/`call` — the harness is only used via `dialect_plug_opts`, whose sole current caller is the imgproxy suite's `Harness.plug_opts`, so verify with `grep -rn "dialect_plug_opts" test/` and update the TwicPics wrapper too if it calls it — if the TwicPics differential wrapper calls `dialect_plug_opts(ImagePipe.Dialect.TwicPics, …)`, this step must WAIT for its arm until Task 7; in that case make the change here and run only the imgproxy differential lane in Step 4, deferring the TwicPics lane to Task 7.)

- [ ] **Step 3: `identity_test.exs` promoted-struct base**

`test/image_pipe/dialect/imgproxy/identity_test.exs` builds `%Negotiation{}` values against the old 3-enforced-key struct. Swap its alias to `ImagePipe.Dialect.Negotiation` and add the newly enforced keys to every construction: `policy: nil, plan_output: nil` (mechanical; no assertion changes).

- [ ] **Step 4: Run the imgproxy suites**

Run: `mise exec -- mix test test/image_pipe/dialect/ test/image_pipe/imgproxy_wire_conformance_test.exs test/image_pipe/imgproxy_telemetry_contract_test.exs test/image_pipe/imgproxy_differential_conformance_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS with **zero** assertion changes beyond the enumerated mechanical edits (mount swaps, `identity_test` base). Telemetry shapes (parse-error tags, `[:request]` results, span sequences vs Native) are pinned by the contract suites — a failure is a port parity bug, not a test to update. The differential lane must be green with no fixture/verdict/tolerance changes.

- [ ] **Step 5: Commit**

```bash
git add -A test/
git commit -m "Mount imgproxy suites through ImagePipe.Plug dialect mode (Phase B task 4)"
```

---

### Task 5: imgproxy debug-header wire coverage (#462 acceptance)

**Files:**
- Test (create): `test/image_pipe/dialect/imgproxy/debug_headers_wire_test.exs`

**Interfaces:**
- Consumes: the ported dialect (Resolved.debug? from the parsed `debug:1`), SharedConfig's `allow_debug_headers` (Task 2), the runner's default debug builder + gated rendering (Phase A). Mirrors `test/image_pipe/debug_headers_wire_test.exs`'s contract on the dialect surface. Signed-URL integrity for `debug:1` is already pinned by the existing wire suite and is not duplicated here.

- [ ] **Step 1: Write the tests (they should pass — the port makes debug structural; a failure is a port bug)**

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

  test "debug:1 under allow_debug_headers renders source facts and measured timings" do
    conn =
      get("/_/debug:1/f:jpeg/rs:fill:100:80/plain/images/beach.jpg",
        opts(allow_debug_headers: true))

    assert conn.status == 200
    assert header(conn, "x-imagepipe-source-format") == "jpeg"
    assert header(conn, "x-imagepipe-source-size") != nil
    assert header(conn, "x-imagepipe-source-color-space") != nil
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
    assert header(debug, "server-timing") =~ "cache;dur="
  end
end
```

(Path grammar check before finalizing: `debug:1` must ride in the processing-options segment and compose with `f:`/`rs:` in any order — copy the exact unsigned-path shape from the nearest passing test in `imgproxy_wire_conformance_test.exs` if `/_/debug:1/f:jpeg/plain/images/beach.jpg` misparses.)

- [ ] **Step 2: Run**

Run: `mise exec -- mix test test/image_pipe/dialect/imgproxy/debug_headers_wire_test.exs`
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
- Modify: `lib/image_pipe/dialect/twic_pics.ex` (chain deleted, behaviour implemented, `build_debug` copy deleted)
- Delete: `lib/image_pipe/dialect/twic_pics/negotiation.ex`
- Modify: `lib/image_pipe/dialect/twic_pics/identity.ex` (alias swap)
- Modify: `lib/image_pipe/dialect/twic_pics/errors.ex` (`send/4` → `send/3`)
- Modify: `mix.exs` (drop the `debug_builder.ex` ExDNA ignore — its "deliberate copy" justification dies with the TwicPics copy)

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

**Delete:** `@behaviour Plug` + `init/1` + `call/2`, `request_stop_metadata/2`, `route/2` (all heads), `parse_with_span/2`, `execute/3` (the old private lifecycle one — note the behaviour's `execute/4` below is different), `send_parse_error/3`, `send_not_modified/3`, `send_error/4`, `send_with_span/4`, `serve/6` (both heads), `deliver_hit/6`, `generate/7`, `build_fun/4`, `build_and_pump/7`, `run_transform/5`, `safe_transform/1`, `transform_stop_metadata/1`, `encode_first_chunk/3`, `encode_stop_metadata/2`, `first_chunk/1`, `materialize_for_delivery/2`, `pipeline_opts/4`, `resolve_output/4`, `result_limits/2`, `min_limit/2`, `delivery_config/2`, `parse_stop_metadata/1` is KEPT (both heads), and the whole debug block: `build_debug/8`, `negotiated?/1`, `output_quality/2`, `output_distance/1`, `aq_from_meta/2`, `quality_search_score/2`, `quality_search_metric/1`, `native_jxl_search?/1` (the runner's `ImagePipe.Plug.DebugBuilder` is the surviving copy).

**Boundary:** deps drop `ImagePipe.Cache`, `ImagePipe.Debug`, `ImagePipe.Decode`, `ImagePipe.Delivery` and add `ImagePipe.Dialect` — final: `[ImagePipe.Config, ImagePipe.Dialect, ImagePipe.Dialect.SharedConfig, ImagePipe.Error, ImagePipe.Format, ImagePipe.Output, ImagePipe.Plan, ImagePipe.Representation, ImagePipe.Response, ImagePipe.Source, ImagePipe.Telemetry, ImagePipe.Transform]`. (If a submodule still references a dropped boundary the compile fails — restore that dep and note it; expected: none.)

**The new surface:**

```elixir
  @behaviour ImagePipe.Dialect

  alias ImagePipe.Dialect.Negotiation, as: DialectNegotiation
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

    {result, parse_stop_metadata(result)}
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
       negotiation: negotiation_result(conn, request, config),
       response_meta: request.response,
       operations: operation_names(request),
       auto_rotate?: request.auto_rotate,
       debug?: request.response.debug?,
       terminal: :image
     }}
  end

  # Deferred, coupled result: the runner unwraps it after Source.resolve,
  # preserving the chain's source-before-negotiation error precedence. The
  # detector identity resolves only when negotiation succeeds, as before.
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
  def execute(state, geometry, %Request{} = request, opts),
    do: Pipeline.run(state, geometry, request, opts)

  # This dialect's status vocabulary splits on reason provenance: the closed
  # core-stage family renders through ErrorStatus (Errors.send/3); everything
  # else is, by construction, a reject from this dialect's own parse phase
  # (Path/Manipulation/RequestBuilder) and renders the 400 parse protocol.
  # The inversion is deliberate: the core family is closed and enumerable,
  # the parse-reject tail is open.
  @impl ImagePipe.Dialect
  def render_error(conn, reason, config) do
    if core_stage_reason?(reason) do
      Errors.send(conn, reason, config)
    else
      Errors.send_parse(conn, reason, config)
    end
  end

  @impl ImagePipe.Dialect
  def classify_error(reason) do
    if core_stage_reason?(reason) do
      Telemetry.request_result({:error, reason})
    else
      :parser_error
    end
  end

  defp core_stage_reason?({tag, _inner})
       when tag in [:source, :decode, :input_limit, :unsupported_output_format, :encode, :session, :transform],
       do: true

  defp core_stage_reason?({:encode, _exception, _stacktrace}), do: true
  defp core_stage_reason?(_reason), do: false
```

(Note: `Pipeline.run/4` inside `execute/4` is no longer wrapped by the chain's `safe_transform/1` rescue — the runner's `produce_stream` rescue/catch owns that (`{:transform, {exception, stacktrace}}`), identical taxonomy.)

- [ ] **Step 3: Delete the dialect Negotiation, swap Identity, shrink Errors, mix.exs**

1. `rm lib/image_pipe/dialect/twic_pics/negotiation.ex`
2. `lib/image_pipe/dialect/twic_pics/identity.ex`: `alias ImagePipe.Dialect.TwicPics.Negotiation` → `alias ImagePipe.Dialect.Negotiation`; update the `@spec`.
3. `lib/image_pipe/dialect/twic_pics/errors.ex`: `send/4` → `send/3` exactly as imgproxy's (drop the headers param from every clause and `send_core/4` → `/3`, delete `put_headers/2` and `@type header`).
4. `mix.exs`: remove `"lib/image_pipe/plug/debug_builder.ex"` and its two-line comment from `@ex_dna_ignores` (the TwicPics copy it mirrored is gone).

- [ ] **Step 4: Compile**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix credo --strict`
Expected: clean (TwicPics suites red until Task 7's mount swap — do not run them yet; credo clean confirms the ExDNA ignore removal is right, i.e. DebugBuilder is no longer a duplicate).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plug/dialect_runner.ex lib/image_pipe/dialect/twic_pics.ex lib/image_pipe/dialect/twic_pics/ mix.exs
git commit -m "Port Dialect.TwicPics onto the contract; promote the request-stop override (Phase B task 6)"
```

---

### Task 7: TwicPics test mounts + debug-pin flips (suites gate the port)

**Files** (from `grep -rln "TwicPics.init\|TwicPics.call\|TwicPics.Negotiation" test/`):
- Modify: `test/image_pipe/twic_pics_wire_conformance_test.exs`, `test/image_pipe/twic_pics_telemetry_contract_test.exs`, `test/image_pipe/dialect/twic_pics/{config,debug,error_paths,lifecycle,parse}_test.exs`
- Modify: `test/image_pipe/dialect/twic_pics/identity_test.exs`, `test/image_pipe/dialect/twic_pics/negotiation_test.exs` (promoted seam)
- Modify: `test/image_pipe/dialect/twic_pics/errors_test.exs` (send/3 arity, if it passes headers)
- Modify: `test/image_pipe/twicpics_differential/constellations_test.exs`, `test/support/mix/tasks/twicpics.gen_fixtures.ex` (parse-shape destructure)

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

Apply to every `TwicPics.init`/`TwicPics.call` site the grep finds. `config_test.exs` keeps calling `Config.validate!/1` directly (unit surface) — swap only any `TwicPics.init` usage.

- [ ] **Step 2: Out-of-suite parse callers**

`test/image_pipe/twicpics_differential/constellations_test.exs` and `test/support/mix/tasks/twicpics.gen_fixtures.ex` call `TwicPics.init([])` + `TwicPics.parse(conn, opts)`. Swap to:

```elixir
    dialect_opts = TwicPics.validate_config!([])
    ...
    {result, _span_metadata} = TwicPics.parse(conn(:get, path), dialect_opts)
```

and match on `result` where the old code matched the bare parse return.

- [ ] **Step 3: Promoted-struct/seam swaps**

- `identity_test.exs`: alias → `ImagePipe.Dialect.Negotiation`; add `plan_output: nil` (and `policy: nil` where absent) to struct constructions — the promoted struct enforces five keys where the TwicPics one enforced four.
- `negotiation_test.exs`: the module under test is deleted; the same assertions now run against the promoted seam — `ImagePipe.Dialect.Negotiation.negotiate(conn, request.output, config)`. If every assertion duplicates `test/image_pipe/dialect/negotiation_test.exs` (Phase A), delete the file instead (post-migration parity pins are deleted per the test guidelines); keep only assertions covering behavior the Phase A file lacks (e.g. TwicPics-specific `auto_avif: false` defaults interacting with `negotiate/3` — those move into the wire suite's existing `output=auto` coverage or stay here against the promoted seam).
- `errors_test.exs`: drop the headers argument from any `Errors.send/4` call (assertions on status/body unchanged; delete any test whose only subject was the headers parameter — that behavior now lives in the runner and is pinned by Task 1).

- [ ] **Step 4: Flip the delta-5 absence pins**

In `test/image_pipe/dialect/twic_pics/debug_test.exs`, the first debug test (lines ~70-72):

```elixir
      assert header(conn, "x-imagepipe-source-size") != nil
      assert header(conn, "x-imagepipe-source-color-space") == "srgb"
      assert header(conn, "x-imagepipe-source-icc") == "false"
```

(Verify the exact values against the run — `beach.jpg` is sRGB without an embedded profile; if `source-icc` renders `"true"` or the color space differs, trust the runtime and pin what it renders, keeping the assertion exact rather than `!= nil` where the value is stable.) Additionally extend the stored-facts replay test's header list with the three new source-fact headers so hit/miss equality covers them.

- [ ] **Step 5: Run the TwicPics suites**

Run: `mise exec -- mix test test/image_pipe/dialect/twic_pics/ test/image_pipe/twic_pics_wire_conformance_test.exs test/image_pipe/twic_pics_telemetry_contract_test.exs test/image_pipe/twicpics_differential_conformance_test.exs test/image_pipe/twicpics_differential/ && mise exec -- mix compile --warnings-as-errors`
Expected: PASS with zero assertion changes beyond the enumerated mechanical edits and the delta-5 pin flips. The telemetry contract's `:streamed_error` scenario passing proves the Task 6 request-stop override. The differential lane green with no fixture changes.

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
- Modify: `docs/debug_headers.md`, `docs/imgproxy_support_matrix.md`, `docs/custom_parser_guide.md`, plus any `docs/`/`README` mount example the grep finds

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

- [ ] **Step 3: Conformance + guide docs (surface axis)**

- `docs/imgproxy_support_matrix.md`: re-verify the two debug passages. The extension row (~line 1185) already describes the restored behavior — confirm its wording matches the shipped surface (signed `debug:1`, `allow_debug_headers`, identity-excluded) and refresh only if drifted. The "Response headers" paragraph (~line 868) likewise. This is the conformance-doc sync rule's **surface** axis; the compatibility reviewer confirms it in review.
- `docs/custom_parser_guide.md`: update the Phase A transition sentence ("`ImagePipe.Dialect.Native` is the first ported example while imgproxy/TwicPics still mount directly during the transition") — all three ordered dialects now implement the behaviour and mount through `ImagePipe.Plug, dialect: …`; IIIF remains on the framework `parser:` mount until Phase C.
- Grep for stale mount examples: `grep -rln "Dialect.Imgproxy\|Dialect.TwicPics" docs/ README.md` — update any `plug ImagePipe.Dialect.<X>` example to the `ImagePipe.Plug, dialect:` form (leave IIIF/framework examples alone).
- Run `vale` over each changed doc (`vale docs/debug_headers.md docs/custom_parser_guide.md docs/imgproxy_support_matrix.md`): no new errors vs the pre-edit state. If the binary is unavailable, note it in the task report rather than skipping silently.

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
grep -n "ex_dna:disable" lib/image_pipe/dialect/imgproxy.ex lib/image_pipe/dialect/imgproxy/*.ex lib/image_pipe/dialect/twic_pics.ex lib/image_pipe/dialect/twic_pics/*.ex lib/image_pipe/plug/dialect_runner.ex
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

## Phase B exit criteria

- `mise run precommit` and `mise run precommit:fiddle` green.
- imgproxy + TwicPics wire/telemetry/differential suites pass with no assertion changes beyond the enumerated mechanical edits and the delta-5 debug-pin flips.
- `lib/image_pipe/request/**`, `lib/image_pipe/parser/**`: zero diffs.
- The runner still names no dialect (architecture-test-pinned); its two new branches dispatch on `%Negotiation{policy:}` and `conn.private[:image_pipe_send_result]`.
- #462's acceptance surface is present: imgproxy debug wire coverage (Task 5), fiddle mount re-enabled, `docs/debug_headers.md` updated. The PR body carries a bare `Fixes #462` line.
- `Imgproxy.init/1`, `Imgproxy.call/2`, `TwicPics.init/1`, `TwicPics.call/2`, both dialect `Negotiation` modules, and TwicPics' `build_debug` block no longer exist.

Phase C (Declarative base, `Dialect.IIIF`, framework-stack deletion, `http_cache`/`RenderTerminal` widening, telemetry-surface sync, docs rewrite) gets its own plan after Phase B merges.

**Notes for Phase C picked up here:** none new — the Phase A exit-note question (delivery-error headers) is resolved by Task 1's runner stamping; no contract-shape questions remain open for Phase C beyond what the spec already stages (U8b `http_cache`, U11 `cache:`/`offers` widening).
