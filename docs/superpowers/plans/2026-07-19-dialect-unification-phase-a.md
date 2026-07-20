# Dialect Unification Phase A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the `ImagePipe.Dialect` contract and the `ImagePipe.Plug` lifecycle runner, and port `ImagePipe.Dialect.Native` onto them — Phase A of `docs/superpowers/specs/2026-07-19-dialect-unification-design.md`.

**Architecture:** A new `ImagePipe.Dialect` boundary defines the coarse request-lifecycle behaviour (`validate_config!`/`parse`/`prepare`/`decode_request`/`execute`/`render_error` + optional `classify_error`/`debug_info`) and its value structs (`Resolved`, `Negotiation`, `RenderTerminal`, `DebugContext`). `ImagePipe.Plug` gains a dialect mode (`plug ImagePipe.Plug, dialect: Module, <flat config>`) whose runner owns the neutral spine — spans, source resolve, deferred-negotiation unwrap, `Representation` identity, pre-fetch conditional 304, cache serve, `produce_stream`, render terminals, unconditional debug build. The framework `parser:` mode is untouched in Phase A; imgproxy, TwicPics, and IIIF are untouched.

**Tech Stack:** Elixir, Plug, Boundary, Vix/libvips, ExUnit. All commands via `mise exec -- …`.

## Global Constraints

- Run every mix command through `mise exec -- …` (fresh worktree: `mise trust` + `mise run setup` first).
- Per-dialect observables are gated: the Native wire/contract/telemetry suites must pass unchanged except the deltas this plan enumerates: (a) the U9 disabled-cache fix; (b) cache entries now store a `Debug.Info` — mandated by U13's unconditional build-and-store, internal, never rendered since Native has no debug trigger; (c) `[:debug, :collect, :error]` (failure-only) and the per-request fact collection become reachable on the imgproxy/TwicPics decode paths through shared `Decode` — the Logger/Capture already subscribe to the event name and no suite gates it.
- U4 anti-leak rule: the runner branches only on `%Resolved{}` fields and neutral core structs — never on dialect identity, never via dialect-specific flags. Every new runner branch must cite the `Resolved` field it dispatches on.
- No changes under `lib/image_pipe/dialect/imgproxy/**`, `lib/image_pipe/dialect/twic_pics/**`, `lib/image_pipe/parser/**`, `lib/image_pipe/request/**` in Phase A (except none — the framework path coexists untouched).
- No differential fixture, verdict, or tolerance changes.
- Subagents must not run state-mutating git commands (`stash`, `reset`, `checkout --`, `clean`) — worktrees share one stash stack.
- Commit after every task; end commit messages with the repo's Claude trailer.

## File Structure (Phase A end state)

```
lib/image_pipe/dialect.ex                      NEW  behaviour + U4 moduledoc (contract boundary root)
lib/image_pipe/dialect/negotiation.ex          NEW  outcome struct + negotiate/3 + terminal/1
lib/image_pipe/dialect/resolved.ex             NEW  the prepare product (values, not callbacks)
lib/image_pipe/dialect/render_terminal.ex      NEW  non-image terminal value
lib/image_pipe/dialect/debug_context.ex        NEW  debug-builder input value
lib/image_pipe/plug.ex                         MOD  init/call dispatch on :dialect
lib/image_pipe/plug/dialect_runner.ex          NEW  the lifecycle runner
lib/image_pipe/plug/debug_builder.ex           NEW  default neutral Debug.Info builder (U13)
lib/image_pipe/transform/source_geometry.ex    MOD  + debug_facts field
lib/image_pipe/decode.ex                       MOD  collect debug facts (+ [:debug, :collect, :error])
lib/image_pipe/dialect/native.ex               MOD  chain deleted; behaviour implemented
lib/image_pipe/dialect/native/negotiation.ex   DEL  replaced by ImagePipe.Dialect.Negotiation
lib/image_pipe/dialect/native/identity.ex      MOD  alias swap to the promoted struct
test/support/image_pipe/test/runner_fixture_dialect.ex  NEW  minimal contract dialect
test/image_pipe/plug_dialect_runner_test.exs   NEW  runner wire tests (the contract smoke test)
test/image_pipe/decode_facts_test.exs          NEW
test/image_pipe/dialect/negotiation_test.exs   NEW
test/image_pipe/dialect/native_wire_test.exs   MOD  mount helpers → ImagePipe.Plug + U9 test
```

---

### Task 1: `ImagePipe.Dialect` contract boundary

**Files:**
- Create: `lib/image_pipe/dialect.ex`
- Create: `lib/image_pipe/dialect/negotiation.ex`
- Create: `lib/image_pipe/dialect/resolved.ex`
- Create: `lib/image_pipe/dialect/render_terminal.ex`
- Create: `lib/image_pipe/dialect/debug_context.ex`
- Test: `test/image_pipe/dialect/negotiation_test.exs`

**Interfaces:**
- Produces (later tasks consume exactly these):
  - `ImagePipe.Dialect` behaviour: `validate_config!(keyword) :: keyword`; `parse(Plug.Conn.t(), keyword) :: {parse_result, map}` with `parse_result :: {:ok, term} | {:redirect, pos_integer, String.t} | {:error, term}`; `prepare(Plug.Conn.t(), term, keyword) :: {:ok, Resolved.t()} | {:error, term}`; `decode_request(term, SourceGeometry.t()) :: DecodePlanner.Request.t()`; `execute(State.t(), SourceGeometry.t(), term, keyword) :: {:ok, State.t()} | {:error, term}`; `render_error(Plug.Conn.t(), term, keyword) :: Plug.Conn.t()`; optional `classify_error(term) :: atom`; optional `debug_info(DebugContext.t()) :: Info.t() | nil`.
  - `ImagePipe.Dialect.Negotiation.negotiate/3`, `terminal/1`, struct fields `selected/vary?/policy_material/policy/plan_output`.
  - `ImagePipe.Dialect.Resolved` struct as coded below (coupled `negotiation` result).
  - `ImagePipe.Dialect.RenderTerminal` struct (`fun` only in Phase A; Phase C widens with `cache`/`offers` per spec U11).
  - `ImagePipe.Dialect.DebugContext` struct as coded below.

- [ ] **Step 1: Write the failing negotiation test**

`test/image_pipe/dialect/negotiation_test.exs`:

```elixir
defmodule ImagePipe.Dialect.NegotiationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Plan.Output

  @config [
    auto_avif: true,
    auto_webp: true,
    auto_jpeg_xl: true,
    output_capabilities: %{avif: true, webp: true, jpeg_xl: true}
  ]

  test "explicit format selects without Vary and carries the plan output" do
    conn = Plug.Test.conn(:get, "/")
    plan_output = %Output{mode: {:explicit, :webp}, quality: :default}

    assert {:ok, %Negotiation{} = negotiation} =
             Negotiation.negotiate(conn, plan_output, @config)

    assert negotiation.selected == {:image, :webp}
    refute negotiation.vary?
    assert negotiation.plan_output == plan_output
    assert is_list(negotiation.policy_material)
    assert negotiation.policy != nil
  end

  test "terminal/1 carries no policy, no vary, empty material" do
    negotiation = Negotiation.terminal(:blurhash)

    assert negotiation.selected == {:terminal, :blurhash}
    refute negotiation.vary?
    assert negotiation.policy_material == []
    assert negotiation.policy == nil
    assert negotiation.plan_output == nil
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/dialect/negotiation_test.exs`
Expected: FAIL — `ImagePipe.Dialect.Negotiation` is undefined.

- [ ] **Step 3: Create the contract modules**

`lib/image_pipe/dialect.ex`:

```elixir
defmodule ImagePipe.Dialect do
  @moduledoc """
  The coarse request-lifecycle contract a dialect implements to mount through
  `ImagePipe.Plug` (`plug ImagePipe.Plug, dialect: __MODULE__, <flat config>`).

  Six required callbacks — one per lifecycle phase, never a mid-execution
  hook. Everything else a dialect decides rides `ImagePipe.Dialect.Resolved`
  as values.

  ## The anti-leak rule (design decision U4)

  The runner in `ImagePipe.Plug` branches only on `Resolved` fields and
  neutral core structs. It never names a dialect and never accepts a
  dialect-specific option. A future need that cannot be expressed as a new
  `Resolved` value with a sensible default belongs in the dialect, not the
  runner.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Debug,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Source,
      ImagePipe.Transform
    ],
    exports: [DebugContext, Negotiation, RenderTerminal, Resolved]

  alias ImagePipe.Dialect.DebugContext
  alias ImagePipe.Dialect.Resolved
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State

  @type config :: keyword()
  @type request :: term()
  @type parse_result ::
          {:ok, request()}
          | {:redirect, pos_integer(), String.t()}
          | {:error, term()}

  @doc "Init-time config validation; raises on invalid input."
  @callback validate_config!(config()) :: config()

  @doc """
  The `[:parse]` phase. Returns the parse result together with the span's
  stop metadata — metadata shape is dialect-owned for both outcomes.
  """
  @callback parse(Plug.Conn.t(), config()) ::
              {parse_result(), span_stop_metadata :: map()}

  @doc """
  Everything else decidable before any side effect: gates, source
  translation, negotiation (computed, carried as a deferred result), identity
  material, terminal selection.
  """
  @callback prepare(Plug.Conn.t(), request(), config()) ::
              {:ok, Resolved.t()} | {:error, term()}

  @doc "Shrink-on-load preflight for the sequential decode re-open."
  @callback decode_request(request(), SourceGeometry.t()) ::
              DecodePlanner.Request.t()

  @doc "The transform stage only; runs inside the runner's decode bracket."
  @callback execute(State.t(), SourceGeometry.t(), request(), keyword()) ::
              {:ok, State.t()} | {:error, term()}

  @doc "Renders any lifecycle error to the client; status vocabulary is dialect-owned."
  @callback render_error(Plug.Conn.t(), reason :: term(), config()) :: Plug.Conn.t()

  @doc """
  Optional: maps an error reason to the `[:request]` span's `:result` atom.
  Default: `ImagePipe.Telemetry.request_result/1`.
  """
  @callback classify_error(reason :: term()) :: atom()

  @doc """
  Optional enrichment override for the runner's default neutral debug
  builder. Expected to have no implementors (design decision U13).
  """
  @callback debug_info(DebugContext.t()) :: ImagePipe.Debug.Info.t() | nil

  @optional_callbacks classify_error: 1, debug_info: 1
end
```

`lib/image_pipe/dialect/negotiation.ex`:

```elixir
defmodule ImagePipe.Dialect.Negotiation do
  @moduledoc """
  The negotiation outcome carried on `ImagePipe.Dialect.Resolved` — one
  struct replacing the per-dialect copies. `plan_output` is the neutral
  output plan the negotiation was built from, carried so the runner can
  compute `Policy.supports_hdr?/3` without reaching into the opaque request.

  Distinct from `ImagePipe.Output.Negotiation` (an Accept-parsing helper
  module with no struct), which is unchanged.
  """

  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Output

  @enforce_keys [:selected, :vary?, :policy_material, :policy, :plan_output]
  defstruct @enforce_keys

  @type selected ::
          {:image, Output.format() | :source_negotiated} | {:terminal, atom()}

  @type t :: %__MODULE__{
          selected: selected(),
          vary?: boolean(),
          policy_material: keyword(),
          policy: Policy.t() | nil,
          plan_output: Output.t() | nil
        }

  @doc """
  Negotiates the image terminal from a neutral output plan — the
  `Policy.from_output_plan → ensure_capable → identity_selection` sequence
  every dialect ran privately.
  """
  @spec negotiate(Plug.Conn.t(), Output.t(), keyword()) ::
          {:ok, t()} | {:error, {:unsupported_output_format, Policy.format()}}
  def negotiate(%Plug.Conn{} = conn, %Output{} = plan_output, config)
      when is_list(config) do
    policy = Policy.from_output_plan(conn, plan_output, config)

    with :ok <- Policy.ensure_capable(policy, config) do
      {selected_format, vary?} = normalize_selection(Policy.identity_selection(policy))

      {:ok,
       %__MODULE__{
         selected: {:image, selected_format},
         vary?: vary?,
         policy_material: Policy.identity_material(policy),
         policy: policy,
         plan_output: plan_output
       }}
    end
  end

  @doc "A fixed non-image terminal: nothing to select, vary by, or carry as policy."
  @spec terminal(atom()) :: t()
  def terminal(name) when is_atom(name) do
    %__MODULE__{
      selected: {:terminal, name},
      vary?: false,
      policy_material: [],
      policy: nil,
      plan_output: nil
    }
  end

  defp normalize_selection({:explicit, format}), do: {format, false}
  defp normalize_selection({:auto_head, format}), do: {format, true}
  defp normalize_selection(:source_negotiated), do: {:source_negotiated, true}
end
```

`lib/image_pipe/dialect/resolved.ex`:

```elixir
defmodule ImagePipe.Dialect.Resolved do
  @moduledoc """
  The product of `c:ImagePipe.Dialect.prepare/3` — values, not callbacks.

  `negotiation` is a deferred, coupled result: identity material cannot
  exist without a successful negotiation (every identity builder consumes
  the struct), so the pair succeeds or fails together. The runner unwraps
  it AFTER `ImagePipe.Source.resolve/3`, preserving the dialects'
  source-before-negotiation error precedence.

  The spec's `http_cache: :generated | :dialect_owned` field is deliberately
  ABSENT in Phase A: the promoted header-policy module it dispatches to is
  Phase C work, and a representable-but-inert value would advertise
  unsupported semantics. Phase C adds the field together with the policy
  module; until then every dialect gets today's dialect-owned behavior.
  """

  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Dialect.RenderTerminal
  alias ImagePipe.Plan.Response
  alias ImagePipe.Representation.IdentityMaterial

  @enforce_keys [
    :request,
    :source,
    :negotiation,
    :response_meta,
    :operations,
    :auto_rotate?,
    :debug?,
    :terminal
  ]
  defstruct @enforce_keys

  @type negotiation_result ::
          {:ok, Negotiation.t(), IdentityMaterial.t()} | {:error, term()}

  @type t :: %__MODULE__{
          request: term(),
          source: struct(),
          negotiation: negotiation_result(),
          response_meta: Response.t(),
          operations: [atom()],
          auto_rotate?: boolean(),
          debug?: boolean(),
          terminal: :image | {:render, RenderTerminal.t()}
        }
end
```

`lib/image_pipe/dialect/render_terminal.ex`:

```elixir
defmodule ImagePipe.Dialect.RenderTerminal do
  @moduledoc """
  A non-image terminal, values only. Phase A supports exactly one delivery:
  the shared complete-body lifecycle (cache-tagged entries, wildcard-INM on
  hit, fail-open write). The spec's `cache: :none` + `offers` variant
  (`Sender`'s `{:rendered, …}` delivery, for the declarative path) is a
  Phase C WIDENING of this struct — deliberately not represented here so the
  Phase A type cannot advertise semantics the runner does not implement.
  """

  alias ImagePipe.Source

  @enforce_keys [:fun]
  defstruct [:fun]

  @type render_fun ::
          (Source.Resolved.t(), keyword() ->
             {:ok, content_type :: String.t(), iodata()} | {:error, term()})

  @type t :: %__MODULE__{fun: render_fun()}
end
```

`lib/image_pipe/dialect/debug_context.ex`:

```elixir
defmodule ImagePipe.Dialect.DebugContext do
  @moduledoc """
  Everything the runner's default neutral debug builder (and the optional
  `c:ImagePipe.Dialect.debug_info/1` override) may draw on. Source facts
  ride `geometry.debug_facts` (collected by `ImagePipe.Decode`). Cache
  hit/miss debug (spec U13's "cache hit/miss" input) is NOT carried here:
  it rides the delivery-time `hit_debug` map exactly as today, because it
  is only known at serve time, after generation built this context.
  """

  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Output.Resolved, as: ResolvedOutput
  alias ImagePipe.Transform.SourceGeometry

  @enforce_keys [
    :geometry,
    :shrink,
    :negotiation,
    :resolved_output,
    :image,
    :search_meta,
    :operations,
    :timings
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          geometry: SourceGeometry.t(),
          shrink: %{w: float(), h: float()} | nil,
          negotiation: Negotiation.t(),
          resolved_output: ResolvedOutput.t(),
          image: Vix.Vips.Image.t(),
          search_meta: map() | nil,
          operations: [atom()],
          timings: %{decode: non_neg_integer(), transform: non_neg_integer(), encode: non_neg_integer()}
        }
end
```

- [ ] **Step 4: Run the test and compile**

Run: `mise exec -- mix test test/image_pipe/dialect/negotiation_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS, clean compile (Boundary accepts the new top-level boundary; the existing `ImagePipe.Dialect.*` dialect boundaries already declare `top_level?: true` so they are not nested under it).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/dialect.ex lib/image_pipe/dialect/{negotiation,resolved,render_terminal,debug_context}.ex test/image_pipe/dialect/negotiation_test.exs
git commit -m "Add the ImagePipe.Dialect contract boundary (Phase A task 1)"
```

---

### Task 2: Decode collects debug source facts

**Files:**
- Modify: `lib/image_pipe/transform/source_geometry.ex` (struct + typedoc)
- Modify: `lib/image_pipe/decode.ex` (fact collection)
- Test: `test/image_pipe/decode_facts_test.exs`

**Interfaces:**
- Produces: `SourceGeometry.debug_facts :: %{optional(:source_bytes) => non_neg_integer() | nil, optional(:source_color_space) => atom() | nil, optional(:source_icc?) => boolean() | nil, optional(:source_bit_depth) => pos_integer() | nil, optional(:source_alpha?) => boolean() | nil, optional(:source_orientation) => 1..8 | nil}` — default `%{}` (collection failure degrades to empty, emitting `[:debug, :collect, :error]`). Task 6's debug builder consumes it.
- Existing `Decode.with_image/4` callers (imgproxy, TwicPics) are unaffected: the field is additive and they never read it.

- [ ] **Step 1: Write the failing test**

`test/image_pipe/decode_facts_test.exs` (source plumbing copied from `test/image_pipe/dialect/native_wire_test.exs:20-27` — same `RootHTTPAdapter`/`OriginImage` test-support pair):

```elixir
defmodule ImagePipe.DecodeFactsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Decode
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.OriginImage
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.SourceGeometry

  @sources [
    path:
      {RootHTTPAdapter,
       root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
  ]

  test "with_image geometry carries the six source debug facts" do
    # validate_runtime! converts :sources into the map Source.resolve expects
    # and supplies the max_body_bytes/max_input_pixels defaults decode reads.
    config = ImagePipe.Dialect.SharedConfig.validate_runtime!(sources: @sources)
    source = %Path{segments: ["images", "beach.jpg"]}
    {:ok, resolved} = Source.resolve(source, config, config)

    result =
      Decode.with_image(
        resolved,
        Keyword.put(config, :auto_rotate?, true),
        fn _geometry -> %DecodePlanner.Request{} end,
        fn _state, %SourceGeometry{debug_facts: facts} -> {:ok, facts} end
      )

    assert {:ok, facts} = result
    assert is_integer(facts.source_bytes) and facts.source_bytes > 0
    assert is_atom(facts.source_color_space)
    assert is_boolean(facts.source_icc?)
    assert facts.source_bit_depth in [8, 16]
    assert is_boolean(facts.source_alpha?)
    assert facts.source_orientation in [nil, 1, 2, 3, 4, 5, 6, 7, 8]
  end
end
```

(Module names verified against `native_wire_test.exs:14-18`: `RootHTTPAdapter` is `ImagePipe.SourceTest.RootHTTPAdapter`; `OriginImage`, `CountingOriginImage`, `OriginShouldNotFetch`, and `CacheProbe` live under `ImgproxyWireConformanceTest`.)

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/decode_facts_test.exs`
Expected: FAIL — `SourceGeometry` has no `debug_facts` key.

- [ ] **Step 3: Implement**

In `lib/image_pipe/transform/source_geometry.ex` change the struct definition (keep `@enforce_keys` as-is; the new field is optional):

```elixir
  @enforce_keys [:storage_dimensions, :display_dimensions, :pending_orientation, :source_format]
  defstruct [
    :storage_dimensions,
    :display_dimensions,
    :pending_orientation,
    :source_format,
    debug_facts: %{}
  ]
```

Add `debug_facts: map()` to the `@type t` map and one moduledoc sentence: best-effort, non-sensitive source facts collected by `ImagePipe.Decode` for the debug headers; `%{}` when collection failed or the geometry was built elsewhere.

In `lib/image_pipe/decode.ex`, inside `decode/4`'s `with` (the `geometry = %SourceGeometry{…}` binding around `decode.ex:153`), add the field:

```elixir
         geometry = %SourceGeometry{
           storage_dimensions: storage_dimensions,
           display_dimensions: display_dimensions,
           pending_orientation: pending_orientation,
           source_format: source_format,
           debug_facts: debug_facts(input, header_image, opts)
         },
```

Then add, at the bottom of the module, a verbatim copy of `ImagePipe.Request.Processor.source_debug_facts/3` and its six private helpers (`processor.ex:362-423`: `source_byte_size/1`, `source_interpretation/1`, `source_has_icc?/1`, `source_bit_depth/1`, `source_orientation/1`, `source_alpha?/1`), renamed `debug_facts/3`, including the `rescue` that emits `[:debug, :collect, :error]` and degrades to `%{}`. `Decode` already aliases `Telemetry`, `Error`, and `VipsImage`; the helpers compile unchanged. (This module's file-level `credo:disable-for-this-file ExDNA.Credo` header already covers the deliberate Processor mirror; Phase C deletes Processor and the annotation.)

- [ ] **Step 4: Run the test and the decode/dialect suites**

Run: `mise exec -- mix test test/image_pipe/decode_facts_test.exs test/image_pipe/dialect/ && mise exec -- mix compile --warnings-as-errors`
Expected: all PASS (existing dialects ignore the new field).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/source_geometry.ex lib/image_pipe/decode.ex test/image_pipe/decode_facts_test.exs
git commit -m "Collect debug source facts in Decode.with_image (Phase A task 2)"
```

---

### Task 3: Runner core — dialect mode in `ImagePipe.Plug`, happy path + error fan-out

**Files:**
- Create: `lib/image_pipe/plug/dialect_runner.ex`
- Modify: `lib/image_pipe/plug.ex` (init/call dispatch + Boundary deps)
- Create: `test/support/image_pipe/test/runner_fixture_dialect.ex`
- Test: `test/image_pipe/plug_dialect_runner_test.exs`

**Interfaces:**
- Consumes: Task 1's behaviour and structs; `Decode.with_image/4`; `Output.Negotiate.negotiate_output/4`; `Output.Clamp.clamp_with_telemetry/4`; `Transform.Materializer.materialize/2`; `Output.Encoder.stream_output/3` + `encoder_limit/1`; `Delivery.stream/5`; `Delivery.StreamPull`; `Representation.build/3`; `Response.{Conditional, CacheHeaders, Sender, CORS}`; `Cache.lookup_entry/2`.
- Produces: `ImagePipe.Plug.DialectRunner.run(conn, dialect :: module(), config :: keyword()) :: Plug.Conn.t()`; `ImagePipe.Plug.init(dialect: Module, …)` returning a keyword whose `:dialect` key `call/2` dispatches on (test seams like appending `output_capabilities:` after `init` keep working). Tasks 4–7 extend this module; Task 8 mounts Native through it.

- [ ] **Step 1: Write the fixture dialect**

`test/support/image_pipe/test/runner_fixture_dialect.ex` — the minimal contract implementor (also the spec's public-contract smoke test). Requests look like `/fix/images/beach.jpg?format=webp`; `?boom=parse` forces a parse error; `?debug=1` sets `debug?` (Task 6 uses it).

```elixir
defmodule ImagePipe.Test.RunnerFixtureDialect do
  @moduledoc false

  # The :boundary compiler runs in all envs; without a declaration this
  # module would fall into the ImagePipe root boundary and violate its deps.
  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Dialect,
      ImagePipe.Dialect.SharedConfig,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Transform
    ]

  @behaviour ImagePipe.Dialect

  import Plug.Conn, only: [send_resp: 3, fetch_query_params: 1]

  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Dialect.Resolved
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Representation
  alias ImagePipe.Representation.IdentityMaterial
  alias ImagePipe.Transform.DecodePlanner

  @impl ImagePipe.Dialect
  # SharedConfig converts :sources/:cache into the shapes Source.resolve and
  # Cache expect (a raw keyword `sources:` fails with {:source,
  # :missing_adapter} — Source.fetch_adapter_config pattern-matches a map)
  # and supplies the max_result_*/max_body_bytes/max_input_pixels defaults
  # the runner fetches with Keyword.fetch!. Unknown keys such as the
  # fixture-only :allow_debug_headers pass through untouched
  # (validate_known_opts! merges the validated subset back).
  def validate_config!(opts), do: ImagePipe.Dialect.SharedConfig.validate_runtime!(opts)

  @impl ImagePipe.Dialect
  def parse(%Plug.Conn{path_info: ["fix" | segments]} = conn, _config) do
    conn = fetch_query_params(conn)

    case conn.query_params do
      %{"boom" => "parse"} ->
        {{:error, :fixture_parse_reject}, %{result: :error, error: :fixture_parse_reject}}

      params ->
        request = %{
          segments: segments,
          format: parse_format(params["format"]),
          debug?: params["debug"] == "1"
        }

        {{:ok, request}, %{result: :ok}}
    end
  end

  def parse(%Plug.Conn{}, _config),
    do: {{:error, :not_found}, %{result: :error, error: :not_found}}

  defp parse_format("webp"), do: :webp
  defp parse_format("jpeg"), do: :jpeg
  defp parse_format(_), do: :jpeg

  @impl ImagePipe.Dialect
  def prepare(%Plug.Conn{} = conn, request, config) do
    plan_output = %Output{mode: {:explicit, request.format}, quality: :default}

    negotiation =
      case Negotiation.negotiate(conn, plan_output, config) do
        {:ok, negotiation} -> {:ok, negotiation, material(request, negotiation, conn, config)}
        {:error, _reason} = error -> error
      end

    {:ok,
     %Resolved{
       request: request,
       source: %Path{segments: request.segments},
       negotiation: negotiation,
       response_meta: %PlanResponse{},
       operations: [],
       auto_rotate?: true,
       debug?: request.debug?,
       terminal: :image
     }}
  end

  defp material(request, negotiation, conn, _config) do
    {storage_only, storage_vary} = Representation.storage_inputs(conn, [])

    %IdentityMaterial{
      dialect_behavior: {__MODULE__, 1},
      representation: [
        segments: request.segments,
        selection: negotiation.selected,
        output_policy: negotiation.policy_material
      ],
      storage_only: storage_only,
      vary_header_names: if(negotiation.vary?, do: storage_vary ++ ["Accept"], else: storage_vary)
    }
  end

  @impl ImagePipe.Dialect
  def decode_request(_request, _geometry), do: %DecodePlanner.Request{}

  @impl ImagePipe.Dialect
  def execute(state, _geometry, _request, _opts), do: {:ok, state}

  @impl ImagePipe.Dialect
  def render_error(conn, :fixture_parse_reject, _config), do: send_resp(conn, 422, "fixture parse reject")
  def render_error(conn, :not_found, _config), do: send_resp(conn, 404, "not found")
  def render_error(conn, {:source, _}, _config), do: send_resp(conn, 404, "source error")
  def render_error(conn, _reason, _config), do: send_resp(conn, 500, "error")
end
```

- [ ] **Step 2: Write the failing runner tests (happy path + error fan-out + method guards)**

`test/image_pipe/plug_dialect_runner_test.exs` (source/config plumbing copied from `native_wire_test.exs`):

```elixir
defmodule ImagePipe.PlugDialectRunnerTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.OriginImage
  alias ImagePipe.Test.RunnerFixtureDialect

  @sources [
    path:
      {RootHTTPAdapter,
       root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
  ]

  defp opts(extra \\ []) do
    base =
      ImagePipe.Plug.init(
        Keyword.merge([dialect: RunnerFixtureDialect, sources: @sources], extra)
      )

    Keyword.merge(base, output_capabilities: %{avif: true, webp: true, jpeg_xl: true})
  end

  defp get(path, config, headers \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    ImagePipe.Plug.call(conn, config)
  end

  test "serves an image with an ETag through the dialect mode" do
    conn = get("/fix/images/beach.jpg?format=webp", opts())

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/webp"
    assert [etag] = get_resp_header(conn, "etag")
    assert is_binary(etag)
  end

  test "parse errors render through the dialect's render_error" do
    conn = get("/fix/images/beach.jpg?boom=parse", opts())
    assert conn.status == 422
    assert conn.resp_body == "fixture parse reject"
  end

  test "OPTIONS answers 204 and non-GET/HEAD answers 405" do
    assert ImagePipe.Plug.call(conn(:options, "/fix/x.jpg"), opts()).status == 204
    assert ImagePipe.Plug.call(conn(:post, "/fix/x.jpg"), opts()).status == 405
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/plug_dialect_runner_test.exs`
Expected: FAIL — `init` rejects `:dialect` as an unknown option (framework `Options.validate!`).

- [ ] **Step 4: Implement the dispatch in `ImagePipe.Plug` and the runner**

In `lib/image_pipe/plug.ex`:

1. Add to the Boundary `deps:` list: `ImagePipe.Cache`, `ImagePipe.Decode`, `ImagePipe.Delivery`, `ImagePipe.Dialect`, `ImagePipe.Output`, `ImagePipe.Representation` (keep the existing entries).
2. Replace `init/1` and add a `call/2` head:

```elixir
  @impl Plug
  def init(opts) do
    case Keyword.fetch(opts, :dialect) do
      {:ok, dialect} when is_atom(dialect) ->
        [dialect: dialect] ++ dialect.validate_config!(Keyword.delete(opts, :dialect))

      :error ->
        opts
        |> Options.validate!()
        |> validate_parser_options()
    end
  end

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    case Keyword.fetch(opts, :dialect) do
      {:ok, dialect} -> ImagePipe.Plug.DialectRunner.run(conn, dialect, opts)
      :error -> legacy_call(conn, opts)
    end
  end
```

Rename the existing `call/2` body to `defp legacy_call(conn, opts)` (body unchanged from `plug.ex:42-51`).

(Known failure-mode change, init-time only: a host typo passing `:dialect`
with a non-dialect module now fails with an `UndefinedFunctionError` from
`validate_config!/1` instead of `Options.validate!`'s `ArgumentError`. No
gated suite observes init errors; acceptable.)

3. Create `lib/image_pipe/plug/dialect_runner.ex`. The chain is `dialect/native.ex`'s, generalized through the contract — copy the referenced native functions and apply exactly the listed changes:

```elixir
defmodule ImagePipe.Plug.DialectRunner do
  @moduledoc false
  # The unified dialect lifecycle (design 2026-07-19, decisions U1–U5).
  # This module branches ONLY on %Resolved{} fields and neutral core structs
  # (U4) — it must never name a dialect or accept a dialect-specific option.

  alias ImagePipe.Cache
  alias ImagePipe.Decode
  alias ImagePipe.Delivery
  alias ImagePipe.Delivery.StreamPull
  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Dialect.Resolved
  alias ImagePipe.Error
  alias ImagePipe.Output.Clamp
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Negotiate
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved, as: ResolvedOutput
  alias ImagePipe.Representation
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.Conditional
  alias ImagePipe.Response.CORS
  alias ImagePipe.Response.Sender
  alias ImagePipe.Source, as: ImageSource
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State

  @spec run(Plug.Conn.t(), module(), keyword()) :: Plug.Conn.t()
  def run(%Plug.Conn{} = conn, dialect, config) do
    Telemetry.Trace.maybe_extract_inbound(conn)
    conn = CORS.maybe_register(conn, config)

    Telemetry.span(Telemetry.telemetry_opts(config), [:request], %{}, fn ->
      {conn, metadata} = route(conn, dialect, config)
      {conn, Map.put(metadata, :status, conn.status)}
    end)
  end

  # -- route: OPTIONS/405 guards, then parse → prepare → resolve → serve ------

  defp route(%Plug.Conn{method: "OPTIONS"} = conn, _dialect, config) do
    conn = send_with_span(conn, config, :options, fn -> CORS.send_options(conn, config) end)
    {conn, %{result: :options}}
  end

  defp route(%Plug.Conn{method: method} = conn, _dialect, config)
       when method not in ["GET", "HEAD"] do
    conn =
      send_with_span(conn, config, :method_not_allowed, fn ->
        Sender.send_method_not_allowed(conn)
      end)

    {conn, %{result: :method_not_allowed}}
  end

  defp route(%Plug.Conn{} = conn, dialect, config) do
    case parse(conn, dialect, config) do
      {:ok, request} ->
        handle_request(conn, dialect, request, config)

      {:redirect, status, location} ->
        conn = send_with_span(conn, config, :redirect, fn ->
          Sender.send_redirect(conn, status, location)
        end)

        {conn, %{result: :redirect, status: status}}

      {:error, reason} ->
        send_error(conn, dialect, reason, config)
    end
  end

  defp parse(%Plug.Conn{} = conn, dialect, config) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:parse], %{}, fn ->
      dialect.parse(conn, config)
    end)
  end

  defp handle_request(conn, dialect, request, config) do
    with {:ok, %Resolved{} = resolved} <- dialect.prepare(conn, request, config),
         {:ok, %ImageSource.Resolved{} = source} <-
           ImageSource.resolve(resolved.source, config, config),
         {:ok, %Negotiation{} = negotiation, material} <- resolved.negotiation do
      representation =
        Representation.build(source.identity, material, source.cache_semantics.byte_identity)

      if Conditional.not_modified?(conn, representation.etag) do
        send_not_modified(conn, representation, config)
      else
        serve(conn, dialect, resolved, source, negotiation, representation, config)
      end
    else
      {:error, reason} -> send_error(conn, dialect, reason, config)
    end
  end

  # -- serve: cache dispatch (Resolved-neutral: branches on Source.Resolved) --

  defp serve(
         conn,
         dialect,
         resolved,
         %ImageSource.Resolved{internal_cache: :disabled} = source,
         negotiation,
         representation,
         config
       ) do
    generate(conn, dialect, resolved, source, negotiation, representation, nil, config)
  end

  defp serve(
         conn,
         dialect,
         resolved,
         %ImageSource.Resolved{internal_cache: :enabled} = source,
         negotiation,
         representation,
         config
       ) do
    start = System.monotonic_time(:microsecond)
    lookup_result = Cache.lookup_entry(representation.cache_key, config)
    cache_serve_us = System.monotonic_time(:microsecond) - start

    case lookup_result do
      {:hit, %Cache.Entry{} = entry} ->
        deliver_hit(conn, dialect, resolved, entry, representation, cache_serve_us, config)

      _miss_or_disabled ->
        generate(
          conn,
          dialect,
          resolved,
          source,
          negotiation,
          representation,
          representation.cache_key,
          config
        )
    end
  end

  # A cache hit is the proof that a current representation exists for this
  # key — the only place `If-None-Match: *` may be honored (mirrors every
  # dialect chain and Request.Runner).
  defp deliver_hit(conn, dialect, resolved, entry, representation, cache_serve_us, config) do
    if Conditional.if_none_match_wildcard?(conn) do
      send_not_modified(conn, representation, config)
    else
      hit_debug = %{cache_key: representation.cache_key.hash, cache_serve_us: cache_serve_us}
      _ = dialect

      conn =
        send_with_span(conn, config, :ok, fn ->
          Sender.send_result(
            conn,
            {:ok,
             {:cache_entry, entry, resolved.response_meta,
              CacheHeaders.from_representation(representation), hit_debug}},
            delivery_config(resolved, config)
          )
        end)

      {conn, %{result: :ok}}
    end
  end

  # -- image terminal: Delivery.stream over produce_stream ---------------------

  defp generate(conn, dialect, %Resolved{terminal: :image} = resolved, source, negotiation, representation, cache_key, config) do
    build_fun = build_fun(dialect, resolved, source, negotiation, config)

    case Delivery.stream(self(), build_fun, cache_key, resolved.response_meta, config) do
      {:ok, prepared} ->
        conn =
          send_with_span(conn, config, :ok, fn ->
            Sender.send_result(
              conn,
              {:ok,
               {:prepared_stream, prepared, resolved.response_meta,
                CacheHeaders.from_representation(representation)}},
              delivery_config(resolved, config)
            )
          end)

        {conn, %{result: :ok}}

      {:error, reason} ->
        # Phase B note: imgproxy/TwicPics ride negotiation.policy.headers on
        # delivery errors (their Errors.send/4); Native's Errors.send/3 takes
        # none, so Phase A's contract carries no headers here — see the plan's
        # exit notes for the Phase B design question.
        send_error(conn, dialect, reason, config)
    end
  end

  defp build_fun(dialect, %Resolved{} = resolved, source, negotiation, config) do
    decode_opts = Keyword.put(config, :auto_rotate?, resolved.auto_rotate?)
    on_bracket_exit = Keyword.get(config, :on_bracket_exit, fn -> :ok end)

    fn pump ->
      Decode.with_image(
        source,
        decode_opts,
        &dialect.decode_request(resolved.request, &1),
        fn state, geometry ->
          try do
            produce_stream(dialect, state, geometry, resolved, negotiation, config, pump)
          after
            on_bracket_exit.()
          end
        end
      )
    end
  end

  # transform → resolve output → clamp → materialize → encode first chunk →
  # hand off. Runs inside Delivery.Producer. (The dialects' build_and_pump,
  # written once — spec §The runner.)
  defp produce_stream(dialect, state, geometry, resolved, negotiation, config, pump) do
    with {:ok, %State{} = state} <-
           run_transform(dialect, state, geometry, resolved, negotiation, config),
         {:ok, %ResolvedOutput{} = resolved_output} <-
           resolve_output(negotiation.policy, geometry.source_format, state.image, config),
         {:ok, clamped, _clamp_info} <-
           Clamp.clamp_with_telemetry(
             state.image,
             result_limits(resolved_output.format, config),
             resolved_output.format,
             config
           ),
         {:ok, %State{image: image}} <-
           materialize_for_delivery(%State{state | image: clamped}, config),
         {:ok, chunk, content_type, stream_state, _search_meta} <-
           encode_first_chunk(image, resolved_output, config) do
      pump.(StreamPull.resume(chunk, stream_state), content_type, resolved_output, nil)
    else
      :empty -> {:error, {:encode, :empty_stream}}
      {:error, _reason} = error -> error
    end
  rescue
    exception -> {:error, {:transform, {exception, __STACKTRACE__}}}
  catch
    kind, reason -> {:error, {:transform, {kind, reason}}}
  end

  defp run_transform(dialect, state, geometry, %Resolved{} = resolved, negotiation, config) do
    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:transform, :execute],
      %{operations: resolved.operations, operation_count: length(resolved.operations)},
      fn ->
        result =
          dialect.execute(
            state,
            geometry,
            resolved.request,
            pipeline_opts(negotiation, geometry, config)
          )

        {result, transform_stop_metadata(result)}
      end
    )
  end

  defp transform_stop_metadata({:ok, %State{}}), do: %{result: :ok}

  defp transform_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Error.tag(error)}

  # `supports_hdr?` from the negotiation's own policy + plan_output — never
  # from the opaque request. Conservative false when there is no policy.
  defp pipeline_opts(%Negotiation{policy: nil}, _geometry, config),
    do: Keyword.put(config, :supports_hdr?, false)

  defp pipeline_opts(%Negotiation{} = negotiation, geometry, config) do
    Keyword.put(
      config,
      :supports_hdr?,
      Policy.supports_hdr?(negotiation.policy, negotiation.plan_output, geometry.source_format)
    )
  end

  defp resolve_output(policy, source_format, image, config) do
    Negotiate.negotiate_output(
      policy,
      source_format,
      fn -> Image.has_alpha?(image) end,
      Telemetry.telemetry_opts(config)
    )
  end

  defp encode_first_chunk(image, %ResolvedOutput{} = resolved_output, config) do
    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:encode],
      %{output_format: resolved_output.format},
      fn ->
        result =
          with {:ok, stream, content_type, search_meta} <-
                 Encoder.stream_output(image, resolved_output, config),
               {:ok, chunk, stream_state} <-
                 StreamPull.translate(fn -> StreamPull.first_chunk(stream) end) do
            {:ok, chunk, content_type, stream_state, search_meta}
          end

        {result, encode_stop_metadata(result, resolved_output.format)}
      end
    )
  end

  defp encode_stop_metadata({:ok, _chunk, _ct, _stream_state, _meta}, format),
    do: %{result: :ok, output_format: format}

  defp encode_stop_metadata(:empty, format),
    do: %{result: :processing_error, output_format: format, error: :empty_stream}

  defp encode_stop_metadata({:error, reason}, format),
    do: %{result: :processing_error, output_format: format, error: Error.tag(reason)}

  defp materialize_for_delivery(%State{materialized?: true} = state, _config), do: {:ok, state}

  defp materialize_for_delivery(%State{} = state, config) do
    case Materializer.materialize(state, config) do
      {:ok, %State{} = materialized} -> {:ok, materialized}
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

  defp result_limits(format, config) do
    %{max_dimension: encoder_dimension, max_pixels: encoder_pixels} =
      Encoder.encoder_limit(format)

    %{
      max_width: min_limit(Keyword.fetch!(config, :max_result_width), encoder_dimension),
      max_height: min_limit(Keyword.fetch!(config, :max_result_height), encoder_dimension),
      max_pixels: min_limit(Keyword.fetch!(config, :max_result_pixels), encoder_pixels)
    }
  end

  defp min_limit(host_limit, :infinity), do: host_limit
  defp min_limit(host_limit, encoder_limit), do: min(host_limit, encoder_limit)

  defp delivery_config(%Resolved{} = resolved, config) do
    Keyword.put(config, :debug?, resolved.debug? and Keyword.get(config, :allow_debug_headers, false))
  end

  # -- terminal sends ---------------------------------------------------------

  defp send_with_span(%Plug.Conn{}, config, result, fun) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:send], %{result: result}, fn ->
      sent_conn = fun.()

      {sent_conn,
       %{
         result: Map.get(sent_conn.private, :image_pipe_send_result, result),
         status: sent_conn.status
       }}
    end)
  end

  defp send_not_modified(conn, %Representation{} = representation, config) do
    conn =
      send_with_span(conn, config, :not_modified, fn ->
        Sender.send_result(
          conn,
          {:not_modified, CacheHeaders.from_representation(representation)},
          config
        )
      end)

    {conn, %{result: :not_modified}}
  end

  defp send_error(conn, dialect, reason, config) do
    metadata = %{result: classify(dialect, reason), error: Error.tag(reason)}

    conn =
      send_with_span(conn, config, metadata.result, fn ->
        dialect.render_error(conn, reason, config)
      end)

    {conn, metadata}
  end

  defp classify(dialect, reason) do
    if function_exported?(dialect, :classify_error, 1) do
      dialect.classify_error(reason)
    else
      Telemetry.request_result({:error, reason})
    end
  end
end
```

Note the `[:parse]` span: `Telemetry.span/4`'s callback must return `{result, stop_metadata}` — `dialect.parse/2` already returns exactly that tuple, so it is passed through unwrapped.

- [ ] **Step 5: Run the tests**

Run: `mise exec -- mix test test/image_pipe/plug_dialect_runner_test.exs test/image_pipe/plug_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: new tests PASS; the legacy `parser:` plug tests PASS unchanged.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/plug.ex lib/image_pipe/plug/dialect_runner.ex test/support/image_pipe/test/runner_fixture_dialect.ex test/image_pipe/plug_dialect_runner_test.exs
git commit -m "Add the dialect-mode lifecycle runner to ImagePipe.Plug (Phase A task 3)"
```

---

### Task 4: Runner conditional-GET and cache paths

**Files:**
- Modify: `lib/image_pipe/plug/dialect_runner.ex` (no new functions — this task adds tests proving paths already coded in Task 3)
- Test: `test/image_pipe/plug_dialect_runner_test.exs`

**Interfaces:**
- Consumes: Task 3's runner; `CacheProbe`/`CountingOriginImage` test support (aliases copied from `native_wire_test.exs`).

- [ ] **Step 1: Write the failing/pinning tests**

Append to `test/image_pipe/plug_dialect_runner_test.exs` (copy the `stateful_cache_probe/0` and `counting_sources/0` helpers verbatim from `native_wire_test.exs:29-56`, including their aliases):

```elixir
  test "matching If-None-Match returns 304 before any source fetch" do
    config = opts(sources: should_not_fetch_after_first_sources())
    first = get("/fix/images/beach.jpg?format=webp", opts())
    [etag] = get_resp_header(first, "etag")

    conn = get("/fix/images/beach.jpg?format=webp", config, [{"if-none-match", etag}])
    assert conn.status == 304
    assert conn.resp_body == ""
  end

  test "miss then hit round trip through the internal cache" do
    config = opts(cache: stateful_cache_probe(), sources: counting_sources())

    miss = get("/fix/images/beach.jpg?format=webp", config)
    assert miss.status == 200
    assert_received :origin_fetch

    hit = get("/fix/images/beach.jpg?format=webp", config)
    assert hit.status == 200
    assert hit.resp_body == miss.resp_body
    refute_received :origin_fetch
  end

  test "If-None-Match: * is honored only on a cache hit" do
    config = opts(cache: stateful_cache_probe(), sources: counting_sources())

    # No entry yet: wildcard proceeds (200, generation happens).
    first = get("/fix/images/beach.jpg?format=webp", config, [{"if-none-match", "*"}])
    assert first.status == 200
    assert_received :origin_fetch

    # Entry exists: wildcard answers 304 without regeneration.
    second = get("/fix/images/beach.jpg?format=webp", config, [{"if-none-match", "*"}])
    assert second.status == 304
    refute_received :origin_fetch
  end
```

For the 304-before-fetch test, add a `should_not_fetch_after_first_sources/0` helper analogous to `native_wire_test.exs`'s `should_not_fetch_sources/0` (an origin plug that raises on any fetch), used only on the conditional request.

- [ ] **Step 2: Run the tests**

Run: `mise exec -- mix test test/image_pipe/plug_dialect_runner_test.exs`
Expected: PASS (Task 3 coded these paths; if any fail, fix the runner — the failure modes are a conditional check placed after `Cache.lookup_entry`, or the wildcard honored outside the hit branch).

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/plug_dialect_runner_test.exs
git commit -m "Pin runner conditional-GET and cache paths (Phase A task 4)"
```

---

### Task 5: Negotiation-unwrap precedence and error classification

**Files:**
- Modify: `test/support/image_pipe/test/runner_fixture_dialect.ex` (add `?format=bmp` producing an incapable output + `classify_error/1`)
- Test: `test/image_pipe/plug_dialect_runner_test.exs`

**Interfaces:**
- Produces: proof of the spec's deferred-unwrap contract — a request whose source translation resolves but whose negotiation fails errors **after** `Source.resolve`; a request with a bad source **and** a bad format yields the source error.

- [ ] **Step 1: Extend the fixture**

In `RunnerFixtureDialect`: extend `parse_format/1` with `defp parse_format("bmp"), do: :bmp` (an incapable output format — `Policy.ensure_capable` rejects it), add

```elixir
  @impl ImagePipe.Dialect
  def classify_error(:fixture_parse_reject), do: :parser_error
  def classify_error(reason), do: ImagePipe.Telemetry.request_result({:error, reason})
```

and a `render_error` clause: `def render_error(conn, {:unsupported_output_format, _}, _config), do: send_resp(conn, 415, "unsupported output")`.

- [ ] **Step 2: Write the failing tests**

Append (telemetry-scoped per the AGENTS.md rule — unique `telemetry_prefix`, handler on the prefixed `[:request, :stop]`):

```elixir
  test "negotiation failure surfaces after source resolution, source failure wins when both fail" do
    # capable source + incapable format -> negotiation error (415)
    conn = get("/fix/images/beach.jpg?format=bmp", opts())
    assert conn.status == 415

    # A config with NO adapter for the :path source kind makes Source.resolve
    # itself fail ({:source, :missing_adapter}) — a genuine resolve-time
    # error, needing no custom adapter. With the incapable format on the
    # same request, the SOURCE error must win (the runner unwraps the
    # deferred negotiation only after resolve succeeds): 404 via the
    # fixture's {:source, _} render_error clause, not 415.
    conn = get("/fix/images/beach.jpg?format=bmp", opts(sources: []))
    assert conn.status == 404
  end

  test "classify_error shapes the [:request] stop result" do
    prefix = [:runner_fixture_classify]
    handler = "runner-fixture-classify-#{inspect(self())}"

    :telemetry.attach(
      handler,
      prefix ++ [:request, :stop],
      fn _event, _measurements, metadata, pid -> send(pid, {:request_stop, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    get("/fix/images/beach.jpg?boom=parse", opts(telemetry_prefix: prefix))
    assert_received {:request_stop, %{result: :parser_error}}
  end
```

(Why `sources: []`: a `%Path{}` source against `RootHTTPAdapter` resolves
successfully and fails only at FETCH — inside the producer, after the
negotiation unwrap — so a missing *file* cannot pin resolve-time precedence.
An empty sources map fails inside `Source.resolve/3` itself
(`fetch_adapter_config` → `{:source, :missing_adapter}`), which is exactly
the pre-negotiation stage the contract orders first.)

- [ ] **Step 3: Run, fix, run**

Run: `mise exec -- mix test test/image_pipe/plug_dialect_runner_test.exs`
Expected: PASS once the runner's `handle_request` keeps `resolved.negotiation` unwrap **after** `ImageSource.resolve` (already coded in Task 3's `with` order — the test pins it against regression).

- [ ] **Step 4: Commit**

```bash
git add test/support/image_pipe/test/runner_fixture_dialect.ex test/image_pipe/plug_dialect_runner_test.exs
git commit -m "Pin deferred-negotiation precedence and error classification (Phase A task 5)"
```

---

### Task 6: Default debug builder — unconditional build, stored, gated rendering

**Files:**
- Create: `lib/image_pipe/plug/debug_builder.ex`
- Modify: `lib/image_pipe/plug/dialect_runner.ex` (timings + builder wiring in `build_fun`/`produce_stream`)
- Modify: `mix.exs` (`@ex_dna_ignores`, `mix.exs:6-11` — add `lib/image_pipe/plug/debug_builder.ex`; that module attribute is the single authoritative ExDNA ignore list, consumed by both the credo integration and the standalone task. The TwicPics copy coexists until Phase B deletes it)
- Test: `test/image_pipe/plug_dialect_runner_test.exs`

**Interfaces:**
- Consumes: Task 1's `DebugContext`; Task 2's `geometry.debug_facts`; TwicPics' neutral fact logic (`dialect/twic_pics.ex:536-627`) as the source to copy.
- Produces: `ImagePipe.Plug.DebugBuilder.build(dialect :: module(), DebugContext.t()) :: ImagePipe.Debug.Info.t()` — calls `dialect.debug_info(ctx)` when exported and non-nil-returning, else the default neutral build.

- [ ] **Step 1: Write the failing tests**

```elixir
  test "debug facts are stored with the entry and replayed on hit only when enabled" do
    cache = stateful_cache_probe()

    # Generated with rendering OFF: no debug headers, but the entry stores facts.
    off = get("/fix/images/beach.jpg?format=webp&debug=1", opts(cache: cache))
    assert off.status == 200
    assert get_resp_header(off, "x-imagepipe-source-format") == []

    # Same mount with rendering ON: the hit replays the STORED facts.
    on =
      get(
        "/fix/images/beach.jpg?format=webp&debug=1",
        opts(cache: cache, allow_debug_headers: true)
      )

    assert on.status == 200
    assert get_resp_header(on, "x-imagepipe-cache") == ["hit"]
    assert get_resp_header(on, "x-imagepipe-source-format") == ["jpeg"]
    assert [timing] = get_resp_header(on, "server-timing")
    assert timing =~ "cache;dur="
  end

  test "a debug miss renders measured timings and the six source facts" do
    conn = get("/fix/images/beach.jpg?format=webp&debug=1", opts(allow_debug_headers: true))

    assert conn.status == 200
    assert get_resp_header(conn, "x-imagepipe-cache") == ["miss"]
    assert [timing] = get_resp_header(conn, "server-timing")
    assert timing =~ "decode;dur=" and timing =~ "transform;dur=" and timing =~ "encode;dur="
    assert get_resp_header(conn, "x-imagepipe-source-size") != []
    assert get_resp_header(conn, "x-imagepipe-source-color-space") != []
  end
```

(`RunnerFixtureDialect.validate_config!` is permissive, so `allow_debug_headers: true` passes through; the runner's `delivery_config/2` already gates on it.)

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/plug_dialect_runner_test.exs`
Expected: FAIL — no debug headers rendered (Task 3 passes `nil` debug to `pump`).

- [ ] **Step 3: Implement**

`lib/image_pipe/plug/debug_builder.ex` — copy the body of TwicPics' `build_debug/8` and its private helpers (`negotiated?/1`, `output_quality/2`, `output_distance/1`, `aq_from_meta/2`, `quality_search_score/2`, `quality_search_metric/1`, `native_jxl_search?/1` — `dialect/twic_pics.ex:536-627`) into:

```elixir
defmodule ImagePipe.Plug.DebugBuilder do
  @moduledoc false
  # The default neutral Debug.Info builder (design decision U13). Runs
  # unconditionally on every generation; rendering is gated at delivery.

  alias ImagePipe.Debug.Info
  alias ImagePipe.Dialect.DebugContext
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved, as: ResolvedOutput

  @spec build(module(), DebugContext.t()) :: Info.t()
  def build(dialect, %DebugContext{} = ctx) do
    if function_exported?(dialect, :debug_info, 1) do
      dialect.debug_info(ctx) || default(ctx)
    else
      default(ctx)
    end
  end

  defp default(%DebugContext{} = ctx) do
    {source_width, source_height} = ctx.geometry.storage_dimensions
    facts = ctx.geometry.debug_facts

    %Info{
      source_format: ctx.geometry.source_format,
      source_bytes: Map.get(facts, :source_bytes),
      source_width: source_width,
      source_height: source_height,
      source_color_space: Map.get(facts, :source_color_space),
      source_icc?: Map.get(facts, :source_icc?),
      source_bit_depth: Map.get(facts, :source_bit_depth),
      source_alpha?: Map.get(facts, :source_alpha?),
      source_orientation: Map.get(facts, :source_orientation),
      shrink: ctx.shrink,
      output_format: ctx.resolved_output.format,
      output_negotiated?: negotiated?(ctx.negotiation.policy),
      output_width: Image.width(ctx.image),
      output_height: Image.height(ctx.image),
      output_quality: output_quality(ctx.resolved_output, ctx.search_meta),
      output_stripped?: ctx.resolved_output.strip_metadata,
      output_color_profile: ctx.resolved_output.color_profile,
      output_distance: output_distance(ctx.resolved_output),
      aq: aq_from_meta(ctx.resolved_output, ctx.search_meta),
      pipeline: ctx.operations,
      timings: ctx.timings
    }
  end

  defp negotiated?(%Policy{mode: {:explicit, _format}}), do: false
  defp negotiated?(%Policy{mode: :source}), do: true

  defp output_quality(%ResolvedOutput{}, %{quality: quality})
       when is_integer(quality) and quality > 0,
       do: quality

  defp output_quality(%ResolvedOutput{quality: {:quality, quality}}, _search_meta), do: quality
  defp output_quality(%ResolvedOutput{quality: :default}, _search_meta), do: :default

  defp output_distance(%ResolvedOutput{quality_search: :none}), do: nil

  defp output_distance(%ResolvedOutput{quality_search: %module{target: target}})
       when is_number(target) do
    case native_jxl_search?(module) do
      true -> target
      false -> nil
    end
  end

  defp output_distance(%ResolvedOutput{}), do: nil

  defp aq_from_meta(_resolved_output, nil), do: nil
  defp aq_from_meta(%ResolvedOutput{quality_search: :none}, _search_meta), do: nil

  defp aq_from_meta(%ResolvedOutput{quality_search: %module{} = search}, %{} = metadata) do
    metric = quality_search_metric(module)

    %{
      metric: metric,
      score: quality_search_score(module, metadata),
      target: Map.get(search, :target),
      min: Map.get(search, :min_quality),
      max: Map.get(search, :max_quality),
      iterations: Map.get(metadata, :iterations),
      outcome: Map.get(metadata, :outcome),
      limiting_factor: Map.get(metadata, :limiting_factor),
      scorer: Map.get(metadata, :scorer),
      tiles: Map.get(metadata, :tiles_scored)
    }
  end

  defp quality_search_score(module, metadata) do
    case native_jxl_search?(module) do
      true -> nil
      false -> Map.get(metadata, :score)
    end
  end

  defp quality_search_metric(module) do
    case module |> Module.split() |> List.last() do
      "Ssimulacra2" -> :ssimulacra2
      "Butteraugli" -> :butteraugli
      "NativeJxlButteraugli" -> :butteraugli
      "Size" -> :size
      _other -> nil
    end
  end

  defp native_jxl_search?(module),
    do: module |> Module.split() |> List.last() == "NativeJxlButteraugli"
end
```

In `DialectRunner`: alias `ImagePipe.Debug.Timing` and `ImagePipe.Dialect.DebugContext`; in `build_fun/5` capture `decode_started_at` before `Decode.with_image` and compute `decode_us` inside the bracket (exactly as `dialect/twic_pics.ex:346-365` does); in `produce_stream/7` wrap the transform call and `encode_first_chunk` in `Timing.measure/1` (the TwicPics pattern at `twic_pics.ex:374-411`, including its `{:empty, _us}`/`{{:error, _}, _us}` else-clauses), build

```elixir
      debug =
        DebugBuilder.build(dialect, %DebugContext{
          geometry: geometry,
          shrink: state.decode_shrink,
          negotiation: negotiation,
          resolved_output: resolved_output,
          image: image,
          search_meta: search_meta,
          operations: resolved.operations,
          timings: %{decode: decode_us, transform: transform_us, encode: encode_us}
        })
```

(capture `shrink = state.decode_shrink` before the transform, as TwicPics does) and pass `debug` instead of `nil` to `pump`. `search_meta` stops being discarded: change the encode-chunk pattern to bind it.

Add `lib/image_pipe/plug/debug_builder.ex` to `@ex_dna_ignores` in `mix.exs` (the single authoritative list), with a comment: deliberate copy of the TwicPics debug build until Phase B deletes the dialect's copy.

- [ ] **Step 4: Run the tests**

Run: `mise exec -- mix test test/image_pipe/plug_dialect_runner_test.exs && mise exec -- mix credo --strict`
Expected: PASS; credo clean (ExDNA ignore in place).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plug/debug_builder.ex lib/image_pipe/plug/dialect_runner.ex test/image_pipe/plug_dialect_runner_test.exs mix.exs
git commit -m "Add the runner's default neutral debug builder (Phase A task 6, U13)"
```

---

### Task 7: Render terminal — the `:complete_body` path

**Files:**
- Modify: `lib/image_pipe/plug/dialect_runner.ex`
- Modify: `test/support/image_pipe/test/runner_fixture_dialect.ex` (a `?render=text` terminal)
- Test: `test/image_pipe/plug_dialect_runner_test.exs`

**Interfaces:**
- Consumes: Task 1's `RenderTerminal`; `Cache.{lookup_entry, open_sink, write_chunk, commit_sink}`; `Conditional.if_none_match_wildcard?/1`.
- Produces: the runner's render-terminal heads for `%Resolved{terminal: {:render, %RenderTerminal{}}}` (Phase A's sole render delivery is the complete-body lifecycle) — consolidating `dialect/native.ex:437-516` (blurhash) / `dialect/imgproxy.ex:731-843` (`/info`). Task 8's blurhash port relies on it.

- [ ] **Step 1: Extend the fixture**

In `RunnerFixtureDialect.prepare/3`, when `request` has `render?: true` (set in `parse` from `?render=text`), return `terminal: {:render, render_terminal()}` and `negotiation: {:ok, Negotiation.terminal(:fixture_text), material(request, Negotiation.terminal(:fixture_text), conn, config)}` where:

```elixir
  defp render_terminal do
    %ImagePipe.Dialect.RenderTerminal{
      fun: fn _resolved_source, _config -> {:ok, "text/plain; charset=utf-8", "fixture-body"} end
    }
  end
```

- [ ] **Step 2: Write the failing tests**

```elixir
  test "complete-body render terminal: generate, cache, hit, wildcard" do
    config = opts(cache: stateful_cache_probe(), sources: counting_sources())

    first = get("/fix/images/beach.jpg?render=text", config)
    assert first.status == 200
    assert first.resp_body == "fixture-body"
    assert get_resp_header(first, "content-type") |> hd() =~ "text/plain"
    assert [_etag] = get_resp_header(first, "etag")

    hit = get("/fix/images/beach.jpg?render=text", config)
    assert hit.status == 200
    assert hit.resp_body == "fixture-body"

    wildcard = get("/fix/images/beach.jpg?render=text", config, [{"if-none-match", "*"}])
    assert wildcard.status == 304
  end
```

- [ ] **Step 3: Run to verify failure, implement**

Run: `mise exec -- mix test test/image_pipe/plug_dialect_runner_test.exs` — expected FAIL (no render head).

Implement in `DialectRunner`, mirroring the imgproxy `/info` shape (`imgproxy.ex:731-843`):

```elixir
  # -- render terminal: consolidated from imgproxy /info + Native blurhash.
  # -- Phase A's sole render delivery is the complete-body lifecycle; the
  # -- spec's cache-:none/offers variant arrives with Phase C's widening.

  defp serve(conn, dialect, %Resolved{terminal: {:render, terminal}} = resolved, source, negotiation, representation, config) do
```

Restructure: keep the Task 3 image `serve/7` heads but route on the terminal FIRST — change `handle_request` to call `serve_terminal(conn, dialect, resolved, source, negotiation, representation, config)` which dispatches:

```elixir
  defp serve_terminal(conn, dialect, %Resolved{terminal: :image} = resolved, source, negotiation, representation, config),
    do: serve(conn, dialect, resolved, source, negotiation, representation, config)

  defp serve_terminal(conn, dialect, %Resolved{terminal: {:render, terminal}} = resolved, %ImageSource.Resolved{internal_cache: :disabled} = source, _negotiation, representation, config),
    do: generate_render(conn, dialect, resolved, terminal, source, representation, nil, config)

  defp serve_terminal(conn, dialect, %Resolved{terminal: {:render, terminal}} = resolved, %ImageSource.Resolved{internal_cache: :enabled} = source, _negotiation, representation, config) do
    case Cache.lookup_entry(representation.cache_key, config) do
      {:hit, %Cache.Entry{representation: {:complete_body, content_type}} = entry} ->
        deliver_render_hit(conn, content_type, entry.body, representation, config)

      # A miss, a disabled cache, or an untagged entry (indistinguishable from
      # an image entry — sending one here would answer the render terminal
      # with image bytes) all regenerate.
      _miss_or_untagged ->
        generate_render(conn, dialect, resolved, terminal, source, representation, representation.cache_key, config)
    end
  end

  defp deliver_render_hit(conn, content_type, body, representation, config) do
    if Conditional.if_none_match_wildcard?(conn) do
      send_not_modified(conn, representation, config)
    else
      conn =
        send_with_span(conn, config, :ok, fn ->
          send_complete_body(conn, content_type, body, representation)
        end)

      {conn, %{result: :ok}}
    end
  end

  defp generate_render(conn, dialect, _resolved, terminal, source, representation, cache_key, config) do
    started_at = System.monotonic_time(:microsecond)

    case terminal.fun.(source, config) do
      {:ok, content_type, body} ->
        cost_us = System.monotonic_time(:microsecond) - started_at
        write_complete_body_cache(cache_key, content_type, body, cost_us, config)

        conn =
          send_with_span(conn, config, :ok, fn ->
            send_complete_body(conn, content_type, body, representation)
          end)

        {conn, %{result: :ok}}

      {:error, reason} ->
        send_error(conn, dialect, reason, config)
    end
  end

  defp write_complete_body_cache(nil = _cache_disabled, _ct, _body, _cost_us, _config), do: :ok

  defp write_complete_body_cache(%Cache.Key{} = cache_key, content_type, body, cost_us, config) do
    cache_key
    |> Cache.open_sink({:complete_body, content_type}, Keyword.put(config, :cost_us, cost_us))
    |> Cache.write_chunk(IO.iodata_to_binary(body), config)
    |> Cache.commit_sink(config)

    :ok
  end

  defp send_complete_body(conn, content_type, body, %Representation{} = representation) do
    cache_headers = CacheHeaders.from_representation(representation)

    conn
    |> put_resp_headers(cache_headers.representation_headers)
    |> put_resp_headers(cache_headers.headers)
    |> Plug.Conn.put_resp_content_type(content_type, nil)
    |> Plug.Conn.send_resp(200, body)
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      Plug.Conn.put_resp_header(acc, name, value)
    end)
  end
```

Also extend `deliver_hit/7` (the IMAGE path) with Native's complete-body hit guard (`native.ex:363-378`): before sending a `{:cache_entry, …}` result, match `%Cache.Entry{representation: {:complete_body, content_type}}` and deliver via `send_complete_body/4` instead — a warmed complete-body entry must not flow through `Sender`'s image-entry delivery.

- [ ] **Step 4: Run the tests**

Run: `mise exec -- mix test test/image_pipe/plug_dialect_runner_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plug/dialect_runner.ex test/support/image_pipe/test/runner_fixture_dialect.ex test/image_pipe/plug_dialect_runner_test.exs
git commit -m "Add the complete-body render terminal to the runner (Phase A task 7)"
```

---

### Task 8: Port `ImagePipe.Dialect.Native` onto the contract

**Files:**
- Modify: `lib/image_pipe/dialect/native.ex` (chain deleted, behaviour implemented)
- Delete: `lib/image_pipe/dialect/native/negotiation.ex`
- Modify: `lib/image_pipe/dialect/native/identity.ex` (alias swap)
- Modify: `test/image_pipe/dialect/native_wire_test.exs`, `native_test.exs`, `native_contract_test.exs`, `native_error_paths_test.exs`, `native_result_limits_test.exs`, and any `test/image_pipe/dialect/native/*` file calling `Native.call/2` or aliasing `Native.Negotiation` (grep first: `grep -rln "Native.call\|Native.init\|Native.Negotiation" test/`)

**Interfaces:**
- Consumes: everything Tasks 1–7 produced.
- Produces: `ImagePipe.Dialect.Native` implementing `ImagePipe.Dialect` — mounted as `plug ImagePipe.Plug, dialect: ImagePipe.Dialect.Native, <same flat config>`. `Native.init/1` and `Native.call/2` no longer exist.

- [ ] **Step 1: Rewrite `lib/image_pipe/dialect/native.ex`**

Keep: the moduledoc (rewrite its first paragraph to describe the contract implementation; keep the mount-prefix caveat), the Boundary declaration — the final `deps:` list is the current one (`native.ex:38-55`) minus `ImagePipe.Cache` and `ImagePipe.Delivery` (the runner owns both now) plus `ImagePipe.Dialect`, i.e. `[ImagePipe.Decode, ImagePipe.Dialect, ImagePipe.Dialect.SharedConfig, ImagePipe.Error, ImagePipe.Format, ImagePipe.Output, ImagePipe.Plan, ImagePipe.Representation, ImagePipe.Response, ImagePipe.Source, ImagePipe.Telemetry, ImagePipe.Transform]` (`Decode` stays for `compute_blurhash/3`; `Output` stays for `Output.Terminal.Blurhash`; `Response` stays for `Errors`' `ErrorStatus`), `@blurhash_content_type`, `@auto_rotate?`, `compute_blurhash/3` + `run_blurhash/4` (unchanged, `native.ex:465-494`), `check_expires/2`, `normalize_lex_error/1`, and the `outcome_result/1` clauses (renamed into `classify_error/1`).

Delete: `call/2`, `route/2` (all heads), `send_with_span/4`, `send_stop_metadata/2`, `send_not_modified/3`, `send_error/3`, `request_metadata/1`, `parse/2` (the span version), `unwrap_parse_result/1`, `parse_stop_metadata/1`, `negotiate/3` + `normalize_selection/1`, `serve/6`, `deliver_hit/5`, `deliver_hit_entry/5`, `generate/6` (both heads), `send_complete_body/4`, `write_complete_body_cache/4`, `put_resp_headers/2`, `build_fun/4`, `build_and_pump/6`, `run_transform/5`, `transform_stop_metadata/1`, `encode_first_chunk/3`, `first_chunk/1`, `encode_stop_metadata/2`, `materialize_for_delivery/2`, `pipeline_opts/4`, `resolve_output/4`, `result_limits/2`, `min_limit/2`, `@debug_info`, and the `@behaviour Plug` + `init/1`.

The new public surface:

```elixir
  @behaviour ImagePipe.Dialect

  alias ImagePipe.Dialect.Negotiation, as: DialectNegotiation
  alias ImagePipe.Dialect.RenderTerminal
  alias ImagePipe.Dialect.Resolved

  @impl ImagePipe.Dialect
  def validate_config!(opts), do: Config.validate!(opts)

  @impl ImagePipe.Dialect
  def parse(%Plug.Conn{} = conn, config) do
    {sig, signed_path} = Path.split_signature(conn)

    result =
      with {:ok, key_index} <- Signature.verify(sig, signed_path, config),
           {:ok, lexed} <- Path.extract(conn) |> normalize_lex_error(),
           {:ok, request} <- Parser.parse(lexed, config) do
        {request, key_index}
      end

    case result do
      {%Request{} = request, key_index} ->
        {{:ok, request}, %{result: :ok, sig_key_index: key_index}}

      {:error, _reason} = error ->
        # Deliberately NO error tag — preserving the chain's parse stop shape.
        {error, %{result: :error}}
    end
  end

  @impl ImagePipe.Dialect
  def prepare(%Plug.Conn{} = conn, %Request{} = request, config) do
    # The clock read moves from route-entry (pre-parse) to here (post-parse):
    # only a sub-second expiry edge differs and nothing pins it.
    with :ok <- check_expires(request, System.os_time(:second)),
         {:ok, plan_source} <- NativeSource.translate(request.source, config) do
      {:ok,
       %Resolved{
         request: request,
         source: plan_source,
         negotiation: negotiation_result(conn, request, config),
         response_meta: %PlanResponse{},
         operations: Pipeline.operation_names(request),
         auto_rotate?: @auto_rotate?,
         debug?: false,
         terminal: terminal(request, config)
       }}
    end
  end

  defp negotiation_result(conn, %Request{output: %Request.Output{terminal: :blurhash}} = request, config) do
    negotiation = DialectNegotiation.terminal(:blurhash)
    {:ok, negotiation, Identity.material(request, negotiation, conn, config)}
  end

  defp negotiation_result(conn, %Request{} = request, config) do
    case DialectNegotiation.negotiate(conn, Identity.plan_output(request), config) do
      {:ok, negotiation} -> {:ok, negotiation, Identity.material(request, negotiation, conn, config)}
      {:error, _reason} = error -> error
    end
  end

  defp terminal(%Request{output: %Request.Output{terminal: :blurhash}} = request, _config) do
    {:render,
     %RenderTerminal{
       fun: fn resolved_source, config ->
         case compute_blurhash(resolved_source, request, config) do
           {:ok, hash} -> {:ok, @blurhash_content_type, hash}
           {:error, _reason} = error -> error
         end
       end
     }}
  end

  defp terminal(_request, _config), do: :image

  @impl ImagePipe.Dialect
  def decode_request(%Request{} = request, geometry), do: Pipeline.decode_request(request, geometry)

  @impl ImagePipe.Dialect
  def execute(state, geometry, %Request{} = request, opts), do: Pipeline.run(state, geometry, request, opts)

  @impl ImagePipe.Dialect
  def render_error(conn, reason, config), do: Errors.send(conn, reason, config)

  @impl ImagePipe.Dialect
  def classify_error(reason)
      when reason in [:missing_signature, :invalid_signature, :signature_without_keys],
      do: :parser_error

  def classify_error({:invalid_request, _diagnostics}), do: :parser_error
  def classify_error(:expired), do: :parser_error
  def classify_error(reason), do: Telemetry.request_result({:error, reason})
```

Prune the alias list to what the remaining code references.

- [ ] **Step 2: Delete `native/negotiation.ex`, swap the alias in `native/identity.ex`**

`rm lib/image_pipe/dialect/native/negotiation.ex`. In `native/identity.ex` replace `alias ImagePipe.Dialect.Native.Negotiation` with `alias ImagePipe.Dialect.Negotiation` (the `%Negotiation{}` pattern and field reads compile unchanged; update the `@spec`).

- [ ] **Step 3: Switch the test mounts**

In `native_wire_test.exs` change only the two helpers (`native_wire_test.exs:60-71`):

```elixir
  defp opts(extra) do
    base =
      ImagePipe.Plug.init(
        Keyword.merge([dialect: Native, sources: @default_sources], extra)
      )

    Keyword.merge(base, output_capabilities: %{avif: true, webp: true, jpeg_xl: true})
  end

  defp get(path, config, headers \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    ImagePipe.Plug.call(conn, config)
  end
```

Apply the same `init`/`call` swap in every other native test file the Step-0 grep found (including `Native.call(config)`-piped forms like `native_wire_test.exs:528`). The one-`%Policy{}` continuity test that called `Native.negotiate/3` directly now calls `ImagePipe.Dialect.Negotiation.negotiate(conn, Identity.plan_output(request), config)` — same assertion, promoted seam.

- [ ] **Step 4: Update the remaining referencing tests (outside the native-named files)**

The Step-3 grep spans all of `test/`; four hits sit outside the native-named
set and MUST get the same `init`/`call` swap — do not skip them:

- `test/image_pipe/imgproxy_telemetry_contract_test.exs:732-734` (the
  Imgproxy-vs-Native stage-sequence gate)
- `test/image_pipe/telemetry/native_delivery_span_parentage_test.exs:65-73`
- `test/image_pipe/dialect/byte_identity_cache_headers_test.exs:40`
- `test/image_pipe/dialect/color_carry_parity_test.exs:58`

One test needs more than a mount swap:
`test/image_pipe/dialect/native/identity_test.exs:47` builds negotiations
via `struct!(Negotiation, …)`; the promoted struct enforces all five keys
(the old one enforced three), so add `policy: nil, plan_output: nil` to the
test's base keyword. This is a listed mechanical edit, not an assertion
change.

(The fiddle mounts only imgproxy/IIIF/TwicPics — no Native mount exists, so
no fiddle edit in Phase A; `mise run precommit:fiddle` still gates Task 10.)

- [ ] **Step 5: Run the native suites**

Run: `mise exec -- mix test test/image_pipe/dialect/ test/image_pipe/plug_dialect_runner_test.exs test/image_pipe/telemetry_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS with **zero** assertion changes beyond the enumerated mechanical edits (mount helpers, the four Step-4 files, `identity_test`'s enforce-keys base, the negotiate-seam swap). Telemetry shapes (parse `sig_key_index`, error-tag omission, `[:request]` results) are pinned by the existing suites — any failure here is a runner parity bug, not a test to update.

- [ ] **Step 6: Commit**

```bash
git add -A lib/image_pipe/dialect/native.ex lib/image_pipe/dialect/native/ test/
git commit -m "Port Dialect.Native onto the ImagePipe.Dialect contract (Phase A task 8)"
```

---

### Task 9: U9 — Native honors `internal_cache: :disabled` (new coverage)

**Files:**
- Test: `test/image_pipe/dialect/native_wire_test.exs`

**Interfaces:**
- Consumes: the runner's `:disabled` serve head (Task 3) — Native gets the fix structurally by the port; this task adds the wire proof the old chain lacked.

- [ ] **Step 1: Write the test**

Copy the existing arrangement at `test/image_pipe/dialect/imgproxy/info_wire_test.exs:328-350`: `RootHTTPAdapter` accepts `internal_cache: :disabled` directly in its adapter opts, and `CacheProbe` already messages the test pid on every cache operation (`{:cache_lookup, key}`, `{:cache_open_sink, key, metadata}`, `{:source_order, :cache_put}`), so both halves of U9 — no read AND no write — are plain `refute_received` assertions:

```elixir
  test "a source resolving internal_cache: :disabled is neither read from nor written to the cache" do
    config =
      opts(
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             byte_identity: :strong,
             req_options: [plug: {CountingOriginImage, test_pid: self()}],
             internal_cache: :disabled}
        ],
        cache: stateful_cache_probe()
      )

    # Two identical requests: both must regenerate from the origin, and the
    # cache must never be consulted or written between them.
    first = get(valid_image_path(), config)
    assert first.status == 200
    assert_received :origin_fetch

    second = get(valid_image_path(), config)
    assert second.status == 200
    assert_received :origin_fetch

    refute_received {:cache_lookup, _key}
    refute_received {:cache_open_sink, _key, _metadata}
    refute_received {:source_order, :cache_put}
  end
```

(`valid_image_path/0` stands for whatever helper the surrounding tests use
to build a signed, valid image request path — copy the exact call shape from
the nearest 200-asserting test in the same file; the cache-message refutes
are the whole assertion.)

- [ ] **Step 2: Run it**

Run: `mise exec -- mix test test/image_pipe/dialect/native_wire_test.exs`
Expected: PASS — the runner's `:disabled` head skips lookup and passes a `nil` cache key. (Under the pre-port chain this test would have failed; the port is the fix.)

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/dialect/native_wire_test.exs
git commit -m "Pin Native internal_cache: :disabled behavior (Phase A task 9, U9)"
```

---

### Task 10: Cleanup, boundaries, gates

**Files:**
- Modify: `lib/image_pipe/dialect/native.ex` ExDNA annotations (native.ex was never on the file-level ignore list — `@ex_dna_ignores` in `mix.exs:6-11` holds only decode.ex, decode/source_format.ex, shared_config.ex, response/conditional.ex. Its suppression is the inline `# ex_dna:disable-for-next-line` annotations; Task 8's chain deletion removed most — audit `native.ex` and `native/pipeline.ex` and delete any now-orphaned annotations whose mirrored counterpart died)
- Modify: `test/image_pipe/architecture_boundary_test.exs` (deps pins: `ImagePipe.Plug` → `ImagePipe.Dialect` allowed; `ImagePipe.Dialect.Native` must not depend on `ImagePipe.Plug`, `ImagePipe.Request`, `ImagePipe.Cache`, `ImagePipe.Delivery`; adjust the existing native deps pin to its pruned list)
- Modify: `docs/` mount examples that show `plug ImagePipe.Dialect.Native` (grep: `grep -rln "Dialect.Native" docs/`) — update to the `ImagePipe.Plug, dialect:` form; leave imgproxy/TwicPics/IIIF examples untouched (Phases B/C)
- Modify: `docs/custom_parser_guide.md` — the "When a parser isn't enough" section (`custom_parser_guide.md:369-397`) states ordered dialects are directly-mounted self-contained Plugs and that ImagePipe ships "**no public SDK** for building such a Plug". Phase A makes both false for Native. Minimal truthful update (the full two-tier rewrite is Phase C): replace the "no public SDK" paragraph with 3–5 sentences saying ordered dialects implement the public `ImagePipe.Dialect` behaviour and mount through `ImagePipe.Plug, dialect: …`; that `ImagePipe.Dialect.Native` is the first ported example while imgproxy/TwicPics still mount directly during the transition; and keep the existing warning that in-tree implementation helpers (`Transform.Lowering`, `Transform.ResizePlanning`) remain private.
- Modify: `mix.exs` `groups_for_modules` (`mix.exs:46-60`) — add a `"Dialect API": [ImagePipe.Dialect, ~r/ImagePipe\.Dialect\..*/]` group ABOVE the "Runtime Internals" group so the new public contract modules don't land ungrouped (the regex also covers the existing `Dialect.SharedConfig`/dialect modules, which is correct — they are public mount surface).

- [ ] **Step 1: Apply the edits above**

For the architecture test, read the existing deps-pin blocks and update the Native entry to the Task 8 Boundary list; add one pin asserting `lib/image_pipe/plug/dialect_runner.ex` contains no reference matching `~r/Dialect\.(Native|Imgproxy|TwicPics|IIIF)\b/` (the U4 rule, enforced the same way the file already enforces no-concrete-transform-modules).

Run Vale over the changed docs explicitly — `.vale.ini` exists but no mise
task runs it, so it is not part of `precommit`:

Run: `vale docs/custom_parser_guide.md`
Expected: no errors (warnings at parity with the file's pre-edit state). If
the `vale` binary is unavailable locally, note that in the task report
rather than skipping silently.

- [ ] **Step 2: Full gates**

Run: `mise run precommit && mise run precommit:fiddle`
Expected: format, compile --warnings-as-errors, credo --strict, full `mix test` (including the imgproxy/TwicPics differential lanes — untouched, must stay green), and the fiddle verify suite all PASS. (Fresh worktree: `pnpm -C fiddle/assets run build` first if the fiddle gate complains about a missing Vite manifest.)

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "Restore ExDNA visibility for native.ex; pin Phase A boundaries (task 10)"
```

---

## Phase A exit criteria

- `mise run precommit` and `mise run precommit:fiddle` green.
- Native wire/contract/telemetry suites pass with no assertion changes except the two mount helpers and the two new tests (U9, runner suite).
- `lib/image_pipe/request/**`, `lib/image_pipe/parser/**`, imgproxy, TwicPics, IIIF: zero diffs.
- The runner contains no dialect names (architecture-test-pinned).

Phases B (imgproxy + TwicPics ports, `allow_debug_headers` → SharedConfig, #462 closure, TwicPics debug-pin flips) and C (Declarative base, IIIF, framework-stack deletion, `cache: :none` render path, docs rewrite) get their own plans after Phase A merges.

**Known contract question deferred to Phase B:** imgproxy and TwicPics pass
`negotiation.policy.headers` into their `Errors.send/4` on delivery failures
(the Accept-negotiated `Vary` rides the error); Native's `Errors.send/3` takes
no headers, so Phase A's `render_error/3` is faithful for Native. The Phase B
plan must decide how those headers reach error rendering (e.g. the runner
merges `negotiation.policy.headers` onto the conn before `render_error`, or
the callback gains an arity) — flagged here so it is designed, not
rediscovered.
