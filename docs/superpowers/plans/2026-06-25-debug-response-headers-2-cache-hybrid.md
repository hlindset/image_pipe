# Debug Response Headers — Plan 2: Cache Hybrid / Hit-Path Replay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the collected `Debug.Info` in every cache entry (unconditionally) and replay it on a cache hit — rendering the stored generation facts merged with a live cache-serve timing and tagged `X-ImagePipe-Cache: hit`, plus a new `X-ImagePipe-Cache-Key` header on both paths.

**Architecture:** Plan 1 collects an `ImagePipe.Debug.Info` in the producer and renders it on the streamed (miss) path, gated by `allow_debug_headers`. Plan 2 (a) makes collection/storage **unconditional** (decoupled from `allow_debug_headers`, which now gates *output* only), (b) stores the `Info` in `Cache.Entry.Metadata.debug` and reshapes the filesystem serialization in place (no version bump), (c) reconstructs the `Info` onto `Cache.Entry` on a hit, and (d) renders it in `Response.Sender.send_cache_entry/6` with a live `cache;dur=` Server-Timing entry. Because the mount flag is not in the cache key, an entry cached while debug was off is reused — and already carries the facts — so flipping `allow_debug_headers: true` immediately yields debug headers for already-cached items with no invalidation.

**Tech Stack:** Elixir, Plug, Vix/libvips, Boundary, `:erlang.term_to_binary`, ExUnit.

**Spec:** `docs/superpowers/specs/2026-06-25-debug-response-headers-design.md` (esp. *Collection vs. rendering*, *Interaction with cache key and ETag*, *Cache storage (hybrid behavior)*).

**Depends on:** Plan 1 (`docs/superpowers/plans/2026-06-25-debug-response-headers-1-boundary-and-miss-path.md`), merged to `main` as #392/#395.

---

## Scope of Plan 2

In scope:
- Make generation-path collection + storage **unconditional** (delete the `collect?` gate in the producer and the `allow_debug_headers` gate in the processor).
- Add a `debug` field to `Cache.Entry.Metadata` and `Cache.Entry`; populate it in `cache/sink.ex` on every write.
- Reshape `cache/file_system.ex` serialize / deserialize / `validate_metadata` **in place** to carry `debug` (no `@metadata_version` bump).
- Best-effort source-fact collection hardening: one boundary `rescue` around `source_debug_facts/3` that emits a new one-shot `[:debug, :collect, :error]` telemetry event and degrades to `%{}`; wire that event into the Logger, OTel Capture, and `docs/telemetry.md`.
- `X-ImagePipe-Cache-Key` header (this phase owns `Cache.Key` stringification), on both the miss and hit paths.
- Hit-path render in `response/sender.ex`: stored `Info` + `X-ImagePipe-Cache: hit` + a live `cache;dur=` Server-Timing entry.
- Wire tests: miss→hit replay, retroactive toggle, same-entry sharing, no-headers-when-not-requested; metadata round-trip; cache-key/ETag invariance for the flag.

Out of scope (Plan 3):
- Fiddle consumption and operator/header-catalogue docs.

---

## Key design decisions (read before implementing)

1. **Store the FULL producer `Info`; read request-invariant fields from it on a hit.** The spec's "re-derived on a hit" set is `Output-Format`, `Output-Negotiated`, `Output-Accept`, `Pipeline`, `Cache-Key`, `Cache` status. Of these, **`Output-Format` / `Output-Negotiated` / `Pipeline` are cache-key-determining** — every input that selects them (negotiated/explicit format, output mode, the plan's pipeline operations) is folded into `Cache.Key`. So two requests that share a cache entry necessarily share those values, and reading them from the stored `Info` is byte-identical to re-deriving them from the current request. The genuinely request-specific facts are supplied **live** via render options: the **raw `Accept` string** (which can differ between two requests that negotiate to the same format → same entry), the **`Cache` status** (`:hit`), the **`Cache-Key`**, and the **cache-serve timing**. This keeps the sender from needing the plan/policy on the hit path. *(This is the one deliberate divergence from the spec's literal split — same output, less plumbing. Flag it for the compatibility/spec reviewer.)*

2. **`cost_us` stays.** It is load-bearing for the bounded-cache Admission cost model (`FileSystem.build_descriptor/2` and `read_descriptor/1` read `metadata.cost_us`). The debug Server-Timing uses `Info.timings` (which already carries `:total` = `cost_us` via `SourceSession.put_total_timing/2`). Keep `cost_us` in `Metadata`, the sink, and the filesystem serialize/validate; do **not** remove it.

3. **No `@metadata_version` bump (greenfield).** `validate_metadata/1` adds `debug:` to its strict map pattern, so any stale dev-disk entry lacking the field fails validation → `:invalid_metadata` → treated as a miss → regenerate. `:erlang.binary_to_term(_, [:safe])` decodes the `Info` struct because its atoms (format/interpretation/metric names) are loaded module constants; a genuinely-unknown atom raises `ArgumentError`, which the existing `decode_metadata/1` rescue maps to `:decode_failed` → miss.

4. **Fully-unconditional collection.** Collection costs one GC'd struct + a few `System.monotonic_time` calls per request even when nothing renders — noise against decode/encode. We do **not** gate on "caching enabled". `allow_debug_headers` and `_debug` continue to gate *rendering* only.

5. **Delivery tuple `{:cache_entry, …}` grows from 4 to 5 elements** (the 5th is a `hit_debug` map `%{cache_key, cache_serve_us}`), and `send_cache_entry/5` becomes `/6`. The runner measures the cache-serve duration with `Debug.Timing.measure/1` around the `[:cache, :lookup]` span and passes `key.hash`.

6. **`Cache-Key` on both paths.** `Debug.Headers.render/2` gains a `:cache_key` option. The miss path threads `key.hash` via a new `PreparedStream.cache_key` field; the hit path passes it via `hit_debug`.

---

## File Structure

**Create:** none (all changes extend existing modules and test files).

**Modify (library):**
- `lib/image_pipe/cache.ex` — add `ImagePipe.Debug` to the `cache` boundary `deps`.
- `lib/image_pipe/cache/entry/metadata.ex` — add `debug` field.
- `lib/image_pipe/cache/entry.ex` — add `debug` field (read side).
- `lib/image_pipe/cache/sink.ex` — populate `Metadata.debug` from a `:debug_info` opt.
- `lib/image_pipe/request/source_session.ex` — pass the (total-timed) `Info` into `Cache.open_sink`.
- `lib/image_pipe/cache/file_system.ex` — serialize / validate / deserialize `debug`; reconstruct it onto `Entry`.
- `lib/image_pipe/request/processor.ex` — always collect source facts; one boundary rescue; emit `[:debug, :collect, :error]`.
- `lib/image_pipe/request/source_session/producer.ex` — delete the `collect?` gate; always measure + build `Info`.
- `lib/image_pipe/telemetry/logger.ex` — subscribe + render + escalate the new event.
- `lib/image_pipe/telemetry/trace/capture.ex` — capture the new one-shot.
- `lib/image_pipe/debug/headers.ex` — add the `:cache_key` option + `x-imagepipe-cache-key`.
- `lib/image_pipe/response/prepared_stream.ex` — add `cache_key` field.
- `lib/image_pipe/request/runner.ex` — measure cache-serve; build the 5-tuple on a hit; thread `cache_key` into `PreparedStream`.
- `lib/image_pipe/response/sender.ex` — render stored `Info` on the hit path; pass `cache_key` on the miss path.

**Modify (tests/docs):**
- `test/image_pipe/debug/headers_test.exs` — `:cache_key` rendering.
- `test/image_pipe/telemetry/logger_test.exs` — the new warning event.
- `test/image_pipe/telemetry/trace/capture_test.exs` and `.../open_telemetry_exporter_test.exs` — the new one-shot.
- `test/image_pipe/cache/file_system_test.exs` — `debug: nil` in the `metadata/3` fixture helper (validation tests) + metadata `debug` round-trip.
- `test/image_pipe/request_runner_test.exs` — widen the `:cache_entry` 4-tuple assertions to 5-tuple.
- `test/image_pipe/debug_headers_wire_test.exs` — miss→hit, retroactive toggle, entry sharing.
- `docs/telemetry.md` — document `[:debug, :collect, :error]`.
- `docs/imgproxy_support_matrix.md` — prose note if the surface changes (confirm with the compatibility reviewer).

---

## Conventions used in this plan

- All `mise exec --` prefixes are required (repo tool versioning).
- Run a single test file with `mise exec -- mix test <path>`; a single test with `mise exec -- mix test <path>:<line>`.
- Commit after every green step. Use Conventional Commits, and append the trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- This is a fresh worktree: if `mise exec -- mix ...` fails on trust/deps, run `mise trust` then `mise exec -- mix deps.get` once before proceeding.

---

## Phase A — Storage shape: boundary + `debug` field

### Task A1: add `ImagePipe.Debug` to the `cache` boundary deps

Plan 1 added `ImagePipe.Debug` to the `request`, `response`, `plug`, and `ImagePipe` boundaries but not `cache` (cache had no debug surface then). The `Metadata`/`Sink`/`FileSystem` modules now reference `ImagePipe.Debug.Info`, so the `cache` boundary must depend on `debug` (`debug → plan` only, so no cycle).

**Files:**
- Modify: `lib/image_pipe/cache.ex` (the `use Boundary, deps:` list, ~lines 6–19)

- [ ] **Step 1: Add the dep**

In `lib/image_pipe/cache.ex`, add `ImagePipe.Debug` to `deps` (the current list — `Error, Format, Plan, Output, Telemetry` — is not strictly alphabetical, so credo does not enforce order; the code block below places `Debug` first for readability):

```elixir
  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Debug,
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Output,
      ImagePipe.Telemetry
    ],
    exports: [
      Entry,
      Key,
      FileSystem
    ]
```

- [ ] **Step 2: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile (no new references yet; this only authorizes the upcoming ones).

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/cache.ex
git commit -m "feat(debug): allow cache boundary to depend on Debug

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task A2: add `debug` to `Cache.Entry.Metadata`

**Files:**
- Modify: `lib/image_pipe/cache/entry/metadata.ex`

- [ ] **Step 1: Add the field and type**

Replace `lib/image_pipe/cache/entry/metadata.ex` with:

```elixir
defmodule ImagePipe.Cache.Entry.Metadata do
  @moduledoc false

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Debug.Info

  @enforce_keys [:content_type, :headers, :created_at, :output_format]
  defstruct [:content_type, :headers, :created_at, :output_format, cost_us: 0, debug: nil]

  @type t :: %__MODULE__{
          content_type: String.t(),
          headers: [Entry.header()],
          created_at: DateTime.t(),
          output_format: atom(),
          cost_us: non_neg_integer(),
          debug: Info.t() | nil
        }
end
```

- [ ] **Step 2: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean (default `nil`, existing constructors unaffected).

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/cache/entry/metadata.ex
git commit -m "feat(debug): add debug field to Cache.Entry.Metadata

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task A3: add `debug` to `Cache.Entry` (read side)

The reconstructed-on-hit `Entry` carries the stored `Info` so the sender can render it without touching storage internals.

**Files:**
- Modify: `lib/image_pipe/cache/entry.ex` (struct + type, ~lines 9–21)

- [ ] **Step 1: Add the field**

In `lib/image_pipe/cache/entry.ex`, add a `Debug.Info` alias and the optional `debug` field. The `@enforce_keys` stay `[:body, :content_type, :headers, :created_at]`; add `debug: nil` as a non-enforced default:

```elixir
defmodule ImagePipe.Cache.Entry do
  @moduledoc """
  Adapter-independent cached response entry.
  """

  alias ImagePipe.Debug.Info
  alias ImagePipe.Format

  @allowed_headers ~w(vary cache-control)
  @enforce_keys [:body, :content_type, :headers, :created_at]
  @header_name_pattern ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/
  @header_value_pattern ~r/^[^\x00-\x1F\x7F]*$/

  defstruct @enforce_keys ++ [debug: nil]

  @type header :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          body: binary(),
          content_type: String.t(),
          headers: [header()],
          created_at: DateTime.t(),
          debug: Info.t() | nil
        }
```

Leave the rest of the module (the `validate/1`, `cacheable_headers/1`, and header-normalization functions) unchanged — `validate/1` pattern-matches only `body`/`content_type`/`headers`, so the new field is inert there.

- [ ] **Step 2: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/cache/entry.ex
git commit -m "feat(debug): add debug field to Cache.Entry read side

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase B — Persist `Info` through the sink

### Task B1: populate `Metadata.debug` in the sink

`Sink.open/5` already reads `:cost_us` from `opts`. Read `:debug_info` the same way and put it on the constructed `Entry.Metadata`.

**Files:**
- Modify: `lib/image_pipe/cache/sink.ex` (`open/5` at ~37–48; `response_metadata/2` at ~86–97)

- [ ] **Step 1: Thread `:debug_info` into `response_metadata`**

In `lib/image_pipe/cache/sink.ex`, change `open/5` to read the debug info and pass it to `response_metadata`:

```elixir
  def open(adapter, %Key{} = key, %Resolved{} = resolved_output, cache_opts, opts) do
    cost_us = Keyword.get(opts, :cost_us, 0)
    debug = Keyword.get(opts, :debug_info)

    with {:ok, metadata} <- response_metadata(resolved_output, cost_us, debug),
         {:ok, adapter_state} <- open_adapter_sink(adapter, key, metadata, cache_opts) do
      build(adapter, key, metadata, cache_opts, adapter_state)
    else
      {:error, reason} ->
        handle_open_error(reason, resolved_output.format, opts)
        nil
    end
  end
```

And update `response_metadata/2` to `response_metadata/3`:

```elixir
  defp response_metadata(%Resolved{} = resolved_output, cost_us, debug) do
    with {:ok, headers} <- Entry.cacheable_headers(resolved_output.response_headers) do
      {:ok,
       %Entry.Metadata{
         content_type: Format.mime_type!(resolved_output.format),
         headers: headers,
         created_at: DateTime.utc_now(),
         output_format: resolved_output.format,
         cost_us: cost_us,
         debug: debug
       }}
    end
  end
```

- [ ] **Step 2: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean. (`debug` is `nil` until Task B2 supplies `:debug_info`; that is fine — `Metadata.debug` is optional.)

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/cache/sink.ex
git commit -m "feat(debug): carry debug Info onto Entry.Metadata in the sink

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task B2: pass the total-timed `Info` into `open_sink`

`SourceSession.handle_producer_result/2` computes `cost_us`, opens the sink, and builds `Prepared`. We compute `put_total_timing(debug, cost_us)` **once**, before opening the sink, so the stored `Info` carries the `:total` stage (the spec stores origin per-stage timings, including total), and pass it via `:debug_info`.

**Files:**
- Modify: `lib/image_pipe/request/source_session.ex` (the first-chunk `handle_producer_result/2` clause, ~lines 252–287)

- [ ] **Step 1: Compute `debug` once and thread it**

Replace the first-chunk `handle_producer_result/2` clause body:

```elixir
  defp handle_producer_result(
         {:ok, {:first_chunk, first_chunk, content_type, headers, resolved_output, debug}},
         %{pending: {:prepare, from}, request: request} = state
       ) do
    with_owner_check(state, fn state ->
      cost_us = System.monotonic_time(:microsecond) - state.fetch_started_at
      debug = put_total_timing(debug, cost_us)

      cache_sink =
        Cache.open_sink(
          request.cache_key,
          resolved_output,
          request.opts
          |> Keyword.put(:cost_us, cost_us)
          |> Keyword.put(:debug_info, debug)
        )

      cache_sink = Cache.write_chunk(cache_sink, first_chunk, request.opts)

      prepared = %Prepared{
        first_chunk: first_chunk,
        content_type: content_type,
        headers: headers,
        resolved_output: resolved_output,
        debug: debug
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

Leave `put_total_timing/2` (already defined ~lines 422–425) unchanged.

- [ ] **Step 2: Compile + run the source-session tests**

Run: `mise exec -- mix compile --warnings-as-errors`
Run: `mise exec -- mix test test/image_pipe/request`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/request/source_session.ex
git commit -m "feat(debug): store total-timed Info in the cache sink

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase C — Filesystem serialize / validate / deserialize (in place)

### Task C1: serialize `debug` in the metadata payload

**Files:**
- Modify: `lib/image_pipe/cache/file_system.ex` (`sink_metadata/3` at ~547–560)

- [ ] **Step 1: Add `debug` to the serialized map**

In `sink_metadata/3`, add `debug: state.metadata.debug` to the map before `:erlang.term_to_binary/2`:

```elixir
  defp sink_metadata(state, body_sha256, body_filename) do
    metadata = %{
      metadata_version: @metadata_version,
      content_type: state.metadata.content_type,
      headers: state.metadata.headers,
      created_at: DateTime.to_iso8601(state.metadata.created_at),
      body_byte_size: state.size,
      body_sha256: body_sha256,
      body_filename: body_filename,
      cost_us: state.metadata.cost_us,
      debug: state.metadata.debug
    }

    :erlang.term_to_binary(metadata, [:deterministic])
  end
```

`@metadata_version` is **not** bumped (greenfield — reshape in place). The `Debug.Info` struct serializes cleanly under `[:deterministic]` (primitives, maps, lists, atoms; no funs/PIDs).

- [ ] **Step 2: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean. (Reads will reject these until Task C2 teaches `validate_metadata` about `debug`; that is fine — the round-trip test lands in C3.)

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/cache/file_system.ex
git commit -m "feat(debug): serialize Info into cache metadata payload

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task C2: validate + deserialize `debug`; reconstruct it onto `Entry`

**Files:**
- Modify: `lib/image_pipe/cache/file_system.ex` (`validate_metadata/1` at ~573–599; `read_entry/1` at ~511–528)

- [ ] **Step 1: Add an alias for the Info struct**

At the top of `lib/image_pipe/cache/file_system.ex`, add (after `alias ImagePipe.Cache.Key`):

```elixir
  alias ImagePipe.Debug.Info
```

- [ ] **Step 2: Require + carry `debug` through `validate_metadata/1`**

Update the success clause of `validate_metadata/1` to require a `debug` key that is either an `%Info{}` struct or `nil` (this is a deserialization boundary — a corrupt payload that decodes to a non-`Info` is rejected → miss), and carry it into the returned map:

```elixir
  defp validate_metadata(%{
         metadata_version: @metadata_version,
         content_type: content_type,
         headers: headers,
         created_at: created_at,
         body_byte_size: body_byte_size,
         body_sha256: body_sha256,
         body_filename: body_filename,
         cost_us: cost_us,
         debug: debug
       })
       when is_binary(content_type) and is_list(headers) and is_binary(created_at) and
              is_integer(body_byte_size) and body_byte_size >= 0 and is_binary(body_sha256) and
              is_binary(body_filename) and is_integer(cost_us) and cost_us >= 0 and
              (is_struct(debug, Info) or is_nil(debug)) do
    with :ok <- validate_metadata_content_type(content_type),
         :ok <- validate_metadata_headers(headers) do
      {:ok,
       %{
         content_type: content_type,
         headers: headers,
         created_at: created_at,
         body_byte_size: body_byte_size,
         body_sha256: body_sha256,
         body_filename: body_filename,
         cost_us: cost_us,
         debug: debug
       }}
    end
  end
```

The two fallback clauses stay:

```elixir
  defp validate_metadata(%{metadata_version: _version}), do: {:error, :version_mismatch}
  defp validate_metadata(_metadata), do: {:error, :invalid_shape}
```

A stale entry lacking `debug:` now falls through to `:invalid_shape` → `{:error, {:invalid_metadata, :invalid_shape}}` → treated as a miss → regenerate. (Intended; no version bump.)

- [ ] **Step 3: Reconstruct `debug` onto the `Entry`**

In `read_entry/1`, add `debug: metadata.debug` to the `%Entry{}` it builds:

```elixir
      {:hit,
       %Entry{
         body: body,
         content_type: metadata.content_type,
         headers: metadata.headers,
         created_at: created_at,
         debug: metadata.debug
       }, metadata}
```

(`read_descriptor/1` at ~772 reads only `metadata.body_byte_size`/`body_sha256`/`cost_us`; it is unaffected, though it now also requires `debug:` to be present for a successful decode — which all newly-written entries satisfy.)

- [ ] **Step 4: Fix the existing serialize-test fixtures (the strict pattern now requires `debug:`)**

`test/image_pipe/cache/file_system_test.exs` has a private `metadata/3` helper (~lines 61–72) that builds the raw serialized map **without** `debug:`. After Step 2, that map falls through `validate_metadata/1` to `{:error, :invalid_shape}` *before* the content-type/header/body-filename checks, so several existing tests (the meta-only "miss", the invalid-body-filename, invalid-content-type, and malformed-headers cases) assert the wrong tag and fail. Add a `debug: nil` default to that helper's map so its callers exercise the same validation paths as before:

```elixir
  defp metadata(cache_key, body, overrides \\ []) do
    Map.merge(
      %{
        metadata_version: 1,
        # ... existing keys unchanged ...
        body_filename: body_filename(cache_key, body),
        cost_us: 0,
        debug: nil
      },
      Map.new(overrides)
    )
  end
```

(Read the helper first; preserve every existing key and the `overrides` merge — only add the `debug: nil` line. The `%{metadata_version: 999}` version-mismatch test at ~line 332 is unaffected: it hits the `metadata_version: _version` fallback clause, not the strict head.)

- [ ] **Step 5: Compile + run the filesystem suite**

Run: `mise exec -- mix compile --warnings-as-errors`
Run: `mise exec -- mix test test/image_pipe/cache/file_system_test.exs`
Expected: clean compile + PASS (the pre-existing validation tests stay green with the helper fix).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/cache/file_system.ex test/image_pipe/cache/file_system_test.exs
git commit -m "feat(debug): validate and reconstruct debug Info on cache reads

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task C3: metadata `debug` round-trip test (through the real adapter)

Prove serialize → write → read reconstructs the `Info` (and that an `Info` with atoms/maps survives `term_to_binary`/`binary_to_term(_, [:safe])`).

**Files:**
- Modify: `test/image_pipe/cache/file_system_test.exs` (create if absent — check first with `ls test/image_pipe/cache`)

- [ ] **Step 1: Write the test**

Add this test (adapt the `cache_opts`/`tmp` helpers to whatever the file already uses; if creating the file, use the `@moduledoc false` + `use ExUnit.Case, async: true` shape and the `tmp_dir` pattern below):

```elixir
  test "round-trips a Debug.Info through metadata serialize/deserialize" do
    root = Path.join(System.tmp_dir!(), "image_pipe_fs_debug_#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    opts = [root: root, path_prefix: "processed"]

    {:ok, key} = ImagePipe.Cache.Key.build(Plug.Test.conn(:get, "/"), plan_fixture(), [kind: :test], [])

    info = %ImagePipe.Debug.Info{
      source_format: :jpeg,
      source_width: 4000,
      source_height: 3000,
      output_format: :avif,
      output_quality: 72,
      aq: %{metric: :ssimulacra2, score: 78.4, min: 60, max: 65},
      pipeline: ["scale", "crop"],
      timings: %{decode: 8, transform: 21, encode: 140, total: 181}
    }

    metadata = %ImagePipe.Cache.Entry.Metadata{
      content_type: "image/avif",
      headers: [],
      created_at: DateTime.utc_now(),
      output_format: :avif,
      cost_us: 181,
      debug: info
    }

    {:ok, sink_state} = ImagePipe.Cache.FileSystem.open_sink(key, metadata, opts)
    {:ok, sink_state} = ImagePipe.Cache.FileSystem.write_chunk(sink_state, "BODYBYTES", opts)
    :ok = ImagePipe.Cache.FileSystem.commit_sink(sink_state, opts)

    assert {:hit, %ImagePipe.Cache.Entry{debug: read_back}} =
             ImagePipe.Cache.FileSystem.get(key, opts)

    assert read_back == info
  after
    # best-effort cleanup; root is unique per test
    :ok
  end
```

If the file has no `plan_fixture/0`, reuse the existing key-building helper in the suite (grep `Key.build` in `test/image_pipe/cache`); the only requirement is *some* valid `%Key{}`.

- [ ] **Step 2: Run**

Run: `mise exec -- mix test test/image_pipe/cache/file_system_test.exs`
Expected: PASS — `read_back == info`.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/cache/file_system_test.exs
git commit -m "test(debug): metadata debug Info round-trips through the filesystem adapter

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase D — Telemetry: the `[:debug, :collect, :error]` event surface

We wire the new one-shot event into both observability surfaces **before** the processor starts emitting it (Phase E), so the subscription is complete within the PR. The tests here emit the event synthetically via `:telemetry.execute/4`.

> **Why `:error`, not `:exception`, as the terminal segment.** The repo reserves the
> `:exception` suffix for span triples: `Logger.handle_event/4` routes **any** event
> whose suffix ends in `:exception` to `exception_message/2` (which renders
> `meta[:kind]`/`meta[:reason]`, not `meta[:error]`), and `Capture.classify/2` treats a
> trailing `:exception` as a span-exception that pops the span stack unless the exact
> stage is in `@oneshot_stages`. Every existing one-shot ends in a non-`:exception`
> verb (`:skipped`, `:blend`, `:chosen`, `:clamp`, `:stage`). So this one-shot is named
> `[:debug, :collect, :error]` (metadata `%{error: <tag>}`) to follow that convention
> and let the normal `message/3` + `level_for/3` path render it.

### Task D1: Logger subscribes, renders, and escalates the event

**Files:**
- Modify: `lib/image_pipe/telemetry/logger.ex`
- Test: `test/image_pipe/telemetry/logger_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/telemetry/logger_test.exs` (mirror the existing `[:output, :clamp]` one-shot test, ~lines 333–354):

```elixir
  test "logs the debug collect error one-shot at warning with the error tag" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :debug, :collect, :error],
          %{},
          %{error: :decode_failed}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "debug collect: error (decode_failed)"
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/logger_test.exs`
Expected: FAIL — the event is unsubscribed, so no log line is produced.

- [ ] **Step 3: Subscribe the event (incl. making `:all` include `:debug`)**

The default `attach_default_logger/1` uses `events: :all`, and `expand_groups(:all)` returns `@all_groups = Map.keys(@group_span_events)` (a **derived** list, not literal). `@group_span_events` has no `:debug` key, so without a new key the event is **silently dropped** under `:all`. Mirror the existing one-shot-only group `http_cache: []`: add a `debug: []` entry so `:debug` joins `@all_groups`.

In `lib/image_pipe/telemetry/logger.ex`, add `debug: []` to `@group_span_events` (the map at ~lines 12–36, after the `http_cache: []` entry):

```elixir
    http_cache: [],
    debug: []
  }
```

Add a `@debug_oneshot` attribute next to the other one-shot lists (after `@output_oneshot`, ~line 68):

```elixir
  # debug one-shot events (best-effort debug-fact collection)
  @debug_oneshot [
    [:debug, :collect, :error]
  ]
```

In `event_names/2` (~lines 97–116), add the conditional alongside the others and append it to the concatenated one-shot list:

```elixir
    debug_oneshots = if :debug in groups, do: @debug_oneshot, else: []
```

and add `++ debug_oneshots` to the `spans ++ … ++ http_cache_oneshots` expression passed to `Enum.map/2`.

- [ ] **Step 4: Render + escalate**

Because the suffix ends in `:error` (not `:exception`), `handle_event/4` dispatches to the normal `message/3`. Add a specific `message/3` clause **before** the generic fallback (~line 337) that surfaces the error tag:

```elixir
  defp message([:debug, :collect, :error | _], _m, meta),
    do: "image_pipe debug collect: error (#{meta[:error]})"
```

The `:error` suffix is not auto-escalated (only `:exception` is, at ~line 149), so add a specific `level_for/3` clause **before** the generic `level_for(suffix, …)` fallback (~line 155):

```elixir
  defp level_for([:debug, :collect, :error | _], _metadata, _base), do: :warning
```

- [ ] **Step 5: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/telemetry/logger_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/telemetry/logger.ex test/image_pipe/telemetry/logger_test.exs
git commit -m "feat(debug): logger renders the debug collect error event at warning

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task D2: OTel Capture captures the new one-shot

**Files:**
- Modify: `lib/image_pipe/telemetry/trace/capture.ex` (`@oneshot_stages`, ~lines 46–62)
- Test: `test/image_pipe/telemetry/trace/capture_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/telemetry/trace/capture_test.exs` (mirror the `[:encode, :search, :probe, :chosen]` one-shot test, ~lines 145–170):

```elixir
  test "folds the debug collect error marker onto the enclosing span" do
    Telemetry.span([], [:cache, :lookup], %{}, fn ->
      Telemetry.execute([], [:debug, :collect, :error], %{}, %{error: :decode_failed})
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.cache.lookup"} = span}

    refute_received {:span, %Span{name: "image_pipe.debug.collect.error"}}

    event = Enum.find(span.events, &(&1.name == "image_pipe.debug.collect.error"))
    assert event
    assert event.attributes[:error] == :decode_failed
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/capture_test.exs`
Expected: FAIL — the stage is not in `@oneshot_stages`, so the annotation is not folded.

- [ ] **Step 3: Add the stage**

In `lib/image_pipe/telemetry/trace/capture.ex`, add `[:debug, :collect, :error]` to `@oneshot_stages` (after the `http_cache` entries, before the closing `]`). `:error` is already in `@safe_keys` — no change needed there.

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/capture_test.exs`
Expected: PASS.

- [ ] **Step 5: Exporter regression check**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs`
Expected: PASS (the exporter folds any captured one-shot generically; no exporter code change is required, but confirm the suite is green). If a list there enumerates expected one-shots, add the new stage and a focused assertion mirroring the existing `[:cache, :stage]` event test (~lines 131–149).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/telemetry/trace/capture.ex test/image_pipe/telemetry/trace/capture_test.exs test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs
git commit -m "feat(debug): capture the debug collect error one-shot for OTel

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task D3: document the event in `docs/telemetry.md`

**Files:**
- Modify: `docs/telemetry.md` (after the `[:output, :clamp]` section, ~line 756)

- [ ] **Step 1: Add the section**

Append a new section in the same style as the existing one-shot sections:

```markdown
## Debug fact collection (`[:debug, :collect, :error]`)

Debug-fact collection (the source/output facts behind the opt-in
`X-ImagePipe-*` headers) is best-effort and runs unconditionally on every
generation. If reading the decoded image's headers raises, ImagePipe degrades
that fact set to empty rather than failing the decode, and emits a one-shot
(non-span) marker so the loss is observable.

```text
[:image_pipe, :debug, :collect, :error]
```

Measurements: none.

Metadata:

- `:error` — the classified exception category atom (`ImagePipe.Error.tag/1`).
  Product-neutral and non-sensitive.

Both surfaces see it: the opt-in default Logger renders one `warning` line
(`image_pipe debug collect: error (<tag>)`), and the OTel exporter folds it
as an annotation onto the enclosing span (typically `[:source, :fetch_decode]`).
```

- [ ] **Step 2: Commit**

(Docs-only; no compile/test gate per the comment-only convention.)

```bash
git add docs/telemetry.md
git commit -m "docs(telemetry): document the debug collect error event

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase E — Make collection unconditional

### Task E1: processor always collects; one boundary rescue; emit on raise

The processor currently gates `source_debug_facts/2` on `allow_debug_headers` and each helper carries its own `rescue _ -> nil`. We (a) always collect, (b) replace the five scattered catch-alls with one documented boundary rescue around `source_debug_facts/3`, and (c) on a real raise emit `[:debug, :collect, :error]` and degrade to `%{}`. Genuinely-absent values still return `nil`/`false` through the existing `case` clauses (silent, correct); only an actual raise is surfaced.

**Files:**
- Modify: `lib/image_pipe/request/processor.ex` (call site ~97–102; `source_debug_facts/2` + helpers ~380–447)

- [ ] **Step 1: Always collect at the call site**

In `decode_validate_source_response/3`, replace the gated block (~lines 97–102) with an unconditional call that passes `opts` (needed for the telemetry prefix):

```elixir
      debug_facts = source_debug_facts(input, header_image, opts)
```

Leave the surrounding `Map.merge(%{...}, debug_facts)` unchanged.

- [ ] **Step 2: One boundary rescue; plain helpers**

Replace `source_debug_facts/2` and its helpers. The wrapper gains `opts`, a single rescue, and the telemetry emission; the per-helper `rescue _ -> nil` clauses are removed (the helpers keep their `case`-based nil/false returns):

```elixir
  # Best-effort, non-sensitive source facts for the debug headers. Collected on
  # every generation (rendering is gated elsewhere). A genuinely-absent value
  # returns nil/false through the helper's own `case`; only a real raise is an
  # anomaly — surfaced as one `[:debug, :collect, :error]` event, then the
  # whole fact set degrades to %{} so collection never breaks decoding.
  defp source_debug_facts(input, header_image, opts) do
    %{
      source_bytes: source_byte_size(input),
      source_color_space: source_interpretation(header_image),
      source_icc?: source_has_icc?(header_image),
      source_bit_depth: source_bit_depth(header_image),
      source_alpha?: source_alpha?(header_image),
      source_orientation: source_orientation(header_image)
    }
  rescue
    exception ->
      Telemetry.execute(
        Telemetry.telemetry_opts(opts),
        [:debug, :collect, :error],
        %{},
        %{error: Error.tag(exception)}
      )

      %{}
  end

  defp source_byte_size({:buffer, binary}), do: byte_size(binary)

  defp source_byte_size({:path, path}) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> nil
    end
  end

  defp source_interpretation(image) do
    case VipsImage.interpretation(image) do
      interp when is_atom(interp) -> interp
      _ -> nil
    end
  end

  defp source_has_icc?(image) do
    case VipsImage.header_value(image, "icc-profile-data") do
      {:ok, blob} when is_binary(blob) and byte_size(blob) > 0 -> true
      _ -> false
    end
  end

  # Bit depth in bits per sample derived from the image interpretation, mirroring
  # the encoder's `icc_depth/1` logic: 16-bit interpretations yield 16, all others 8.
  defp source_bit_depth(image) do
    case VipsImage.interpretation(image) do
      :VIPS_INTERPRETATION_GREY16 -> 16
      :VIPS_INTERPRETATION_RGB16 -> 16
      :VIPS_INTERPRETATION_scRGB -> 16
      _ -> 8
    end
  end

  defp source_orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) and value in 1..8 -> value
      _ -> nil
    end
  end

  defp source_alpha?(image), do: Image.has_alpha?(image)
```

- [ ] **Step 3: Compile + run the processor/request suite**

Run: `mise exec -- mix compile --warnings-as-errors`
Run: `mise exec -- mix test test/image_pipe/request`
Expected: clean compile + PASS. (`Telemetry` and `Error` are already aliased in `processor.ex`.)

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/request/processor.ex
git commit -m "feat(debug): collect source facts unconditionally with one rescue boundary

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task E2: producer always measures + builds `Info`

Delete the `collect?` plumbing. Each stage calls `Timing.measure/1` directly; `build_debug/1` always builds.

**Files:**
- Modify: `lib/image_pipe/request/source_session/producer.ex` (`prepare_first_chunk/1` ~116–166; `measure_*` ~252–282; `build_debug/2` ~284–319)

- [ ] **Step 1: Drop `collect?` from `prepare_first_chunk/1`**

Rewrite `prepare_first_chunk/1` to remove the `collect?` variable and always measure/build:

```elixir
  defp prepare_first_chunk(%__MODULE__{request: %Request{} = request} = state) do
    with_stream_translation(&prepare_fallback/2, fn ->
      with {{:ok, decoded}, decode_us} <-
             measure_decode(request.plan, request.resolved_source, request.opts),
           {{:ok, %State{} = final_state}, transform_us} <-
             measure_transform(decoded, request),
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
             measure_encode(image, resolved_output, request.opts) do
        debug =
          build_debug(%{
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

- [ ] **Step 2: Simplify the `measure_*` wrappers and delete `measure/2`**

Replace the three `measure_*` helpers and the boolean `measure/2` with direct `Timing.measure/1`:

```elixir
  defp measure_decode(plan, resolved_source, opts),
    do:
      Timing.measure(fn ->
        Processor.fetch_decode_validate_source_with_source_format(plan, resolved_source, opts)
      end)

  defp measure_transform(decoded, request),
    do:
      Timing.measure(fn ->
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
      end)

  defp measure_encode(image, resolved_output, opts),
    do: Timing.measure(fn -> encode_first_chunk(image, resolved_output, opts) end)
```

Delete the two `defp measure(false, fun)` / `defp measure(true, fun)` clauses entirely.

- [ ] **Step 3: Make `build_debug/1` unconditional**

Replace `build_debug(false, _ctx)` / `build_debug(true, ctx)` with a single `build_debug/1` (drop the boolean; the body is otherwise identical):

```elixir
  defp build_debug(ctx) do
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
```

Leave `dim/2`, `negotiated?/1`, `output_quality/2`, `output_distance/2`, `aq_from_meta/2`, `quality_search_metric/1`, `native_jxl_search?/1`, `pipeline_names/1`, `operation_name/1` unchanged.

- [ ] **Step 4: Compile + run**

Run: `mise exec -- mix compile --warnings-as-errors`
Run: `mise exec -- mix test test/image_pipe/debug_headers_wire_test.exs test/image_pipe/request`
Expected: clean compile + PASS. The Plan-1 miss-path wire tests still pass (rendering is still gated on `debug?`; only collection changed).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/request/source_session/producer.ex
git commit -m "feat(debug): collect Info unconditionally in the producer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase F — `X-ImagePipe-Cache-Key` in the renderer

### Task F1: `Debug.Headers.render/2` gains `:cache_key`

**Files:**
- Modify: `lib/image_pipe/debug/headers.ex`
- Test: `test/image_pipe/debug/headers_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/debug/headers_test.exs`:

```elixir
  test "renders the cache key when provided and omits it otherwise" do
    info = %Info{output_format: :avif}

    with_key = Headers.render(info, accept: "", cache: :hit, cache_key: "a1b2c3")
    assert header(with_key, "x-imagepipe-cache-key") == {"x-imagepipe-cache-key", "a1b2c3"}
    assert header(with_key, "x-imagepipe-cache") == {"x-imagepipe-cache", "hit"}

    without_key = Headers.render(info, accept: "", cache: :miss)
    refute header(without_key, "x-imagepipe-cache-key")
  end

  test "appends a live cache;dur entry to Server-Timing on a hit" do
    info = %Info{timings: %{decode: 8_000, total: 181_000}}
    headers = Headers.render(info, accept: "", cache: :hit, cache_serve_us: 1_500)

    {"server-timing", server_timing} = header(headers, "server-timing")
    assert server_timing =~ "cache;dur=1.5"
    assert server_timing =~ "total;dur=181.0"
  end
```

(`header/2` is the `List.keyfind/3` helper already defined at the top of the file. Note durations render in **milliseconds**: `cache_serve_us: 1_500` → `cache;dur=1.5`.)

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/debug/headers_test.exs`
Expected: FAIL — `x-imagepipe-cache-key` is not rendered.

- [ ] **Step 3: Add the option + header**

In `lib/image_pipe/debug/headers.ex`, read the option in `render/2` and pass it to `cache_headers`:

```elixir
  def render(%Info{} = info, opts) do
    accept = Keyword.get(opts, :accept)
    cache = Keyword.get(opts, :cache, :miss)
    cache_serve_us = Keyword.get(opts, :cache_serve_us)
    cache_key = Keyword.get(opts, :cache_key)

    (source_headers(info) ++
       output_headers(info, accept) ++
       aq_headers(info.aq) ++
       pipeline_headers(info) ++
       cache_headers(cache, cache_key) ++
       server_timing(info.timings, cache_serve_us))
    |> Enum.reject(&is_nil/1)
  end
```

Replace `cache_headers/1` with `cache_headers/2`:

```elixir
  defp cache_headers(cache, cache_key) do
    [
      kv("x-imagepipe-cache", cache),
      kv("x-imagepipe-cache-key", cache_key)
    ]
  end
```

(`kv/2` already omits `nil`/`""`, so an absent `cache_key` drops the header.) Update the `@doc` for `render/2` to mention `:cache_key`.

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/debug/headers_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/debug/headers.ex test/image_pipe/debug/headers_test.exs
git commit -m "feat(debug): render X-ImagePipe-Cache-Key from a render option

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase G — Hit-path render + miss-path Cache-Key

### Task G1: `PreparedStream` carries the cache key (miss path)

**Files:**
- Modify: `lib/image_pipe/response/prepared_stream.ex`

- [ ] **Step 1: Add the field**

In `lib/image_pipe/response/prepared_stream.ex`, add `cache_key: nil` to the non-enforced defaults and the type:

```elixir
  @enforce_keys [:first_chunk, :content_type, :headers, :next, :cancel, :resolved_output]
  defstruct @enforce_keys ++ [debug: nil, cache_key: nil]

  @type t() :: %__MODULE__{
          first_chunk: binary(),
          content_type: String.t(),
          headers: [{String.t(), String.t()}],
          next: (-> next_result()),
          cancel: (-> cancel_result()),
          resolved_output: Resolved.t(),
          debug: Info.t() | nil,
          cache_key: String.t() | nil
        }
```

- [ ] **Step 2: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/response/prepared_stream.ex
git commit -m "feat(debug): add cache_key field to PreparedStream

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task G2: runner measures cache-serve, builds the hit 5-tuple, threads the miss-path key

**Files:**
- Modify: `lib/image_pipe/request/runner.ex`

- [ ] **Step 1: Alias `Timing` and widen the delivery type**

Add to the alias block in `lib/image_pipe/request/runner.ex`:

```elixir
  alias ImagePipe.Debug.Timing
```

Update the `@type delivery()` to make `:cache_entry` a 5-tuple:

```elixir
  @type hit_debug() :: %{cache_key: String.t(), cache_serve_us: non_neg_integer()}

  @type delivery() ::
          {:cache_entry, Entry.t(), Response.t(), CacheHeaders.t(), hit_debug()}
          | {:prepared_stream, PreparedStream.t(), Response.t(), CacheHeaders.t()}
          | {:rendered, String.t(), iodata(), [{String.t(), [String.t()]}], CacheHeaders.t()}
```

- [ ] **Step 2: Measure the lookup and build the hit tuple**

In `run_with_cache_config/5` (the `:enabled` clause), wrap the lookup span with `Timing.measure/1` and use the duration in the hit branch:

```elixir
    telemetry_opts = Telemetry.telemetry_opts(opts)

    {result, cache_serve_us} =
      Timing.measure(fn ->
        Telemetry.span(telemetry_opts, [:cache, :lookup], cache_lookup_metadata(opts), fn ->
          result =
            case Keyword.get(opts, :cache) do
              nil ->
                :disabled

              _cache ->
                Cache.lookup(
                  conn,
                  plan,
                  resolved_source.identity,
                  opts
                )
            end

          {result, cache_lookup_stop_metadata(result)}
        end)
      end)

    case result do
      :disabled ->
        process_prepared_stream(conn, plan, resolved_source, nil, prepared_http_cache, opts)

      {:hit, %Key{} = key, %Entry{} = entry} ->
        hit_debug = %{cache_key: key.hash, cache_serve_us: cache_serve_us}
        {:ok, {:cache_entry, entry, plan.response, prepared_http_cache, hit_debug}}

      {:miss, %Key{} = key} ->
        process_cacheable_miss(conn, plan, resolved_source, key, prepared_http_cache, opts)

      {:miss, %Key{} = key, {:cache_read, _error}} ->
        process_cacheable_miss(conn, plan, resolved_source, key, prepared_http_cache, opts)
    end
```

- [ ] **Step 3: Thread the cache key into `PreparedStream` (miss path)**

`process_prepared_stream/6` already receives `cache_key` (a `%Key{}` or `nil`). Thread it into the prepared-stream construction. Update the `prepare_supervised_session/5` call and signature, and `prepared_stream/4`:

In `process_prepared_stream/6`, change the success call:

```elixir
          {:ok, session} ->
            prepare_supervised_session(
              session,
              supervisor,
              plan.response,
              policy,
              prepared_http_cache,
              cache_key
            )
```

Change `prepare_supervised_session/5` to `/6` (add a trailing `cache_key` parameter) and pass it to `prepared_stream`:

```elixir
  defp prepare_supervised_session(
         session,
         supervisor,
         %Response{} = response,
         %Policy{} = policy,
         %CacheHeaders{} = prepared_http_cache,
         cache_key
       ) do
    case SourceSession.prepare(session) do
      {:ok, %SessionPrepared{} = prepared} ->
        case prepared_stream(session, supervisor, prepared, response, cache_key) do
          {:ok, %PreparedStream{} = prepared_stream} ->
            {:ok, {:prepared_stream, prepared_stream, response, prepared_http_cache}}

          {:error, reason} ->
            _stop_result = SourceSessionSupervisor.stop_session(supervisor, session)
            {:error, {:processing, normalize_session_prepare_error(reason), policy.headers}}
        end

      {:error, reason} ->
        _stop_result = SourceSessionSupervisor.stop_session(supervisor, session)
        {:error, {:processing, normalize_session_prepare_error(reason), policy.headers}}
    end
  end
```

Change `prepared_stream/4` to `/5` and set the field:

```elixir
  defp prepared_stream(session, supervisor, %SessionPrepared{} = prepared, %Response{} = response, cache_key) do
    with :ok <- check_first_chunk(prepared.first_chunk),
         {:ok, content_disposition} <-
           Response.content_disposition(response, prepared.content_type) do
      {:ok,
       %PreparedStream{
         first_chunk: prepared.first_chunk,
         content_type: prepared.content_type,
         headers: prepared.headers ++ [{"content-disposition", content_disposition}],
         next: fn -> SourceSession.next(session) end,
         cancel: fn -> cancel_supervised_session(supervisor, session) end,
         resolved_output: prepared.resolved_output,
         debug: prepared.debug,
         cache_key: key_hash(cache_key)
       }}
    else
      {:error, reason} ->
        _cancel_result = SourceSession.cancel(session)
        {:error, reason}
    end
  end

  defp key_hash(%Key{hash: hash}), do: hash
  defp key_hash(nil), do: nil
```

- [ ] **Step 4: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: FAIL at this point — `Response.Sender.send_result/3` still pattern-matches the 4-tuple `:cache_entry`. That is fixed in Task G3. (If you prefer a green intermediate, do G3 in the same commit.) Proceed to G3.

- [ ] **Step 5: Commit (with G3)**

Defer the commit until G3 compiles. (G2 + G3 form one green step because the delivery-tuple arity change spans both modules.)

---

### Task G3: sender renders the stored `Info` on a hit; passes Cache-Key on a miss

**Files:**
- Modify: `lib/image_pipe/response/sender.ex`

- [ ] **Step 1: Widen the delivery type + `send_result/3` clause**

In `lib/image_pipe/response/sender.ex`, update `@type delivery()` to match the runner (add the `hit_debug()` 5th element to `:cache_entry`):

```elixir
  @type hit_debug() :: %{cache_key: String.t(), cache_serve_us: non_neg_integer()}

  @type delivery() ::
          {:cache_entry, Entry.t(), Response.t(), CacheHeaders.t(), hit_debug()}
          | {:prepared_stream, PreparedStream.t(), Response.t(), CacheHeaders.t()}
          | {:rendered, String.t(), iodata(), [{String.t(), [String.t()]}], CacheHeaders.t()}
```

Update the `:cache_entry` `send_result/3` clause to unpack the 5th element:

```elixir
  def send_result(
        %Plug.Conn{} = conn,
        {:ok,
         {:cache_entry, %Entry{} = entry, %Response{} = response, %CacheHeaders{} = prepared,
          hit_debug}},
        opts
      ) do
    send_cache_entry(conn, entry, response, prepared, hit_debug, opts)
  end
```

- [ ] **Step 2: Alias `Info` and render on the hit path**

Add `alias ImagePipe.Debug.Info` to the alias block. Change `send_cache_entry/5` to `/6` and inject hit debug headers into the merged delivery headers:

```elixir
  defp send_cache_entry(
         %Plug.Conn{} = conn,
         %Entry{} = entry,
         %Response{} = response,
         %CacheHeaders{} = prepared,
         hit_debug,
         opts
       ) do
    with {:ok, entry_headers} <- Entry.cacheable_headers(entry.headers),
         {:ok, content_disposition} <- Response.content_disposition(response, entry.content_type) do
      delivery_headers =
        entry_headers ++
          [{"content-disposition", content_disposition}] ++
          hit_debug_headers(entry, conn, hit_debug, opts)

      merged = merge_delivery_headers(conn, delivery_headers, prepared)

      Telemetry.execute(
        Telemetry.telemetry_opts(opts),
        [:http_cache, :cache_hit, :headers],
        %{},
        %{
          etag: prepared.etag != nil,
          generated_cache_headers: prepared.headers != [],
          representation_headers: prepared.representation_headers != []
        }
      )

      send_normalized_cache_entry(conn, entry, merged)
    else
      {:error, error} -> send_cache_error(conn, error)
    end
  end

  defp hit_debug_headers(%Entry{debug: nil}, _conn, _hit_debug, _opts), do: []

  defp hit_debug_headers(%Entry{debug: %Info{} = info}, conn, hit_debug, opts) do
    if Keyword.get(opts, :debug?, false) do
      Debug.Headers.render(info,
        accept: accept_header(conn),
        cache: :hit,
        cache_serve_us: hit_debug.cache_serve_us,
        cache_key: hit_debug.cache_key
      )
    else
      []
    end
  end
```

- [ ] **Step 3: Pass Cache-Key on the miss path**

Update `maybe_add_debug_headers/3` (the miss-path renderer) to also pass the `cache_key`:

```elixir
  defp maybe_add_debug_headers(%PreparedStream{debug: nil} = prepared_stream, _conn, _opts),
    do: prepared_stream

  defp maybe_add_debug_headers(%PreparedStream{debug: info} = prepared_stream, conn, opts) do
    if Keyword.get(opts, :debug?, false) do
      debug_headers =
        Debug.Headers.render(info,
          accept: accept_header(conn),
          cache: :miss,
          cache_key: prepared_stream.cache_key
        )

      %{prepared_stream | headers: prepared_stream.headers ++ debug_headers}
    else
      prepared_stream
    end
  end
```

- [ ] **Step 4: Update the runner-test `:cache_entry` tuple assertions (4→5)**

`test/image_pipe/request_runner_test.exs` matches the `:cache_entry` delivery as a 4-tuple in ~10 places (the return value of `Runner.run/5` on a hit). Grep `:cache_entry` in that file — the matches are at approximately lines 708, 736, 747, 769, 792, 815, 838, 1256, 1316, 1346. Each looks like:

```elixir
assert {:ok, {:cache_entry, ^entry, %ImagePipe.Plan.Response{}, %CacheHeaders{}}} =
```

(some use `%Response{}` and/or `^prepared_http_cache` / `^response` instead). Add a trailing 5th element to every one — bind it and assert its shape so the test also documents the new contract:

```elixir
assert {:ok,
        {:cache_entry, ^entry, %ImagePipe.Plan.Response{}, %CacheHeaders{},
         %{cache_key: cache_key, cache_serve_us: cache_serve_us}}} =
```

with follow-up assertions `assert is_binary(cache_key)` / `assert is_integer(cache_serve_us)` on at least one representative test (a bare `_hit_debug` binding is fine for the rest). Do **not** change the non-hit (`:prepared_stream`/`:rendered`) tuple matches — only `:cache_entry` grew.

- [ ] **Step 5: Compile + run the response/runner/wire suites**

Run: `mise exec -- mix compile --warnings-as-errors`
Run: `mise exec -- mix test test/image_pipe/request_runner_test.exs test/image_pipe/debug_headers_wire_test.exs test/image_pipe/response`
Expected: clean compile + PASS. The Plan-1 miss-path tests still pass; the miss path now additionally emits `x-imagepipe-cache-key` when caching is configured (and omits it when `cache_key` is `nil`).

- [ ] **Step 6: Commit (G2 + G3 together)**

```bash
git add lib/image_pipe/request/runner.ex lib/image_pipe/response/sender.ex test/image_pipe/request_runner_test.exs
git commit -m "feat(debug): render stored Info and Cache-Key on the cache-hit path

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase H — Wire-level hybrid tests

These use the filesystem cache + a counting origin so a true hit (no regeneration) is provable. Reuse the helpers already in `test/image_pipe/debug_headers_wire_test.exs` (`base_opts/1`, `request_path/0`, `call/2`, `header/2`) and the cached-opts pattern from `test/image_pipe/imgproxy_wire_conformance_test.exs` `cached_opts/1`.

### Task H1: a cached-opts helper + a counting origin in the debug wire suite

**Files:**
- Modify: `test/image_pipe/debug_headers_wire_test.exs`

- [ ] **Step 1: Add a counting origin module + cached-opts helper**

At the top of `test/image_pipe/debug_headers_wire_test.exs` (alongside the existing test source modules), add a counting origin that signals the test pid on each fetch, and a helper that builds filesystem-cache opts and returns the cache root for cleanup. Mirror `cached_opts/1` from the conformance suite:

```elixir
  defmodule CountingDebugOrigin do
    def init(opts), do: opts

    def call(conn, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :origin_fetch)
      body = File.read!("priv/static/images/beach.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defp cached_opts(overrides) do
    cache_root =
      Path.join(
        System.tmp_dir!(),
        "image_pipe_debug_hit_cache_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(cache_root)
    File.mkdir_p!(cache_root)

    opts =
      [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             req_options: [plug: {CountingDebugOrigin, test_pid: self()}]}
        ],
        cache:
          {ImagePipe.Cache.FileSystem,
           root: cache_root,
           path_prefix: "processed",
           max_body_bytes: 10_000_000,
           key_headers: [],
           key_cookies: []}
      ]
      |> Keyword.merge(overrides)

    {opts, cache_root}
  end
```

Confirm `RootHTTPAdapter` is the alias the file already uses for the imgproxy origin source (it is used by `base_opts/1`); reuse the same alias rather than re-importing.

- [ ] **Step 2: Compile the test (no assertions yet)**

Run: `mise exec -- mix test test/image_pipe/debug_headers_wire_test.exs`
Expected: PASS (existing tests still green; the new helper is unused so far).

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/debug_headers_wire_test.exs
git commit -m "test(debug): add counting origin + cached opts helper for hit-path tests

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task H2: miss→hit replay test

**Files:**
- Modify: `test/image_pipe/debug_headers_wire_test.exs`

- [ ] **Step 1: Write the test**

```elixir
  describe "cache hybrid (hit-path replay)" do
    test "a hit replays stored facts, tags hit, and merges a live cache;dur" do
      {opts, cache_root} = cached_opts(allow_debug_headers: true)

      try do
        miss = call(request_path() <> "?_debug=1", opts)
        assert miss.status == 200
        assert header(miss, "x-imagepipe-cache") == "miss"
        assert_received :origin_fetch
        miss_source_format = header(miss, "x-imagepipe-source-format")
        miss_output_width = header(miss, "x-imagepipe-output-width")
        assert is_binary(miss_source_format)

        hit = call(request_path() <> "?_debug=1", opts)
        assert hit.status == 200
        assert hit.resp_body == miss.resp_body
        refute_received :origin_fetch

        # status flips to hit; the stored facts replay identically
        assert header(hit, "x-imagepipe-cache") == "hit"
        assert header(hit, "x-imagepipe-source-format") == miss_source_format
        assert header(hit, "x-imagepipe-output-width") == miss_output_width
        assert header(hit, "x-imagepipe-cache-key") =~ ~r/^[0-9a-f]{64}$/

        # origin per-stage timings replay; a live cache entry is appended
        server_timing = header(hit, "server-timing")
        assert server_timing =~ "total;dur="
        assert server_timing =~ "cache;dur="
      after
        File.rm_rf!(cache_root)
      end
    end
  end
```

- [ ] **Step 2: Run**

Run: `mise exec -- mix test test/image_pipe/debug_headers_wire_test.exs`
Expected: PASS. If the hit shows `x-imagepipe-cache: miss` or no debug headers, re-check Task G3 (the `:cache_entry` clause unpacking and `hit_debug_headers/4`). If the second request re-fetches the origin, the entry was not stored — re-check Phase B/C.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/debug_headers_wire_test.exs
git commit -m "test(debug): hit replays stored facts with live cache timing

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task H3: retroactive-toggle test (the headline behavior)

Generate with `allow_debug_headers: false` (entry cached, facts stored unconditionally), then request the same path with `allow_debug_headers: true` + `_debug=1` — full debug headers render off the **same** cached entry, no regeneration.

**Files:**
- Modify: `test/image_pipe/debug_headers_wire_test.exs`

- [ ] **Step 1: Write the test**

```elixir
    test "flipping allow_debug_headers on renders debug headers for an already-cached entry" do
      {base, cache_root} = cached_opts([])

      try do
        # Generated while debug output was OFF — no debug headers, but facts are
        # collected and stored unconditionally.
        off = call(request_path() <> "?_debug=1", Keyword.put(base, :allow_debug_headers, false))
        assert off.status == 200
        assert header(off, "x-imagepipe-cache") == nil
        assert header(off, "x-imagepipe-source-format") == nil
        assert_received :origin_fetch

        # Same path, now with the mount flag ON. Reuses the cached entry (flag is
        # not in the key) and replays the stored facts — no origin re-fetch.
        on = call(request_path() <> "?_debug=1", Keyword.put(base, :allow_debug_headers, true))
        assert on.status == 200
        assert on.resp_body == off.resp_body
        refute_received :origin_fetch

        assert header(on, "x-imagepipe-cache") == "hit"
        assert header(on, "x-imagepipe-source-format") != nil
        assert header(on, "x-imagepipe-output-width") =~ ~r/^\d+$/
        assert header(on, "server-timing") =~ "cache;dur="
      after
        File.rm_rf!(cache_root)
      end
    end
```

- [ ] **Step 2: Run**

Run: `mise exec -- mix test test/image_pipe/debug_headers_wire_test.exs`
Expected: PASS. A failure where `on` shows `cache: miss` (re-generated) means collection is still gated — re-check Phase E (the processor gate removal and the producer `collect?` deletion) and that the sink stored a non-nil `debug`.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/debug_headers_wire_test.exs
git commit -m "test(debug): retroactive allow_debug_headers toggle renders cached facts

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task H4: entry-sharing + no-headers-when-not-requested

Proves `_debug=1` and a plain request share the same cache entry/key, that `allow_debug_headers` on vs off resolve to the same entry, and that a hit without `_debug` emits no debug headers even though facts are stored.

**Files:**
- Modify: `test/image_pipe/debug_headers_wire_test.exs`

- [ ] **Step 1: Write the tests**

```elixir
    test "_debug and a plain request share one cache entry; a plain hit emits no debug headers" do
      {opts, cache_root} = cached_opts(allow_debug_headers: true)

      try do
        first = call(request_path() <> "?_debug=1", opts)
        assert first.status == 200
        assert_received :origin_fetch

        # Plain request (no _debug): hits the same entry, identical bytes, and
        # renders NO debug headers despite the stored facts.
        plain = call(request_path(), opts)
        assert plain.status == 200
        assert plain.resp_body == first.resp_body
        refute_received :origin_fetch
        assert header(plain, "x-imagepipe-cache") == nil
        assert header(plain, "x-imagepipe-source-format") == nil
      after
        File.rm_rf!(cache_root)
      end
    end

    test "the cache key hash is identical regardless of allow_debug_headers/_debug" do
      conn = conn(:get, request_path())

      {:ok, plain_key} =
        ImagePipe.Cache.Key.build(conn, plan_fixture(), [kind: :path, path: "wire"], [])

      {:ok, debug_key} =
        ImagePipe.Cache.Key.build(
          conn(:get, request_path() <> "?_debug=1"),
          plan_fixture(),
          [kind: :path, path: "wire"],
          allow_debug_headers: true
        )

      assert plain_key.hash == debug_key.hash
    end
```

This last test asserts the *key* (not just entry reuse) is byte-identical with the flag/param toggled — closing the issue's "on vs off resolve to the same key" line directly. Build `plan_fixture/0` from the same imgproxy parse the wire tests use, or reuse any existing `%Plan{}` builder in the suite (the assertion only needs the same plan for both calls). If a plan fixture is awkward to construct here, place this test in the cache-key suite (`test/image_pipe/cache/key_test.exs`) instead, where plan fixtures already exist.

- [ ] **Step 2: Run the whole debug wire suite**

Run: `mise exec -- mix test test/image_pipe/debug_headers_wire_test.exs`
Expected: PASS. (The Plan-1 "cache identity invariance" describe block — `_debug` does not change the ETag, conditional GET still 304s — continues to pass and already covers ETag invariance under the flag.)

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/debug_headers_wire_test.exs
git commit -m "test(debug): _debug shares the cache entry and a plain hit stays clean

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase I — Conformance doc + full gate

### Task I1: imgproxy support matrix (confirm no change)

Plan 2 changes no parser surface (no imgproxy option), no processing stage/order, and no output pixels — it adds a response-observability surface and a cache-metadata field. Per the repo's conformance rule, that is **none of** the surface/stage/pixel axes. The plan-review compatibility lens confirmed the matrix already documents the `x-imagepipe-*` debug-header surface (added in Plan 1) at `docs/imgproxy_support_matrix.md:720-740`, including the deliberate non-implementation of imgproxy's `IMGPROXY_ENABLE_DEBUG_HEADERS`/`X-Origin-*`/`X-Result-*` contract.

**Files:**
- No change expected: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Re-read `docs/imgproxy_support_matrix.md:720-740` and confirm**

Confirm the existing prose still accurately describes the surface after Plan 2 (the hit-path additions — `Cache: hit`, `Cache-Key`, live `cache;dur` — are all within the already-documented opt-in `x-imagepipe-*` / `_debug` surface and appear on no default imgproxy response). Expected: **no edit required.** Only if the existing prose has gone stale relative to Plan 2 (e.g. it enumerates specific headers and now misses `Cache-Key`) make a minimal prose update and commit it; otherwise record "no matrix change required (product-neutral; surface already documented)" in the PR description and move on.

- [ ] **Step 2: Commit (only if the prose actually changed)**

```bash
git add docs/imgproxy_support_matrix.md
git commit -m "docs(imgproxy): refresh debug response header note

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task I2: full precommit gate

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
(Runs `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`.)
Expected: all green. Fix formatting (`mise exec -- mix format`), any credo findings, and any failing tests.

Watch for: the dangling `.credo.exs` symlink failure mode (a worktree gotcha) — if `mix format --check-formatted` fails repo-wide, `rm` any untracked dangling `.credo.exs` symlink and re-run.

- [ ] **Step 2: Final commit if formatting changed**

```bash
git add -A
git commit -m "chore(debug): formatting and gate fixes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review (completed during authoring)

- **Spec coverage (Plan 2 scope):**
  - *Collection vs. rendering — unconditional collection/storage:* Phase E (processor gate removed, producer `collect?` deleted) + Phase B (sink stores on every write).
  - *Cache key / ETag exclude the flag and `_debug`:* unchanged by design (the key derives from plan + negotiated Accept + source identity; `_debug` is stripped/ignored in the plug). The Plan-1 "cache identity invariance" tests stay; Task H4 + H3 prove flag-on/off and `_debug`/plain share one entry.
  - *Filesystem reshape in place, no version bump:* Phase C (serialize/validate/deserialize carry `debug`; stale entries fail → miss).
  - *Hit-path render (stored `Info`, `Cache: hit`, live `cache;dur`):* Phase G3 (sender) + Phase F (renderer `cache;dur` already existed; `cache_key` added).
  - *Stored vs re-derived split:* Key design decision #1 — stored full `Info`; live `Accept`/`Cache`/`Cache-Key`/serve-time via render options. Flagged for the compatibility/spec reviewer.
  - *`X-ImagePipe-Cache-Key` (this phase owns `Key` stringification):* Phase F (`:cache_key` option) + Phase G (`key.hash` on both paths).
  - *Retroactive-toggle test:* Task H3.
  - *Best-effort rescue consolidation + `[:debug, :collect, :error]` event with full telemetry sync:* Phase E1 + Phase D (Logger, Capture, docs).
  - *Metadata round-trip test:* Task C3.
- **`cost_us` preserved** for the Admission cost model (decision #2); the debug Server-Timing uses `Info.timings.total`.
- **Type/arity consistency:** the `:cache_entry` delivery tuple is a 5-tuple in **both** `runner.ex` and `sender.ex` (`@type delivery()` and the build/match sites); `send_cache_entry/6`; `prepare_supervised_session/6`; `prepared_stream/5`; `Debug.Headers.render/2` accepts `:cache_key`; `PreparedStream` gains `cache_key`; `Cache.Entry`/`Metadata` gain `debug`; `Sink.response_metadata/3`.
- **Boundary:** `cache → debug` added (Task A1); `request → debug` and `response → debug` already exist from Plan 1 (the runner uses `Debug.Timing`, the sender uses `Debug.Headers`/`Info`).
- **Known verification points flagged inline:** the exporter test's one-shot list (Task D2 Step 5); the `file_system_test.exs` key-building helper (Task C3 Step 1); the `RootHTTPAdapter` alias name in the debug wire suite (Task H1 Step 1); the `plan_fixture/0`/key-builder for the key-equality test (Task H4).

## Plan-review cycle (completed before execution)

Four parallel reviewers with disjoint lenses (code-faithfulness, spec/design conformance, **imgproxy compatibility**, telemetry+serialization safety) reviewed this plan against the merged `main`. Resolved findings folded in:

- **Event name `:exception` → `:error` (BLOCKING).** A one-shot ending in `:exception` collides with the repo's span-triple convention: `Logger.handle_event/4` would route it to `exception_message/2` (rendering `meta[:kind]`/`meta[:reason]`, printing `( nil)`), and `Capture.classify/2` would treat it as a span exception. Renamed to `[:debug, :collect, :error]` so the normal `message/3`/`level_for/3` path renders it (Phase D rationale callout).
- **Logger `:all` silently drops the new event (BLOCKING).** `expand_groups(:all)` returns `Map.keys(@group_span_events)`, which has no `:debug` key. Task D1 Step 3 now adds `debug: []` to `@group_span_events` (mirroring `http_cache: []`) rather than merely "verifying".
- **`request_runner_test.exs` 4-tuple assertions (BLOCKING).** ~10 `:cache_entry` matches break on the 4→5 tuple change; Task G3 Step 4 updates them.
- **`file_system_test.exs` `metadata/3` fixture (BLOCKING).** The strict `validate_metadata/1` pattern now requires `debug:`; Task C2 Step 4 adds `debug: nil` to the fixture helper so the pre-existing validation tests stay green.
- **Direct cache-key equality test (NON-BLOCKING add).** Task H4 now asserts `Cache.Key.build(...).hash` is identical with the flag/`_debug` toggled.

Confirmed sound by review (no change needed): the stored-vs-re-derived decision #1 (verified against `key.ex`/`policy.ex`/`negotiation.ex` — output_format/negotiated/pipeline are all key-determining, so reading them from the stored `Info` equals re-deriving; only raw `Accept` differs and is supplied live); `:erlang.binary_to_term(_, [:safe])` decodes the `Info` struct safely (unknown atoms are *created*, not rejected; genuine corruption → `ArgumentError` → `:decode_failed` → miss); `:error` already in Capture `@safe_keys`; the product-neutral imgproxy claim (no key fork, byte-identical non-debug responses, `_debug` invisible to the path-only imgproxy parser; the matrix already documents the `x-imagepipe-*` surface at `docs/imgproxy_support_matrix.md:720-740`, so Task I1 is genuinely a no-op confirmation).
