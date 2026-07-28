# Dialect Unification Phase C Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the declarative tier (`ImagePipe.Dialect.Declarative`), re-express IIIF as `ImagePipe.Dialect.IIIF`, delete the whole framework parser stack (`ImagePipe.Request.*`, `ImagePipe.Parser`, `ImagePipe.Plug`'s legacy branch, `Cache.Key`'s Plan machinery), and finish the U8b/U11 contract widenings — Phase C of `docs/superpowers/specs/2026-07-19-dialect-unification-design.md`.

**Architecture:** `ImagePipe.Dialect.Declarative` is a top-level boundary and a `use`-macro base that implements the six-callback `ImagePipe.Dialect` contract on top of one host callback, `parse_plan/2 -> {:ok, %Plan{}}`. It derives `%Resolved{}` from the Plan (identity material, negotiation from `plan.output`, detector identity, terminal selection, `http_cache: :generated`), plans the decode through a new neutral chain→`DecodePlanner.Request` defunctionalization, and executes through `Transform.execute_plan/3`. The runner in `ImagePipe.Plug` gains the two staged widenings the spec deferred to this phase: the promoted generated-cache-header policy (U8b, gated by `Resolved.http_cache`) applied between `Representation.build` and the conditional gate, and the `RenderTerminal` `cache: :none` + `offers` delivery (U11) through `Sender`'s existing `{:rendered, …}` path. `ImagePipe.Dialect.IIIF` is the only declarative dialect; once its suites are green on the dialect mount, the framework stack is deleted wholesale.

**Tech Stack:** Elixir, Plug, Boundary, NimbleOptions, Vix/libvips, ExUnit, StreamData. All commands via `mise exec -- …`.

## Global Constraints

- Run every mix command through `mise exec -- …`. Fresh worktree: `mise trust` + `mise run setup` first; the fiddle gate may need `pnpm -C fiddle/assets run build` once.
- **U4 anti-leak rule.** The runner branches only on `%Resolved{}` fields, neutral core structs, and shared conn-private state stamped by neutral core (`:image_pipe_send_result`). It never names a dialect and never accepts a dialect-specific option.
- **U5.** Product ordering stays wholly inside `execute/4`. The runner gains no ordering concept.
- **U6.** `ImagePipe.Dialect`, `Resolved`, `Negotiation`, `RenderTerminal`, `Failure`, `DebugContext`, `SharedConfig`, and `Declarative` are the public SDK. Nothing from the retired geometry-strategy vocabulary returns: no `Resolver`, no `Directive`, no `:deferred`, no Plan markers, no dialect dep on `Transform.Lowering`/`Transform.ResizePlanning`.
- **U12.** The imgproxy, TwicPics, and Native wire/telemetry/differential suites must pass **unchanged**. No differential fixture, verdict, or tolerance changes. Only the enumerated deltas may differ.
- **Greenfield.** No production deployments and no pre-existing cache entries. Do not bump `Representation`'s `@core_execution_epoch` or any dialect epoch; reshape key data in place.
- **Every task must leave `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs` green.** The arch test reads boundary declarations from disk (`@boundary_files`) and greps source globs, so a task that changes a `use Boundary` block, adds a boundary, or deletes a pinned file MUST update that test in the same commit. Each task's run command includes it. Do not defer arch-test edits to the boundary task — that task only *adds* the new pins.
- **No new comment may reference `ImagePipe.Request.*` or `ImagePipe.Parser`.** Those namespaces die in Task 11; a doc comment explaining "what the framework did" becomes a dangling note the moment it lands (AGENTS.md clean-removal rule). Describe new code on its own terms. Provenance belongs in the commit message.
- AGENTS.md test guidelines apply to the deletions: post-migration parity pins, name/existence-policing tests, and characterization tests for the deleted path are deleted, not ported.
- Subagents must not run state-mutating git commands (`stash`, `reset`, `checkout --`, `clean`).
- Commit after every task.

## Enumerated observable deltas (exhaustive for Phase C)

**IIIF-visible.**

1. **IIIF identity values change** (U8). ETags and cache keys move from `Request.HTTPCache`'s `"ip1-…"` digest and `Cache.Key`'s schema-2 hash to `Representation`'s `"ipr1-…"` ETag and representation key. Round-trip behavior (pre-fetch 304 on a matching `If-None-Match`, `Vary`, storage separation, cachebuster/storage-vary partitioning) is preserved and asserted behaviorally. Literal-value assertions become round-trip assertions.

2. **IIIF span shape becomes the dialect shape.** `[:request]`/`[:parse]` **start** metadata lose `parser:` and `request_method` (dialect shape is `%{}`). Parse **error** stop metadata becomes richer (`Error.tag(reason)` instead of the constant `:error` the framework's double-wrap produced). `[:source, :fetch_decode]` is emitted by `ImagePipe.Decode`, `[:cache, :lookup]` by `Cache.lookup_entry/2` — same names, same metadata shapes, different emitters. **No telemetry event name is added or removed.**

3. **`[:request]`/`[:send]` error metadata loses one unwrap level.** The framework emitted `error: Error.tag(inner)` for `{:source, inner}` and `{:plan_validation, inner}` (`:connect_error`, `:invalid_output_plan`, …). The runner emits `Error.tag/1` on the whole reason, so those collapse to the constant `:source` / `:plan_validation`. This is existing shared-runner behavior for all three ordered dialects; IIIF now joins them.

4. **`[:render]` span position, duration, and failure behavior change for `info.json`.** It was opened *around* fetch+decode (so it enclosed `[:source, :fetch_decode]`, its duration included the fetch, and a fetch/decode failure still closed it with `result: :render_error`). It now runs after the decode bracket closes: it is a **sibling** of `[:source, :fetch_decode]`, its duration is render-only, and a fetch/decode failure emits **no** `[:render]` span. Event name and metadata shapes are unchanged.

5. **Negotiation-capability check moves before cache access.** `Policy.ensure_capable/2` ran only after a cache miss; the runner surfaces a negotiation error right after source resolution. Same status (501), but observable to a cache spy. Related: a negotiation-error response no longer carries `Vary: Accept` (the runner stamps policy headers only on `Delivery.stream` failures). Inert for real IIIF (always `{:explicit, format}` → `policy.headers == []`), live for the automatic-output test double.

6. **IIIF error rendering is dialect-owned.** `Dialect.IIIF.Errors` renders parse, plan-validation, detector, source, decode, limit, output, encode, cache-write, and render failures. Statuses and bodies are reproduced exactly, with these deliberate changes: parse-error responses gain `content-type: text/plain`; a delivery-session failure (`{:session, _}`) renders 500 `"internal server error"` instead of 500 `"error encoding image"` and no longer stamps `:image_pipe_send_result`; a delivery-time output-negotiation failure renders **501** `"requested output format is not supported by this server"` instead of 500; `Logger` no longer emits the `source_error:`/`processing_error:` info lines from `Sender`.

7. **IIIF mount config flattens.** `parser: ImagePipe.Parser.IIIF, iiif: [...]` becomes `dialect: ImagePipe.Dialect.IIIF, <flat keys>`. Consequences:
   - Unknown keys now raise (`unknown ImagePipe.Dialect.IIIF option(s): [...]`) where `Request.Options` accepted them; its typo-suggestion guard and `ImagePipe.Parser.validate_options!/2`'s keyword-return guard are gone.
   - **Test/DI seam keys** (`image_module`, `image_open_module`, `buffer_loader`, `image_materializer`, `on_bracket_exit`, `clock`) are no longer accepted at `init/1`. They are spliced onto the validated config *after* `ImagePipe.Plug.init/1`, exactly as the ordered-dialect suites already do (`test/image_pipe/dialect/native_error_paths_test.exs:236-244`).
   - **Top-level source timeouts** (`receive_timeout`, `connect_timeout`, `pool_timeout`) are no longer accepted at the mount; they move into the per-source adapter config, matching every other dialect.

8. **`key_headers`/`key_cookies` are removed.** They are **cache-adapter** options (`cache: {Adapter, key_headers: [...]}`), read only by `Cache.key_options/2` ← `Cache.lookup/4` — the framework runner. Header/cookie cache partitioning is now the mount-level `storage_inputs: [{:header, name}, {:cookie, name}]`. `Cache.validate_config!` must **reject** them with a message naming `storage_inputs:`; leaving them accepted-but-unread would silently serve cross-variant cache hits.

9. **`storage_inputs` header names enter `Vary`.** `Representation.storage_inputs/2` returns every `{:header, name}` as a vary name; the framework emitted `Vary` only for `mode: :automatic`. A header-partitioned IIIF mount gains `Vary: <name>[, Accept]`.

10. **ETag/key `Accept` sensitivity narrows.** The framework digested the full `Negotiation.modern_candidates/2` list; `Dialect.Negotiation` carries only the selected head, which is all `Policy.resolve/2` uses. Not a collision — it removes needless re-downloads. Inert for real IIIF, live for the automatic-output double.

11. **`{:unsupported_source_format, _}` / `:source_format_required` change wrapper.** `Decode` wraps both in `{:decode, _}` where `Processor` returned them bare. Status and body are unchanged (415 / "source response is not a supported image"), but `[:source, :fetch_decode]` stop metadata tags `:decode` instead of `:unsupported_source_format`.

12. **`allow_debug_headers` gating moves to the runner** (`delivery_config/2` from `Resolved.debug?` + the `SharedConfig` flag). Byte-identical headers; `Debug.Info` is now built unconditionally and **stored with IIIF cache entries**.

13. **`http_cache: [mode: :enabled]` is required for a declarative dialect to emit any `ETag` or `Cache-Control`.** This matches the framework (`mode:` defaulted to `:disabled` and `HTTPCache.prepare` generated nothing under it), but it is an asymmetry with the ordered dialects, which always emit the representation's ETag. Document it.

14. **`Vary: Accept` can be lost when an automatic output plan collapses to an explicit selection.** The framework emitted `Vary` from `plan.output.mode == :automatic`; the replacement sources it from `Negotiation.vary?`, which is `false` when `Policy.identity_selection/1` returns `{:explicit, _}` (every `auto_*` disabled, or restricted `output_capabilities`). Task 10 must either pin the case in `cdn_http_cache_wire_test.exs` or prove it unreachable.

**Cross-dialect.**

15. **`Resolved.http_cache` becomes a required field.** Native, imgproxy, and TwicPics set `:dialect_owned` — the policy is skipped, so they emit none of `[:http_cache, :prepare]`, `[:http_cache, :conditional, :match]`, `[:http_cache, :fallback, :no_store]` (they emit none today) and no generated `Cache-Control`. `[:http_cache, :cache_hit, :headers]` is **not** a policy event: it stays in `Response.Sender` and keeps firing for every dialect's image cache hits.

16. **`ImagePipe.Transform.Executor`'s preamble gate splits.** `:seed_input_color_management` is separated from `:seed_orientation`, defaulting to it. No current caller changes behavior; the ordered dialects never reach `Executor` (they call `InputColorManagement.condition/2` from their own pipelines).

17. **`DecodePlanner.open_options/5` is retired.** Its only production caller dies; `request_from_chain/3` + `open_options_for/5` becomes the single entry point. Task 12 deletes it and repoints `decode_planner_test.exs`. No load option changes — Task 1's property test gates that.

Everything not listed is gated to remain byte-identical by the existing suites.

## File Structure (Phase C end state)

```
lib/image_pipe.ex                                   MOD  root Boundary drops Parser + Request
lib/image_pipe/transform/decode_planner.ex          MOD  + request_from_chain/3; open_options/5 retired (T12)
lib/image_pipe/transform/executor.ex                MOD  :seed_input_color_management gate split
lib/image_pipe/renderer.ex                          MOD  run/3 owns the [:render] span
lib/image_pipe/dialect/render_terminal.ex           MOD  + cache: :complete_body | :none, + offers
lib/image_pipe/dialect/resolved.ex                  MOD  + http_cache (required)
lib/image_pipe/response/cache_policy.ex             NEW  promoted generated-cache-header policy (U8b)
lib/image_pipe/response.ex                          MOD  + CachePolicy export
lib/image_pipe/plug/dialect_runner.ex               MOD  cache-policy gate; cache: :none render delivery
lib/image_pipe/dialect/declarative.ex               NEW  own top-level boundary; the declarative tier
lib/image_pipe/dialect/declarative/identity.ex      NEW  Plan -> IdentityMaterial
lib/image_pipe/dialect.ex                           MOD  + parse_boolean/1 (deps unchanged)
lib/image_pipe/dialect/iiif.ex                      NEW  + iiif/{config,errors}.ex; submodules moved
lib/image_pipe/parser.ex, lib/image_pipe/parser/**  DEL  (T11)
lib/image_pipe/request.ex, lib/image_pipe/request/**  DEL  (T11)
lib/image_pipe/plug.ex                              MOD  dialect-only init/call
lib/image_pipe/cache/key.ex                         MOD  struct only (T12)
lib/image_pipe/cache.ex                             MOD  lookup/4, key_headers, key_cookies deleted (T12)
mix.exs, .credo.exs                                 MOD  ExDNA ignores + the comment that explains them
validator/server.exs                                MOD  dialect mount (IIIF Level-2 conformance gate)
docs/custom_parser_guide.md -> custom_dialect_guide.md, execution_flow.md, cdn-http-cache.md,
  debug_headers.md, telemetry.md, iiif_3_support_matrix.md, imgproxy_support_matrix.md, AGENTS.md
fiddle/lib/image_pipe_fiddle/application.ex         MOD  IIIF dialect mount
```

---

### Task 1: Neutral chain → `DecodePlanner.Request` defunctionalization

The declarative base runs on `ImagePipe.Decode.with_image/4`, whose `decode_request_fun` must return a `%DecodePlanner.Request{}`. The framework fed `DecodePlanner.open_options/5` the semantic op chain directly. Build the bridge inside `DecodePlanner`, where the private helpers live, and prove the two entry points agree.

**Files:**
- Modify: `lib/image_pipe/transform/decode_planner.ex`
- Test: `test/image_pipe/transform/decode_planner_chain_request_test.exs` (create)

**Interfaces:**
- Produces: `DecodePlanner.request_from_chain(chain, storage_dimensions, exif_quarter_turn?) :: Request.t()`. Task 5's `Declarative.decode_request/2` is the only caller.
- Consumes: `%ImagePipe.Plan.Operation.{Resize, CropGuided, CropRegion, Rotate, Trim}` — all already aliased in the module.

- [ ] **Step 1: Write the failing equivalence test**

Create `test/image_pipe/transform/decode_planner_chain_request_test.exs`:

```elixir
defmodule ImagePipe.Transform.DecodePlannerChainRequestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Gray
  alias ImagePipe.Transform.DecodePlanner

  # The declarative tier plans its decode through the %Request{} entry point,
  # but IIIF's shrink-on-load behavior is defined by the chain entry point.
  # These must produce IDENTICAL load options for every constructible chain.
  defp equivalent?(chain, format, dims, exif_qt?, auto_rotate?) do
    from_chain = DecodePlanner.open_options(chain, format, dims, exif_qt?, auto_rotate?)

    from_request =
      chain
      |> DecodePlanner.request_from_chain(dims, exif_qt? and auto_rotate?)
      |> DecodePlanner.open_options_for(format, dims, exif_qt?, auto_rotate?)

    from_chain == from_request
  end

  defp resize!(mode, w, h, opts \\ []) do
    {:ok, op} = Operation.resize(mode, w, h, opts)
    op
  end

  defp crop_region!(w, h) do
    {:ok, op} =
      Operation.crop_region({:px, 0}, {:px, 0}, {:px, w}, {:px, h}, on_out_of_bounds: :reject)

    op
  end

  defp rotate!(angle) do
    {:ok, op} = Operation.rotate(angle, false)
    op
  end

  defp trim! do
    {:ok, op} = Operation.trim(threshold: 10, background: :auto, equal_hor: false, equal_ver: false)
    op
  end

  describe "request_from_chain/3 reproduces open_options/5" do
    test "no resize" do
      assert equivalent?([%Gray{}], :jpeg, {4000, 3000}, false, true)
    end

    test "single-axis pixel resize across formats" do
      chain = [resize!(:fit, {:px, 400}, :auto)]
      for format <- [:jpeg, :webp, :png, :avif] do
        assert equivalent?(chain, format, {4000, 3000}, false, true)
      end
    end

    test "crop before resize narrows the extent feeding the shrink" do
      chain = [crop_region!(800, 600), resize!(:fit, {:px, 400}, :auto)]
      assert equivalent?(chain, :jpeg, {4000, 3000}, false, true)
    end

    test "min_width forbids shrink" do
      chain = [resize!(:fit, {:px, 400}, {:px, 300}, min_width: {:px, 100})]
      assert equivalent?(chain, :jpeg, {4000, 3000}, false, true)
    end

    test "trim disables shrink" do
      chain = [trim!(), resize!(:fit, {:px, 400}, :auto)]
      assert equivalent?(chain, :jpeg, {4000, 3000}, false, true)
    end

    test "quarter-turn rotate before the resize swaps the shrink axes" do
      chain = [rotate!(90), resize!(:fit, {:px, 400}, :auto)]
      assert equivalent?(chain, :jpeg, {4000, 3000}, false, true)
      assert equivalent?(chain, :jpeg, {4000, 3000}, true, true)
    end

    # %Rotate{} accepts ANY angle in [0, 360) (plan/operation/rotate.ex), and
    # the IIIF grammar parses arbitrary floats. A naive boolean XOR of the EXIF
    # and user turns diverges from the chain path's `rem(sum, 180) == 90` here.
    test "an arbitrary-angle rotate before the resize agrees on the axis choice" do
      for angle <- [45, 30.5, 135, 200, 359.9] do
        chain = [rotate!(angle), resize!(:fit, {:px, 400}, :auto)]
        assert equivalent?(chain, :jpeg, {4000, 3000}, true, true), "angle #{angle}"
        assert equivalent?(chain, :jpeg, {4000, 3000}, false, true), "angle #{angle}"
      end
    end

    test "two rotates before the resize accumulate" do
      chain = [rotate!(45), rotate!(45), resize!(:fit, {:px, 400}, :auto)]
      assert equivalent?(chain, :jpeg, {4000, 3000}, true, true)
    end

    test "flip contributes no turn" do
      chain = [%Flip{axis: :horizontal}, resize!(:fit, {:px, 400}, :auto)]
      assert equivalent?(chain, :jpeg, {4000, 3000}, true, true)
    end

    test "a rotate AFTER the resize contributes no turn (the IIIF operation order)" do
      chain = [resize!(:fit, {:px, 400}, :auto), rotate!(90)]
      assert equivalent?(chain, :jpeg, {4000, 3000}, true, true)
    end
  end

  property "the two entry points agree over IIIF-shaped chains" do
    check all(
            src_w <- integer(64..6000),
            src_h <- integer(64..6000),
            target_w <- one_of([constant(nil), integer(1..4000)]),
            target_h <- one_of([constant(nil), integer(1..4000)]),
            crop <- one_of([constant(nil), tuple({integer(1..6000), integer(1..6000)})]),
            angle <- one_of([constant(0), member_of([90, 180, 270]), float(min: 0.0, max: 359.9)]),
            format <- member_of([:jpeg, :webp, :png, :avif]),
            exif_qt? <- boolean(),
            auto_rotate? <- boolean(),
            max_runs: 300
          ) do
      chain = rotate_ops(angle) ++ crop_ops(crop) ++ resize_ops(target_w, target_h)
      assert equivalent?(chain, format, {src_w, src_h}, exif_qt?, auto_rotate?)
    end
  end

  defp rotate_ops(0), do: []
  defp rotate_ops(angle), do: [rotate!(angle)]

  defp crop_ops(nil), do: []
  defp crop_ops({w, h}), do: [crop_region!(w, h)]

  defp resize_ops(nil, nil), do: []
  defp resize_ops(w, h), do: [resize!(:fit, axis(w), axis(h))]

  defp axis(nil), do: :auto
  defp axis(n), do: {:px, n}
end
```

Before running: confirm `Operation.trim/1`'s and `Operation.rotate/2`'s real signatures (`lib/image_pipe/plan/operation.ex`) and `%Rotate{}`'s accepted angle domain, and adjust the helpers to whatever they actually are. `%ImagePipe.Plan.Operation.Trim{}` has four enforced keys — never build it as a bare struct literal. `min_width:` takes a tagged dimension (`{:px, n}`), not a bare integer.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/transform/decode_planner_chain_request_test.exs`
Expected: FAIL — `DecodePlanner.request_from_chain/3` is undefined.

- [ ] **Step 3: Implement `request_from_chain/3`**

In `lib/image_pipe/transform/decode_planner.ex`, add after `open_options_for/5`:

```elixir
  @doc """
  Defunctionalizes a semantic `ImagePipe.Plan.Pipeline` operation chain into the
  `%Request{}` `open_options_for/5` consumes.

  Exact: for every constructible chain, `open_options_for/5` over the returned
  request yields the identical load options `open_options/5` yields over the
  chain (`test/image_pipe/transform/decode_planner_chain_request_test.exs`).

  `exif_quarter_turn?` is the NET EXIF turn — already gated by the caller's
  auto-rotate policy. `ImagePipe.Transform.PendingOrientation.quarter_turn?/1`
  on a decode-time pending orientation is exactly this value, since the decode
  seeds `user_angle: 0`.

  ## Why `user_quarter_turn?` is derived, not measured

  `%Request{}` carries the user turn as a BOOLEAN, which `open_options_for/5`
  XORs with the EXIF turn. A chain's rotates sum to an arbitrary angle (a
  `%Rotate{}` accepts any angle in `[0, 360)`), and `rem(exif + user, 180) == 90`
  is NOT reproducible by XORing two booleans whenever the user sum is not a
  multiple of 90 — e.g. exif 90° + user 45° is not a quarter turn, but
  `true XOR false` says it is. So compute the net turn here, exactly as the
  chain path does, and set `user_quarter_turn?` to whatever value makes the
  planner's XOR agree: `exif_quarter_turn? != net_quarter_turn?`.
  """
  @spec request_from_chain(
          [ImagePipe.Plan.Pipeline.operation()],
          {pos_integer(), pos_integer()},
          boolean()
        ) :: Request.t()
  def request_from_chain(chain, {src_w, src_h}, exif_quarter_turn?)
      when is_list(chain) and is_integer(src_w) and src_w > 0 and
             is_integer(src_h) and src_h > 0 and is_boolean(exif_quarter_turn?) do
    exif_angle = if exif_quarter_turn?, do: 90, else: 0
    net_quarter_turn? = rem(exif_angle + user_rotate_angle_before_resize(chain), 180) == 90
    {shrink_w, shrink_h} = shrink_axes({src_w, src_h}, net_quarter_turn?)

    %Request{
      trim?: Enum.any?(chain, &match?(%PlanTrim{}, &1)),
      crop_extent: crop_extent_before_resize(chain, shrink_w, shrink_h),
      resize_target: chain_resize_target(chain),
      terminal_reduction: nil,
      required_extent: nil,
      user_quarter_turn?: exif_quarter_turn? != net_quarter_turn?
    }
  end

  # Mirrors `resize_load_shrink/3`'s two decisions as data: a `min_width`/
  # `min_height` resize is ineligible (no per-axis multiplier exists), and only
  # `{:px, n}` axes contribute a target. `{nil, nil}` MUST normalize to `nil` —
  # see `t:Request.resize_target/0`; `{nil, nil}` would shadow
  # `terminal_reduction` in `open_options_for/5`'s precedence.
  defp chain_resize_target(chain) do
    case Enum.find(chain, &match?(%PlanResize{}, &1)) do
      nil ->
        nil

      %PlanResize{min_width: mw, min_height: mh} when not is_nil(mw) or not is_nil(mh) ->
        nil

      %PlanResize{width: width, height: height} = resize ->
        normalize_resize_target(
          {px_target_extent(width, resize, :x), px_target_extent(height, resize, :y)}
        )
    end
  end

  defp normalize_resize_target({nil, nil}), do: nil
  defp normalize_resize_target(target), do: target
```

`user_rotate_angle_before_resize/1` reduces `rem(acc + angle, 360)` over a float-capable angle; confirm `rem/2` accepts what `%Rotate{angle:}` actually holds (if it is a float, the chain path already has the same issue — read it before assuming, and if the chain path itself would raise, note it and restrict the property generator to integers with a recorded reason).

- [ ] **Step 4: Run**

Run: `mise exec -- mix test test/image_pipe/transform/decode_planner_chain_request_test.exs test/image_pipe/transform/ test/image_pipe/architecture_boundary_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/decode_planner.ex test/image_pipe/transform/decode_planner_chain_request_test.exs
git commit -m "Defunctionalize a Plan op chain into a DecodePlanner.Request (Phase C task 1)"
```

---

### Task 2: The `[:render]` span moves into `ImagePipe.Renderer.run/3`

`Request.RenderRunner` is the sole emitter today. Move the span to the neutral facade so the declarative render bridge keeps it after the framework dies.

**Files:**
- Modify: `lib/image_pipe/renderer.ex`, `lib/image_pipe/request/render_runner.ex`
- Modify: `test/image_pipe/architecture_boundary_test.exs` (the `Renderer` deps pin)
- Test: `test/image_pipe/renderer_span_test.exs` (create)

**Interfaces:**
- Produces: `ImagePipe.Renderer.run(spec, %RenderContext{}, opts)` emits `[:render]` with start metadata `%{renderer: module}` and stop metadata `%{result: :ok, content_type: ct}` / `%{result: :render_error, error: tag}`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.RendererSpanTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.RenderContext
  alias ImagePipe.Plan.SourceInfo
  alias ImagePipe.Renderer

  defmodule OkRenderer do
    @behaviour ImagePipe.Renderer
    @impl true
    def requires(_params), do: [:header]
    @impl true
    def render(%RenderContext{}, _params, _opts), do: {:ok, {"application/json", "{}"}}
  end

  defmodule FailRenderer do
    @behaviour ImagePipe.Renderer
    @impl true
    def requires(_params), do: [:header]
    @impl true
    def render(%RenderContext{}, _params, _opts), do: {:error, :boom}
  end

  @prefix [:renderer_span_test]

  setup do
    handler = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach_many(
      handler,
      [@prefix ++ [:render, :start], @prefix ++ [:render, :stop]],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp context do
    %RenderContext{info: %SourceInfo{format: :jpeg, width: 10, height: 10, orientation: 1}}
  end

  test "run/3 emits the [:render] span with the renderer and content type" do
    assert {:ok, {"application/json", "{}"}} =
             Renderer.run({:custom, OkRenderer, %{}}, context(), telemetry_prefix: @prefix)

    assert_received {:telemetry, [:renderer_span_test, :render, :start], _, %{renderer: OkRenderer}}

    assert_received {:telemetry, [:renderer_span_test, :render, :stop], _,
                     %{result: :ok, content_type: "application/json"}}
  end

  test "a render failure closes the span with :render_error" do
    assert {:error, :boom} =
             Renderer.run({:custom, FailRenderer, %{}}, context(), telemetry_prefix: @prefix)

    assert_received {:telemetry, [:renderer_span_test, :render, :stop], _,
                     %{result: :render_error, error: :boom}}
  end
end
```

A private `telemetry_prefix` is mandatory — `:telemetry` handlers are global (AGENTS.md).

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/renderer_span_test.exs`
Expected: FAIL — no `[:render]` events (`Renderer.run/3` is a bare dispatch).

- [ ] **Step 3: Implement**

In `lib/image_pipe/renderer.ex`:

1. Widen the Boundary: `deps: [ImagePipe.Error, ImagePipe.Plan, ImagePipe.Telemetry]`.
2. Add `alias ImagePipe.Error` and `alias ImagePipe.Telemetry`.
3. Replace `run/3`:

```elixir
  @doc """
  Invokes the renderer inside the `[:render]` span.

  The span lives on the facade so every caller of the behaviour gets it.
  (`ImagePipe.Dialect.Imgproxy`'s `/info` and `ImagePipe.Dialect.Native`'s
  blurhash terminals render through their own `RenderTerminal` funs, not this
  facade, and emit no `[:render]` span.)
  """
  @spec run(spec(), RenderContext.t(), keyword()) :: {:ok, body()} | {:error, term()}
  def run({:custom, module, params}, %RenderContext{} = context, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:render], %{renderer: module}, fn ->
      result = module.render(context, params, opts)
      {result, stop_metadata(result)}
    end)
  end

  defp stop_metadata({:ok, {content_type, _body}}),
    do: %{result: :ok, content_type: content_type}

  defp stop_metadata({:error, reason}),
    do: %{result: :render_error, error: Error.tag(reason)}
```

4. In `lib/image_pipe/request/render_runner.ex`, delete the `Telemetry.span/4` wrapper in `run/3` (call `do_run/3` directly), delete `render_stop_metadata/1`, and drop the now-unused aliases.
5. In `test/image_pipe/architecture_boundary_test.exs`, update the `Renderer` deps pin (an exact-equality `assert_boundary_deps(renderer, [ImagePipe.Plan])` today) to the widened list. This is not optional: the arch test fails otherwise.

- [ ] **Step 4: Run**

Run: `mise exec -- mix test test/image_pipe/renderer_span_test.exs test/image_pipe/request/render_runner_test.exs test/parser/iiif_wire_test.exs test/image_pipe/telemetry_test.exs test/image_pipe/architecture_boundary_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS. The span is emitted exactly once per render.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/renderer.ex lib/image_pipe/request/render_runner.ex test/image_pipe/renderer_span_test.exs test/image_pipe/architecture_boundary_test.exs
git commit -m "Move the [:render] span into the Renderer facade (Phase C task 2)"
```

---
### Task 3: `RenderTerminal` widening — `cache:` and `offers:` (U11)

Phase A shipped a fun-only `RenderTerminal` with the complete-body delivery implied. IIIF `info.json` needs the other variant: per-request `Accept` negotiation against `offers`, `Vary: Accept`, and **no** internal cache read or write.

**Files:**
- Modify: `lib/image_pipe/dialect/render_terminal.ex`, `lib/image_pipe/plug/dialect_runner.ex`
- Modify: `test/support/image_pipe/test/runner_fixture_dialect.ex`
- Test: `test/image_pipe/plug_dialect_runner_test.exs`

**Interfaces:**
- Produces: `%RenderTerminal{fun:, charset: :default | nil, cache: :complete_body | :none, offers: [{content_type, [accept_token]}]}`. `cache` defaults to `:complete_body` and `offers` to `[]`, so imgproxy `/info` and Native blurhash are source-compatible and byte-identical.
- Consumes: `ImagePipe.Response.Sender.send_result/3`'s existing `{:ok, {:rendered, content_type, body, offers, %CacheHeaders{}}}` clause, which performs the offers negotiation and stamps `Vary: Accept`.

- [ ] **Step 1: Extend the fixture dialect with a `cache: :none` render terminal**

`test/support/image_pipe/test/runner_fixture_dialect.ex` selects its existing render terminal from `params["render"] == "text"` and builds it in a private `render_terminal/0`. Add a second value — `params["render"] == "uncached"` — returning:

```elixir
  defp uncached_render_terminal do
    %RenderTerminal{
      cache: :none,
      offers: [{"application/ld+json", ["application/ld+json"]}],
      fun: fn _resolved_source, _config -> {:ok, "application/json", ~s({"ok":true})} end
    }
  end
```

Read the file's actual `prepare/3` heads before editing; do not invent a `terminal/2` it does not have.

- [ ] **Step 2: Write the failing tests**

Append to `test/image_pipe/plug_dialect_runner_test.exs`. Use the suite's own cache double — it is `stateful_cache_probe/0` (around `:113`), not `CacheProbe` (that lives in other suites). If the probe does not report reads, extend it to `send/2` the test process on `get`/`put` and assert with `refute_received`; "no cache interaction at all" is the contract, not an empty table.

```elixir
  describe "render terminal with cache: :none" do
    test "negotiates the offered content type against the request's Accept and varies" do
      conn =
        :get
        |> conn("/fix/images/beach.jpg?render=uncached")
        |> put_req_header("accept", "application/ld+json")
        |> ImagePipe.Plug.call(opts())

      assert conn.status == 200
      assert hd(get_resp_header(conn, "content-type")) =~ "application/ld+json"
      assert get_resp_header(conn, "vary") == ["Accept"]
    end

    test "falls back to the canonical content type without a matching Accept" do
      conn = get("/fix/images/beach.jpg?render=uncached", opts())

      assert conn.status == 200
      assert hd(get_resp_header(conn, "content-type")) =~ "application/json"
      assert get_resp_header(conn, "vary") == ["Accept"]
    end

    test "never reads or writes the internal cache" do
      {cache, _table} = stateful_cache_probe()
      config = opts(cache: cache)

      assert get("/fix/images/beach.jpg?render=uncached", config).status == 200
      assert get("/fix/images/beach.jpg?render=uncached", config).status == 200

      refute_received {:cache_lookup, _key}
      refute_received {:cache_write, _key}
    end
  end
```

`content-type` is asserted with `=~`, not `==`: whether `Response.Json.send/3` appends a charset parameter to a negotiated type is a `Json` detail this task does not change.

- [ ] **Step 3: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/plug_dialect_runner_test.exs`
Expected: FAIL — `%RenderTerminal{}` rejects `:cache`/`:offers` (`KeyError`).

- [ ] **Step 4: Implement**

In `lib/image_pipe/dialect/render_terminal.ex`, replace the struct and moduledoc:

```elixir
defmodule ImagePipe.Dialect.RenderTerminal do
  @moduledoc """
  A non-image terminal, values only. Two deliveries, selected by `cache`:

    * `:complete_body` — the shared complete-body lifecycle: a
      `{:complete_body, content_type}` cache entry, `If-None-Match: *` honored
      on a hit, fail-open write on a miss.
    * `:none` — `ImagePipe.Response.Sender`'s `{:rendered, …}` delivery: the
      content type is negotiated against the CURRENT request's `Accept` over
      `offers`, `Vary: Accept` is stamped, and the internal cache is neither
      read nor written.

  Presentation is never stored: `offers`, the negotiated type, and `charset`
  come from the current terminal on both hit and miss; a cache entry keeps a
  bare canonical content type.

  `charset` selects how the content type is stamped on the `:complete_body`
  delivery. `nil` sends it verbatim; `:default` lets
  `Plug.Conn.put_resp_content_type/2` append the endpoint's default charset
  parameter. It does not apply to `:none`, whose content type is stamped by
  `ImagePipe.Response.Json`.

  `offers` is `[{content_type, [accept_token]}]` — the first entry whose tokens
  appear in the request's `Accept` wins; `[]` means no negotiation. It is
  meaningful only with `cache: :none`.
  """

  alias ImagePipe.Source

  @enforce_keys [:fun]
  defstruct [:fun, charset: nil, cache: :complete_body, offers: []]

  @type render_fun ::
          (Source.Resolved.t(), keyword() ->
             {:ok, content_type :: String.t(), iodata()} | {:error, term()})

  @type offer :: {content_type :: String.t(), accept_tokens :: [String.t()]}

  @type t :: %__MODULE__{
          fun: render_fun(),
          charset: :default | nil,
          cache: :complete_body | :none,
          offers: [offer()]
        }
end
```

In `lib/image_pipe/plug/dialect_runner.ex`, add a `cache: :none` clause **above** the two existing `{:render, terminal}` `serve_terminal/7` clauses — it must win regardless of `internal_cache`, because the terminal, not the source, decides. Implement it against the CURRENT parameter (`serve_terminal/7` receives a `%Representation{}` today; Task 4 swaps that to a `%CacheHeaders{}`), so the clause reads:

```elixir
  # `cache: :none` bypasses the internal cache entirely and delivers through
  # `Sender`'s offers-negotiated `{:rendered, …}` path. The source's
  # `internal_cache` setting is irrelevant — the terminal already says no.
  defp serve_terminal(
         conn,
         dialect,
         %Resolved{terminal: {:render, %RenderTerminal{cache: :none} = terminal}},
         source,
         _negotiation,
         %Representation{} = representation,
         config
       ) do
    case terminal.fun.(source, config) do
      {:ok, content_type, body} ->
        conn =
          send_with_span(conn, config, :ok, fn ->
            Sender.send_result(
              conn,
              {:ok,
               {:rendered, content_type, body, terminal.offers,
                CacheHeaders.from_representation(representation)}},
              config
            )
          end)

        {conn, %{result: :ok}}

      {:error, reason} ->
        send_error(conn, dialect, reason, config)
    end
  end
```

Match the two existing render clauses on `%RenderTerminal{cache: :complete_body}` so an unhandled future value fails loudly rather than silently taking the cached path.

- [ ] **Step 5: Run**

Run: `mise exec -- mix test test/image_pipe/plug_dialect_runner_test.exs test/image_pipe/dialect/ test/image_pipe/architecture_boundary_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS. Native blurhash and imgproxy `/info` are unchanged (`cache:` defaults to `:complete_body`).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/dialect/render_terminal.ex lib/image_pipe/plug/dialect_runner.ex test/support/image_pipe/test/runner_fixture_dialect.ex test/image_pipe/plug_dialect_runner_test.exs
git commit -m "Widen RenderTerminal with cache:/offers: and the uncached render delivery (Phase C task 3)"
```

---

### Task 4: Promote the generated cache-header policy (U8b)

`Request.HTTPCache` does two jobs: identity mechanics (dies, replaced by `Representation` + `Conditional`) and header-generation policy (survives, promoted to core). Move the policy, add `Resolved.http_cache`, and wire it between `Representation.build/3` and the conditional gate — where its ETag suppression can veto the 304, as today.

**Files:**
- Create: `lib/image_pipe/response/cache_policy.ex`
- Modify: `lib/image_pipe/response.ex`, `lib/image_pipe/dialect/resolved.ex`, `lib/image_pipe/plug/dialect_runner.ex`
- Modify: `lib/image_pipe/dialect/{native,imgproxy,twic_pics}.ex` (add `http_cache: :dialect_owned`)
- Modify: `test/support/image_pipe/test/runner_fixture_dialect.ex`, `test/image_pipe/architecture_boundary_test.exs`
- Test: `test/image_pipe/response/cache_policy_test.exs` (create), `test/image_pipe/plug_dialect_runner_test.exs`

**Interfaces:**
- Produces: `ImagePipe.Response.CachePolicy.generate(conn, %Representation{}, source_facts, config) :: %CacheHeaders{}` and `CachePolicy.conditional_matched(conn, config) :: :ok`, where

  ```elixir
  @type source_facts :: %{
          http_cache: :inherit | :enabled | :disabled,
          byte_identity: {:strong, term()} | :none,
          stable?: boolean(),
          adapter: module(),
          source_kind: :path | :url | :object | :reference
        }
  ```

  A plain map, not `%Source.Resolved{}` — the `Response` boundary must not gain a dep on `ImagePipe.Source`. The runner projects it.
- Produces: `%Resolved{http_cache: :generated | :dialect_owned}`, added to `@enforce_keys`.
- Emits: `[:http_cache, :prepare]`, `[:http_cache, :conditional, :match]`, `[:http_cache, :fallback, :no_store]` — same names, same metadata shapes. `[:http_cache, :cache_hit, :headers]` is **not** a policy event: it stays in `Response.Sender` and keeps firing for every dialect's image cache hits.

- [ ] **Step 1: Write the failing policy test**

Create `test/image_pipe/response/cache_policy_test.exs`. Port the **header-policy** cases from `test/image_pipe/request/http_cache_test.exs` — read that file first; it is the specification of the behavior being moved. Leave its ETag-material and digest-stability cases behind (they pin the deleted identity mechanism).

Every case must carry a private `telemetry_prefix`: `CachePolicy.generate/4` emits `[:http_cache, :prepare]` on every call, and `cdn_http_cache_wire_test.exs` asserts and refutes exactly those events concurrently (AGENTS.md telemetry-scoping rule).

```elixir
defmodule ImagePipe.Response.CachePolicyTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias ImagePipe.Cache.Key
  alias ImagePipe.Representation
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.CachePolicy

  @generated "public, max-age=31536000, immutable"

  # A hand-built %Representation{} is legitimate here: it is the value the
  # runner hands this module, and this module's whole contract is a pure
  # function of it. Representation's OWN construction is tested by
  # representation_test.exs.
  defp representation(overrides \\ []) do
    %Representation{
      cache_key: %Key{hash: "deadbeef", data: []},
      etag: Keyword.get(overrides, :etag, ~s("ipr1-abc")),
      vary: Keyword.get(overrides, :vary, []),
      no_store?: Keyword.get(overrides, :no_store?, false)
    }
  end

  defp facts(overrides \\ []) do
    Enum.into(overrides, %{
      http_cache: :inherit,
      byte_identity: {:strong, "seed"},
      stable?: true,
      adapter: ImagePipe.Source.HTTP,
      source_kind: :url
    })
  end

  defp config(overrides \\ []) do
    Keyword.merge(
      [http_cache: [mode: :enabled], telemetry_prefix: [:cache_policy_test]],
      overrides
    )
  end

  test "generates Cache-Control and the representation's ETag when enabled" do
    assert %CacheHeaders{headers: headers, etag: ~s("ipr1-abc")} =
             CachePolicy.generate(conn(:get, "/x"), representation(), facts(), config())

    assert {"cache-control", @generated} in headers
    assert {"etag", ~s("ipr1-abc")} in headers
  end

  test "mode :disabled generates nothing and withholds the ETag" do
    assert %CacheHeaders{headers: [], etag: nil} =
             CachePolicy.generate(
               conn(:get, "/x"),
               representation(),
               facts(),
               config(http_cache: [mode: :disabled])
             )
  end

  test "a per-source :disabled overrides an enabled mount" do
    assert %CacheHeaders{headers: [], etag: nil} =
             CachePolicy.generate(
               conn(:get, "/x"),
               representation(),
               facts(http_cache: :disabled),
               config()
             )
  end

  test "a host Set-Cookie suppresses generation" do
    conn = put_resp_cookie(conn(:get, "/x"), "session", "1")

    assert %CacheHeaders{headers: [], etag: nil} =
             CachePolicy.generate(conn, representation(), facts(), config())
  end

  test "a host Vary: * suppresses generation" do
    conn = put_resp_header(conn(:get, "/x"), "vary", "*")

    assert %CacheHeaders{headers: [], etag: nil} =
             CachePolicy.generate(conn, representation(), facts(), config())
  end

  test "a representation Vary: * suppresses generation" do
    assert %CacheHeaders{headers: [], etag: nil} =
             CachePolicy.generate(conn(:get, "/x"), representation(vary: ["*"]), facts(), config())
  end

  test "a host no-store suppresses generation" do
    conn = put_resp_header(conn(:get, "/x"), "cache-control", "no-store")

    assert %CacheHeaders{headers: [], etag: nil} =
             CachePolicy.generate(conn, representation(), facts(), config())
  end

  test "a host Cache-Control yields the ETag only" do
    conn = put_resp_header(conn(:get, "/x"), "cache-control", "max-age=60")

    assert %CacheHeaders{headers: [{"etag", ~s("ipr1-abc")}], etag: ~s("ipr1-abc")} =
             CachePolicy.generate(conn, representation(), facts(), config())
  end

  test "a host ETag is respected: none generated" do
    conn = put_resp_header(conn(:get, "/x"), "etag", ~s("host"))

    assert %CacheHeaders{headers: [{"cache-control", @generated}], etag: nil} =
             CachePolicy.generate(conn, representation(), facts(), config())
  end

  test "a no-store representation gets Cache-Control: no-store and no ETag" do
    assert %CacheHeaders{headers: [{"cache-control", "no-store"}], etag: nil} =
             CachePolicy.generate(
               conn(:get, "/x"),
               representation(etag: nil, no_store?: true),
               facts(byte_identity: :none, stable?: false),
               config()
             )
  end

  test "a non-GET/HEAD method generates nothing" do
    assert %CacheHeaders{headers: [], etag: nil} =
             CachePolicy.generate(conn(:post, "/x"), representation(), facts(), config())
  end

  test "representation Vary merges with a host Vary, deduplicated" do
    conn = put_resp_header(conn(:get, "/x"), "vary", "Origin")

    assert %CacheHeaders{representation_headers: [{"vary", "Origin, Accept"}]} =
             CachePolicy.generate(conn, representation(vary: ["Accept"]), facts(), config())
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/response/cache_policy_test.exs`
Expected: FAIL — `ImagePipe.Response.CachePolicy` is undefined.

- [ ] **Step 3: Implement the policy module**

Create `lib/image_pipe/response/cache_policy.ex` by porting `lib/image_pipe/request/http_cache.ex`'s header-generation half. Copy verbatim: `@generated_cache_control`, `@no_store`, `generated_cache_headers/6`'s `cond`, `cache_control_without_etag/2`, `generated_etag_only/…`, `merge_vary/2`, `split_vary/1`, both `vary_star?/1` heads, `host_has_no_store?/1`, `has_resp_header?/2`, `has_set_cookie?/1`, `has_host_cache_control?/1`, `byte_identity_kind/1`, `etag_emitted?/1`, `emit_fallback_telemetry/3`. Three substitutions:

- The ETag is **not** computed here — it is the representation's (U8: one identity mechanism). The policy only decides whether to emit it:

```elixir
  defp policy_etag(_conn, %Representation{etag: nil}), do: :not_generated

  defp policy_etag(conn, %Representation{etag: etag}) do
    cond do
      has_resp_header?(conn, "etag") -> :not_generated
      host_has_no_store?(conn) -> :not_generated
      true -> {:etag, etag}
    end
  end
```

- `representation_headers/2` sources `Vary` from the representation instead of the plan's output mode, and `merge_vary/2` takes a **list**:

```elixir
  defp representation_headers(_conn, %Representation{vary: []}), do: []
  defp representation_headers(conn, %Representation{vary: names}), do: merge_vary(conn, names)
```

  with `merge_vary(conn, names)` doing `existing ++ names |> Enum.uniq_by(&String.downcase/1)` and preserving the `Vary: *` collapse.

- `cache_control_without_etag/2` matches `%{byte_identity: :none}` and `%{byte_identity: {:strong, _}, stable?: true}` instead of `%CacheSemantics{}`; `emit_fallback_telemetry/3` reads `source_facts.adapter` / `source_facts.source_kind`.

Public surface:

```elixir
  @spec generate(Plug.Conn.t(), Representation.t(), source_facts(), keyword()) :: CacheHeaders.t()
  def generate(%Plug.Conn{} = conn, %Representation{} = representation, source_facts, config) do
    effective_mode = effective_mode(source_facts, config)
    representation_headers = representation_headers(conn, representation)

    {headers, etag, fallback_reason} =
      generated_cache_headers(
        conn,
        representation,
        source_facts,
        effective_mode,
        representation_headers
      )

    Telemetry.execute(
      Telemetry.telemetry_opts(config),
      [:http_cache, :prepare],
      %{},
      %{
        effective_mode: effective_mode,
        byte_identity: byte_identity_kind(source_facts.byte_identity),
        etag: etag_emitted?(etag)
      }
    )

    emit_fallback_telemetry(fallback_reason, source_facts, config)

    %CacheHeaders{
      representation_headers: representation_headers,
      headers: headers,
      etag: etag
    }
  end

  @doc """
  Emits `[:http_cache, :conditional, :match]`. The runner calls this at the
  conditional gate when the policy owns the headers — the policy owns the
  event, `ImagePipe.Response.Conditional` owns the matching.
  """
  @spec conditional_matched(Plug.Conn.t(), keyword()) :: :ok
  def conditional_matched(%Plug.Conn{method: method}, config) do
    Telemetry.execute(
      Telemetry.telemetry_opts(config),
      [:http_cache, :conditional, :match],
      %{},
      %{method: conditional_method(method)}
    )
  end

  defp conditional_method("GET"), do: :get
  defp conditional_method("HEAD"), do: :head

  defp effective_mode(%{http_cache: :inherit}, config),
    do: config |> Keyword.fetch!(:http_cache) |> Keyword.fetch!(:mode)

  defp effective_mode(%{http_cache: mode}, _config) when mode in [:enabled, :disabled], do: mode
```

Named `generate/4`, not `apply/4`: arity 4 does not clash with `Kernel.apply`, but the name reads as the wrong thing.

Add `CachePolicy` to `lib/image_pipe/response.ex`'s `exports:`, and update the `Response` **exports** pin in `test/image_pipe/architecture_boundary_test.exs` (it is an exact-equality assertion). `Response` already deps on `Representation` and `Telemetry`; **do not** add `ImagePipe.Source`.

- [ ] **Step 4: Run the policy test**

Run: `mise exec -- mix test test/image_pipe/response/cache_policy_test.exs test/image_pipe/architecture_boundary_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS.

- [ ] **Step 5: Add `Resolved.http_cache` and wire the runner**

1. `lib/image_pipe/dialect/resolved.ex`: add `:http_cache` to `@enforce_keys` (after `:debug?`), type `:generated | :dialect_owned`, and replace the "deliberately ABSENT in Phase A" moduledoc paragraph with:

```
  `http_cache` selects whether the runner applies the core generated
  cache-header policy (`ImagePipe.Response.CachePolicy`) between building the
  representation and the conditional gate:

    * `:generated` — the policy runs. It generates `Cache-Control` and emits
      the representation's `ETag` subject to the host-override and
      byte-identity suppression rules, and its suppression can veto the 304.
      It also owns the `[:http_cache, :prepare]`,
      `[:http_cache, :conditional, :match]`, and
      `[:http_cache, :fallback, :no_store]` events. Requires an
      `http_cache: [mode: :enabled]` config to generate anything at all.
    * `:dialect_owned` — the policy is skipped; identity headers come straight
      from the representation and none of those three events fire.
```

2. Add `http_cache: :dialect_owned` to the `%Resolved{}` literals in `lib/image_pipe/dialect/native.ex`, `lib/image_pipe/dialect/imgproxy.ex` (**both** `prepare/3` heads — the `/info` head and the image head), `lib/image_pipe/dialect/twic_pics.ex`, and `test/support/image_pipe/test/runner_fixture_dialect.ex`.

3. In `lib/image_pipe/plug/dialect_runner.ex`, `handle_request/4`:

```elixir
  defp handle_request(conn, dialect, request, config) do
    with {:ok, %Resolved{} = resolved} <- dialect.prepare(conn, request, config),
         {:ok, %ImageSource.Resolved{} = source} <-
           ImageSource.resolve(resolved.source, config, config),
         {:ok, %Negotiation{} = negotiation, material} <-
           resolve_negotiation(resolved.negotiation) do
      representation =
        Representation.build(source.identity, material, source.cache_semantics.byte_identity)

      # U8b: the generated-header policy runs HERE — before the conditional
      # gate — because its ETag suppression (mode :disabled, a host Set-Cookie
      # / Vary: * / Cache-Control: no-store, a byte-identity-less source) must
      # be able to veto the 304.
      cache_headers = cache_headers(conn, resolved, representation, source, config)

      if Conditional.not_modified?(conn, cache_headers.etag) do
        maybe_emit_conditional_match(conn, resolved, config)
        send_not_modified(conn, cache_headers, config)
      else
        serve_terminal(
          conn,
          dialect,
          resolved,
          source,
          negotiation,
          representation,
          cache_headers,
          config
        )
      end
    else
      {:error, reason} -> send_error(conn, dialect, reason, config)
    end
  end

  defp cache_headers(_conn, %Resolved{http_cache: :dialect_owned}, representation, _source, _config),
    do: CacheHeaders.from_representation(representation)

  defp cache_headers(conn, %Resolved{http_cache: :generated}, representation, source, config),
    do: CachePolicy.generate(conn, representation, source_facts(source), config)

  defp source_facts(%ImageSource.Resolved{} = source) do
    %{
      http_cache: source.http_cache,
      byte_identity: source.cache_semantics.byte_identity,
      stable?: source.cache_semantics.stable?,
      adapter: source.adapter,
      source_kind: source.source_kind
    }
  end

  defp maybe_emit_conditional_match(conn, %Resolved{http_cache: :generated}, config),
    do: CachePolicy.conditional_matched(conn, config)

  defp maybe_emit_conditional_match(_conn, %Resolved{http_cache: :dialect_owned}, _config),
    do: :ok
```

Every unused parameter is `_`-prefixed — `mix compile --warnings-as-errors` runs in Step 7.

4. **Thread BOTH `representation` and `cache_headers` through the serve path.** The cache **key** comes from `representation.cache_key`; the response **headers** now come from `cache_headers`. Do not conflate them into one struct — that would hide which of the two each site uses. Add the `cache_headers` parameter to, and delete the internal `CacheHeaders.from_representation/1` call from, **all nine** of:

   `serve_terminal/7` (all four clauses, including Task 3's new one) → `/8`, `serve/7` → `/8`, `deliver_hit/6` → `/7`, `deliver_hit_entry/6` → `/7`, `generate/8` → `/9`, `deliver_render_hit/6` → `/7`, `generate_render/7` → `/8`, `send_complete_body/5`, `send_not_modified/3`.

   `deliver_render_hit/6` and `generate_render/7` are imgproxy `/info`'s **only** two paths and are easy to miss: they call `send_complete_body/5` and `send_not_modified/3`, which this task re-signatures. Missing them is a runtime `FunctionClauseError` that `--warnings-as-errors` will not catch — only the imgproxy `/info` wire tests will.

5. **The fixture dialect needs a `:generated` mode.** `RunnerFixtureDialect.validate_config!/1` is `SharedConfig.validate_runtime!/1`, and `:http_cache` is **not** a `SharedConfig` key (delta 15 keeps it off the ordered dialects), so the key would be dropped. Give the fixture its own two-line `validate_config!/1` that splits `:http_cache` out, validates it as `[mode: :disabled | :enabled]`, and merges it back — and select `http_cache: :generated` from a `?http_cache=generated` query flag in `prepare/3`.

- [ ] **Step 6: Add runner-level pins**

Append to `test/image_pipe/plug_dialect_runner_test.exs` (scope the telemetry assertion with a private prefix):

```elixir
  describe "http_cache: :generated" do
    test "generates Cache-Control and the representation ETag, and round-trips a 304" do
      config = opts(http_cache: [mode: :enabled])
      conn = get("/fix/images/beach.jpg?http_cache=generated", config)

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert [etag] = get_resp_header(conn, "etag")

      revalidated =
        :get
        |> conn("/fix/images/beach.jpg?http_cache=generated")
        |> put_req_header("if-none-match", etag)
        |> ImagePipe.Plug.call(config)

      assert revalidated.status == 304
    end

    test "suppressing the ETag also vetoes the 304" do
      etag =
        "/fix/images/beach.jpg?http_cache=generated"
        |> get(opts(http_cache: [mode: :enabled]))
        |> get_resp_header("etag")
        |> hd()

      conn =
        :get
        |> conn("/fix/images/beach.jpg?http_cache=generated")
        |> put_req_header("if-none-match", etag)
        |> ImagePipe.Plug.call(opts(http_cache: [mode: :disabled]))

      assert conn.status == 200
      assert get_resp_header(conn, "etag") == []
    end

    test "dialect_owned emits the representation ETag and no policy events" do
      prefix = [:runner_dialect_owned_test]
      attach_forwarding_handler(prefix ++ [:http_cache, :prepare])

      conn = get("/fix/images/beach.jpg", opts(telemetry_prefix: prefix))

      assert [_etag] = get_resp_header(conn, "etag")
      assert get_resp_header(conn, "cache-control") == []
      refute_received {:telemetry, _, _, _}
    end
  end
```

Reuse the suite's existing telemetry-handler helper if it has one; otherwise attach and detach inline via `on_exit/1`.

- [ ] **Step 7: Run**

Run: `mise exec -- mix test test/image_pipe/response/cache_policy_test.exs test/image_pipe/plug_dialect_runner_test.exs test/image_pipe/dialect/ test/image_pipe/imgproxy_wire_conformance_test.exs test/image_pipe/twic_pics_wire_conformance_test.exs test/image_pipe/architecture_boundary_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS. The ordered dialects are byte-identical — `:dialect_owned` skips the policy entirely, and the imgproxy `/info` suite proves the nine-function threading is complete.

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/response/cache_policy.ex lib/image_pipe/response.ex lib/image_pipe/dialect/resolved.ex lib/image_pipe/dialect/native.ex lib/image_pipe/dialect/imgproxy.ex lib/image_pipe/dialect/twic_pics.ex lib/image_pipe/plug/dialect_runner.ex test/support/image_pipe/test/runner_fixture_dialect.ex test/image_pipe/response/cache_policy_test.exs test/image_pipe/plug_dialect_runner_test.exs test/image_pipe/architecture_boundary_test.exs
git commit -m "Promote the generated cache-header policy to core, gated by Resolved.http_cache (Phase C task 4)"
```

---
### Task 5: `ImagePipe.Dialect.Declarative` — the declarative tier

The base implements five of the six contract callbacks on top of one host callback. A declarative dialect writes `parse_plan/2`, `render_error/3`, and `validate_config!/1` and gets the rest.

It is its **own top-level boundary**, not a widening of `ImagePipe.Dialect`. `ImagePipe.Dialect` is the thin contract boundary every ordered dialect deps on; widening it to reach `Decode`/`Renderer`/`Telemetry` would let `Native`/`Imgproxy`/`TwicPics` reach those transitively and would hollow out the `refute_boundary_deps` pins that currently prove they cannot. `ImagePipe.Dialect.SharedConfig` sets the precedent — it is a sibling top-level boundary for exactly this reason.

**Files:**
- Create: `lib/image_pipe/dialect/declarative.ex`, `lib/image_pipe/dialect/declarative/identity.ex`
- Modify: `lib/image_pipe/dialect.ex` (add `parse_boolean/1`; deps unchanged)
- Modify: `lib/image_pipe/transform/executor.ex` (gate split)
- Modify: `test/image_pipe/architecture_boundary_test.exs` (add the new boundary + `@boundary_files` entry)
- Create: `test/support/image_pipe/test/declarative_fixture_dialect.ex`
- Test: `test/image_pipe/dialect/declarative_test.exs`, `test/image_pipe/dialect/declarative/identity_test.exs`, a `Transform.Executor` gate test, and an IIIF-shaped arm in `test/image_pipe/dialect/color_carry_parity_test.exs`

**Interfaces:**
- Consumes: `DecodePlanner.request_from_chain/3` (T1), `%RenderTerminal{cache: :none, offers: …}` (T3), `Resolved.http_cache: :generated` (T4), `ImagePipe.Renderer.run/3` (T2).
- Produces:
  - `use ImagePipe.Dialect.Declarative` — injects `@behaviour ImagePipe.Dialect`, `parse/2`, `prepare/3`, `decode_request/2`, `execute/4`, and an overridable `classify_error/1`.
  - `@callback parse_plan(Plug.Conn.t(), keyword()) :: {:ok, Plan.t()} | {:redirect, pos_integer(), String.t()} | {:error, term()}`.
  - `Declarative.config_keys/0 :: [:http_cache, :detector, :detector_required, :storage_inputs]` and `validate_config!/1` — the keys the base's own `prepare/3` reads. Task 6's `Dialect.IIIF.Config` splits on it.
  - `ImagePipe.Dialect.parse_boolean/1` (moved from `ImagePipe.Parser`).
- Parse failures are wrapped as `{:error, %ImagePipe.Dialect.Failure{phase: :parse, reason: reason}}`. This is the Phase B provenance mechanism, and it is what lets a host dialect render a 400 for an unrecognized *parse* rejection while an unrecognized *post-parse* failure stays a 500 — without inferring provenance from a tag allowlist.

- [ ] **Step 1: Write the failing wire test with a minimal fixture dialect**

Create `test/support/image_pipe/test/declarative_fixture_dialect.ex` — the public-contract smoke dialect the spec's Testing section calls for:

```elixir
defmodule ImagePipe.Test.DeclarativeFixtureDialect do
  @moduledoc false
  # The smallest possible host dialect on the declarative tier: proof that a
  # third party can `use ImagePipe.Dialect.Declarative`, implement three
  # functions, and mount through `ImagePipe.Plug` with no core changes.

  use Boundary, top_level?: true, check: [out: false]
  use ImagePipe.Dialect.Declarative

  alias ImagePipe.Dialect.Declarative
  alias ImagePipe.Dialect.Failure
  alias ImagePipe.Dialect.SharedConfig
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source.Path, as: SourcePath

  @impl ImagePipe.Dialect
  def validate_config!(opts) do
    {shared, rest} = Keyword.split(opts, SharedConfig.keys())
    {base, []} = Keyword.split(rest, Declarative.config_keys())

    Keyword.merge(SharedConfig.validate_runtime!(shared), Declarative.validate_config!(base))
  end

  @impl ImagePipe.Dialect.Declarative
  def parse_plan(%Plug.Conn{} = conn, _config) do
    conn = Plug.Conn.fetch_query_params(conn)

    with {:ok, width} <- width(conn.query_params),
         {:ok, resize} <- Operation.resize(:fit, {:px, width}, :auto) do
      {:ok,
       %Plan{
         source: %SourcePath{segments: conn.path_info},
         pipelines: [%Pipeline{operations: [resize]}],
         output: %Output{mode: {:explicit, :jpeg}}
       }}
    end
  end

  @impl ImagePipe.Dialect
  def render_error(conn, %Failure{phase: :parse, reason: reason}, _config),
    do: Plug.Conn.send_resp(conn, 400, "declarative fixture: #{inspect(reason)}")

  def render_error(conn, reason, _config),
    do: Plug.Conn.send_resp(conn, 500, "declarative fixture: #{inspect(reason)}")

  defp width(%{"w" => raw}) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _other -> {:error, {:invalid_width, raw}}
    end
  end

  defp width(_params), do: {:ok, 200}
end
```

Create `test/image_pipe/dialect/declarative_test.exs`:

```elixir
defmodule ImagePipe.Dialect.DeclarativeTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias ImagePipe.Test.DeclarativeFixtureDialect

  defp opts(extra \\ []) do
    ImagePipe.Plug.init(
      Keyword.merge([dialect: DeclarativeFixtureDialect, sources: sources()], extra)
    )
  end

  defp get(path, config), do: ImagePipe.Plug.call(conn(:get, path), config)

  test "a minimal host dialect mounts and serves an image" do
    conn = get("/images/beach.jpg?w=64", opts())

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    {:ok, image} = Image.open(conn.resp_body)
    assert Image.width(image) == 64
  end

  test "the host's parse rejection reaches its own render_error as a parse Failure" do
    conn = get("/images/beach.jpg?w=nope", opts())

    assert conn.status == 400
    assert conn.resp_body =~ "invalid_width"
  end

  test "http_cache: [mode: :enabled] generates CDN headers and round-trips a 304" do
    config = opts(http_cache: [mode: :enabled])
    conn = get("/images/beach.jpg?w=64", config)

    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert [etag] = get_resp_header(conn, "etag")

    revalidated =
      :get
      |> conn("/images/beach.jpg?w=64")
      |> put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(config)

    assert revalidated.status == 304
  end

  test "without http_cache: [mode: :enabled] the declarative tier emits no ETag" do
    conn = get("/images/beach.jpg?w=64", opts())

    assert conn.status == 200
    assert get_resp_header(conn, "etag") == []
  end

  defp sources do
    # Reuse the shipped source-test doubles; copy the arrangement from
    # test/image_pipe/plug_dialect_runner_test.exs's `opts/1`. If the origin
    # plug it uses lives inside another suite module rather than test/support,
    # promote it into test/support in this task.
    ImagePipe.SourceTest.fixture_sources()
  end
end
```

The last test is not decoration: it pins delta 13. A declarative dialect emits **no** `ETag` at all under the default `http_cache: [mode: :disabled]` — matching the framework, but asymmetric with the ordered dialects, which always emit the representation ETag. Do **not** write the 304 test against the default config; it cannot pass.

- [ ] **Step 2: Write the failing identity test**

Create `test/image_pipe/dialect/declarative/identity_test.exs`. Task 12 deletes ~1200 lines of `cache/key_test.exs`, which is the only place the field-level composition of a Plan-derived key is pinned today. `Declarative.Identity` is the only genuinely new logic in this phase; it needs its own invariants, not just the wire round-trips:

```elixir
defmodule ImagePipe.Dialect.Declarative.IdentityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test

  alias ImagePipe.Dialect.Declarative.Identity
  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Representation

  # These build a %Plan{} through the real constructors (Operation.resize/4 and
  # friends) — never a hand-rolled struct literal — so every shape asserted here
  # is one a parse_plan/2 can actually produce.

  defp key(plan, opts \\ []) do
    negotiation = Keyword.get(opts, :negotiation, image_negotiation())
    config = Keyword.get(opts, :config, [])
    conn = Keyword.get(opts, :conn, conn(:get, "/x"))
    detector = Keyword.get(opts, :detector)

    material = Identity.material(SomeDialect, plan, negotiation, conn, config, detector)
    Representation.build([source: "seed"], material, {:strong, "seed"})
  end

  test "the cachebuster moves the cache key but not the ETag" do
    base = key(plan())
    busted = key(%{plan() | cachebuster: "v2"})

    assert base.cache_key.hash != busted.cache_key.hash
    assert base.etag == busted.etag
  end

  test "a configured storage-input header value moves the key but not the ETag" do
    config = [storage_inputs: [{:header, "accept-language"}]]
    en = key(plan(), config: config, conn: conn_with_header("accept-language", "en"))
    de = key(plan(), config: config, conn: conn_with_header("accept-language", "de"))

    assert en.cache_key.hash != de.cache_key.hash
    assert en.etag == de.etag
  end

  test "the detector identity moves both the key and the ETag" do
    without = key(plan())
    with_detector = key(plan(), detector: {SomeDetector, "model-v3"})

    assert without.cache_key.hash != with_detector.cache_key.hash
    assert without.etag != with_detector.etag
  end

  test "plan.response never moves either digest" do
    debug = %{plan() | response: %ImagePipe.Plan.Response{debug?: true}}

    assert key(plan()).cache_key.hash == key(debug).cache_key.hash
    assert key(plan()).etag == key(debug).etag
  end

  test "derivation is stable across repeated calls" do
    assert key(plan()).cache_key.hash == key(plan()).cache_key.hash
    assert key(plan()).etag == key(plan()).etag
  end

  property "any byte-affecting difference separates the cache key" do
    check all({left, right} <- distinct_plan_pair(), max_runs: 200) do
      assert key(left).cache_key.hash != key(right).cache_key.hash
    end
  end
end
```

Build `distinct_plan_pair/0` to vary one byte-affecting field at a time: an operation parameter, the operation list, `auto_rotate`, the output mode, the output quality, an encoder option, and the negotiation's `selected`. Also assert that a `%Plan{output: nil, render: {:custom, …}}` (the info-plan shape) with a different renderer module or params separates the key — that is the render terminal's identity.

- [ ] **Step 3: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/dialect/declarative_test.exs test/image_pipe/dialect/declarative/`
Expected: FAIL at compile — `ImagePipe.Dialect.Declarative` is undefined.

- [ ] **Step 4: Implement the Plan → identity material derivation**

Create `lib/image_pipe/dialect/declarative/identity.ex` — the analogue of each ordered dialect's `Identity.material/4-5`:

```elixir
defmodule ImagePipe.Dialect.Declarative.Identity do
  @moduledoc """
  Composes a declarative dialect's representation identity material from its
  `%ImagePipe.Plan{}`.

    * `representation` — byte-affecting data: the canonical semantic operation
      chains (`ImagePipe.Plan.KeyData.data/1` per operation), `auto_rotate`,
      the terminal identity (`:image`, or the renderer module + params), the
      canonical output plan, the resolved detector identity, and the
      negotiation outcome + effective output policy material.
    * `storage_only` — the plan's cachebuster plus configured `storage_inputs`
      values. Excluded from the ETag: both partition storage without changing
      the delivered bytes.

  `dialect_behavior` is the host dialect's module plus `@declarative_epoch` —
  the tier's own behavioral epoch, bumped when a change to this derivation must
  invalidate every representation every declarative dialect has built.

  `plan.expires` and `plan.response` are deliberately absent from both buckets:
  `expires` is a gate, not identity, and `response` is delivery presentation
  (including `debug?`, which must never move the key or ETag).
  """

  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.KeyData
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Representation
  alias ImagePipe.Representation.IdentityMaterial

  @declarative_epoch 1

  @spec material(module(), Plan.t(), Negotiation.t(), Plug.Conn.t(), keyword(), term()) ::
          IdentityMaterial.t()
  def material(dialect, %Plan{} = plan, %Negotiation{} = negotiation, conn, config, detector) do
    {storage_only, storage_vary_names} =
      Representation.storage_inputs(conn, Keyword.get(config, :storage_inputs, []))

    representation =
      [
        pipelines: pipelines_data(plan.pipelines),
        auto_rotate: plan.auto_rotate,
        detector: detector,
        output: output_data(plan.output, config)
      ] ++
        terminal_material(plan, negotiation.selected) ++
        [output_policy: negotiation.policy_material]

    vary_header_names =
      if negotiation.vary?,
        do: Enum.uniq(storage_vary_names ++ ["Accept"]),
        else: storage_vary_names

    %IdentityMaterial{
      representation: representation,
      storage_only: storage_only ++ [cachebuster: plan.cachebuster],
      dialect_behavior: {dialect, @declarative_epoch},
      vary_header_names: vary_header_names
    }
  end

  defp pipelines_data(pipelines) do
    Enum.map(pipelines, fn %Pipeline{operations: operations} ->
      Enum.map(operations, &KeyData.data/1)
    end)
  end

  # A render terminal's identity IS the renderer module + params. It rides the
  # Plan, not `negotiation.selected` — the promoted `%Negotiation{}`'s
  # `selected` type is `{:terminal, atom()}`, and widening a public SDK type to
  # carry a renderer spec would be a contract change for a value only this
  # module reads.
  defp terminal_material(_plan, {:image, _selection} = selected),
    do: [terminal: :image, selection: selected]

  defp terminal_material(%Plan{render: {:custom, module, params}}, {:terminal, :render}),
    do: [terminal: {:render, module, params}]

  # A custom render carries no image output plan.
  defp output_data(nil, _config), do: []

  defp output_data(%Output{mode: :automatic} = output, config) do
    [
      mode: :automatic,
      auto: [
        jpeg_xl: Keyword.get(config, :auto_jpeg_xl, true),
        avif: Keyword.get(config, :auto_avif, true),
        webp: Keyword.get(config, :auto_webp, true)
      ]
    ] ++ common_output_data(output, output.encoder_options)
  end

  defp output_data(%Output{mode: {:explicit, format}} = output, _config) do
    # Explicit format: only the selected format's encoder options shape the
    # bytes (`Policy.resolved/2` forwards only `Map.get(.., format)`), so the
    # digest narrows to it.
    [mode: :explicit, format: format] ++
      common_output_data(output, Map.take(output.encoder_options, [format]))
  end

  defp common_output_data(%Output{} = output, encoder_options) do
    [
      quality: output.quality,
      format_qualities: output.format_qualities,
      quality_search: KeyData.quality_search_data(output.quality_search),
      max_bytes: output.max_bytes,
      strip_metadata: output.strip_metadata,
      color_profile: output.color_profile,
      keep_copyright: output.keep_copyright,
      hdr: output.hdr,
      flatten_background: Color.key_data(output.flatten_background),
      encoder_options:
        Map.new(encoder_options, fn {format, struct} -> {format, Map.from_struct(struct)} end)
    ]
  end
end
```

`KeyData.quality_search_data/1` does not exist yet — **move** `Cache.Key`'s private `quality_search_key/1` and `quality_metric_key/2` into `ImagePipe.Plan.KeyData` as a public `quality_search_data/1`, and have `Cache.Key` call it (it stays alive until Task 12). `Plan.KeyData` is already a `Plan`-boundary export; `ImagePipe.Cache` must **not** become a `Declarative` dep.

- [ ] **Step 5: Split the `Executor` preamble gate**

`ImagePipe.Transform.Executor.seed_execution_state/3` gates BOTH the EXIF-orientation seed and the input-color-management preamble on one `:seed_orientation` option. On the dialect path `ImagePipe.Decode.with_image/4` already seeded `State.pending_orientation`, so the base must run the colour preamble **without** re-seeding orientation. In `lib/image_pipe/transform/executor.ex`:

- `seed_execution_state/3` keeps reading `opts[:seed_orientation]` for the orientation seed.
- `seed_color_management/2` reads `Keyword.get(opts, :seed_input_color_management, Keyword.get(opts, :seed_orientation, false))` — defaulting to the old gate so every current caller and Executor test keeps its behavior with no edit.
- Rewrite the two comments that describe the preamble as riding "the same gate as EXIF orientation" so they describe the two gates as they now are. Two dialect pipelines cite this gate by name and line and go stale in the same edit — fix them in this commit: `lib/image_pipe/dialect/imgproxy/pipeline.ex` (the "Mirrors `Executor.seed_color_management/2`" block and its "no `seed_orientation` gate" divergence note) and `lib/image_pipe/dialect/native/pipeline.ex`'s corresponding reference.

Add a focused Executor test asserting `seed_input_color_management: true, seed_orientation: false` conditions the input colour and leaves `pending_orientation` untouched.

- [ ] **Step 6: Implement the base**

Create `lib/image_pipe/dialect/declarative.ex`:

```elixir
defmodule ImagePipe.Dialect.Declarative do
  @moduledoc """
  The declarative tier of the `ImagePipe.Dialect` contract (design decision U6).

  A dialect whose whole request is expressible as a product-neutral
  `%ImagePipe.Plan{}` implements ONE parse callback and gets the rest of the
  lifecycle from this base:

      defmodule MyApp.Dialect do
        use ImagePipe.Dialect.Declarative

        @impl ImagePipe.Dialect.Declarative
        def parse_plan(conn, config), do: {:ok, %ImagePipe.Plan{...}}

        @impl ImagePipe.Dialect
        def render_error(conn, reason, config), do: ...

        @impl ImagePipe.Dialect
        def validate_config!(opts), do: ...
      end

  Mount it exactly like an ordered dialect:

      plug ImagePipe.Plug, dialect: MyApp.Dialect, sources: [...]

  This is not a second lifecycle. Same behaviour, same runner, same mount — the
  runner never branches on which base produced the
  `%ImagePipe.Dialect.Resolved{}`. The ordered/declarative distinction is only
  about who owns the transform stage: an ordered dialect runs its own pipeline
  in `c:ImagePipe.Dialect.execute/4`, a declarative one runs the fixed neutral
  driver.

  `parse_plan/2` is deliberately NOT named `parse/2`: this base implements the
  behaviour's `parse/2` (the `[:parse]` span's stop metadata and the parse-phase
  `%ImagePipe.Dialect.Failure{}` wrapper) on top of it.

  ## What your `render_error/3` receives

  A parse rejection arrives wrapped as `%ImagePipe.Dialect.Failure{phase: :parse,
  reason: your_reason}`; every other failure arrives as a bare reason. Match the
  wrapper to render client errors for parse rejections you do not recognize,
  without inferring provenance from a tag allowlist. `classify_error/1` is
  injected with a sensible default and is `defoverridable` — an override must
  re-declare `@impl ImagePipe.Dialect`.
  """

  alias ImagePipe.Decode
  alias ImagePipe.Dialect.Declarative.Identity
  alias ImagePipe.Dialect.Failure
  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Dialect.RenderTerminal
  alias ImagePipe.Dialect.Resolved
  alias ImagePipe.Error
  alias ImagePipe.Plan
  alias ImagePipe.Plan.RenderContext
  alias ImagePipe.Plan.SourceInfo
  alias ImagePipe.Renderer
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.InputColorManagement
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Decode,
      ImagePipe.Dialect,
      ImagePipe.Dialect.SharedConfig,
      ImagePipe.Error,
      ImagePipe.Plan,
      ImagePipe.Renderer,
      ImagePipe.Representation,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: []

  @doc """
  Parses a request into a product-neutral plan. The base wraps this in the
  behaviour's `c:ImagePipe.Dialect.parse/2` and its `[:parse]` span.
  """
  @callback parse_plan(Plug.Conn.t(), keyword()) ::
              {:ok, Plan.t()}
              | {:redirect, pos_integer(), String.t()}
              | {:error, term()}

  @config_keys [:http_cache, :detector, :detector_required, :storage_inputs]

  @config_schema NimbleOptions.new!(
                   http_cache: [
                     type: :keyword_list,
                     default: [mode: :disabled],
                     keys: [mode: [type: {:in, [:disabled, :enabled]}, default: :disabled]]
                   ],
                   detector: [type: {:or, [{:in, [:default, nil]}, :atom]}, default: :default],
                   detector_required: [type: :boolean, default: false],
                   storage_inputs: [
                     type:
                       {:list,
                        {:custom, ImagePipe.Dialect.SharedConfig, :validate_storage_input, []}},
                     default: []
                   ]
                 )

  @doc """
  The config keys this base reads, for a declarative dialect's own
  `c:ImagePipe.Dialect.validate_config!/1` to split on — the same delegation
  shape `ImagePipe.Dialect.SharedConfig.keys/0` uses.
  """
  @spec config_keys() :: [atom()]
  def config_keys, do: @config_keys

  @doc "Validates and defaults the keys `config_keys/0` names. Raises on invalid input."
  @spec validate_config!(keyword()) :: keyword()
  def validate_config!(opts) when is_list(opts) do
    case NimbleOptions.validate(Keyword.take(opts, @config_keys), @config_schema) do
      {:ok, validated} ->
        Keyword.merge(opts, validated)

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError,
              "invalid ImagePipe declarative dialect options: #{Exception.message(error)}"
    end
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour ImagePipe.Dialect
      @behaviour ImagePipe.Dialect.Declarative

      @impl ImagePipe.Dialect
      def parse(conn, config), do: ImagePipe.Dialect.Declarative.parse(__MODULE__, conn, config)

      @impl ImagePipe.Dialect
      def prepare(conn, plan, config),
        do: ImagePipe.Dialect.Declarative.prepare(__MODULE__, conn, plan, config)

      @impl ImagePipe.Dialect
      def decode_request(plan, geometry),
        do: ImagePipe.Dialect.Declarative.decode_request(plan, geometry)

      @impl ImagePipe.Dialect
      def execute(state, geometry, plan, opts),
        do: ImagePipe.Dialect.Declarative.execute(state, geometry, plan, opts)

      @impl ImagePipe.Dialect
      def classify_error(reason), do: ImagePipe.Dialect.Declarative.classify_error(reason)

      defoverridable classify_error: 1
    end
  end

  # -- parse ------------------------------------------------------------------

  @doc false
  def parse(dialect, %Plug.Conn{} = conn, config) do
    result = dialect.parse_plan(conn, config)
    {wrap_parse_failure(result), parse_stop_metadata(result)}
  end

  defp wrap_parse_failure({:error, reason}), do: {:error, %Failure{phase: :parse, reason: reason}}
  defp wrap_parse_failure(result), do: result

  defp parse_stop_metadata({:ok, %Plan{}}), do: %{result: :ok}

  defp parse_stop_metadata({:redirect, status, _location}),
    do: %{result: :redirect, status: status}

  defp parse_stop_metadata({:error, reason}), do: %{result: :error, error: Error.tag(reason)}

  # -- prepare ----------------------------------------------------------------

  @doc false
  def prepare(dialect, %Plug.Conn{} = conn, %Plan{} = plan, config) do
    with {:ok, _pipelines} <- validate_plan(plan),
         :ok <- check_detector(plan, config) do
      {:ok,
       %Resolved{
         request: plan,
         source: plan.source,
         negotiation: fn -> negotiation_result(dialect, conn, plan, config) end,
         response_meta: plan.response,
         operations: Plan.operation_names(plan),
         auto_rotate?: plan.auto_rotate,
         debug?: plan.response.debug?,
         http_cache: :generated,
         terminal: terminal(plan)
       }}
    end
  end

  # `parse_plan/2` is a host callback, so its return value is a real boundary:
  # validate the plan's shape here rather than trusting it.
  defp validate_plan(%Plan{} = plan) do
    case Transform.validate_prefetch_safe_plan(plan) do
      {:ok, _pipelines} = ok -> ok
      {:error, reason} -> {:error, {:plan_validation, reason}}
    end
  end

  # Strict-mode capability gate: when the host opts into `detector_required`
  # and the plan asks for content detection, reject up-front. Availability is a
  # cheap load check (no I/O), so it runs before any source fetch or cache read.
  defp check_detector(%Plan{} = plan, config) do
    classes = Plan.detect_classes(plan)

    if Keyword.get(config, :detector_required, false) and classes != nil do
      config = Keyword.put(config, :classes, classes)

      if Transform.detector_available?(Keyword.get(config, :detector, :default), config),
        do: :ok,
        else: {:error, {:detector, :unavailable}}
    else
      :ok
    end
  end

  # The thunk is invoked by the runner only after `ImagePipe.Source.resolve/3`,
  # preserving source-before-negotiation error precedence — and keeping the
  # detector-identity callback (a host callback) behind a successful resolve.
  defp negotiation_result(dialect, conn, %Plan{output: nil} = plan, config) do
    negotiation = Negotiation.terminal(:render)
    {:ok, negotiation, material(dialect, plan, negotiation, conn, config)}
  end

  defp negotiation_result(dialect, conn, %Plan{} = plan, config) do
    case Negotiation.negotiate(conn, plan.output, config) do
      {:ok, negotiation} ->
        {:ok, negotiation, material(dialect, plan, negotiation, conn, config)}

      {:error, _reason} = error ->
        error
    end
  end

  defp material(dialect, plan, negotiation, conn, config) do
    Identity.material(dialect, plan, negotiation, conn, config, detector_identity(plan, config))
  end

  defp detector_identity(%Plan{} = plan, config) do
    classes = Plan.detect_classes(plan)

    if classes != nil or Plan.face_assist?(plan) do
      config = Keyword.put(config, :classes, classes || ["face"])
      Transform.detector_identity(Keyword.get(config, :detector, :default), config)
    end
  end

  # -- terminal ---------------------------------------------------------------

  defp terminal(%Plan{render: :image}), do: :image

  defp terminal(%Plan{render: {:custom, _module, params} = spec}) do
    {:render,
     %RenderTerminal{
       cache: :none,
       offers: Map.get(params, :offers, []),
       fun: fn resolved_source, config -> render(spec, resolved_source, config) end
     }}
  end

  # Bridges to the `ImagePipe.Renderer` facade, which owns the `[:render]` span.
  # A renderer declares its depth with `requires/1`; today the only depth is
  # `:header`, satisfied by the decode bracket's header open.
  #
  # `Renderer.run/3` runs AFTER the bracket closes, not inside it: a renderer is
  # host code and has no business running inside the decode bracket's cleanup
  # scope. The `%SourceInfo{}` it needs is a plain value, so it travels out.
  defp render(spec, resolved_source, config) do
    info =
      Decode.with_image(
        resolved_source,
        Keyword.put(config, :auto_rotate?, false),
        fn _geometry -> %DecodePlanner.Request{} end,
        fn %State{} = state, %SourceGeometry{} = geometry ->
          {:ok, source_info(state, geometry)}
        end
      )

    with {:ok, %SourceInfo{} = info} <- info,
         {:ok, {content_type, body}} <- Renderer.run(spec, %RenderContext{info: info}, config) do
      {:ok, content_type, body}
    else
      # Every failure — fetch, decode, input limit, and the renderer's own —
      # carries the `{:render, _}` envelope, so a dialect's error module can
      # distinguish a render-terminal failure from an image-terminal one and
      # unwrap the inner families it renders specifically.
      {:error, reason} -> {:error, {:render, reason}}
    end
  end

  # `SourceInfo.width`/`height` are the STORED (pre-orientation) dimensions and
  # `orientation` is the raw EXIF tag read from the decoded image — NOT from
  # `geometry.debug_facts`, whose collection is best-effort and degrades to
  # `%{}` on failure, which would silently report orientation 1 and hand a
  # renderer the wrong display dimensions. The bracket is opened with
  # `auto_rotate?: false`, so `geometry.storage_dimensions` is the stored frame.
  # `byte_size` stays nil.
  defp source_info(%State{image: image}, %SourceGeometry{} = geometry) do
    {width, height} = geometry.storage_dimensions

    %SourceInfo{
      format: geometry.source_format,
      width: width,
      height: height,
      orientation: exif_orientation(image),
      byte_size: nil
    }
  end

  defp exif_orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) and value in 1..8 -> value
      _other -> 1
    end
  end

  # -- decode + execute -------------------------------------------------------

  @doc false
  def decode_request(%Plan{} = plan, %SourceGeometry{} = geometry) do
    DecodePlanner.request_from_chain(
      first_pipeline_operations(plan),
      geometry.storage_dimensions,
      PendingOrientation.quarter_turn?(geometry.pending_orientation)
    )
  end

  defp first_pipeline_operations(%Plan{pipelines: [%{operations: operations} | _rest]}),
    do: operations

  defp first_pipeline_operations(%Plan{pipelines: []}), do: []

  @doc false
  def execute(%State{} = state, %SourceGeometry{}, %Plan{} = plan, opts) do
    ImagePipe.Dialect.safe_transform(fn ->
      case Transform.execute_plan(plan, state, Keyword.put(opts, :seed_input_color_management, true)) do
        # `stamp_carry/1` is the ONLY writer of the icc-imported/icc-backup
        # headers the encoder's colorspace-to-result step reads. Skipping it
        # makes the encoder take its "no import ran" branch on an imported
        # image — correct output profile header, wrong pixels. Every pipeline
        # that runs the import preamble must also run this.
        {:ok, %State{} = state} -> {:ok, InputColorManagement.stamp_carry(state)}
        {:error, {:materialize_error, reason}} -> {:error, {:decode, reason}}
        {:error, _reason} = error -> error
      end
    end)
  end

  # -- error classification ---------------------------------------------------

  @doc false
  def classify_error(%Failure{phase: :parse}), do: :parser_error
  def classify_error({:plan_validation, _reason}), do: :plan_error
  def classify_error({:detector, :unavailable}), do: :plan_error
  def classify_error(reason), do: Telemetry.request_result({:error, reason})
end
```

`{:error, {:materialize_error, _}}` → `{:decode, _}` reproduces AGENTS.md's rule that materialization failures are decode failures (415), consistent between the mid-chain and delivery paths.

`Plan.operation_names/1` already exists and is the neutral derivation (`Operation.name/1` → `String.to_existing_atom`). Do **not** hand-roll a second one — a `String.to_atom` spelling is both a duplication ExDNA will flag and an unsafe variant of a function the core already owns.

Then in `lib/image_pipe/dialect.ex`, move `parse_boolean/1` verbatim from `lib/image_pipe/parser.ex` (its `@doc` too) — `Parser` dies in Task 11 and the IIIF/Native grammars share it. `ImagePipe.Dialect`'s Boundary deps are **unchanged**.

- [ ] **Step 7: Add the boundary pins and the ICC parity arm**

1. In `test/image_pipe/architecture_boundary_test.exs`, add `ImagePipe.Dialect.Declarative => "lib/image_pipe/dialect/declarative.ex"` to `@boundary_files` and a deps/exports pin for it, alongside the existing `ImagePipe.Dialect.SharedConfig` pin.
2. `test/image_pipe/dialect/color_carry_parity_test.exs` currently mounts only `dialect: Imgproxy` and `dialect: Native`. Add a declarative arm using `DeclarativeFixtureDialect` over an ICC-bearing fixture, comparing decoded pixels against an ordered-dialect leg. Without it, a dropped `stamp_carry/1` ships silently — the output profile header stays correct, so only a pixel comparison catches it (AGENTS.md: a change that visibly moves pixels needs a request-boundary pixel test, not a transform-unit assertion).

- [ ] **Step 8: Verify the source-runtime opts**

The framework called `Source.resolve(plan.source, opts, Options.source_runtime_opts(opts))` — a narrowed third argument. The runner calls `ImageSource.resolve(resolved.source, config, config)`. That is the established dialect-path behavior (all three ordered dialects already run this way) and the narrowing was a `Keyword.take/2`, so every key `Source` reads is present with the same name and value. Confirm by reading `ImagePipe.Source.resolve/3`'s use of its third argument; if it reads a key the narrowing deliberately withheld, record a delta rather than assuming equivalence.

- [ ] **Step 9: Run**

Run: `mise exec -- mix test test/image_pipe/dialect/declarative_test.exs test/image_pipe/dialect/declarative/ test/image_pipe/dialect/color_carry_parity_test.exs test/image_pipe/transform/ test/image_pipe/dialect/ test/image_pipe/architecture_boundary_test.exs && mise exec -- mix compile --warnings-as-errors && mise exec -- mix credo --strict`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/image_pipe/dialect/declarative.ex lib/image_pipe/dialect/declarative/identity.ex lib/image_pipe/dialect.ex lib/image_pipe/plan/key_data.ex lib/image_pipe/cache/key.ex lib/image_pipe/transform/executor.ex lib/image_pipe/dialect/imgproxy/pipeline.ex lib/image_pipe/dialect/native/pipeline.ex test/support/image_pipe/test/declarative_fixture_dialect.ex test/image_pipe/dialect/ test/image_pipe/transform/ test/image_pipe/architecture_boundary_test.exs
git commit -m "Add the ImagePipe.Dialect.Declarative tier (Phase C task 5)"
```

---
### Task 6: `ImagePipe.Dialect.IIIF`

Move `ImagePipe.Parser.IIIF` and its submodules onto the declarative tier with flat config. The grammar, plan building, tiling, info document, and resolver are unchanged code moving namespace.

**Files:**
- Create: `lib/image_pipe/dialect/iiif.ex`, `lib/image_pipe/dialect/iiif/config.ex`, `lib/image_pipe/dialect/iiif/errors.ex`
- Move: `lib/image_pipe/parser/iiif/{grammar,info,info_renderer,path,plan_builder,tiling,resolver}.ex` and `resolver/static.ex` → `lib/image_pipe/dialect/iiif/`
- Modify: `lib/image_pipe/parser/iiif.ex` (repoint at the moved submodules; deleted in Task 11)
- Modify: `test/image_pipe/architecture_boundary_test.exs`
- Test: `test/image_pipe/dialect/iiif/mount_test.exs` (create)

**Interfaces:**
- Produces: `ImagePipe.Dialect.IIIF` implementing `parse_plan/2`, `render_error/3`, `validate_config!/1`, `classify_error/1`; `ImagePipe.Dialect.IIIF.Resolver` behaviour + `Resolver.Static`.
- Config: flat dialect keys `resolver`, `formats`, `qualities`, `tile_size`, `max_width`, `max_height`, `max_area`; plus `Declarative.config_keys/0`, `SharedConfig.keys/0`, and `ImagePipe.Config.keys/0`.

- [ ] **Step 1: Move the submodules and hold the arch test green**

```bash
mkdir -p lib/image_pipe/dialect/iiif/resolver
for f in grammar info info_renderer path plan_builder tiling resolver; do
  git mv lib/image_pipe/parser/iiif/$f.ex lib/image_pipe/dialect/iiif/$f.ex
done
git mv lib/image_pipe/parser/iiif/resolver/static.ex lib/image_pipe/dialect/iiif/resolver/static.ex
```

Rename every `ImagePipe.Parser.IIIF.X` module and alias to `ImagePipe.Dialect.IIIF.X`; bodies are otherwise unchanged. Point the surviving `lib/image_pipe/parser/iiif.ex` at the new names so the framework path keeps working until Task 11.

That makes `lib/image_pipe/parser/iiif.ex` name `ImagePipe.Dialect.*`, which **fails two things**: `ImagePipe.Parser.IIIF`'s pinned Boundary deps (an exact-equality assertion), and the arch test's `"core, transform, and parser code does not name a dialect"` source grep, whose globs include `lib/image_pipe/parser/**`. Both must be handled in this commit:

- add `ImagePipe.Dialect.IIIF` to `ImagePipe.Parser.IIIF`'s `use Boundary` deps and to its pinned deps list;
- add a single, explicitly time-boxed exemption for `lib/image_pipe/parser/iiif.ex` to the dialect-name grep, with the comment: *"The framework IIIF shim delegates to the dialect's submodules for the duration of the migration. Removed with the file in Task 11."*

Task 14 removes both. Do not weaken the rule for any other path.

- [ ] **Step 2: Write the failing mount test**

Create `test/image_pipe/dialect/iiif/mount_test.exs`. Build its source arrangement by copying `test/parser/iiif_wire_test.exs`'s existing setup (`ImagePipe.SourceTest.RootHTTPAdapter` plus that file's origin plugs) — do not invent a fixtures directory:

```elixir
defmodule ImagePipe.Dialect.IIIF.MountTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias ImagePipe.Dialect.IIIF
  alias ImagePipe.Dialect.IIIF.Resolver.Static
  alias ImagePipe.Plan.Source.Path, as: SourcePath

  defp opts(extra \\ []) do
    ImagePipe.Plug.init(
      Keyword.merge(
        [
          dialect: IIIF,
          resolver: {Static, map: %{"beach" => %SourcePath{segments: ["images", "beach.jpg"]}}},
          sources: sources()
        ],
        extra
      )
    )
  end

  defp get(path, config), do: ImagePipe.Plug.call(conn(:get, path), config)

  test "serves an image request through the flat dialect mount" do
    conn = get("/beach/full/64,/0/default.jpg", opts())

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    {:ok, image} = Image.open(conn.resp_body)
    assert Image.width(image) == 64
  end

  test "info.json negotiates ld+json and varies, and touches no cache" do
    conn =
      :get
      |> conn("/beach/info.json")
      |> put_req_header("accept", "application/ld+json")
      |> ImagePipe.Plug.call(opts())

    assert conn.status == 200
    assert hd(get_resp_header(conn, "content-type")) =~ "application/ld+json"
    assert get_resp_header(conn, "vary") == ["Accept"]
    assert %{"type" => "ImageService3"} = JSON.decode!(conn.resp_body)
  end

  test "the base-URI redirect survives" do
    conn = get("/beach", opts())

    assert conn.status == 303
    assert [location] = get_resp_header(conn, "location")
    assert location =~ "/beach/info.json"
  end

  test "an unknown identifier is 404 and a bad grammar token is 400, both text/plain" do
    not_found = get("/nope/full/max/0/default.jpg", opts())
    assert not_found.status == 404
    assert hd(get_resp_header(not_found, "content-type")) =~ "text/plain"

    bad = get("/beach/full/max/0/nope.jpg", opts())
    assert bad.status == 400
    assert hd(get_resp_header(bad, "content-type")) =~ "text/plain"
  end

  test "an unrecognized parse rejection stays a 400, not a 500" do
    # A plan-building failure inside parse_plan/2 (e.g. an Operation.* reject)
    # must render as a client error via the %Failure{phase: :parse} envelope.
    # Drive it through whatever grammar-valid-but-unbuildable request the
    # PlanBuilder rejects; if none exists, assert it directly against
    # IIIF.render_error/3 with a synthetic %Failure{}.
    conn = get("/beach/-1,-1,0,0/max/0/default.jpg", opts())
    assert conn.status == 400
  end

  test "rejects an unknown config key with the dialect message" do
    assert_raise ArgumentError, ~r/unknown ImagePipe\.Dialect\.IIIF option/, fn ->
      ImagePipe.Plug.init(dialect: IIIF, resolver: {Static, map: %{}}, nope: 1)
    end
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/dialect/iiif/mount_test.exs`
Expected: FAIL — `ImagePipe.Dialect.IIIF` is undefined.

- [ ] **Step 4: Implement `Dialect.IIIF.Config`**

Create `lib/image_pipe/dialect/iiif/config.ex`, modelled on `lib/image_pipe/dialect/twic_pics/config.ex`:

```elixir
defmodule ImagePipe.Dialect.IIIF.Config do
  @moduledoc false

  alias ImagePipe.Config, as: NeutralConfig
  alias ImagePipe.Dialect.Declarative
  alias ImagePipe.Dialect.SharedConfig
  alias ImagePipe.Plan.Output.QualitySearch

  @dialect_keys [:resolver, :formats, :qualities, :tile_size, :max_width, :max_height, :max_area]

  @dialect_schema NimbleOptions.new!(
                    resolver: [
                      type: {:custom, __MODULE__, :validate_resolver, []},
                      required: true
                    ],
                    formats: [type: {:list, :atom}, default: [:jpg, :png, :webp, :avif]],
                    qualities: [
                      type: {:list, :atom},
                      default: [:default, :color, :gray, :bitonal]
                    ],
                    tile_size: [type: :pos_integer, default: 512],
                    max_width: [type: :pos_integer],
                    max_height: [type: :pos_integer],
                    max_area: [type: :pos_integer]
                  )

  @spec validate!(keyword()) :: keyword()
  def validate!(opts) when is_list(opts) do
    {shared, rest} = Keyword.split(opts, SharedConfig.keys())
    {base, rest} = Keyword.split(rest, Declarative.config_keys())
    {neutral, rest} = Keyword.split(rest, NeutralConfig.keys())
    {dialect, unknown} = Keyword.split(rest, @dialect_keys)

    reject_unknown!(unknown)
    validate_max_bounds!(dialect)

    resolved =
      shared
      |> SharedConfig.validate_runtime!()
      |> Keyword.merge(Declarative.validate_config!(base))
      |> Keyword.merge(NeutralConfig.resolve!(neutral, []))
      |> Keyword.merge(validate_dialect!(dialect))

    validate_autoquality!(resolved)
    resolved
  end

  defp reject_unknown!([]), do: :ok

  defp reject_unknown!(unknown) do
    raise ArgumentError,
          "unknown ImagePipe.Dialect.IIIF option(s): #{inspect(Keyword.keys(unknown))}"
  end

  defp validate_dialect!(dialect) do
    case NimbleOptions.validate(dialect, @dialect_schema) do
      {:ok, validated} ->
        validated

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid ImagePipe.Dialect.IIIF options: #{Exception.message(error)}"
    end
  end

  # IIIF Image API 3.0 §5.1: maxWidth must be specified if maxHeight is.
  # Checked on the RAW keyword — neither bound is defaulted, so presence is the
  # discriminator and it must be read before the schema merge.
  defp validate_max_bounds!(dialect) do
    if Keyword.has_key?(dialect, :max_height) and not Keyword.has_key?(dialect, :max_width) do
      raise ArgumentError,
            "ImagePipe.Dialect.IIIF max_height requires max_width (IIIF Image API 3.0 §5.1)"
    end

    :ok
  end

  # Config-only dialect: the autoquality search is fully determined here, so a
  # bad method/target combination surfaces at boot, not per request.
  defp validate_autoquality!(config) do
    case QualitySearch.from_config(config) do
      {:ok, _quality_search} ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "invalid ImagePipe.Dialect.IIIF autoquality config: #{inspect(reason)}"
    end
  end

  @doc false
  def validate_resolver(resolver), do: ImagePipe.Dialect.IIIF.Resolver.validate(resolver)
end
```

Port the resolver validation from `lib/image_pipe/parser/iiif.ex`'s existing `validate_resolver/1` verbatim — do not invent a new check. It validates a **host-supplied module**, which is a real boundary, so the `Code.ensure_loaded?`/`function_exported?` probe is appropriate here (unlike internal dispatch). Put it on `Resolver` if that reads better; either way it is one implementation, not two.

Also port `ImagePipe.Config.reject_unsupported!/3` (`@supported_neutral :all`, a no-op today) if the framework's `validate_options!/1` calls it — keeping the seam means a future IIIF-unsupported neutral key still raises.

- [ ] **Step 5: Implement `Dialect.IIIF.Errors`**

Create `lib/image_pipe/dialect/iiif/errors.ex`. It must reproduce the framework's statuses and bodies for **every** reachable reason. Before writing it, read `lib/image_pipe/parser/iiif.ex`'s `status_for/1`, `lib/image_pipe/response/sender.ex`'s `handle_processing_error/4` tree, `lib/image_pipe/response/error_status.ex`, and — for the core-stage families — `lib/image_pipe/dialect/imgproxy/errors.ex`, which already solved this for a dialect on the runner.

```elixir
defmodule ImagePipe.Dialect.IIIF.Errors do
  @moduledoc """
  Dialect-owned error → HTTP status mapping for the IIIF dialect.

  Grammar and identifier-resolution failures keep IIIF's terse vocabulary
  (404 `not found` / 400 `bad request`), and **any** unrecognized parse-phase
  rejection stays a 400: provenance rides the
  `%ImagePipe.Dialect.Failure{phase: :parse}` envelope, never a tag allowlist.

  Everything else routes through the shared `ImagePipe.Response.ErrorStatus`
  table, with the same core-stage rewraps every ordered dialect performs:
  a transform failure becomes `{:transform_error, _}` (422), a materialization
  failure becomes `{:decode, _}` (415), and a delivery-session failure is a
  server error.
  """

  import Plug.Conn, only: [put_resp_content_type: 2, send_resp: 3]

  require Logger

  alias ImagePipe.Dialect.Failure
  alias ImagePipe.Response.ErrorStatus

  @grammar_tags [
    :invalid_region,
    :invalid_size,
    :invalid_rotation,
    :invalid_quality,
    :invalid_format
  ]

  @spec send(Plug.Conn.t(), term(), keyword()) :: Plug.Conn.t()
  def send(%Plug.Conn{} = conn, %Failure{phase: :parse, reason: reason}, config),
    do: send_parse(conn, reason, config)

  def send(%Plug.Conn{} = conn, {:plan_validation, reason}, config),
    do: resolve(conn, reason, config)

  def send(%Plug.Conn{} = conn, {:detector, :unavailable}, config),
    do: resolve(conn, {:detector_unavailable, :unavailable}, config)

  # A renderer's own failure. Every inner family ErrorStatus already recurses
  # on ({:render, inner} -> classify(inner)/message_for(inner)) needs no clause;
  # this one reproduces Sender's distinct copy for an UNRECOGNIZED render
  # failure, which ErrorStatus alone would render "internal server error".
  def send(%Plug.Conn{} = conn, {:render, reason} = full, config) do
    case ErrorStatus.classify(full) do
      :server_error ->
        Logger.error("render_error: #{inspect(reason)}")
        text(conn, 500, "error rendering response")

      _class ->
        resolve(conn, full, config)
    end
  end

  # Core-stage rewraps, mirroring ImagePipe.Dialect.Imgproxy.Errors: a
  # materialization failure is a decode failure (415), a pipeline failure is
  # unprocessable (422).
  def send(%Plug.Conn{} = conn, {:transform, {:materialize_error, reason}}, config),
    do: resolve(conn, {:decode, reason}, config)

  def send(%Plug.Conn{} = conn, {:transform, inner}, config),
    do: resolve(conn, {:transform_error, inner}, config)

  def send(%Plug.Conn{} = conn, reason, config), do: resolve(conn, reason, config)

  defp send_parse(conn, :not_found, _config), do: text(conn, 404, "not found")

  defp send_parse(conn, {tag, _raw}, _config) when tag in @grammar_tags,
    do: text(conn, 400, "bad request")

  # `status_for/1`'s catch-all: every other parse rejection is a client error.
  defp send_parse(conn, _reason, _config), do: text(conn, 400, "bad request")

  defp resolve(conn, reason, config) do
    {status, message} = ErrorStatus.resolve_status(reason, config)
    text(conn, status, message)
  end

  defp text(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end
```

Two things to verify while implementing, and correct the module if either is false:

- `ErrorStatus.classify/1` is public (the `{:render, _}` clause needs it). If it is not, invert the check: enumerate the inner families `ErrorStatus` recurses on and let everything else fall to the 500 `"error rendering response"` clause.
- `{:session, _}` and the delivery-time `{:unsupported_output_format, _}` reach `render_error/3` from the runner. Their statuses/bodies change (delta 6); add a wire pin for each in Task 7 rather than leaving the change unasserted.

Delete any clause whose reason shape no producer constructs — AGENTS.md forbids guarding impossible misuse. Check each against a real producer before keeping it.

- [ ] **Step 6: Implement `Dialect.IIIF`**

Create `lib/image_pipe/dialect/iiif.ex`:

```elixir
defmodule ImagePipe.Dialect.IIIF do
  @moduledoc """
  IIIF Image API 3.0 (Level 2) dialect — the declarative tier's reference
  implementation. Mount it with:

      plug ImagePipe.Plug,
        dialect: ImagePipe.Dialect.IIIF,
        resolver: {MyApp.Resolver, []},
        sources: [...],
        max_width: 4000

  The positional grammar (`{id}/{region}/{size}/{rotation}/{quality}.{format}`)
  lowers to a product-neutral `%ImagePipe.Plan{}`; `ImagePipe.Dialect.Declarative`
  drives the rest of the lifecycle and `ImagePipe.Plug` owns the request spine.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Config,
      ImagePipe.Dialect,
      ImagePipe.Dialect.Declarative,
      ImagePipe.Dialect.SharedConfig,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Renderer,
      ImagePipe.Response
    ],
    exports: [Resolver]

  use ImagePipe.Dialect.Declarative

  alias ImagePipe.Dialect.Failure
  alias ImagePipe.Dialect.IIIF.Config
  alias ImagePipe.Dialect.IIIF.Errors
  alias ImagePipe.Dialect.IIIF.Grammar
  alias ImagePipe.Dialect.IIIF.Path
  alias ImagePipe.Dialect.IIIF.PlanBuilder

  @impl ImagePipe.Dialect
  def validate_config!(opts), do: Config.validate!(opts)

  @impl ImagePipe.Dialect.Declarative
  def parse_plan(%Plug.Conn{} = conn, config) do
    case Path.classify(conn) do
      {:redirect, _id, location} ->
        {:redirect, 303, location}

      {:info, id} ->
        with {:ok, source} <- resolve(id, config) do
          PlanBuilder.info_plan(source, Path.base_uri(conn) <> "/" <> URI.encode(id), config)
        end

      {:image, id, tokens} ->
        with {:ok, source} <- resolve(id, config),
             {:ok, parsed} <- parse_tokens(tokens) do
          PlanBuilder.image_plan(
            source,
            parsed,
            Keyword.put(config, :debug?, debug_requested?(conn))
          )
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  @impl ImagePipe.Dialect
  def render_error(conn, reason, config), do: Errors.send(conn, reason, config)

  # A parse rejection is a client error, whatever its shape — the phase decides,
  # not a tag table. Everything else defers to the declarative default.
  @impl ImagePipe.Dialect
  def classify_error(%Failure{phase: :parse}), do: :parser_error
  def classify_error(reason), do: ImagePipe.Dialect.Declarative.classify_error(reason)

  # `?debug=1` (also `?debug=true`) opts the response into `X-ImagePipe-*` debug
  # headers, honored only under the `allow_debug_headers: true` mount flag. The
  # IIIF path grammar has no free slot, so the trigger is an out-of-band query
  # param — an ImagePipe extension, not part of the IIIF spec. It is read
  # leniently: any non-true value (absent, `0`, `false`, garbage) disables it,
  # so a malformed flag never fails an otherwise-valid image request. IIIF has
  # no request signing, so the trigger is unprotected; see
  # docs/iiif_3_support_matrix.md.
  defp debug_requested?(%Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    Map.get(conn.query_params, "debug") in ["1", "true"]
  end

  defp resolve(id, config) do
    {module, resolver_opts} = Keyword.fetch!(config, :resolver)

    case module.resolve(id, resolver_opts) do
      {:ok, %_{} = source} -> {:ok, source}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp parse_tokens(%{region: r, size: s, rotation: rot, quality: q, format: f}) do
    with {:ok, region} <- Grammar.region(r),
         {:ok, size} <- Grammar.size(s),
         {:ok, rotation} <- Grammar.rotation(rot),
         {:ok, quality} <- Grammar.quality(q),
         {:ok, format} <- Grammar.format(f) do
      {:ok, %{region: region, size: size, rotation: rotation, quality: quality, format: format}}
    end
  end
end
```

`classify_error/1` is not optional here: without it, every 404/400 IIIF client rejection would be reported to telemetry handlers as `:processing_error` (the `Telemetry.request_result/1` default), where the framework reported `:parser_error`.

`PlanBuilder.info_plan/3` and `image_plan/3` now receive the **flat** config instead of the `iiif:` sublist. The key names are identical, so no `PlanBuilder` change should be needed — verify by reading both functions; if either reads a key the flat list spells differently, fix the read, not the config.

Add `ImagePipe.Dialect.IIIF => "lib/image_pipe/dialect/iiif.ex"` to `@boundary_files` and a deps/exports pin in `test/image_pipe/architecture_boundary_test.exs`, refuting `ImagePipe.Cache`, `ImagePipe.Delivery`, `ImagePipe.Request`, and every other dialect.

- [ ] **Step 7: Run**

Run: `mise exec -- mix test test/image_pipe/dialect/iiif/ test/parser/ test/image_pipe/architecture_boundary_test.exs && mise exec -- mix compile --warnings-as-errors && mise exec -- mix credo --strict`
Expected: PASS. The framework `Parser.IIIF` path still works (its submodule aliases were repointed), so `test/parser/` stays green.

- [ ] **Step 8: Commit**

```bash
git add -A lib/image_pipe/dialect lib/image_pipe/parser test/image_pipe/dialect/iiif test/image_pipe/architecture_boundary_test.exs
git commit -m "Add ImagePipe.Dialect.IIIF on the declarative tier (Phase C task 6)"
```

---

### Task 7: Migrate the IIIF-owned suites

**Files:**
- Move: `test/parser/iiif_test.exs` → `test/image_pipe/dialect/iiif/parse_test.exs`; `test/parser/iiif_wire_test.exs` → `test/image_pipe/dialect/iiif/wire_test.exs`; `test/parser/iiif/{grammar,info,path,plan_builder,resolver_static,tiling,openseadragon_sim}_test.exs` → `test/image_pipe/dialect/iiif/`
- Modify: `test/image_pipe/parser_test.exs` (keep only the `parse_boolean/1` cases, moved to `test/image_pipe/dialect_test.exs`; the `validate_options!/2` dispatch cases die with the behaviour)

- [ ] **Step 1: Move and repoint**

```bash
git mv test/parser/iiif_test.exs test/image_pipe/dialect/iiif/parse_test.exs
git mv test/parser/iiif_wire_test.exs test/image_pipe/dialect/iiif/wire_test.exs
for f in grammar info path plan_builder resolver_static tiling openseadragon_sim; do
  git mv test/parser/iiif/${f}_test.exs test/image_pipe/dialect/iiif/${f}_test.exs
done
rmdir test/parser/iiif test/parser
```

Rename every `ImagePipe.Parser.IIIF*` reference to `ImagePipe.Dialect.IIIF*`, and rename the test modules.

- [ ] **Step 2: Swap the mounts**

Every `ImagePipe.Plug.init(parser: ImagePipe.Parser.IIIF, iiif: [resolver: …, max_width: …], sources: …, cache: …)` becomes flat:

```elixir
    ImagePipe.Plug.init(
      dialect: ImagePipe.Dialect.IIIF,
      resolver: ...,
      max_width: ...,
      sources: ...,
      cache: ...
    )
```

Three config shapes change (delta 7):
- `cache: {Adapter, key_headers: [...], key_cookies: [...]}` → a top-level `storage_inputs: [{:header, name}, {:cookie, name}]`.
- **Test/DI seam keys** (`image_module`, `image_open_module`, `buffer_loader`, `image_materializer`, `on_bracket_exit`, `clock`) must be spliced onto the config **after** `ImagePipe.Plug.init/1`, not passed into it. Copy the pattern from `test/image_pipe/dialect/native_error_paths_test.exs`'s `opts/1`: split the seam keys out, `init/1` the rest, then `Keyword.merge` the seams back.
- Top-level `receive_timeout`/`connect_timeout`/`pool_timeout` move into the per-source adapter config.

`parse_test.exs` calls the parser directly. `Dialect.IIIF.parse/2` now returns `{result, span_metadata}` **and** wraps failures in `%Failure{phase: :parse}` — call **`parse_plan/2`** instead (the host contract, bare result), building config with `Dialect.IIIF.Config.validate!/1`. Then add three direct assertions on the behaviour surface:

```elixir
    assert {{:ok, %Plan{}}, %{result: :ok}} = IIIF.parse(conn(:get, "/beach/full/max/0/default.jpg"), config)

    assert {{:error, %Failure{phase: :parse, reason: :not_found}}, %{result: :error, error: :not_found}} =
             IIIF.parse(conn(:get, "/nope/full/max/0/default.jpg"), config)

    assert {{:redirect, 303, _location}, %{result: :redirect, status: 303}} =
             IIIF.parse(conn(:get, "/beach"), config)
```

- [ ] **Step 3: Rewrite the identity assertions as round-trips**

In `wire_test.exs`, any assertion on a literal ETag string or the `"ip1-"` prefix pins the framework's identity mechanism (delta 1). Replace with:

```elixir
    assert [etag] = get_resp_header(conn, "etag")

    revalidated =
      :get |> conn(path) |> put_req_header("if-none-match", etag) |> ImagePipe.Plug.call(config)

    assert revalidated.status == 304
```

Keep every assertion about **separation** (two different requests must not share an ETag or entry) and **stability** (the same request twice yields the same ETag) — those survive the mechanism swap and are the real contract. Note that ETag assertions require `http_cache: [mode: :enabled]` in the mount (delta 13); if the suite's config omitted it, the framework emitted no ETag either, so the test is new — add it deliberately rather than "fixing" it.

- [ ] **Step 4: Pin the delta-6 error-rendering changes**

Add wire pins for the reason families whose status or body changes, so the change is asserted rather than discovered:

- a parse rejection now carries `content-type: text/plain`;
- an unrecognized parse rejection is 400, not 500;
- a delivery-session failure renders 500 `"internal server error"`;
- a delivery-time output-negotiation failure renders 501.

Drive the last two through the existing `image_module` seam (spliced post-`init/1`), mirroring `test/image_pipe/dialect/native_error_paths_test.exs`.

- [ ] **Step 5: Run**

Run: `mise exec -- mix test test/image_pipe/dialect/ test/image_pipe/architecture_boundary_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS. Diagnose any failure as a port bug in Tasks 5/6, not a test to loosen — except for the enumerated deltas, where the assertion is what changes.

- [ ] **Step 6: Commit**

```bash
git add -A test/
git commit -m "Migrate the IIIF suites onto the dialect mount (Phase C task 7)"
```

---
### Task 8: Test-support parsers → declarative dialects, and the small framework suites

**Files:**
- Move: `test/support/image_pipe/test/automatic_iiif_parser.ex` → `automatic_iiif_dialect.ex`; `guided_iiif_parser.ex` → `guided_iiif_dialect.ex`
- Move: `test/support/image_pipe/request_safety_test/{invalid_plan,invalid_pipeline_plan}_parser.ex` → `*_dialect.ex`
- Modify: `test/image_pipe/request_safety_test.exs`, `test/image_pipe/cache_test.exs`, `test/image_pipe/source_test.exs`, `test/image_pipe/shrink_on_load_test.exs`, `test/image_pipe/deferred_orientation_property_test.exs`, `test/image_pipe/plug_redirect_test.exs`, `test/image_pipe/request_options_test.exs`

- [ ] **Step 1: Convert the test-support parsers**

`ImagePipe.Test.AutomaticIIIFParser` becomes:

```elixir
defmodule ImagePipe.Test.AutomaticIIIFDialect do
  @moduledoc false
  # IIIF with the output mode forced to :automatic, so the Accept-negotiation
  # suites keep a dialect that varies by Accept.

  use Boundary, top_level?: true, check: [out: false]
  use ImagePipe.Dialect.Declarative

  alias ImagePipe.Dialect.IIIF
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output

  @impl ImagePipe.Dialect
  def validate_config!(opts), do: IIIF.validate_config!(opts)

  @impl ImagePipe.Dialect.Declarative
  def parse_plan(conn, config) do
    case IIIF.parse_plan(conn, config) do
      {:ok, %Plan{output: %Output{} = output} = plan} ->
        {:ok, %Plan{plan | output: %Output{output | mode: :automatic}}}

      result ->
        result
    end
  end

  @impl ImagePipe.Dialect
  def render_error(conn, reason, config), do: IIIF.render_error(conn, reason, config)

  @impl ImagePipe.Dialect
  def classify_error(reason), do: IIIF.classify_error(reason)
end
```

`GuidedIIIFParser` converts the same way (`rewrite_guide/2` unchanged). The two `request_safety_test` parsers become dialects with the same shape: `parse_plan/2` returning their deliberately-invalid plan, the other three callbacks delegating to `IIIF`.

- [ ] **Step 2: Swap the mounts**

For each file, `rg -n "parser:|ImagePipe\.Parser|key_headers|key_cookies|image_module|image_open_module|buffer_loader|image_materializer|on_bracket_exit|receive_timeout|connect_timeout|pool_timeout"` and convert per delta 7 and delta 8 (the three config shapes listed in Task 7 Step 2). `parser: ImagePipe.Test.AutomaticIIIFParser` → `dialect: ImagePipe.Test.AutomaticIIIFDialect`.

- [ ] **Step 3: Fix the assertions the deltas move**

- **`request_options_test.exs`** pins `Request.Options`' typo suggestions and the `invalid ImagePipe options:` message — a deleted module's private messages. Delete the typo-suggestion tests (no replacement exists, by design) and rewrite the remaining validation cases against `Dialect.IIIF.Config.validate!/1`'s messages. If nothing survives that is not already covered by `shared_config_test.exs` and the new IIIF config test, delete the file.
- **`request_safety_test.exs`**: the negotiation-capability gate now fires before the cache (delta 5). A test asserting a cache lookup happened on an incapable-output request flips to `refute`. Its top-level `receive_timeout`/`connect_timeout` move into the source adapter config.
- **`cache_test.exs`**: convert wire-level cases to the dialect mount. The direct `Cache.lookup(conn, plan, …)` unit calls pin a function Task 12 deletes — port to `Cache.lookup_entry/2` where the behavior survives (fail-open read error, `:disabled`, hit/miss) and delete the rest. Its `key_headers`/`key_cookies` cases move to `storage_inputs` coverage, or delete if `identity_test.exs` (Task 5) already pins the partitioning.
- **`shrink_on_load_test.exs`**, **`deferred_orientation_property_test.exs`**: mount swap only; these pin pixel behavior that must not move. A failure here means Task 1's defunctionalization is wrong — fix `request_from_chain/3`.

- [ ] **Step 4: Run**

Run: `mise exec -- mix test test/image_pipe/request_safety_test.exs test/image_pipe/cache_test.exs test/image_pipe/source_test.exs test/image_pipe/shrink_on_load_test.exs test/image_pipe/deferred_orientation_property_test.exs test/image_pipe/plug_redirect_test.exs test/image_pipe/dialect/ test/image_pipe/architecture_boundary_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A test/
git commit -m "Convert the test-support parsers to declarative dialects; migrate the small framework suites (Phase C task 8)"
```

---

### Task 9: `plug_test.exs` → the dialect mount

2346 lines, 68 `parser:` mounts. Its own task because it is too large to review alongside anything else.

**Files:**
- Modify: `test/image_pipe/plug_test.exs`

- [ ] **Step 1: Swap every mount**

Work through the file in `describe`-block order. Apply the three config-shape conversions from Task 7 Step 2 — in particular, the `image_module:` / `image_open_module:` / `image_materializer:` sites (there are several) must be spliced **after** `ImagePipe.Plug.init/1`.

- [ ] **Step 2: Move only the four assertion families the deltas cover**

Everything else — statuses, bodies, decoded pixel dimensions, `Vary`, content types, cache hit/miss counts, source-fetch counts — must pass unchanged. The four that move:

1. `[:request]`/`[:parse]` **start** metadata: `parser:`/`request_method` are gone (delta 2).
2. Parse-error `error:` tags: the real tag, not the constant `:error` (delta 2).
3. `[:request]`/`[:send]` error metadata for source and plan-validation failures: `:source` / `:plan_validation` instead of the inner tag (delta 3).
4. ETag literals → round-trips (delta 1), and only under `http_cache: [mode: :enabled]` (delta 13).

Any other failure is a port bug. Do not loosen an assertion to make it pass; find the cause in Tasks 4–6.

- [ ] **Step 3: Run**

Run: `mise exec -- mix test test/image_pipe/plug_test.exs test/image_pipe/architecture_boundary_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add test/image_pipe/plug_test.exs
git commit -m "Migrate plug_test.exs onto the dialect mount (Phase C task 9)"
```

---

### Task 10: CDN-cache, debug-header, and telemetry suites

The gates for U8b, U13, and delta 2 respectively — their own task so a reviewer can reject the cache-policy port without rejecting Task 8/9's mechanical swaps.

**Files:**
- Modify: `test/image_pipe/cdn_http_cache_wire_test.exs`, `test/image_pipe/debug_headers_wire_test.exs`, `test/image_pipe/telemetry_test.exs`
- Modify: `test/image_pipe/telemetry/trace/{inbound_plug,cross_process,encode_span,materialize_span,open_telemetry_integration}_test.exs`, `test/image_pipe/telemetry/delivery_span_parentage_baseline_test.exs`
- Move: `test/image_pipe/request/delivery_owner_cleanup_baseline_test.exs` → `test/image_pipe/dialect/delivery_owner_cleanup_baseline_test.exs`

- [ ] **Step 1: `cdn_http_cache_wire_test.exs` — the U8b gate**

Swap the mount to `dialect: ImagePipe.Dialect.IIIF` with flat keys, keeping `http_cache: [mode: :enabled]` where the suite sets it. **Every header assertion must pass unchanged** — that is the point of promoting the policy rather than reimplementing it: generated `Cache-Control`, the Set-Cookie / `Vary: *` / host-`Cache-Control` / host-`no-store` suppressions, the `no-store` fallback for a byte-identity-less source, the per-source `:inherit` override, and the `[:http_cache, :*]` events.

Two families change:
- ETag literals and the `"ip1-"` prefix → round-trips (delta 1).
- `Vary` gains configured `storage_inputs` header names (delta 9). Add a pin for the merged value and its ordering.

Then resolve **delta 14** here: construct the case where `plan.output.mode == :automatic` but `Policy.identity_selection/1` collapses to `{:explicit, _}` (every `auto_*` disabled, or a restricted `output_capabilities`). The framework emitted `Vary: Accept`; the replacement does not. Either add a pin recording the new behavior, or demonstrate the case is unreachable and record why. Do not leave it unexamined.

- [ ] **Step 2: `debug_headers_wire_test.exs`**

Swap the mount. Every `X-ImagePipe-*` and `Server-Timing` assertion must pass unchanged, including the stored-facts hit replay — `Debug.Info` is now built unconditionally and stored with IIIF cache entries (delta 12). The `?debug=1` trigger and the `allow_debug_headers` gate are unchanged.

- [ ] **Step 3: `telemetry_test.exs` — the delta-2/3/4 gate**

Swap the mount, then work the span-shape deltas:

- `[:request]`/`[:parse]` **start** metadata → `%{}`.
- Parse-error stop metadata → `Error.tag(reason)`.
- Source/plan-validation error metadata → the outer tag (delta 3).
- `[:cache, :lookup]` and `[:source, :fetch_decode]`: same names, same metadata shapes, different emitters — assertions unchanged, except `{:unsupported_source_format, _}` now tags `:decode` in the fetch_decode stop metadata (delta 11).
- `[:render]`: still emitted for `info.json`, but as a **sibling** of `[:source, :fetch_decode]` with render-only duration, and **absent** when the fetch or decode fails (delta 4). Rewrite any assertion that depended on the old nesting or on its presence after a decode failure.

Add a positive assertion that the dialect-shaped span set is complete for one image request and one `info.json` request, so a future runner change that silently drops a span fails here. Scope every handler with a private `telemetry_prefix`.

- [ ] **Step 4: Trace/OTel and baseline suites**

Swap the mounts. `open_telemetry_integration_test.exs` asserts span names **and parentage** — delta 4 changes `[:render]`'s parent, so this is not a mount-only swap. Read its assertions before editing and update the `[:render]` parentage expectation deliberately.

- [ ] **Step 5: Run**

Run: `mise exec -- mix test test/image_pipe/cdn_http_cache_wire_test.exs test/image_pipe/debug_headers_wire_test.exs test/image_pipe/telemetry_test.exs test/image_pipe/telemetry/ test/image_pipe/dialect/ test/image_pipe/architecture_boundary_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A test/
git commit -m "Migrate the CDN-cache, debug-header, and telemetry suites onto the dialect mount (Phase C task 10)"
```

---
### Task 11: Delete the framework stack

Nothing mounts through `parser:` any more. Remove the second request model.

**Files:**
- Modify: `lib/image_pipe/plug.ex`, `lib/image_pipe.ex`
- Delete: `lib/image_pipe/request.ex`, `lib/image_pipe/request/`, `lib/image_pipe/parser.ex`, `lib/image_pipe/parser/`
- Delete: `test/image_pipe/request_runner_test.exs`, `test/image_pipe/processor_test.exs`, `test/image_pipe/request/{delivery_build,http_cache,options,render_runner,source_format}_test.exs`, `test/image_pipe/parser_test.exs`
- Modify: `test/image_pipe/request/vix_stream_continuation_test.exs` (ported, not deleted — see Step 4)
- Modify: `test/image_pipe/{shrink_on_load_property,shrink_through_crop,shrink_through_rotate}_test.exs`
- Modify: `test/image_pipe/architecture_boundary_test.exs`, `test/support/image_pipe/test/differential/harness.ex`

**Interfaces:**
- Produces: `ImagePipe.Plug.init/1` requires `:dialect` (an atom) and returns `[dialect: mod] ++ mod.validate_config!(rest)`; `call/2` delegates to `ImagePipe.Plug.DialectRunner.run/3`. There is no other mount mode.

- [ ] **Step 1: Shrink `ImagePipe.Plug` to the runner**

```elixir
defmodule ImagePipe.Plug do
  @moduledoc """
  The single mount interface for ImagePipe (design decision U2).

      plug ImagePipe.Plug, dialect: ImagePipe.Dialect.Imgproxy, sources: [...]

  `:dialect` names a module implementing `ImagePipe.Dialect` — an ordered
  dialect that owns its own pipeline, or a declarative one built on
  `ImagePipe.Dialect.Declarative`. Every other option is the dialect's flat
  config, validated by its `c:ImagePipe.Dialect.validate_config!/1` at init.

  This module is the lifecycle runner: parse → prepare → source resolve →
  representation → conditional gate → cache → terminal → deliver. It branches
  only on `%ImagePipe.Dialect.Resolved{}` fields and neutral core structs, and
  never names a dialect (design decision U4).
  """

  use Boundary,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Decode,
      ImagePipe.Delivery,
      ImagePipe.Dialect,
      ImagePipe.Error,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: []

  @behaviour Plug

  alias ImagePipe.Plug.DialectRunner

  @impl Plug
  def init(opts) do
    dialect = Keyword.fetch!(opts, :dialect)

    unless is_atom(dialect) do
      raise ArgumentError, "dialect: expected a module, got: #{inspect(dialect)}"
    end

    [dialect: dialect] ++ dialect.validate_config!(Keyword.delete(opts, :dialect))
  end

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    DialectRunner.run(conn, Keyword.fetch!(opts, :dialect), opts)
  end
end
```

The `is_atom/1` check is a host-config boundary guard the current `init/1` already has (`{:ok, dialect} when is_atom(dialect)`); keep it rather than letting a bad value die inside `validate_config!/1`.

Everything from `legacy_call/2` through `debug_requested?/2` is deleted.

- [ ] **Step 2: Delete the modules**

```bash
git rm -r lib/image_pipe/request.ex lib/image_pipe/request lib/image_pipe/parser.ex lib/image_pipe/parser
git rm test/image_pipe/request_runner_test.exs test/image_pipe/processor_test.exs test/image_pipe/parser_test.exs
git rm test/image_pipe/request/delivery_build_test.exs test/image_pipe/request/http_cache_test.exs \
       test/image_pipe/request/options_test.exs test/image_pipe/request/render_runner_test.exs \
       test/image_pipe/request/source_format_test.exs
```

Then drop `ImagePipe.Parser` and `ImagePipe.Request` from the root Boundary's `deps:` in `lib/image_pipe.ex` — the compiler surfaces this as a Boundary diagnostic under `--warnings-as-errors`, and it is easy to miss because it is not a module reference.

Run `mise exec -- mix compile --warnings-as-errors` and fix every remaining reference.

- [ ] **Step 3: Repoint the shrink suites**

`shrink_on_load_property_test.exs`, `shrink_through_crop_test.exs`, and `shrink_through_rotate_test.exs` drive `Request.Processor` directly. They pin shrink-on-load behavior, which survives. Repoint them at `ImagePipe.Decode.with_image/4` with `ImagePipe.Dialect.Declarative.decode_request/2` as the preflight, so they keep testing the same decision through the surviving seam. If a test's only subject is `Processor`'s two-open flow (already mirrored and tested in `Decode`), delete it instead of porting.

- [ ] **Step 4: Port `vix_stream_continuation_test.exs`, do not delete it**

It drives `Delivery.Producer` + `ProducerClient` + `ProofServer` to prove cross-process Vix stream continuation and fd cleanup. Only its `build_fun` comes from `Request.DeliveryBuild`; nothing on the dialect path replaces that coverage. Move it to `test/image_pipe/dialect/vix_stream_continuation_test.exs` and source the `build_fun` from the runner's build path (the fixture dialect through `DialectRunner`).

- [ ] **Step 5: Survivor audit for the deleted suites**

`request_runner_test.exs` (1355 lines) and `processor_test.exs` (627) are deleted wholesale. Before committing, produce a short written audit — in the commit message or the task report — naming, for each behavior family those files pinned, the dialect-path test that now covers it. The spec's Testing section names the families that must survive: conditional gate ordering, cache hit/miss/disabled, wildcard-INM-only-on-hit, render-terminal cache path, and error fan-out. Anything with no successor is either genuinely dead (say so) or a coverage hole to fill in this task.

- [ ] **Step 6: Clean the differential harness's framework arm**

`test/support/image_pipe/test/differential/harness.ex` still has a `plug_opts(parser, sources_dir)` calling `ImagePipe.Plug.init(parser: …)`. It is dead (only `dialect_plug_opts/2` has callers), so it will not break compilation — but it survives the deletion and violates the one-mount-shape exit criterion. Delete `plug_opts/2` and the framework-arm paragraphs in its moduledoc.

- [ ] **Step 7: Update the architecture test**

Delete every pin naming `ImagePipe.Request.*` or `ImagePipe.Parser.*`, including their `@boundary_files` entries (`boundary_declaration/1` does `File.read!` — a stale entry *raises*). Remove `lib/image_pipe/parser/**` and `lib/image_pipe/request/**` from `@parser_globs`, `@dialect_forbidden_globs`, `@detector_forbidden_globs`, and any other glob list. Remove the Task 6 grep exemption for `lib/image_pipe/parser/iiif.ex`.

- [ ] **Step 8: Run**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`
Expected: PASS. `rg -n "ImagePipe\.(Request|Parser)\b" lib/ test/` still reports comment hits — Task 13 clears those.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Delete the framework parser stack (Phase C task 11)"
```

---

### Task 12: Retire the Plan-derived cache key and the chain decode planner

Two API surfaces whose only production callers died in Task 11. Neither failure is a compile error — a public function with no caller compiles clean — so both need an explicit step.

**Files:**
- Modify: `lib/image_pipe/cache/key.ex`, `lib/image_pipe/cache.ex`, `lib/image_pipe/transform/decode_planner.ex`
- Modify: `test/image_pipe/cache/key_test.exs`, `test/image_pipe/transform/decode_planner_test.exs`
- Delete: `test/image_pipe/cache/key_render_test.exs`, `test/image_pipe/transform/decode_planner_chain_request_test.exs`

**Interfaces:**
- Produces: `ImagePipe.Cache.Key` keeps only `@enforce_keys`/`defstruct`/`@type` — no functions. `ImagePipe.Cache` keeps `lookup_entry/2` and the sink API. `DecodePlanner` keeps `open_options_for/5` + `request_from_chain/3` as its single entry point.

- [ ] **Step 1: Gut `Cache.Key`**

Delete `build/4`, `plan_material/2`, `representation_version/0`, `pipelines_data/1`, `transform_data/0`, `representation_data/1`, `output_plan_data/2`, `output_data/3`, `encoder_options_key/1`, `replace_keyword_value/3`, `cache_data/1`, `selected_headers/2`, `selected_cookies/2`, **and `hash/1`** (private, and `build/4` was its only caller), plus the `@schema_version`/`@transform_key_data_version`/`@representation_version` attributes, the `Plug.Conn` import, and the now-unused aliases (`MaterialDigest`, `Negotiation`, `Plan`, `Color`, `Output`, `Pipeline`, `KeyData`). `quality_search_key/1` already moved to `Plan.KeyData` in Task 5.

- [ ] **Step 2: Gut `Cache`'s framework surface**

Delete `lookup/4`, `lookup_configured/6`, `key_options/2`, and any private helper only they used. Delete `:key_headers`/`:key_cookies` from `@shared_cache_option_keys`, the shared cache option schema, and `reject_reserved_key_headers/1`.

**They must not simply stop being read.** A host passing `cache: {Adapter, key_headers: ["accept-language"]}` today gets a partitioned cache; after this task the option would validate, reach the adapter, and partition nothing — silent cross-variant cache hits. Make `Cache.validate_config!` **reject** both with a message naming the replacement:

```elixir
    raise ArgumentError,
          "cache option #{inspect(key)} was removed; partition on request headers and cookies " <>
            "with the mount-level storage_inputs: [{:header, name}, {:cookie, name}]"
```

Then check whether `ImagePipe.Plan` is still reachable from the `Cache` boundary; if not, drop it from `deps:` and update the `Cache` deps pin in the arch test.

- [ ] **Step 3: Prune `cache/key_test.exs`**

It is 1279 lines, almost entirely `plan_material`/`build` coverage — inputs no in-repo producer constructs any more. Delete it except for what still has a producer: the `MaterialDigest` canonicalization invariants and any `Plan.KeyData`/`quality_search_data/1` case, which move to `test/image_pipe/plan/key_data_test.exs`. Delete `cache/key_render_test.exs` outright (it tests `plan_material`'s render branch).

Its field-level key-composition coverage is replaced by `test/image_pipe/dialect/declarative/identity_test.exs` (Task 5) — confirm that file actually covers what you are deleting before deleting it, and extend it if not. Do not leave the composition unpinned.

- [ ] **Step 4: Retire `DecodePlanner.open_options/5`**

Its only production caller (`Request.Processor`) is gone. Delete `open_options/5`, `compute_load_shrink/3`, `crop_extent_before_resize/3`'s chain-walking caller if it becomes single-use, and `net_quarter_turn?/3` — keeping every helper `request_from_chain/3` and `open_options_for/5` still need.

Repoint `test/image_pipe/transform/decode_planner_test.exs`'s 30+ `open_options/5` calls through `request_from_chain/3 |> open_options_for/5`; the assertions are unchanged, so its coverage is preserved.

Then delete `test/image_pipe/transform/decode_planner_chain_request_test.exs`. It is a post-migration parity pin: with only one entry point left there is nothing to compare against, and AGENTS.md says such pins are deleted once the refactor lands. Its job — proving the port equal — is done, and `decode_planner_test.exs` now exercises the surviving path directly.

- [ ] **Step 5: Run**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test && mise exec -- mix credo --strict`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Retire the Plan-derived cache key and the chain decode planner (Phase C task 12)"
```

---

### Task 13: Retire the recorded duplications and the framework prose

The duplications several modules recorded are over — the framework twin is gone. AGENTS.md's clean-removal rule applies: the files must read as if the duplication never existed, with no note in its place.

**Files:**
- Modify: `mix.exs`, `.credo.exs`
- Modify: `lib/image_pipe/decode.ex`, `lib/image_pipe/decode/source_format.ex`, `lib/image_pipe/response/conditional.ex`, `lib/image_pipe/representation.ex`, `lib/image_pipe/transform/input_color_management.ex`, `lib/image_pipe/transform/decode_planner.ex`, `lib/image_pipe/dialect/imgproxy/{config,assembly,errors,option_grammar,response_meta,pipeline}.ex`, `lib/image_pipe/dialect/imgproxy.ex`, `lib/image_pipe/plug/debug_builder.ex`

- [ ] **Step 1: Inventory**

```bash
rg -n "ImagePipe\.(Request|Parser)" lib/
rg -n "ex_dna:disable" lib/
```

The first command is the exit gate, so its output must reach zero. Known hits at plan time (verify — the list may have grown):
`lib/image_pipe.ex` (fixed in Task 11), `decode/source_format.ex`, `representation.ex` (moduledoc), `transform/input_color_management.ex`, `transform/decode_planner.ex` (moduledoc: "The caller (Request.Processor) reads the header dims…"), `dialect/imgproxy/config.ex` (three), `dialect/imgproxy/assembly.ex`, `dialect/imgproxy/errors.ex` (two), `dialect/imgproxy/option_grammar.ex`, `dialect/imgproxy/response_meta.ex`, `dialect/imgproxy/pipeline.ex`, `dialect/imgproxy.ex` (three).

For each: retarget the comment at its surviving twin (`Transform.Executor`, `ImagePipe.Decode`, `Response.Conditional`, `ImagePipe.Plug.DialectRunner`) or delete it cleanly. No "formerly mirrored X" note in its place.

- [ ] **Step 2: Retire the duplication notes**

- `lib/image_pipe/decode.ex`: delete the file-header `# credo:disable-for-this-file ExDNA.Credo` block and its "deliberately mirrors ImagePipe.Request.Processor" paragraph; rewrite the moduledoc's `with_image/4` sentence and the `## The [:source, :fetch_decode] span` section so they describe the bracket on its own terms.
- `lib/image_pipe/response/conditional.ex`: delete the moduledoc comment block explaining the deliberate duplication, and the `not_modified?/2` `@doc`'s "Mirrors `ImagePipe.Request.HTTPCache.evaluate_conditional/3`" sentence.
- `lib/image_pipe/representation.ex`: delete the moduledoc sentence about the framework reproducing the byte-identity decision on its own path.
- `lib/image_pipe/dialect/imgproxy/option_grammar.ex`: its comment documents a deliberate local copy of `Parser.parse_boolean/1`. That function now lives on `ImagePipe.Dialect` (Task 5) — either call it and delete the copy, or retarget the comment at the new home and check whether the copy is now an ExDNA duplicate.

- [ ] **Step 3: Prune the ExDNA ignores**

`mix.exs`'s `@ex_dna_ignores` has **five** entries. Twins:

| entry | twin | fate |
| --- | --- | --- |
| `lib/image_pipe/decode.ex` | `Request.Processor` | remove |
| `lib/image_pipe/decode/source_format.ex` | `Request.SourceFormat` | remove |
| `lib/image_pipe/dialect/shared_config.ex` | `Request.Options` | remove |
| `lib/image_pipe/plug/debug_builder.ex` | `Request.DeliveryBuild` | remove |
| `lib/image_pipe/response/conditional.ex` | `Request.HTTPCache` | remove |

All five twins die in Task 11, so the list should end empty — verify each with `mise exec -- mix credo --strict` after removal. Credo failing on a removal means the duplication survives against some *other* twin: restore that one entry and retarget its comment at the real one.

`.credo.exs` has no `ignore:` list of its own — it splices `ImagePipe.MixProject.ex_dna_options()`. What it does have is the explanatory comment naming the framework twins; rewrite or delete it to match the pruned list.

- [ ] **Step 4: Audit the inline annotations**

For each `ex_dna:disable-for-next-line` hit, check whether the annotated definition still has a living twin. The framework deletion removed a large share. Delete the orphans, running `mise exec -- mix credo --strict` after each batch.

- [ ] **Step 5: Run**

Run: `mise exec -- mix credo --strict && mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`
and confirm `rg -n "ImagePipe\.(Request|Parser)\b" lib/ test/` returns nothing.
Expected: PASS, empty.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Retire the recorded duplications and the framework prose (Phase C task 13)"
```

---
### Task 14: Boundary pins

Tasks 2, 4, 5, 6, and 11 each updated the pins they broke. This task **adds** the pins the new architecture needs and closes the two gaps the current arch test has.

**Files:**
- Modify: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Add the missing boundary pins**

`@boundary_files` has no entry for `ImagePipe.Plug` or `ImagePipe.Dialect` — neither boundary is pinned at all today. Add:

- `ImagePipe.Plug => "lib/image_pipe/plug.ex"` with a deps pin matching Task 11 Step 1's list, and `refute_boundary_deps` for `ImagePipe.Request` and `ImagePipe.Parser` (now nonexistent — the refute is what keeps them from coming back).
- `ImagePipe.Dialect => "lib/image_pipe/dialect.ex"` with its deps (unchanged by this phase) and its exports (`DebugContext`, `Failure`, `Negotiation`, `RenderTerminal`, `Resolved`). Pinning the exports is what makes the U6 public surface reviewable.
- `ImagePipe.Dialect.Declarative` (added in Task 5) and `ImagePipe.Dialect.IIIF` (Task 6) if either task's pin is missing.

- [ ] **Step 2: Extend the U4 runner grep to the runner**

The "core must not name a dialect" source grep covers `lib/image_pipe/plug.ex` but **not** `lib/image_pipe/plug/**/*.ex` — so it does not cover `dialect_runner.ex`, the one file U4 is actually about. Extend the glob, and extend the dialect-name pattern with `IIIF` alongside `Imgproxy|TwicPics|Native`.

- [ ] **Step 3: Exempt the declarative tier from the no-`%Plan{}` rule**

The syntax-aware rule rejecting `%Plan{}` construction inside ordered dialects stays. Add `lib/image_pipe/dialect/iiif/**` and any declarative dialect to its exemption list — Plan production is the declarative contract, so the rule must be scoped to the ordered tier by construction, with a comment saying so.

- [ ] **Step 4: Drop the vacuous refutes**

`refute_boundary_deps` compares declared Boundary **names**. `ImagePipe.Transform.Lowering` and `ImagePipe.Transform.ResizePlanning` are not boundaries, so refuting them can never fire — a name-policing assertion with no teeth. Either drop them or enforce the rule through the existing source-grep mechanism, which can actually see a module reference.

- [ ] **Step 5: Run**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add test/image_pipe/architecture_boundary_test.exs
git commit -m "Pin the Phase C boundaries (task 14)"
```

---

### Task 15: Fiddle mount, IIIF validator, AGENTS.md

**Files:**
- Modify: `fiddle/lib/image_pipe_fiddle/application.ex`, `fiddle/lib/image_pipe_fiddle_web/iiif.ex`
- Modify: `validator/server.exs`
- Modify: `AGENTS.md`

- [ ] **Step 1: Fiddle**

In `fiddle/lib/image_pipe_fiddle/application.ex`, `build_iiif_opts/0`:

```elixir
  defp build_iiif_opts do
    static_root = Application.app_dir(:image_pipe_fiddle, "priv/static")

    [
      dialect: ImagePipe.Dialect.IIIF,
      resolver: {ImagePipe.Dialect.IIIF.Resolver.Static, map: iiif_source_map()},
      max_width: 4000,
      max_height: 4000,
      sources: [
        path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted}
      ],
      allow_debug_headers: true,
      allow_origin: "*"
    ]
    |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
    |> ImagePipe.Plug.init()
  end
```

Update `iiif_source_map/0`'s module reference and `ImagePipeFiddleWeb.IIIF`'s `@moduledoc` (it already forwards to `ImagePipe.Plug`, so `call/2` is unchanged). No `fiddle/assets` change: the IIIF provider's URL surface is unchanged.

- [ ] **Step 2: The IIIF Level-2 conformance validator**

`validator/server.exs` mounts `parser: ImagePipe.Parser.IIIF, iiif: [...]`. It is not under `elixirc_paths`, so nothing breaks at compile time — it breaks at runtime, silently, the next time anyone runs `mise run validator`, which `docs/iiif_3_support_matrix.md` names as the conformance gate. Swap it to the flat dialect mount and run it:

```bash
mise run validator
```

Expected: the same Level-2 conformance result as before. If the harness needs Docker and is unavailable, say so explicitly in the task report rather than marking it done.

- [ ] **Step 3: `AGENTS.md`**

Update the lines this phase invalidates:

- **Namespace boundary guidelines**: replace *"Keep parser behaviours and adapters under `ImagePipe.Parser.*`"* with the dialect equivalent (`ImagePipe.Dialect.*` — the behaviour, the shared values, `Declarative`, one module tree per dialect). Delete *"Keep request orchestration and runtime options under `ImagePipe.Request.*`"* and replace it with the runner's ownership (`ImagePipe.Plug` + `ImagePipe.Plug.DialectRunner`).
- **Boundary library guidelines**: rewrite the `deps:` direction list — `plug` → neutral core + `dialect`; `dialect` → the thin contract subset; `dialect.declarative` → its own tier list; a concrete dialect → `dialect` (+ `dialect.declarative` if declarative) + neutral core, never another dialect and never `ImagePipe.Plug`. Delete the `parser`/`request` rows.
- **Native API / Transform guidelines**: replace *"parsers … translate their syntax into `ImagePipe.Plan`"* phrasing with the two tiers, keeping the marker-accretion rule verbatim — it is unchanged and still load-bearing.
- Rename every `custom_parser_guide.md` reference to `custom_dialect_guide.md`.

Edit `AGENTS.md`, not `CLAUDE.md` (symlink).

- [ ] **Step 4: Gate**

Run: `mise run precommit:fiddle`
Expected: PASS (build the fiddle assets first if the Vite manifest is missing).

- [ ] **Step 5: Commit**

```bash
git add fiddle/ validator/ AGENTS.md
git commit -m "Mount IIIF as a dialect in the fiddle and the conformance validator (Phase C task 15)"
```

---

### Task 16: Docs rewrite

**Files:**
- Move: `docs/custom_parser_guide.md` → `docs/custom_dialect_guide.md` (rewritten)
- Modify: `docs/execution_flow.md`, `docs/cdn-http-cache.md`, `docs/debug_headers.md`, `docs/telemetry.md`, `docs/iiif_3_support_matrix.md`, `docs/imgproxy_support_matrix.md`, `README.md`, `mix.exs` (docs `extras:`)

- [ ] **Step 1: `custom_parser_guide.md` → `custom_dialect_guide.md`**

```bash
git mv docs/custom_parser_guide.md docs/custom_dialect_guide.md
```

Rewrite around the two tiers:

- **Declarative tier** — `use ImagePipe.Dialect.Declarative`, implement `parse_plan/2` + `render_error/3` + `validate_config!/1`, mount with `plug ImagePipe.Plug, dialect: …`. Show the config split (`SharedConfig.keys/0` → `Declarative.config_keys/0` → `ImagePipe.Config.keys/0` → your own) using `ImagePipe.Dialect.IIIF.Config` as the worked example. Document the `%Dialect.Failure{phase: :parse}` envelope `render_error/3` receives, and that `http_cache: [mode: :enabled]` is required for any generated `ETag`/`Cache-Control`.
- **Ordered tier** — implement the full six-callback behaviour when the product's semantics need ordered, positional runtime carry the neutral Plan cannot express. Reference `ImagePipe.Dialect.TwicPics`, and `execute/4` + `ImagePipe.Dialect.safe_transform/1` as the ordering boundary.
- **The contract surface** — the behaviour, `%Resolved{}`, `%Negotiation{}`, `%RenderTerminal{}`, `%Failure{}`, `SharedConfig`, `Declarative`. State that core internals behind the runner are private and unversioned.
- **Delete** the "no public SDK" section (T13 is reversed) and the Phase A/B transition sentences. Carry over still-accurate parser-authoring guidance (error rendering, option validation, safety expectations).

Update the filename in `mix.exs`'s docs `extras:` and every inbound link (`rg -n "custom_parser_guide" README.md docs mix.exs fiddle`).

- [ ] **Step 2: `docs/execution_flow.md` — one spine**

Rewrite as a single lifecycle: `init` → `dialect.validate_config!` → `call` → `[:request]` span → OPTIONS/405 → `[:parse]` span → `dialect.parse` → `dialect.prepare` → `Source.resolve` → deferred negotiation → `Representation.build` → cache-header policy (`:generated` only) → conditional gate (304 before any fetch/decode/encode/cache read) → cache dispatch → terminal (`:image` via `Delivery.stream` + `produce_stream`; `{:render, …}` via the complete-body or the offers-negotiated delivery) → `[:send]`. Delete every "two mount modes" / "framework path vs dialect path" passage.

- [ ] **Step 3: `docs/cdn-http-cache.md`**

Mount examples → `plug ImagePipe.Plug, dialect: …`. Document that generated CDN cache headers are a **declarative-tier** capability today: `http_cache: [mode: :enabled]` is a `Declarative.config_keys/0` option applied by `ImagePipe.Response.CachePolicy`; the ordered dialects are `http_cache: :dialect_owned` and their identity headers come straight from the representation. Note that opting an ordered dialect into generated headers is separate, compat-reviewed work. Keep the suppression-rule table, the per-source `:inherit` override, and the `[:http_cache, :*]` event list exactly as-is — the policy moved, its behavior did not. Add delta 9 (`storage_inputs` names enter `Vary`).

- [ ] **Step 4: `docs/debug_headers.md` and `docs/telemetry.md`**

- `debug_headers.md`: replace the framework `parser:` mount example with the IIIF dialect mount; the availability paragraph becomes one mount shape with per-dialect triggers (imgproxy signed `debug:1`, TwicPics `debug=1`, IIIF `?debug=1`, Native none yet — keep the follow-up issue number Phase B filed). Its "excluded from both the cache key and the ETag" passage still holds — verify against `Declarative.Identity` rather than assuming.
- `telemetry.md`: update the emitter attributions (`[:cache, :lookup]` → `Cache.lookup_entry/2`; `[:source, :fetch_decode]` → `Decode.with_image/4`; `[:render]` → `Renderer.run/3`; the three policy events → `Response.CachePolicy`, fired only under `http_cache: :generated`; `[:http_cache, :cache_hit, :headers]` unchanged in `Response.Sender`). Update the `[:request]`/`[:parse]` start-metadata documentation to the dialect shape, and record delta 4's `[:render]` position change. Replace the `ImagePipe.Parser.IIIF.InfoRenderer` `:renderer` example with the dialect module.

  **No event name is added or removed**, so the Logger's subscription lists and `Trace.Capture`'s `@span_stages`/`@oneshot_stages` need no edit — verify that by re-reading both against this doc's event list, and record the cross-check in the task report (AGENTS.md requires both surfaces to be kept in sync and cross-checked whenever events change).

- [ ] **Step 5: The two conformance docs**

`docs/iiif_3_support_matrix.md` — under AGENTS.md's conformance-sync rule this needs **surface**, **stage/order**, AND **behavioral** edits. Named passages, all of which go stale:

- the mount shape, the flat config keys, and `storage_inputs` replacing `key_headers`/`key_cookies` (surface);
- the architecture framing: IIIF is a declarative dialect on the shared runner, not a framework parser (stage/order);
- the status-mapping table row routing malformed grammar tokens through `handle_error/2`, and the rows describing transform errors going *directly* to `ErrorStatus` — both now route through `Dialect.IIIF.Errors`;
- **new** behavioral rows: `content-type: text/plain` on parse errors; 501 for an unsupported output format; the `{:session, _}` and delivery-time negotiation body changes (delta 6);
- the `info.json` section: the `render: {:custom, …}` mechanism becomes `%RenderTerminal{cache: :none, offers: …}`, and the "cache identity stays Accept-independent" claim needs restating — `info.json` has no internal cache identity at all;
- the debug-header gating passage (delta 12), including that IIIF cache entries now store a `Debug.Info`;
- the identity-value change (delta 1) as a behavioral note;
- the four test paths Task 7's `git mv` broke, and the validator path Task 15 touched.

`docs/imgproxy_support_matrix.md` — **no conformance axis changes for imgproxy** (surface, stage/order, and pixel behavior are all untouched: `:dialect_owned` skips the policy, `/info` does not use the `Renderer` facade, and the Executor gate split cannot reach a dialect that runs its own colour preamble). Two passages still go stale and must be fixed:

- the line contrasting the dialect with "no `ImagePipe.Request.*`" — strike it outright; do not replace it with a note (clean-removal rule);
- the intro and processing-pipeline preamble that frame imgproxy as a compatibility **parser** producing a `%Plan{}` whose order is fixed by the "parser/plan layer". After the execution-flow rewrite those contradict the rest of the docs. Re-word to the dialect framing: imgproxy runs its own ordered `Dialect.Imgproxy.Pipeline`.

State explicitly in the commit message that no imgproxy conformance claim changed, so the compatibility reviewer knows the edit is vocabulary-only.

- [ ] **Step 6: Sweep and Vale**

```bash
rg -n "ImagePipe\.(Parser|Request)|parser:|iiif: \[|key_headers|key_cookies|custom_parser_guide" README.md docs fiddle --glob '!docs/superpowers/**'
rg -n "self-contained Plug|owns its whole request chain|two mount modes|framework parser" README.md docs --glob '!docs/superpowers/**'
```

Both must come back empty of live mount-shape or architecture claims. Historical docs under `docs/superpowers/**` describe past states and stay as-is.

Run Vale over every changed current Markdown file (`git diff --name-only` filtered to `*.md`, inspected before invoking). No new errors; if the binary is unavailable, report that explicitly.

- [ ] **Step 7: Commit**

```bash
git add -A docs/ README.md mix.exs
git commit -m "Rewrite the docs for one spine and the two dialect tiers (Phase C task 16)"
```

---

### Task 17: Spec addendum and full gates

**Files:**
- Modify: `docs/superpowers/specs/2026-07-19-dialect-unification-design.md`

- [ ] **Step 1: Record Phase C in the per-phase addendum**

Append a `### Phase C (docs/superpowers/plans/2026-07-28-dialect-unification-phase-c.md)` subsection under the existing "Per-phase addenda" heading, covering:

- **All seventeen enumerated deltas**, each with its task number. Call out the ones with no counterpart in the spec's original list: delta 3 (error-metadata unwrap level), delta 4 (`[:render]` span position/duration/absence), delta 6 (dialect-owned IIIF error rendering, including the `{:session, _}` and negotiation-failure body changes), delta 7 (config-surface losses: the typo guard, `Parser.validate_options!/2`'s keyword-return guard, DI seams, top-level source timeouts), delta 8 (`key_headers`/`key_cookies` removed rather than renamed), deltas 9/10/11 (Vary, Accept-material narrowing, `{:decode, _}` wrapper), delta 13 (`http_cache: [mode: :enabled]` required for any declarative ETag), delta 14 (the automatic→explicit Vary collapse), delta 17 (`open_options/5` retired).
- **The contract widenings**: `Resolved.http_cache` (now **required**), `RenderTerminal.cache`/`offers`, `ImagePipe.Dialect.Declarative` as its **own top-level boundary** with `parse_plan/2`, `config_keys/0`, `validate_config!/1`, and its use of `%Dialect.Failure{phase: :parse}` for parse provenance, `ImagePipe.Dialect.parse_boolean/1`, `ImagePipe.Response.CachePolicy`, `DecodePlanner.request_from_chain/3`, `Plan.KeyData.quality_search_data/1`.
- **Core changes the spec did not anticipate**: the `Executor` gate split (`:seed_input_color_management` separated from `:seed_orientation`, defaulted to it), needed because the dialect path seeds orientation in `Decode` while the framework seeded it in `Executor`; and `Declarative.execute/4`'s `InputColorManagement.stamp_carry/1` call, without which the encoder silently takes its "no import ran" branch on an ICC-bearing source.
- **Deletion scope the spec's Deletions section did not name**: `Cache.Key`'s Plan machinery, `Cache.lookup/4`, the `key_headers`/`key_cookies` cache options, `DecodePlanner.open_options/5`, and the `Cache` boundary's `Plan` dep.
- Mark U7, U8, U8b, U10, and U11 **implemented**, and record that the `debug_info/1` hook stayed deleted — the declarative tier does not need it either, completing U13's contingency across every tier.

- [ ] **Step 2: Full gates**

Run: `mise run precommit && mise run precommit:fiddle`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, the full `mix test` (both differential lanes green, no fixture/verdict/tolerance changes), and the fiddle verify suite — all PASS.

If the imgproxy or TwicPics differential lane shows any diff, stop: Phase C must not touch their pixels. Diagnose it as a runner regression from Task 3 or 4.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "Record the Phase C contract widenings and deltas in the spec (task 17)"
```

---

## Phase C exit criteria

- `mise run precommit` and `mise run precommit:fiddle` green; `mise run validator` reports the same IIIF Level-2 conformance as before.
- **One request model.** `ImagePipe.Plug.init/1` requires `:dialect`; there is no `parser:` branch. `rg -n "ImagePipe\.(Request|Parser)\b" lib/ test/ fiddle/ validator/ docs/ README.md --glob '!docs/superpowers/**'` returns nothing.
- **One mount shape.** Every mount in `lib/`, `test/`, `fiddle/`, `validator/`, and `docs/` is `plug ImagePipe.Plug, dialect: …, <flat config>`.
- The imgproxy, TwicPics, and Native wire, telemetry, and differential suites pass **unchanged** — no fixture, verdict, or tolerance changes, no assertion edits.
- The IIIF suites pass on the dialect mount with assertion changes confined to the seventeen enumerated deltas.
- The declarative tier is proven public: `ImagePipe.Test.DeclarativeFixtureDialect` — a three-function host module with no core changes — mounts and serves, and its suite pins the image terminal, the host's own error rendering through the parse-`Failure` envelope, the generated CDN headers, and the no-ETag-without-`http_cache` asymmetry.
- `Declarative.Identity` has its own invariant coverage (cachebuster and storage-inputs move the key but not the ETag; detector identity moves both; `plan.response` moves neither; any byte-affecting difference separates the key), replacing what `cache/key_test.exs` pinned.
- An ICC-bearing source served through the declarative tier is pixel-identical to the same source through an ordered dialect (`color_carry_parity_test.exs`), proving `stamp_carry/1` is wired.
- `DecodePlanner` has one entry point; the IIIF shrink-on-load suites pass unchanged, proving the defunctionalization moved no load option.
- `cdn_http_cache_wire_test.exs` passes with only delta-1 round-trip and delta-9 `Vary` rewrites, proving the U8b policy is behavior-identical; delta 14 is either pinned or shown unreachable.
- The runner still names no dialect, and the U4 grep now actually covers `lib/image_pipe/plug/**`. Every new branch dispatches on a `%Resolved{}` field (`http_cache`, `terminal`) or a neutral struct (`%RenderTerminal{cache: …}`).
- No telemetry event name was added or removed; the Logger's and `Trace.Capture`'s lists are unchanged and cross-checked against `docs/telemetry.md`.
- `mix.exs`'s `@ex_dna_ignores` contains no entry whose twin is gone, and no file carries a note about a duplication that no longer exists.
- Both conformance docs are current: `iiif_3_support_matrix.md` on all three axes, `imgproxy_support_matrix.md` on vocabulary only (no conformance claim changed).
- The spec's per-phase addendum records every Phase C delta, contract widening, and unanticipated core change.
