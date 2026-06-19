# Cache Bug Trio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three independent cache correctness bugs (#181 ETag/detector divergence, #183 raising adapter crashes, #184 content-disposition overwrite on cache hit) in one PR.

**Architecture:** Each fix is local to one call site. #181 lifts a private function to a public one and moves the call earlier in the plug pipeline. #183 adds `rescue` blocks at each adapter call boundary. #184 reorders the content-disposition computation relative to the merge/reject step.

**Tech Stack:** Elixir, Plug, `:telemetry`

---

### Task 1: Fix #181 — ETag missing detector identity

**Files:**
- Modify: `lib/image_pipe/request/runner.ex:257-270` — rename `put_detector_identity/2` to public `with_detector_identity/2`; remove its call from `run_with_cache_config`
- Modify: `lib/image_pipe/plug.ex:83-84` — call `Runner.with_detector_identity/2` before `HTTPCache.prepare`
- Test: `test/image_pipe/request/http_cache_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/request/http_cache_test.exs`, after the existing `use` / `alias` block. Add `alias ImagePipe.Plan.Pipeline` (already present) and `alias ImagePipe.Plan.Operation.CropGuided`:

```elixir
alias ImagePipe.Plan.Operation.CropGuided
```

Then add these two tests after the existing `"set-cookie suppresses generated public cache headers"` test:

```elixir
test "detector_identity in opts produces a different ETag" do
  base =
    HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

  with_identity =
    HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(),
      opts(detector_identity: {"MyDetector", "model-v2"})
    )

  assert base.etag != nil
  assert with_identity.etag != nil
  assert base.etag != with_identity.etag
end

test "changing detector_identity does not affect ETag when opts carry no identity" do
  first = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())
  second = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

  assert first.etag == second.etag
end
```

- [ ] **Step 2: Run the tests to confirm they pass already**

These tests exercise `HTTPCache.prepare` directly with the opts already containing `detector_identity`, so they pass before the fix — they document the contract of `etag_material`.

```bash
mise exec -- mix test test/image_pipe/request/http_cache_test.exs
```

Expected: all pass (including the two new ones).

- [ ] **Step 3: Update `runner.ex` — rename to public + remove inner call**

Both changes go in one edit to keep the file compiling throughout.

In `lib/image_pipe/request/runner.ex`:

1. Change `defp put_detector_identity(opts, plan) do` → `def with_detector_identity(opts, plan) do`

2. In `run_with_cache_config`, change the `Cache.lookup` call (lines ~92–97) from:

```elixir
              Cache.lookup(
                conn,
                plan,
                resolved_source.identity,
                put_detector_identity(opts, plan)
              )
```

to:

```elixir
              Cache.lookup(
                conn,
                plan,
                resolved_source.identity,
                opts
              )
```

- [ ] **Step 4: Call `Runner.with_detector_identity` in `plug.ex` before `HTTPCache.prepare`**

In `lib/image_pipe/plug.ex`, inside `do_call_with_plan/4`, in the `with` success block (after `Source.resolve`):

```elixir
    prepared_http_cache = HTTPCache.prepare(conn, plan, resolved_source, opts)
    send_conditional_response(conn, plan, resolved_source, prepared_http_cache, opts)
```

change to:

```elixir
    opts = Runner.with_detector_identity(opts, plan)
    prepared_http_cache = HTTPCache.prepare(conn, plan, resolved_source, opts)
    send_conditional_response(conn, plan, resolved_source, prepared_http_cache, opts)
```

- [ ] **Step 5: Run the full test suite**

```bash
mise exec -- mix test
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/request/runner.ex lib/image_pipe/plug.ex test/image_pipe/request/http_cache_test.exs
git commit -m "fix(cache): resolve detector identity once in plug, feed same opts to ETag and cache key (#181)"
```

---

### Task 2: Fix #183 — Raising adapter fails closed

**Files:**
- Modify: `lib/image_pipe/cache.ex:152-165` — add `rescue` in `get_configured`
- Modify: `lib/image_pipe/cache/sink.ex:139-157` — add `rescue` in `do_write_chunk`
- Modify: `lib/image_pipe/cache/sink.ex:160-165` — add `rescue` inside the `Telemetry.span` lambda in `emit_commit_result`
- Modify: `lib/image_pipe/cache/sink.ex:201-207` — add `rescue` in `abort_adapter`
- Test: `test/image_pipe/cache_test.exs`

- [ ] **Step 1: Add raising adapter modules to `cache_test.exs`**

Add these two module definitions alongside the existing adapter modules at the top of `test/image_pipe/cache_test.exs` (after `SinkAdmissionRejectedAdapter` around line 165):

```elixir
  defmodule RaisingGetAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: raise("adapter get crashed")
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule RaisingCommitAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: raise("adapter commit crashed")
    def abort_sink(_state, _opts), do: :ok
  end
```

- [ ] **Step 2: Write failing test for `get` raise**

Add to `test/image_pipe/cache_test.exs` alongside the existing `"read errors fail open by default and are logged"` test:

```elixir
  test "lookup returns miss when adapter.get raises" do
    log =
      capture_log(fn ->
        assert {:miss, %Key{}, {:cache_read, %RuntimeError{message: "adapter get crashed"}}} =
                 Cache.lookup(
                   conn(:get, "/_/f:webp/plain/images/cat.jpg"),
                   plan(),
                   source_identity(),
                   cache: {RaisingGetAdapter, []}
                 )
      end)

    assert log =~ "cache read error"
  end
```

- [ ] **Step 3: Write failing test for `commit_sink` raise**

Add to `test/image_pipe/cache_test.exs` alongside the existing `"commit_sink fails open and logs commit errors"` test:

```elixir
  test "commit_sink returns :ok and logs when adapter.commit_sink raises" do
    attach_telemetry([[:image_pipe, :cache, :write, :stop]])

    sink =
      cache_key()
      |> Cache.open_sink(resolved_output(), cache: {RaisingCommitAdapter, []})
      |> Cache.write_chunk("abc", cache: {RaisingCommitAdapter, []})

    log =
      capture_log(fn ->
        assert :ok = Cache.commit_sink(sink, cache: {RaisingCommitAdapter, []})
      end)

    assert log =~ "cache sink commit error"

    assert_receive {:telemetry_event, [:image_pipe, :cache, :write, :stop], _measurements,
                    %{result: :cache_error, cache: :write_error}}
  end
```

- [ ] **Step 4: Run new tests to confirm they fail**

```bash
mise exec -- mix test test/image_pipe/cache_test.exs
```

Expected: the two new tests fail — the `get` raise propagates (test crashes instead of pattern-matching a miss), and the commit raise propagates (test crashes instead of matching `:ok`).

- [ ] **Step 5: Add `rescue` to `Cache.get_configured`**

In `lib/image_pipe/cache.ex`, change `get_configured/3`:

```elixir
  defp get_configured(adapter, key, cache_opts) do
    case adapter.get(key, cache_opts) do
      {:hit, %Entry{} = entry} ->
        handle_hit(entry, key, cache_opts)

      :miss ->
        {:miss, key}

      {:error, reason} ->
        handle_read_error(reason, key, cache_opts)

      unexpected ->
        handle_read_error({:invalid_adapter_result, unexpected}, key, cache_opts)
    end
  rescue
    exception -> handle_read_error(exception, key, cache_opts)
  end
```

- [ ] **Step 6: Add `rescue` inside the `Telemetry.span` lambda in `Sink.emit_commit_result`**

In `lib/image_pipe/cache/sink.ex`, change `emit_commit_result/2`:

```elixir
  defp emit_commit_result(%__MODULE__{} = sink, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :write], %{}, fn ->
      result =
        try do
          sink.adapter.commit_sink(sink.state, sink.adapter_opts)
        rescue
          exception -> {:error, exception}
        end

      {:ok, commit_stop_metadata(result, sink)}
    end)
  end
```

- [ ] **Step 7: Add `rescue` to `Sink.do_write_chunk`**

In `lib/image_pipe/cache/sink.ex`, change `do_write_chunk/3`:

```elixir
  defp do_write_chunk(%__MODULE__{} = sink, chunk, opts) do
    case sink.adapter.write_chunk(sink.state, chunk, sink.adapter_opts) do
      {:ok, adapter_state} ->
        {:ok, %{sink | state: adapter_state}}

      {:error, reason, adapter_state} ->
        sink = %{sink | state: adapter_state}
        emit_abort_cleanup(abort_adapter(sink, opts), :write_error, sink, opts)
        Logger.warning("cache sink write error: #{inspect(reason)}")
        emit_stage_event(:stage_error, :write, reason, sink, opts)
        {:error, reason}

      unexpected ->
        reason = {:invalid_adapter_result, unexpected}
        emit_abort_cleanup(abort_adapter(sink, opts), :write_error, sink, opts)
        Logger.warning("cache sink write error: #{inspect(reason)}")
        emit_stage_event(:stage_error, :write, reason, sink, opts)
        {:error, reason}
    end
  rescue
    exception ->
      emit_abort_cleanup(abort_adapter(sink, opts), :write_error, sink, opts)
      Logger.warning("cache sink write error: #{inspect(exception)}")
      emit_stage_event(:stage_error, :write, exception, sink, opts)
      {:error, exception}
  end
```

- [ ] **Step 8: Add `rescue` to `Sink.abort_adapter`**

In `lib/image_pipe/cache/sink.ex`, change `abort_adapter/2`:

```elixir
  defp abort_adapter(%__MODULE__{} = sink, _opts) do
    case sink.adapter.abort_sink(sink.state, sink.adapter_opts) do
      :ok = ok -> ok
      {:error, _reason} = error -> error
      unexpected -> {:error, {:invalid_adapter_result, unexpected}}
    end
  rescue
    exception -> {:error, exception}
  end
```

- [ ] **Step 9: Run the tests to confirm they pass**

```bash
mise exec -- mix test test/image_pipe/cache_test.exs
```

Expected: all green including the two new tests.

- [ ] **Step 10: Commit**

```bash
git add lib/image_pipe/cache.ex lib/image_pipe/cache/sink.ex test/image_pipe/cache_test.exs
git commit -m "fix(cache): rescue raises from host cache adapter callbacks, translate to fail-open paths (#183)"
```

---

### Task 3: Fix #184 — Cache-hit overwrites host-set content-disposition

**Files:**
- Modify: `lib/image_pipe/response/sender.ex:268-293` — restructure `send_cache_entry/5`; delete `delivery_headers/3`
- Test: `test/image_pipe/cdn_http_cache_wire_test.exs`

- [ ] **Step 1: Write the failing wire test**

Add to `test/image_pipe/cdn_http_cache_wire_test.exs` after the existing `"internal cache hit returns 200 with current prepared etag"` test:

```elixir
  test "host-set content-disposition is preserved on both miss and cache-hit responses" do
    probe_opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheProbe, test_pid: self()},
        http_cache: [mode: :enabled]
      )

    miss_conn =
      conn(:get, "/_/plain/beach.jpg")
      |> put_resp_header("content-disposition", ~s(attachment; filename="custom.jpg"))
      |> ImagePipe.Plug.call(probe_opts)

    assert miss_conn.status == 200

    assert get_resp_header(miss_conn, "content-disposition") == [
             ~s(attachment; filename="custom.jpg")
           ]

    assert_received {:cache_put, %Entry{} = entry}

    hit_opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheHitProbe, test_pid: self(), entry: entry},
        http_cache: [mode: :enabled]
      )

    hit_conn =
      conn(:get, "/_/plain/beach.jpg")
      |> put_resp_header("content-disposition", ~s(attachment; filename="custom.jpg"))
      |> ImagePipe.Plug.call(hit_opts)

    assert hit_conn.status == 200

    assert get_resp_header(hit_conn, "content-disposition") == [
             ~s(attachment; filename="custom.jpg")
           ]
  end
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
mise exec -- mix test test/image_pipe/cdn_http_cache_wire_test.exs
```

Expected: the new test fails — the hit response has ImagePipe's auto-generated content-disposition instead of the host's value.

- [ ] **Step 3: Restructure `send_cache_entry/5` in `sender.ex`**

Replace the current `send_cache_entry/5` body:

```elixir
  defp send_cache_entry(
         %Plug.Conn{} = conn,
         %Entry{} = entry,
         %Response{} = response,
         %CacheHeaders{} = prepared,
         opts
       ) do
    with {:ok, headers} <- Entry.cacheable_headers(entry.headers),
         merged_headers <- merge_delivery_headers(conn, headers, prepared),
         {:ok, headers} <- delivery_headers(merged_headers, response, entry.content_type) do
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

      send_normalized_cache_entry(conn, entry, headers)
    else
      {:error, error} -> send_cache_error(conn, error)
    end
  end
```

with:

```elixir
  defp send_cache_entry(
         %Plug.Conn{} = conn,
         %Entry{} = entry,
         %Response{} = response,
         %CacheHeaders{} = prepared,
         opts
       ) do
    with {:ok, entry_headers} <- Entry.cacheable_headers(entry.headers),
         {:ok, content_disposition} <- Response.content_disposition(response, entry.content_type) do
      merged =
        merge_delivery_headers(
          conn,
          entry_headers ++ [{"content-disposition", content_disposition}],
          prepared
        )

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
```

- [ ] **Step 4: Delete `delivery_headers/3`**

`delivery_headers/3` is now dead code — its only call site was the `with` chain above. Delete these lines from `lib/image_pipe/response/sender.ex`:

```elixir
  defp delivery_headers(response_headers, %Response{} = response, content_type) do
    with {:ok, content_disposition} <- Response.content_disposition(response, content_type) do
      {:ok, response_headers ++ [{"content-disposition", content_disposition}]}
    end
  end
```

- [ ] **Step 5: Run the tests to confirm they pass**

```bash
mise exec -- mix test test/image_pipe/cdn_http_cache_wire_test.exs
```

Expected: all green including the new test.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/response/sender.ex test/image_pipe/cdn_http_cache_wire_test.exs
git commit -m "fix(cache): preserve host-set content-disposition on cache-hit responses (#184)"
```

---

### Task 4: Gate, docs update, and branch rename

**Files:**
- Modify: `docs/cdn-http-cache.md` — verify key/ETag divergence list is still accurate after #181 fix

- [ ] **Step 1: Check the cdn-http-cache doc divergence section**

```bash
grep -n "diverge\|cachebuster\|detector\|ETag\|etag" docs/cdn-http-cache.md | head -30
```

If the doc lists only the cachebuster and vary inputs as deliberate key/ETag divergences (and now detector identity is no longer a divergence — it's included in both), confirm the text is accurate. No changes needed if the doc says "ETag excludes the cachebuster and vary inputs" — that remains true. Detector identity is now correctly included in both.

- [ ] **Step 2: Run the full precommit gate**

```bash
mise run precommit
```

Expected: format ✓, compile ✓, credo ✓, tests ✓.

- [ ] **Step 3: Rename the branch**

```bash
git branch -m fix/cache-etag-detector-raising-adapter-content-disposition
```

- [ ] **Step 4: Push to remote**

```bash
git push -u origin fix/cache-etag-detector-raising-adapter-content-disposition
```
