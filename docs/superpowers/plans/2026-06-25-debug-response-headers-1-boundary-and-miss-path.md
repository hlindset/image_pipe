# Debug Response Headers — Plan 1: Boundary + Gate + Miss-Path Headers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit opt-in `X-ImagePipe-*` debug headers and a `Server-Timing` header on freshly generated (cache-miss) image responses, gated by a mount option plus a per-request `_debug=1` query flag.

**Architecture:** A new neutral `ImagePipe.Debug` boundary owns the fact model (`Info`), a timing helper (`Timing`), and pure header rendering (`Headers`). Generation facts are collected in the producer process (where source/output/encode data all exist), threaded as an `Info` struct through the `{:first_chunk, …}` reply → `Prepared` → `PreparedStream`, and rendered into the response by `Response.Sender` on the streamed (miss) path. Collection runs whenever the mount allows debug headers; rendering runs only when the request carries `_debug=1`. Cache-hit replay and storage are Plan 2; fiddle/docs are Plan 3.

**Tech Stack:** Elixir, Plug, Vix/libvips, NimbleOptions, Boundary, ExUnit.

**Spec:** `docs/superpowers/specs/2026-06-25-debug-response-headers-design.md`

---

## Scope of Plan 1

In scope:
- `ImagePipe.Debug` boundary: `Info`, `Timing`, `Headers`.
- Mount option `allow_debug_headers` (default `false`) + `_debug=1` request flag plumbed into `opts`.
- `Encoder.stream_output/3` returns the autoquality search `meta` (currently discarded).
- Collection in the producer; threading through `Prepared` and `PreparedStream`.
- Rendering on the streamed (cache-miss) delivery path, including `Server-Timing`.
- Wire-level tests + a cache-key/ETag invariance test + a boundary test.

Out of scope (later plans):
- Storing `Info` in the cache entry and rendering on cache hits, with timing merge (Plan 2).
- `X-ImagePipe-Cache-Key` header (Plan 2 — cache phase owns `Key` stringification).
- Fiddle consumption and operator/header-catalogue docs (Plan 3).

Headers delivered in Plan 1 (miss path): all `X-ImagePipe-Source-*`, `X-ImagePipe-Shrink`, all `X-ImagePipe-Output-*`, all `X-ImagePipe-AQ-*`, `X-ImagePipe-Pipeline`, `X-ImagePipe-Cache: miss`, and `Server-Timing`.

---

## File Structure

**Create:**
- `lib/image_pipe/debug.ex` — boundary module (`use Boundary`, exports `Info`, `Headers`, `Timing`).
- `lib/image_pipe/debug/info.ex` — the collected-facts struct.
- `lib/image_pipe/debug/timing.ex` — a `measure/1` helper returning `{result, microseconds}`.
- `lib/image_pipe/debug/headers.ex` — pure `Info` → header list + `Server-Timing` renderer (header names live here).
- `test/image_pipe/debug/info_test.exs`
- `test/image_pipe/debug/headers_test.exs`
- `test/image_pipe/debug_headers_wire_test.exs` — wire-level `ImagePipe.Plug.call/2` tests.

**Modify:**
- `lib/image_pipe/request/options.ex` — add `allow_debug_headers` to schema + validated keys.
- `lib/image_pipe/plug.ex` — read `_debug` query param, set `debug?` in opts; add `ImagePipe.Debug` to deps.
- `lib/image_pipe.ex` — add `ImagePipe.Debug` to deps.
- `lib/image_pipe/response.ex` — add `ImagePipe.Debug` to deps.
- `lib/image_pipe/request.ex` — add `ImagePipe.Debug` to deps (producer/runner/source_session live under `request`).
- `lib/image_pipe/output/encoder.ex` — return search `meta` from `stream_output/3`.
- `lib/image_pipe/request/source_session/producer.ex` — collect `Info`, thread it in the first-chunk reply.
- `lib/image_pipe/request/source_session.ex` — carry `Info` into `Prepared`; add `:total` timing.
- `lib/image_pipe/request/source_session/prepared.ex` — add `debug` field.
- `lib/image_pipe/response/prepared_stream.ex` — add `debug` field.
- `lib/image_pipe/request/runner.ex` — copy `debug` into `PreparedStream`.
- `lib/image_pipe/response/sender.ex` — render debug headers on the streamed path.
- `test/image_pipe/architecture_boundary_test.exs` — extend if it enumerates boundaries (verify).

---

## Conventions used in this plan

- All `mise exec --` prefixes are required (repo tool versioning).
- Run a single test file with `mise exec -- mix test <path>`; a single test with `mise exec -- mix test <path>:<line>`.
- Commit after every green step. Use Conventional Commits, and append the trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## Phase A — `ImagePipe.Debug` boundary foundation

### Task A1: `ImagePipe.Debug.Timing` helper

**Files:**
- Create: `lib/image_pipe/debug/timing.ex`
- Test: `test/image_pipe/debug/info_test.exs` (shared file; timing tests added under a describe block) — actually create `test/image_pipe/debug/timing_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/debug/timing_test.exs`:

```elixir
defmodule ImagePipe.Debug.TimingTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Debug.Timing

  test "measure/1 returns the function result and a non-negative microsecond duration" do
    {result, us} = Timing.measure(fn -> :work_done end)

    assert result == :work_done
    assert is_integer(us)
    assert us >= 0
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/debug/timing_test.exs`
Expected: FAIL — `module ImagePipe.Debug.Timing is not available`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/image_pipe/debug/timing.ex`:

```elixir
defmodule ImagePipe.Debug.Timing do
  @moduledoc false

  @doc """
  Runs `fun`, returning `{result, microseconds}` where microseconds is the
  wall-clock duration of `fun`. Used to record per-stage durations for the
  `Server-Timing` debug header.
  """
  @spec measure((-> result)) :: {result, non_neg_integer()} when result: term()
  def measure(fun) when is_function(fun, 0) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    {result, System.monotonic_time(:microsecond) - start}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/debug/timing_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/debug/timing.ex test/image_pipe/debug/timing_test.exs
git commit -m "feat(debug): add Timing.measure/1 helper

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task A2: `ImagePipe.Debug.Info` struct

**Files:**
- Create: `lib/image_pipe/debug/info.ex`
- Test: `test/image_pipe/debug/info_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/debug/info_test.exs`:

```elixir
defmodule ImagePipe.Debug.InfoTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Debug.Info

  test "defaults: empty pipeline, empty timings, nil autoquality" do
    info = %Info{}

    assert info.pipeline == []
    assert info.timings == %{}
    assert info.aq == nil
    assert info.source_format == nil
    assert info.output_format == nil
  end

  test "holds source, output, autoquality, pipeline, and timing facts" do
    info = %Info{
      source_format: :jpeg,
      source_width: 4000,
      source_height: 3000,
      output_format: :avif,
      output_width: 1200,
      output_height: 900,
      output_quality: 72,
      aq: %{metric: :ssimulacra2, score: 78.4, min: 60, max: 65},
      pipeline: ["scale", "crop"],
      timings: %{decode: 8, transform: 21, encode: 140, total: 181}
    }

    assert info.source_format == :jpeg
    assert info.aq.metric == :ssimulacra2
    assert info.pipeline == ["scale", "crop"]
    assert info.timings.total == 181
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/debug/info_test.exs`
Expected: FAIL — `ImagePipe.Debug.Info is not available`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/image_pipe/debug/info.ex`:

```elixir
defmodule ImagePipe.Debug.Info do
  @moduledoc """
  Aggregated, non-sensitive facts about how one response was produced, used to
  render the opt-in `X-ImagePipe-*` debug headers. Product-neutral: populated by
  request orchestration from values the source/output/transform layers already
  return. Every field is optional so partial collection degrades gracefully.
  """

  defstruct source_format: nil,
            source_bytes: nil,
            source_width: nil,
            source_height: nil,
            source_color_space: nil,
            source_icc?: nil,
            source_bit_depth: nil,
            source_alpha?: nil,
            source_orientation: nil,
            shrink: nil,
            output_format: nil,
            output_negotiated?: nil,
            output_width: nil,
            output_height: nil,
            output_quality: nil,
            output_stripped?: nil,
            output_color_profile: nil,
            output_distance: nil,
            aq: nil,
            pipeline: [],
            timings: %{}

  @type aq :: %{
          optional(:metric) => :ssimulacra2 | :butteraugli | :size,
          optional(:score) => float() | nil,
          optional(:target) => number() | nil,
          optional(:min) => 1..100,
          optional(:max) => 1..100,
          optional(:iterations) => non_neg_integer(),
          optional(:outcome) => atom(),
          optional(:limiting_factor) => atom() | nil,
          optional(:scorer) => :full | :crop,
          optional(:tiles) => pos_integer() | nil
        }

  @type t :: %__MODULE__{
          source_format: atom() | nil,
          source_bytes: non_neg_integer() | nil,
          source_width: pos_integer() | nil,
          source_height: pos_integer() | nil,
          source_color_space: atom() | nil,
          source_icc?: boolean() | nil,
          source_bit_depth: pos_integer() | nil,
          source_alpha?: boolean() | nil,
          source_orientation: 1..8 | nil,
          shrink: %{w: float(), h: float()} | nil,
          output_format: atom() | nil,
          output_negotiated?: boolean() | nil,
          output_width: pos_integer() | nil,
          output_height: pos_integer() | nil,
          output_quality: 1..100 | :default | nil,
          output_stripped?: boolean() | nil,
          output_color_profile: atom() | nil,
          output_distance: float() | nil,
          aq: aq() | nil,
          pipeline: [String.t()],
          timings: %{optional(atom()) => non_neg_integer()}
        }
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/debug/info_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/debug/info.ex test/image_pipe/debug/info_test.exs
git commit -m "feat(debug): add Info fact struct

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task A3: `ImagePipe.Debug.Headers` renderer

This is the single source of truth for header names. `nil` fields are omitted. `Accept` and cache status are passed in (the sender supplies them from the conn / delivery path).

**Files:**
- Create: `lib/image_pipe/debug/headers.ex`
- Test: `test/image_pipe/debug/headers_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/debug/headers_test.exs`:

```elixir
defmodule ImagePipe.Debug.HeadersTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Debug.Headers
  alias ImagePipe.Debug.Info

  defp header(headers, name), do: List.keyfind(headers, name, 0)

  test "renders source, output, pipeline, cache status and Server-Timing" do
    info = %Info{
      source_format: :jpeg,
      source_width: 4000,
      source_height: 3000,
      source_color_space: :srgb,
      source_icc?: true,
      source_bit_depth: 8,
      source_alpha?: false,
      source_orientation: 6,
      shrink: %{w: 2.0, h: 2.0},
      output_format: :avif,
      output_negotiated?: true,
      output_width: 1200,
      output_height: 900,
      output_quality: 72,
      output_stripped?: true,
      output_color_profile: :srgb,
      pipeline: ["scale", "crop"],
      timings: %{decode: 8, transform: 21, encode: 140, total: 181}
    }

    headers = Headers.render(info, accept: "image/avif,image/*", cache: :miss)

    assert header(headers, "x-imagepipe-source-format") == {"x-imagepipe-source-format", "jpeg"}
    assert header(headers, "x-imagepipe-source-width") == {"x-imagepipe-source-width", "4000"}
    assert header(headers, "x-imagepipe-source-icc") == {"x-imagepipe-source-icc", "true"}
    assert header(headers, "x-imagepipe-source-orientation") ==
             {"x-imagepipe-source-orientation", "6"}

    assert header(headers, "x-imagepipe-shrink") == {"x-imagepipe-shrink", "w=2.0;h=2.0"}

    assert header(headers, "x-imagepipe-output-format") == {"x-imagepipe-output-format", "avif"}
    assert header(headers, "x-imagepipe-output-negotiated") ==
             {"x-imagepipe-output-negotiated", "true"}

    assert header(headers, "x-imagepipe-output-accept") ==
             {"x-imagepipe-output-accept", "image/avif,image/*"}

    assert header(headers, "x-imagepipe-output-width") == {"x-imagepipe-output-width", "1200"}
    assert header(headers, "x-imagepipe-output-quality") == {"x-imagepipe-output-quality", "72"}

    assert header(headers, "x-imagepipe-pipeline") == {"x-imagepipe-pipeline", "scale,crop"}
    assert header(headers, "x-imagepipe-cache") == {"x-imagepipe-cache", "miss"}

    {"server-timing", server_timing} = header(headers, "server-timing")
    assert server_timing =~ "decode;dur=8"
    assert server_timing =~ "transform;dur=21"
    assert server_timing =~ "encode;dur=140"
    assert server_timing =~ "total;dur=181"
  end

  test "omits nil fields" do
    info = %Info{source_format: :png}
    headers = Headers.render(info, accept: "", cache: :miss)

    assert header(headers, "x-imagepipe-source-format") == {"x-imagepipe-source-format", "png"}
    refute header(headers, "x-imagepipe-source-width")
    refute header(headers, "x-imagepipe-output-format")
    refute header(headers, "x-imagepipe-output-accept")
  end

  test "renders autoquality block including per-format quality bounds" do
    info = %Info{
      output_format: :avif,
      aq: %{
        metric: :ssimulacra2,
        score: 78.4,
        target: 78.0,
        min: 60,
        max: 65,
        iterations: 5,
        outcome: :hit,
        limiting_factor: :ceiling,
        scorer: :crop,
        tiles: 9
      }
    }

    headers = Headers.render(info, accept: "", cache: :miss)

    assert header(headers, "x-imagepipe-aq-metric") == {"x-imagepipe-aq-metric", "ssimulacra2"}
    assert header(headers, "x-imagepipe-aq-score") == {"x-imagepipe-aq-score", "78.4"}
    assert header(headers, "x-imagepipe-aq-target") == {"x-imagepipe-aq-target", "78.0"}
    assert header(headers, "x-imagepipe-aq-quality-min") == {"x-imagepipe-aq-quality-min", "60"}
    assert header(headers, "x-imagepipe-aq-quality-max") == {"x-imagepipe-aq-quality-max", "65"}
    assert header(headers, "x-imagepipe-aq-iterations") == {"x-imagepipe-aq-iterations", "5"}
    assert header(headers, "x-imagepipe-aq-outcome") == {"x-imagepipe-aq-outcome", "hit"}
    assert header(headers, "x-imagepipe-aq-limiting-factor") ==
             {"x-imagepipe-aq-limiting-factor", "ceiling"}

    assert header(headers, "x-imagepipe-aq-scorer") == {"x-imagepipe-aq-scorer", "crop"}
    assert header(headers, "x-imagepipe-aq-tiles") == {"x-imagepipe-aq-tiles", "9"}
  end

  test "renders JXL output distance" do
    info = %Info{output_format: :jpeg_xl, output_distance: 1.0}
    headers = Headers.render(info, accept: "", cache: :miss)
    assert header(headers, "x-imagepipe-output-distance") == {"x-imagepipe-output-distance", "1.0"}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/debug/headers_test.exs`
Expected: FAIL — `ImagePipe.Debug.Headers is not available`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/image_pipe/debug/headers.ex`:

```elixir
defmodule ImagePipe.Debug.Headers do
  @moduledoc """
  Pure rendering of `ImagePipe.Debug.Info` into the opt-in `X-ImagePipe-*` debug
  response headers and the standard `Server-Timing` header. This module is the
  single source of truth for debug header names. `nil` facts are omitted.
  """

  alias ImagePipe.Debug.Info

  @stage_order [:decode, :transform, :encode, :cache, :total]

  @doc """
  Renders the debug headers for `info`.

  Options:
    * `:accept` — the request `Accept` header value (string), rendered as
      `x-imagepipe-output-accept`. Omitted when empty/nil.
    * `:cache` — `:hit` or `:miss`, rendered as `x-imagepipe-cache`.
    * `:cache_serve_us` — when serving from cache, the live cache-read duration
      in microseconds, appended to `Server-Timing` as `cache;dur=…` (Plan 2).
  """
  @spec render(Info.t(), keyword()) :: [{String.t(), String.t()}]
  def render(%Info{} = info, opts) do
    accept = Keyword.get(opts, :accept)
    cache = Keyword.get(opts, :cache, :miss)
    cache_serve_us = Keyword.get(opts, :cache_serve_us)

    (source_headers(info) ++
       output_headers(info, accept) ++
       aq_headers(info.aq) ++
       pipeline_headers(info) ++
       cache_headers(cache) ++
       server_timing(info.timings, cache_serve_us))
    |> Enum.reject(&is_nil/1)
  end

  defp source_headers(%Info{} = info) do
    [
      kv("x-imagepipe-source-format", info.source_format),
      kv("x-imagepipe-source-size", info.source_bytes),
      kv("x-imagepipe-source-width", info.source_width),
      kv("x-imagepipe-source-height", info.source_height),
      kv("x-imagepipe-source-color-space", info.source_color_space),
      kv("x-imagepipe-source-icc", info.source_icc?),
      kv("x-imagepipe-source-bit-depth", info.source_bit_depth),
      kv("x-imagepipe-source-alpha", info.source_alpha?),
      kv("x-imagepipe-source-orientation", info.source_orientation),
      shrink_header(info.shrink)
    ]
  end

  defp output_headers(%Info{} = info, accept) do
    [
      kv("x-imagepipe-output-format", info.output_format),
      kv("x-imagepipe-output-negotiated", info.output_negotiated?),
      accept_header(accept),
      kv("x-imagepipe-output-width", info.output_width),
      kv("x-imagepipe-output-height", info.output_height),
      kv("x-imagepipe-output-quality", quality_value(info.output_quality)),
      kv("x-imagepipe-output-stripped", info.output_stripped?),
      kv("x-imagepipe-output-color-profile", info.output_color_profile),
      kv("x-imagepipe-output-distance", info.output_distance)
    ]
  end

  defp aq_headers(nil), do: []

  defp aq_headers(%{} = aq) do
    [
      kv("x-imagepipe-aq-metric", Map.get(aq, :metric)),
      kv("x-imagepipe-aq-score", Map.get(aq, :score)),
      kv("x-imagepipe-aq-target", Map.get(aq, :target)),
      kv("x-imagepipe-aq-quality-min", Map.get(aq, :min)),
      kv("x-imagepipe-aq-quality-max", Map.get(aq, :max)),
      kv("x-imagepipe-aq-iterations", Map.get(aq, :iterations)),
      kv("x-imagepipe-aq-outcome", Map.get(aq, :outcome)),
      kv("x-imagepipe-aq-limiting-factor", Map.get(aq, :limiting_factor)),
      kv("x-imagepipe-aq-scorer", Map.get(aq, :scorer)),
      kv("x-imagepipe-aq-tiles", Map.get(aq, :tiles))
    ]
  end

  defp pipeline_headers(%Info{pipeline: []}), do: []
  defp pipeline_headers(%Info{pipeline: ops}), do: [kv("x-imagepipe-pipeline", Enum.join(ops, ","))]

  defp cache_headers(cache), do: [kv("x-imagepipe-cache", cache)]

  defp server_timing(timings, cache_serve_us) do
    entries =
      @stage_order
      |> Enum.map(fn stage -> timing_entry(stage, timing_value(stage, timings, cache_serve_us)) end)
      |> Enum.reject(&is_nil/1)

    case entries do
      [] -> [nil]
      entries -> [{"server-timing", Enum.join(entries, ", ")}]
    end
  end

  defp timing_value(:cache, _timings, cache_serve_us), do: cache_serve_us
  defp timing_value(stage, timings, _cache_serve_us), do: Map.get(timings, stage)

  defp timing_entry(_stage, nil), do: nil
  defp timing_entry(stage, us), do: "#{stage};dur=#{us}"

  defp shrink_header(nil), do: nil
  defp shrink_header(%{w: w, h: h}), do: {"x-imagepipe-shrink", "w=#{w};h=#{h}"}

  defp accept_header(accept) when is_binary(accept) and accept != "",
    do: {"x-imagepipe-output-accept", accept}

  defp accept_header(_accept), do: nil

  defp quality_value(:default), do: nil
  defp quality_value(value), do: value

  defp kv(_name, nil), do: nil
  defp kv(name, value), do: {name, to_header_value(value)}

  defp to_header_value(value) when is_binary(value), do: value
  defp to_header_value(value) when is_atom(value), do: Atom.to_string(value)
  defp to_header_value(value), do: to_string(value)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/debug/headers_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/debug/headers.ex test/image_pipe/debug/headers_test.exs
git commit -m "feat(debug): add Headers renderer (single source of header names)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task A4: `ImagePipe.Debug` boundary module + wiring

**Files:**
- Create: `lib/image_pipe/debug.ex`
- Modify: `lib/image_pipe.ex`, `lib/image_pipe/response.ex`, `lib/image_pipe/request.ex`, `lib/image_pipe/plug.ex`

- [ ] **Step 1: Create the boundary module**

Create `lib/image_pipe/debug.ex`:

```elixir
defmodule ImagePipe.Debug do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Plan],
    exports: [
      Headers,
      Info,
      Timing
    ]
end
```

- [ ] **Step 2: Add `ImagePipe.Debug` to dependent boundaries**

In `lib/image_pipe.ex`, add `ImagePipe.Debug` to the `deps:` list (alphabetical, after `ImagePipe.Cache`):

```elixir
  use Boundary,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Error,
      ImagePipe.Parser,
      ImagePipe.Plan,
      ImagePipe.Request,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: [Plug]
```

In `lib/image_pipe/plug.ex`, add `ImagePipe.Debug` to its `deps:` list (after `ImagePipe.Error`):

```elixir
  use Boundary,
    deps: [
      ImagePipe.Debug,
      ImagePipe.Error,
      ImagePipe.Parser,
      ImagePipe.Plan,
      ImagePipe.Request,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: []
```

In `lib/image_pipe/response.ex`, add `ImagePipe.Debug` to `deps:` (after `ImagePipe.Cache`):

```elixir
  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Error,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Telemetry
    ],
    exports: [
      CacheHeaders,
      Json,
      PreparedStream,
      Sender
    ]
```

In `lib/image_pipe/request.ex`, open the file and add `ImagePipe.Debug` to the `deps:` list of the `ImagePipe.Request` boundary (keep alphabetical order). If the request boundary lists transform/output/etc., insert `ImagePipe.Debug` accordingly.

- [ ] **Step 3: Compile with warnings as errors**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile, no Boundary violations. If Boundary reports a missing dep, add `ImagePipe.Debug` to the offending boundary's `deps`.

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/debug.ex lib/image_pipe.ex lib/image_pipe/plug.ex lib/image_pipe/response.ex lib/image_pipe/request.ex
git commit -m "feat(debug): add Debug boundary and wire dependents

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase B — Gate: mount option + `_debug` request flag

### Task B1: `allow_debug_headers` mount option

**Files:**
- Modify: `lib/image_pipe/request/options.ex:14-29` (validated keys) and `:65-118` (schema)
- Test: `test/image_pipe/request/options_test.exs` (create if it does not exist; otherwise add a describe block)

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/request/options_test.exs` (create the file with this content if absent):

```elixir
defmodule ImagePipe.Request.OptionsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Request.Options

  test "allow_debug_headers defaults to false" do
    opts = Options.validate!(parser: ImagePipe.Parser.Imgproxy)
    assert Keyword.fetch!(opts, :allow_debug_headers) == false
  end

  test "allow_debug_headers can be enabled" do
    opts = Options.validate!(parser: ImagePipe.Parser.Imgproxy, allow_debug_headers: true)
    assert Keyword.fetch!(opts, :allow_debug_headers) == true
  end

  test "allow_debug_headers rejects non-boolean" do
    assert_raise ArgumentError, fn ->
      Options.validate!(parser: ImagePipe.Parser.Imgproxy, allow_debug_headers: "yes")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/request/options_test.exs`
Expected: FAIL — `key :allow_debug_headers not found` (default not applied because the key is neither in the validated keys nor the schema).

- [ ] **Step 3: Implement**

In `lib/image_pipe/request/options.ex`, add `:allow_debug_headers` to `@validated_option_keys` (after `:auto_jpeg_xl`):

```elixir
  @validated_option_keys [
    :parser,
    :clock,
    :telemetry_prefix,
    :http_cache,
    :detector,
    :detector_required,
    :max_body_bytes,
    :max_input_pixels,
    :max_result_width,
    :max_result_height,
    :max_result_pixels,
    :auto_avif,
    :auto_webp,
    :auto_jpeg_xl,
    :allow_debug_headers
  ]
```

And add it to `@options_schema` (after the `auto_jpeg_xl` entry, before the closing `)`):

```elixir
                    auto_jpeg_xl: [
                      type: :boolean,
                      default: true
                    ],
                    allow_debug_headers: [
                      type: :boolean,
                      default: false
                    ]
                  )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/request/options_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/request/options.ex test/image_pipe/request/options_test.exs
git commit -m "feat(debug): add allow_debug_headers mount option

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task B2: parse `_debug` flag into opts at the Plug boundary

The flag is honored only when `allow_debug_headers` is true. We read it from the query params and put `debug?: true|false` into `opts` so it flows to the runner/producer/sender. We do **not** strip it from the conn; because the cache key/ETag derive from the parsed plan + Accept (not the raw query string), a stray `_debug` param does not enter them — Task G2 proves this with an invariance test.

**Files:**
- Modify: `lib/image_pipe/plug.ex` (`do_call/2`, the second clause at lines 58-73)

- [ ] **Step 1: Write a helper + thread it (no separate unit test; covered by the wire tests in Phase G)**

In `lib/image_pipe/plug.ex`, modify the main `do_call/2` clause to compute the debug flag and add it to `opts` before parsing:

Before:

```elixir
  defp do_call(%Plug.Conn{} = conn, opts) do
    parser = Keyword.fetch!(opts, :parser)

    case parse(conn, parser, opts) do
```

After:

```elixir
  defp do_call(%Plug.Conn{} = conn, opts) do
    parser = Keyword.fetch!(opts, :parser)
    opts = put_debug_flag(conn, opts)

    case parse(conn, parser, opts) do
```

Add these private helpers near the bottom of the module (before the final `end`):

```elixir
  # `_debug=1` is the per-request trigger, honored only when the mount opted in
  # via `allow_debug_headers`. It is a reserved query param: it does not affect
  # the parsed plan, cache key, or ETag (those derive from the plan + Accept), so
  # it needs no stripping — only gating.
  defp put_debug_flag(%Plug.Conn{} = conn, opts) do
    Keyword.put(opts, :debug?, debug_requested?(conn, opts))
  end

  defp debug_requested?(%Plug.Conn{} = conn, opts) do
    Keyword.get(opts, :allow_debug_headers, false) and debug_param_truthy?(conn)
  end

  defp debug_param_truthy?(%Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case conn.query_params do
      %{"_debug" => value} -> value in ["1", "true", ""]
      _ -> false
    end
  end
```

- [ ] **Step 2: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile.

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/plug.ex
git commit -m "feat(debug): gate _debug query flag behind allow_debug_headers

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase C — Encoder returns autoquality meta

`Encoder.stream_output/3` currently returns `{:ok, Enumerable.t(), String.t()}` and discards the search `meta` in `search_output/5`. We change it to also return `meta` (or `nil` on the non-search path) so the producer can collect `AQ-*` facts.

### Task C1: surface search meta from the encoder

**Files:**
- Modify: `lib/image_pipe/output/encoder.ex` (`stream_output/3` at 38-49; `deliver/5` and the non-search path; `search_output/5` at 118-125)
- Modify: `lib/image_pipe/request/source_session/producer.ex` (`encode_first_chunk/3`)
- Test: extend `test/image_pipe/output/encoder_test.exs` if present (otherwise rely on the wire test in Phase G; add a focused test here)

- [ ] **Step 1: Read the full encode path**

Open `lib/image_pipe/output/encoder.ex` and read `deliver/5`, `finalize/2`, and the lazy (non-search) output function it calls. Identify each function that currently returns `{:ok, enumerable, mime_type}`; all of them must return a fourth element `meta` (a map from `EncodeSearch.meta` on the search path, or `nil` on the lazy path).

- [ ] **Step 2: Write the failing test**

Add to `test/image_pipe/output/encoder_test.exs` (create if absent — mirror the existing encoder test setup for building a small `%Resolved{}` and a Vix image; if no such test exists, skip this task's unit test and rely on Phase G's wire assertions, then proceed to Step 4):

```elixir
  test "stream_output returns nil meta on the non-search (lazy) path" do
    image = ImagePipe.Test.Image.solid(64, 64)
    resolved = %ImagePipe.Output.Resolved{
      format: :png,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: false,
      color_profile: :srgb
    }

    assert {:ok, _stream, "image/png", nil} =
             ImagePipe.Output.Encoder.stream_output(image, resolved, [])
  end
```

If `ImagePipe.Test.Image.solid/2` does not exist, build the image the way the existing encoder/transform tests do (check `test/support`), or skip to Step 4 and let Phase G cover it.

- [ ] **Step 3: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output/encoder_test.exs`
Expected: FAIL — match error: `stream_output` returns a 3-tuple.

- [ ] **Step 4: Implement the contract change**

In `lib/image_pipe/output/encoder.ex`:

Update `stream_output/3`'s `@spec` and body to thread a fourth element:

```elixir
  @spec stream_output(VixImage.t(), Resolved.t(), keyword()) ::
          {:ok, Enumerable.t(), String.t(), map() | nil}
          | {:error, {:encode, Exception.t(), list()}}
          | {:error, {:decode, term()}}
  def stream_output(%VixImage{} = image, %Resolved{} = resolved_output, opts) do
    with {:ok, mime_type, suffix} <- output_format(resolved_output),
         {:ok, finalized} <- finalize(image, resolved_output) do
      deliver(finalized, resolved_output, mime_type, suffix, opts)
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end
```

Update `search_output/5` to keep the meta:

```elixir
  defp search_output(finalized, resolved_output, mime_type, scorer, opts) do
    search_opts = [scorer: scorer, telemetry_opts: ImagePipe.Telemetry.telemetry_opts(opts)]

    case EncodeSearch.run(finalized, resolved_output, search_opts) do
      {:ok, binary, meta} -> {:ok, [binary], mime_type, meta}
      {:error, _reason} = err -> err
    end
  end
```

Update `deliver/5` and the lazy/non-search branch(es) so every `{:ok, enumerable, mime_type}` becomes `{:ok, enumerable, mime_type, nil}` on the lazy path. (Exact edits depend on Step 1's reading; ensure all success returns of `deliver/5` carry the fourth element.)

- [ ] **Step 5: Thread meta through the producer**

In `lib/image_pipe/request/source_session/producer.ex`, update `encode_first_chunk/3` to capture the meta and return it. Replace the current body:

```elixir
  defp encode_first_chunk(image, %Resolved{} = resolved_output, opts) do
    Telemetry.span(
      Telemetry.telemetry_opts(opts),
      [:encode],
      %{output_format: resolved_output.format},
      fn ->
        result =
          with {:ok, stream, content_type, search_meta} <-
                 Encoder.stream_output(image, resolved_output, opts),
               {:ok, chunk, stream_state} <- first_chunk(stream) do
            {:ok, chunk, content_type, stream_state, search_meta}
          end

        {result, encode_stop_metadata(result, resolved_output.format)}
      end
    )
  end
```

Update `encode_stop_metadata/2`'s success clause to the new arity:

```elixir
  defp encode_stop_metadata({:ok, _chunk, _content_type, _stream_state, _search_meta}, format),
    do: %{result: :ok, output_format: format}
```

And update the caller in `prepare_first_chunk/1`. The `with` clause currently is:

```elixir
           {:ok, chunk, content_type, stream_state} <-
             encode_first_chunk(image, resolved_output, request.opts) do
```

Change to capture `search_meta`:

```elixir
           {:ok, chunk, content_type, stream_state, search_meta} <-
             encode_first_chunk(image, resolved_output, request.opts) do
```

For now, bind `search_meta` and ignore it (`_ = search_meta`) — Task D2 consumes it. Compile must stay clean, so prefix with underscore if unused: rename the bound var to `search_meta` and add `_ = search_meta` immediately inside the `do` block, or leave it unused only after Task D2 wires it. Simplest: proceed directly to Task D2 in the same change so `search_meta` is consumed.

- [ ] **Step 6: Run tests**

Run: `mise exec -- mix test test/image_pipe/output/encoder_test.exs`
Expected: PASS (if the unit test was added).

Run the broader output/encode suite to catch other callers of `stream_output/3`:
Run: `mise exec -- mix test test/image_pipe/output`
Expected: PASS. If any other caller pattern-matches the 3-tuple, update it to the 4-tuple (grep: `Encoder.stream_output`).

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/output/encoder.ex lib/image_pipe/request/source_session/producer.ex test/image_pipe/output/encoder_test.exs
git commit -m "feat(debug): surface autoquality search meta from the encoder

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase D — Collection + threading

### Task D1: add `debug` field to `Prepared` and `PreparedStream`

**Files:**
- Modify: `lib/image_pipe/request/source_session/prepared.ex`
- Modify: `lib/image_pipe/response/prepared_stream.ex`

- [ ] **Step 1: Add the field to `Prepared`**

Replace `lib/image_pipe/request/source_session/prepared.ex` with:

```elixir
defmodule ImagePipe.Request.SourceSession.Prepared do
  @moduledoc false

  alias ImagePipe.Debug.Info
  alias ImagePipe.Output.Resolved

  @enforce_keys [:first_chunk, :content_type, :headers, :resolved_output]
  defstruct @enforce_keys ++ [debug: nil]

  @type t() :: %__MODULE__{
          first_chunk: binary(),
          content_type: String.t(),
          headers: [{String.t(), String.t()}],
          resolved_output: Resolved.t(),
          debug: Info.t() | nil
        }
end
```

- [ ] **Step 2: Add the field to `PreparedStream`**

Replace `lib/image_pipe/response/prepared_stream.ex` with:

```elixir
defmodule ImagePipe.Response.PreparedStream do
  @moduledoc false

  alias ImagePipe.Debug.Info
  alias ImagePipe.Output.Resolved

  @enforce_keys [:first_chunk, :content_type, :headers, :next, :cancel, :resolved_output]
  defstruct @enforce_keys ++ [debug: nil]

  @type next_result() :: {:chunk, binary()} | :done | {:error, term()}
  @type cancel_result() :: :ok | {:error, term()}

  @type t() :: %__MODULE__{
          first_chunk: binary(),
          content_type: String.t(),
          headers: [{String.t(), String.t()}],
          next: (-> next_result()),
          cancel: (-> cancel_result()),
          resolved_output: Resolved.t(),
          debug: Info.t() | nil
        }
end
```

- [ ] **Step 3: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean (default `nil`, no existing constructor breaks).

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/request/source_session/prepared.ex lib/image_pipe/response/prepared_stream.ex
git commit -m "feat(debug): add debug field to Prepared and PreparedStream

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task D2: assemble `Info` in the producer

The producer's `prepare_first_chunk/1` is where `decoded`, `final_state`, `resolved_output`, `clamp_info`, the delivered `image`, and now `search_meta` are all in scope. We assemble an `Info` there (only when `allow_debug_headers` is set) and add it to the first-chunk reply tuple. Per-stage timings wrap the three measurable stages.

**Files:**
- Modify: `lib/image_pipe/request/source_session/producer.ex`
- Test: covered by Phase G wire tests (assembly is process-internal; a focused unit test would require booting the producer GenServer).

- [ ] **Step 1: Add a collector module reference + helper imports**

At the top of `producer.ex`, add aliases:

```elixir
  alias ImagePipe.Debug.Info
  alias ImagePipe.Debug.Timing
```

(Keep the existing aliases. Do not add `alias ImagePipe.Debug` or `alias ImagePipe.Transform` — they are not used by the debug collection code.)

- [ ] **Step 2: Wrap stages with timing and assemble `Info`**

Rewrite `prepare_first_chunk/1` so that, when `Keyword.get(request.opts, :allow_debug_headers, false)` is true, it measures each stage and builds an `Info`. The structure (preserving the existing `with` and error handling) becomes:

```elixir
  defp prepare_first_chunk(%__MODULE__{request: %Request{} = request} = state) do
    collect? = Keyword.get(request.opts, :allow_debug_headers, false)

    with_stream_translation(&prepare_fallback/2, fn ->
      with {{:ok, decoded}, decode_us} <-
             measure(collect?, fn ->
               Processor.fetch_decode_validate_source_with_source_format(
                 request.plan,
                 request.resolved_source,
                 request.opts
               )
             end),
           {{:ok, %State{} = final_state}, transform_us} <-
             measure(collect?, fn ->
               Processor.process_decoded_source(
                 decoded,
                 request.plan,
                 Keyword.put(
                   request.opts,
                   :supports_hdr?,
                   Policy.supports_hdr?(
                     request.output_policy,
                     request.plan.output,
                     decoded.source_format
                   )
                 )
               )
             end),
           {:ok, %Resolved{} = resolved_output} <-
             resolve_output(
               request.output_policy,
               decoded.source_format,
               final_state.image,
               request.opts
             ),
           limits = effective_limits(resolved_output.format, request.opts),
           {:ok, clamped, clamp_info} <-
             Clamp.clamp(final_state.image, limits, request.opts),
           :ok <- emit_clamp_telemetry(clamp_info, resolved_output.format, request.opts),
           {:ok, %State{image: image}} <-
             Processor.materialize_for_delivery(
               %State{final_state | image: clamped},
               request.opts
             ),
           {{:ok, chunk, content_type, stream_state, search_meta}, encode_us} <-
             measure(collect?, fn ->
               encode_first_chunk(image, resolved_output, request.opts)
             end) do
        debug =
          build_debug(collect?, %{
            request: request,
            decoded: decoded,
            resolved_output: resolved_output,
            image: image,
            search_meta: search_meta,
            timings: %{decode: decode_us, transform: transform_us, encode: encode_us}
          })

        {:ok, chunk,
         %{
           state
           | stream_state: stream_state,
             resolved_output: resolved_output,
             content_type: content_type
         }, debug}
      else
        {:empty, _us} -> :empty
        :empty -> :empty
        {{:error, reason}, _us} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end)
  end
```

Note: `prepare_first_chunk/1` now returns a 4-tuple `{:ok, chunk, state, debug}` (was 3-tuple). Update `next_result/1`'s `prepare_first_chunk` clause accordingly (Step 4).

- [ ] **Step 3: Add the `measure/2` and `build_debug/2` helpers**

Add to `producer.ex`:

```elixir
  # When collecting, return `{result, microseconds}`; otherwise run the stage and
  # return `{result, nil}` so the `with` shape is uniform without timing cost.
  defp measure(false, fun), do: {fun.(), nil}
  defp measure(true, fun), do: Timing.measure(fun)

  defp build_debug(false, _ctx), do: nil

  defp build_debug(true, ctx) do
    %{
      request: request,
      decoded: decoded,
      resolved_output: resolved_output,
      image: image,
      search_meta: search_meta,
      timings: timings
    } = ctx

    %Info{
      source_format: decoded.source_format,
      source_bytes: Map.get(decoded, :source_bytes),
      source_width: dim(decoded, 0),
      source_height: dim(decoded, 1),
      source_color_space: Map.get(decoded, :source_color_space),
      source_icc?: Map.get(decoded, :source_icc?),
      source_bit_depth: Map.get(decoded, :source_bit_depth),
      source_alpha?: Map.get(decoded, :source_alpha?),
      source_orientation: Map.get(decoded, :source_orientation),
      shrink: Map.get(decoded, :achieved_shrink),
      output_format: resolved_output.format,
      output_negotiated?: negotiated?(request.output_policy),
      output_width: Image.width(image),
      output_height: Image.height(image),
      output_quality: output_quality(resolved_output, search_meta),
      output_stripped?: resolved_output.strip_metadata,
      output_color_profile: resolved_output.color_profile,
      output_distance: output_distance(resolved_output, search_meta),
      aq: aq_from_meta(resolved_output, search_meta),
      pipeline: pipeline_names(request.plan),
      timings: timings
    }
  end

  defp dim(decoded, index) do
    case Map.get(decoded, :original_dims) do
      {w, _h} when index == 0 -> w
      {_w, h} when index == 1 -> h
      _ -> nil
    end
  end

  defp negotiated?(%Policy{mode: {:explicit, _format}}), do: false
  defp negotiated?(%Policy{mode: :source}), do: true

  defp output_quality(%Resolved{}, %{quality: q}) when is_integer(q) and q > 0, do: q
  defp output_quality(%Resolved{quality: {:quality, q}}, _meta), do: q
  defp output_quality(%Resolved{quality: :default}, _meta), do: :default

  # Pipeline operation names, in order, derived neutrally from the plan's semantic
  # operations (ImagePipe.Plan.Operation.*). We reflect on the struct module's
  # short name rather than naming any concrete module literal (boundary rule) and
  # do NOT use Transform.transform_name/1 (that operates on translated *transform*
  # operations, not the plan's semantic structs).
  defp pipeline_names(plan) do
    plan.pipelines
    |> Enum.flat_map(fn %{operations: ops} -> ops end)
    |> Enum.map(&operation_name/1)
  end

  defp operation_name(%module{}),
    do: module |> Module.split() |> List.last() |> Macro.underscore()
```

Notes on data sources used above:
  - `decoded.source_bytes`, `decoded.source_color_space`, `decoded.source_icc?`,
    `decoded.source_bit_depth`, `decoded.source_alpha?` — all captured in the
    processor at decode time (Task F1, below). Until F1 lands they are absent and
    `Headers` omits them.
  - `decoded.source_orientation` and `decoded.achieved_shrink` already exist on the
    decoded map (see `Processor` `decoded()` type).
  - Output dimensions use `Image.width/1` / `Image.height/1` on the delivered
    image. The producer already calls `Image.has_alpha?/1` (see `do_resolve_output/3`),
    so the `Image` module is in scope — no new alias needed for this.
  - `pipeline_names/1` needs no `ImagePipe.Transform` alias (it does not call
    Transform); drop `alias ImagePipe.Transform` from the Step 1 alias list if the
    compiler flags it as unused.

- [ ] **Step 4: Update `next_result/1` to carry `debug` in the reply**

In `producer.ex`, update the first `next_result/1` clause to unpack the new 4-tuple and include `debug` in the `:first_chunk` reply:

```elixir
  defp next_result(%__MODULE__{prepared?: false} = state) do
    case prepare_first_chunk(state) do
      {:ok, chunk, state, debug} ->
        reply =
          {:ok,
           {:first_chunk, chunk, state.content_type, state.resolved_output.response_headers,
            state.resolved_output, debug}}

        {:reply, reply, %{state | prepared?: true}}

      :empty ->
        {:stop, {:error, {:encode, :empty_stream}}}

      {:error, reason} ->
        {:stop, {:error, reason}}
    end
  end
```

- [ ] **Step 5: Add `Image` alias if needed**

`build_debug/2` calls `Image.width/1` and `Image.height/1`. Confirm how the producer/processor refer to the image library (the codebase uses `Image.width(...)` per `do_resolve_output` which calls `Image.has_alpha?(image)`). Ensure the corresponding module is available (it already is — `Image.has_alpha?/1` is used in `do_resolve_output/3`).

- [ ] **Step 6: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean. Resolve any reference to a not-yet-existing accessor by implementing it per Step 3's notes.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/request/source_session/producer.ex
git commit -m "feat(debug): collect Info in the producer and carry it in the reply

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task D3: thread `Info` through `SourceSession` into `Prepared`

`SourceSession.handle_producer_result/2` builds `%Prepared{}` and already computes `cost_us`. We unpack the new `debug` element, add `:total` (= `cost_us`) to its timings, and put it on `Prepared`.

**Files:**
- Modify: `lib/image_pipe/request/source_session.ex` (the first `handle_producer_result/2` clause, ~lines 252-285)

- [ ] **Step 1: Update the first-chunk handler**

Replace the first `handle_producer_result/2` clause:

```elixir
  defp handle_producer_result(
         {:ok, {:first_chunk, first_chunk, content_type, headers, resolved_output, debug}},
         %{pending: {:prepare, from}, request: request} = state
       ) do
    with_owner_check(state, fn state ->
      cost_us = System.monotonic_time(:microsecond) - state.fetch_started_at

      cache_sink =
        Cache.open_sink(
          request.cache_key,
          resolved_output,
          Keyword.put(request.opts, :cost_us, cost_us)
        )

      cache_sink = Cache.write_chunk(cache_sink, first_chunk, request.opts)

      prepared = %Prepared{
        first_chunk: first_chunk,
        content_type: content_type,
        headers: headers,
        resolved_output: resolved_output,
        debug: put_total_timing(debug, cost_us)
      }

      GenServer.reply(from, {:ok, prepared})

      {:noreply,
       %{
         state
         | pending: nil,
           phase: :prepared,
           cache_sink: cache_sink,
           resolved_output: resolved_output
       }}
    end)
  end
```

Add a private helper:

```elixir
  defp put_total_timing(nil, _cost_us), do: nil

  defp put_total_timing(%ImagePipe.Debug.Info{} = info, cost_us) do
    %{info | timings: Map.put(info.timings, :total, cost_us)}
  end
```

- [ ] **Step 2: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean. (If Boundary complains that `request` cannot reference `ImagePipe.Debug.Info`, confirm Task A4 added `ImagePipe.Debug` to the `request` boundary deps.)

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/request/source_session.ex
git commit -m "feat(debug): carry Info into Prepared and record total timing

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task D4: copy `debug` into `PreparedStream` in the runner

**Files:**
- Modify: `lib/image_pipe/request/runner.ex` (`prepared_stream/4`, ~lines 193-211)

- [ ] **Step 1: Add the field to the `%PreparedStream{}` construction**

In `prepared_stream/4`, add `debug: prepared.debug` to the struct:

```elixir
      {:ok,
       %PreparedStream{
         first_chunk: prepared.first_chunk,
         content_type: prepared.content_type,
         headers: prepared.headers ++ [{"content-disposition", content_disposition}],
         next: fn -> SourceSession.next(session) end,
         cancel: fn -> cancel_supervised_session(supervisor, session) end,
         resolved_output: prepared.resolved_output,
         debug: prepared.debug
       }}
```

- [ ] **Step 2: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/request/runner.ex
git commit -m "feat(debug): pass Info from Prepared to PreparedStream

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase E — Render on the streamed (miss) path

### Task E1: render debug headers in `send_prepared_stream`

When `opts[:debug?]` is true and the `PreparedStream` carries a `debug` `Info`, render the debug headers (with `cache: :miss` and the request `Accept`) and merge them into the stream headers before delivery.

**Files:**
- Modify: `lib/image_pipe/response/sender.ex` (`send_prepared_stream/5` at ~269-283; add a helper; add `alias ImagePipe.Debug`)

- [ ] **Step 1: Add the alias**

In `sender.ex`, add to the alias block:

```elixir
  alias ImagePipe.Debug
```

- [ ] **Step 2: Inject debug headers before streaming**

Modify `send_prepared_stream/5` to add debug headers into `prepared_stream.headers` when requested. Replace the body:

```elixir
  defp send_prepared_stream(
         %Plug.Conn{} = conn,
         %PreparedStream{} = prepared_stream,
         %Response{},
         %CacheHeaders{} = prepared,
         opts
       ) do
    telemetry_opts = Telemetry.telemetry_opts(opts)
    prepared_stream = maybe_add_debug_headers(prepared_stream, conn, opts)

    Telemetry.span(
      telemetry_opts,
      [:deliver],
      output_metadata(prepared_stream.resolved_output),
      fn ->
        prepared_stream = merge_prepared_stream_headers(conn, prepared_stream, prepared)
        {conn, outcome} = do_send_prepared_stream(conn, prepared_stream)

        {conn, deliver_stop_metadata(outcome, conn, prepared_stream.resolved_output)}
      end
    )
  end
```

Add the helper near the other `merge_*` helpers:

```elixir
  defp maybe_add_debug_headers(%PreparedStream{debug: nil} = prepared_stream, _conn, _opts),
    do: prepared_stream

  defp maybe_add_debug_headers(%PreparedStream{debug: info} = prepared_stream, conn, opts) do
    if Keyword.get(opts, :debug?, false) do
      debug_headers = Debug.Headers.render(info, accept: accept_header(conn), cache: :miss)
      %{prepared_stream | headers: prepared_stream.headers ++ debug_headers}
    else
      prepared_stream
    end
  end
```

(`accept_header/1` already exists in `sender.ex`.)

- [ ] **Step 3: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/response/sender.ex
git commit -m "feat(debug): render debug headers on the streamed miss path

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase F — Source facts at decode

### Task F1: capture source byte size + image facts into `decoded`

`decoded()` (in `Processor`) carries `source_format`, `original_dims`, `source_orientation`, and `achieved_shrink`, but not the source byte count or the source image's color/ICC/bit-depth/alpha facts. Add them so the producer can read them from `decoded` (no image reflection in the producer).

**Files:**
- Modify: `lib/image_pipe/request/processor.ex`
- Test: covered by Phase G (assert `x-imagepipe-source-size` etc. present and well-formed)

- [ ] **Step 1: Read the decode path**

Open `lib/image_pipe/request/processor.ex` and read `fetch_decode_validate_source_with_source_format/3` and the `decoded()` construction (the map with `source_format`, `original_dims`, `source_orientation`, etc.). Identify:
  - where the source byte size is available (the source is buffer/file-seekable, never incremental-stream, so a total byte size is obtainable from the resolved source / fetched body — `byte_size(body)` for a binary, or the file size known to the source layer);
  - which image is the authoritative source header image (the one `original_dims` is read from). Read the project's existing helpers for image header fields — search the codebase for how it reads `Image.has_alpha?/1`, the image `interpretation`, ICC-profile presence, and bits-per-sample (likely `Image.*` from the `image` hex package and/or `Vix.Vips.Image.header_value/2`). Use the same helpers; do not invent new ones.

- [ ] **Step 2: Add the source facts to the decoded map and its `@type`**

Add these optional keys to the `decoded()` `@type` and populate them in the decoded map, all read from the source header image identified in Step 1 (and the source bytes from the body/file):

```
optional(:source_bytes) => non_neg_integer(),
optional(:source_color_space) => atom(),
optional(:source_icc?) => boolean(),
optional(:source_bit_depth) => pos_integer(),
optional(:source_alpha?) => boolean()
```

Concretely:
  - `:source_bytes` — `byte_size(body)` (binary) or the known file size.
  - `:source_color_space` — the source image interpretation as an atom (e.g. `:srgb`, `:cmyk`, `:b_w`).
  - `:source_icc?` — whether the source image header carries an `icc-profile-data` field.
  - `:source_bit_depth` — bits-per-sample from the source image header.
  - `:source_alpha?` — `Image.has_alpha?/1` on the source image.

If any single fact is genuinely unavailable from the header for some format, set it to `nil` (the renderer omits nil) rather than failing the decode — these are best-effort debug facts and must never break decoding.

- [ ] **Step 3: Confirm the producer reads them**

`build_debug/2` (Task D2) reads each of these via `Map.get(decoded, :source_*)`. No producer change needed once the fields exist.

- [ ] **Step 4: Compile + targeted test**

Run: `mise exec -- mix compile --warnings-as-errors`
Then run the processor/decode tests:
Run: `mise exec -- mix test test/image_pipe/request`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/request/processor.ex
git commit -m "feat(debug): capture source byte size and image facts during decode

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase G — Integration tests + boundary + gate

### Task G1: wire-level miss-path test

**Files:**
- Create: `test/image_pipe/debug_headers_wire_test.exs`

- [ ] **Step 1: Read an existing wire test for the harness pattern**

Open `test/image_pipe/imgproxy_wire_conformance_test.exs` and note how it: builds a `Plug.Conn` (via `Plug.Test`), stubs/provides a source (the local source adapter / fixture), mounts the imgproxy parser with options, calls `ImagePipe.Plug.call/2`, and decodes the response body to assert dimensions. Reuse that exact setup (source stubbing helper, option keyword list) in the new file.

- [ ] **Step 2: Write the failing test**

Create `test/image_pipe/debug_headers_wire_test.exs`. Mirror the conformance test's setup helpers; the assertions are:

```elixir
defmodule ImagePipe.DebugHeadersWireTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  # Reuse the conformance suite's setup: replace these two helpers with the real
  # ones from test/image_pipe/imgproxy_wire_conformance_test.exs (source stub +
  # base opts). They are named here for clarity.
  #   - debug_opts/1: base imgproxy mount opts merged with the given overrides
  #   - request_path/0: an imgproxy URL that resizes a known fixture

  defp call(path, opts) do
    conn(:get, path) |> ImagePipe.Plug.call(ImagePipe.Plug.init(opts))
  end

  defp header(conn, name), do: get_resp_header(conn, name) |> List.first()

  test "no debug headers without _debug, even when allowed" do
    conn = call(request_path(), debug_opts(allow_debug_headers: true))
    assert conn.status == 200
    assert header(conn, "x-imagepipe-output-format") == nil
    assert header(conn, "server-timing") == nil
  end

  test "no debug headers with _debug when not allowed" do
    conn = call(request_path() <> "?_debug=1", debug_opts(allow_debug_headers: false))
    assert conn.status == 200
    assert header(conn, "x-imagepipe-output-format") == nil
  end

  test "debug headers present with _debug=1 when allowed (cache miss)" do
    conn = call(request_path() <> "?_debug=1", debug_opts(allow_debug_headers: true))

    assert conn.status == 200
    assert header(conn, "x-imagepipe-cache") == "miss"
    assert header(conn, "x-imagepipe-source-format") != nil
    assert header(conn, "x-imagepipe-source-width") =~ ~r/^\d+$/
    assert header(conn, "x-imagepipe-source-size") =~ ~r/^\d+$/
    assert header(conn, "x-imagepipe-output-format") != nil
    assert header(conn, "x-imagepipe-output-width") =~ ~r/^\d+$/
    assert header(conn, "x-imagepipe-pipeline") != nil

    server_timing = header(conn, "server-timing")
    assert server_timing =~ "total;dur="
    assert server_timing =~ "encode;dur="
  end
end
```

- [ ] **Step 3: Run test to verify it fails, then passes**

Run: `mise exec -- mix test test/image_pipe/debug_headers_wire_test.exs`
Expected (before the full chain is wired): some assertions FAIL. After Phases A–F are complete, all PASS. Fix any wiring gaps surfaced here (most likely an accessor name in `build_debug/2`).

- [ ] **Step 4: Commit**

```bash
git add test/image_pipe/debug_headers_wire_test.exs
git commit -m "test(debug): wire-level miss-path debug header coverage

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task G2: cache-key / ETag invariance test

Proves `_debug=1` does not change the cache key or the ETag (so a conditional GET still `304`s and `_debug` shares the same cache entry).

**Files:**
- Modify: `test/image_pipe/debug_headers_wire_test.exs` (add a describe block)

- [ ] **Step 1: Write the test**

Add to `test/image_pipe/debug_headers_wire_test.exs`:

```elixir
  describe "cache identity invariance" do
    test "_debug does not change the generated ETag" do
      opts = debug_opts(allow_debug_headers: true, http_cache: [mode: :enabled])

      plain = call(request_path(), opts)
      debug = call(request_path() <> "?_debug=1", opts)

      plain_etag = header(plain, "etag")
      debug_etag = header(debug, "etag")

      assert is_binary(plain_etag)
      assert plain_etag == debug_etag
    end

    test "conditional GET with _debug still 304s against the plain ETag" do
      opts = debug_opts(allow_debug_headers: true, http_cache: [mode: :enabled])
      etag = header(call(request_path(), opts), "etag")

      conn =
        conn(:get, request_path() <> "?_debug=1")
        |> put_req_header("if-none-match", etag)
        |> ImagePipe.Plug.call(ImagePipe.Plug.init(opts))

      assert conn.status == 304
    end
  end
```

- [ ] **Step 2: Run**

Run: `mise exec -- mix test test/image_pipe/debug_headers_wire_test.exs`
Expected: PASS. If the ETags differ, the parser is folding `_debug` into the plan — strip `_debug` from the conn query in `ImagePipe.Plug.do_call/2` before `parse/3` (rebuild `conn.query_string`/`query_params` without `_debug`) and re-run.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/debug_headers_wire_test.exs
git commit -m "test(debug): assert _debug does not affect cache key or ETag

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task G3: autoquality wire coverage

Exercises the `AQ-*` headers and `Output-Distance` through a real search request.

**Files:**
- Modify: `test/image_pipe/debug_headers_wire_test.exs`

- [ ] **Step 1: Write the test**

Add a test that issues an imgproxy autoquality request (e.g. `.../autoquality:ssim2:...` per the imgproxy parser grammar; copy the exact option string form from an existing autoquality test in the suite) with `_debug=1`, and asserts:

```elixir
  test "autoquality request emits AQ-* headers" do
    opts = debug_opts(allow_debug_headers: true)
    # Replace `autoquality_path/0` with an imgproxy URL that triggers an ssim2
    # quality search on the fixture (copy the option string from the existing
    # autoquality wire/parser tests).
    conn = call(autoquality_path() <> "?_debug=1", opts)

    assert conn.status == 200
    assert header(conn, "x-imagepipe-aq-metric") == "ssimulacra2"
    assert header(conn, "x-imagepipe-aq-iterations") =~ ~r/^\d+$/
    assert header(conn, "x-imagepipe-aq-outcome") != nil
    assert header(conn, "x-imagepipe-aq-quality-min") =~ ~r/^\d+$/
    assert header(conn, "x-imagepipe-aq-quality-max") =~ ~r/^\d+$/
  end
```

- [ ] **Step 2: Run, fix, commit**

Run: `mise exec -- mix test test/image_pipe/debug_headers_wire_test.exs`
Expected: PASS.

```bash
git add test/image_pipe/debug_headers_wire_test.exs
git commit -m "test(debug): autoquality AQ-* wire coverage

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task G4: boundary architecture check

**Files:**
- Modify/verify: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Inspect the boundary test**

Open `test/image_pipe/architecture_boundary_test.exs`. If it enumerates the set of top-level boundaries or asserts specific dep directions, add `ImagePipe.Debug` (deps: `[ImagePipe.Plan]`) and the new edges (`request`/`response`/`plug`/`ImagePipe` → `debug`). If it only asserts the request-must-not-name-concrete-transform-modules rule, confirm `producer.ex`'s use of `Transform.plan_operations/1` + `Transform.transform_name/1` does not name a concrete operation module (it must not).

- [ ] **Step 2: Run**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS.

- [ ] **Step 3: Commit (only if the file changed)**

```bash
git add test/image_pipe/architecture_boundary_test.exs
git commit -m "test(debug): cover Debug boundary in architecture test

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task G5: full gate (precommit)

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
(Runs `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`.)
Expected: all green. Fix formatting (`mise exec -- mix format`), credo findings, and any failing tests.

- [ ] **Step 2: Final commit if formatting changed**

```bash
git add -A
git commit -m "chore(debug): formatting and gate fixes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review (completed during authoring)

- **Spec coverage (Plan 1 scope):** gate (B1/B2), Server-Timing (A3/D2/D3/E1), source facts (D2/F1), output facts (D2), autoquality incl. quality-min/max + distance (C1/D2/A3/G3), pipeline (D2), cache=miss tag (A3/E1), boundary (A4/G4). Cache-hit replay, `Cache-Key`, fiddle, and docs are explicitly deferred to Plans 2–3.
- **Known verification points flagged inline** (Task D2 Step 3, Task F1 Step 1, Task C1 Step 1): producer image accessors, the `Transform` operation-enumeration facade name, the encoder `deliver/5` branches, and the source byte-size capture point. These require reading one function before writing and are called out as explicit steps, not left as silent assumptions.
- **Type consistency:** `prepare_first_chunk/1` returns a 4-tuple consumed in `next_result/1`; the `:first_chunk` reply is a 6-tuple consumed in `SourceSession.handle_producer_result/2`; `Encoder.stream_output/3` returns a 4-tuple consumed in `encode_first_chunk/3`; `Info`/`Headers` field names match across A2/A3/D2.
```
