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

> **Why a wire-level test, not a `HTTPCache.prepare`-direct test:** the bug lives in
> `plug.ex`, which feeds *raw* opts (no `:detector_identity`) to `HTTPCache.prepare`. A test
> that calls `HTTPCache.prepare` with `detector_identity` already in opts passes *before* the
> fix — it pins `etag_material`'s contract (already covered by `cache/key_test.exs`), not the
> broken plug wiring. The regression guard must drive the full `ImagePipe.Plug.call/2` so the
> plug's opts-threading is exercised end-to-end. Three reviewers independently flagged this.

- [ ] **Step 1: Write the failing wire test**

The test uses `ImagePipe.Test.FakeDetector` (`test/support/fake_detector.ex`), whose
`identity/1` returns `{FakeDetector, Keyword.get(opts, :identity, :fake_v1)}`. The `:identity`
opt is an unknown-but-tolerated extension key (`Options.validate_known_opts!` passes it
through to the detector — same mechanism the imgproxy conformance suite uses for
`face_ver`/`object_ver`). A `g:obj:face` URL parses to a `{:detect, …}` guide, so
`with_detector_identity` resolves the identity into both the ETag and the cache key.

Add to `test/image_pipe/cdn_http_cache_wire_test.exs`, after the
`"internal cache hit returns 200 with current prepared etag"` test:

```elixir
  test "detector identity change moves the generated ETag end-to-end (#181 regression)", _ctx do
    etag_for = fn identity ->
      opts =
        ImagePipe.Plug.init(
          parser: ImagePipe.Parser.Imgproxy,
          sources: [path: {StableSource, test_pid: self()}],
          cache: {CacheProbe, test_pid: self()},
          http_cache: [mode: :enabled],
          detector: ImagePipe.Test.FakeDetector,
          identity: identity
        )

      conn =
        ImagePipe.Plug.call(
          conn(:get, "/_/rs:fill:50:50/g:obj:face/f:jpeg/plain/beach.jpg"),
          opts
        )

      assert conn.status == 200
      assert [etag] = get_resp_header(conn, "etag")
      etag
    end

    assert etag_for.(:model_v1) != etag_for.(:model_v2)
  end
```

- [ ] **Step 2: Run the test to confirm it FAILS before the fix**

```bash
mise exec -- mix test test/image_pipe/cdn_http_cache_wire_test.exs
```

Expected: the new test FAILS — both calls produce the same ETag because `plug.ex` feeds raw
opts (detector identity `nil`) to `HTTPCache.prepare`, so the `:model_v1`/`:model_v2`
difference never reaches the ETag.

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

The plug now owns the single point of detector-identity resolution. `with_detector_identity`
is idempotent (`Keyword.put` overwrites with the same value), so a stray second call would be
harmless — but the inner call in `run_with_cache_config` was removed in Step 3 precisely so
the key and ETag derive from one resolution. Don't re-introduce it.

- [ ] **Step 5: Run the wire test to confirm it now PASSES**

```bash
mise exec -- mix test test/image_pipe/cdn_http_cache_wire_test.exs
```

Expected: the #181 regression test passes — the two ETags now differ.

- [ ] **Step 6: Run the full test suite**

```bash
mise exec -- mix test
```

Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/request/runner.ex lib/image_pipe/plug.ex test/image_pipe/cdn_http_cache_wire_test.exs
git commit -m "fix(cache): resolve detector identity once in plug, feed same opts to ETag and cache key (#181)"
```

---

### Task 2: Fix #183 — Raising adapter fails closed

> **Scope: raises only, deliberately.** `rescue` catches raised exceptions (class `:error`),
> which is exactly what the issue describes and what realistic third-party adapters do (an
> S3/Redis client raising on timeout). An adapter that `exit`s or `throw`s, or whose linked
> process dies, is a *different* failure mode handled by OTP supervision, not by this fix —
> we do **not** broaden to `try/catch :exit, :throw`, which would also swallow legitimate
> shutdown/kill signals. The tests are raise-shaped to match.
>
> **Confirmed during planning:** `ImagePipe.Error.tag/1` (`lib/image_pipe/error.ex:9-12`) has a
> catch-all `def tag(_reason), do: :error`, so passing a bare `%RuntimeError{}` into
> `commit_stop_metadata({:error, exception}, …)` → `Error.tag(exception)` yields `:error` and
> does **not** re-raise inside the telemetry lambda. Containment holds.

**Files:**
- Modify: `lib/image_pipe/cache.ex:152-165` — add `rescue` in `get_configured`
- Modify: `lib/image_pipe/cache/sink.ex:139-157` — add `rescue` in `do_write_chunk`
- Modify: `lib/image_pipe/cache/sink.ex:160-165` — add `rescue` inside the `Telemetry.span` lambda in `emit_commit_result`
- Modify: `lib/image_pipe/cache/sink.ex:201-207` — add `rescue` in `abort_adapter`
- Test: `test/image_pipe/cache_test.exs` (unit) and `test/image_pipe/cdn_http_cache_wire_test.exs` (body-delivery)

- [ ] **Step 1: Add raising adapter modules to `cache_test.exs`**

Add these two module definitions alongside the existing adapter modules at the top of `test/image_pipe/cache_test.exs` (after `SinkAdmissionRejectedAdapter` around line 165). The `@impl true` annotations match the existing adapter modules' style and keep `credo --strict` quiet:

```elixir
  defmodule RaisingGetAdapter do
    @behaviour ImagePipe.Cache

    @impl true
    def get(%Key{}, _opts), do: raise("adapter get crashed")
    @impl true
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    @impl true
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    @impl true
    def commit_sink(_state, _opts), do: :ok
    @impl true
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule RaisingCommitAdapter do
    @behaviour ImagePipe.Cache

    @impl true
    def get(%Key{}, _opts), do: :miss
    @impl true
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    @impl true
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    @impl true
    def commit_sink(_state, _opts), do: raise("adapter commit crashed")
    @impl true
    def abort_sink(_state, _opts), do: :ok
  end
```

> Note: the existing adapter modules in this file use bare `def` without `@impl`. If `credo
> --strict` does not flag the missing `@impl` on those (it currently passes), the `@impl true`
> additions here are optional consistency. Match whatever the existing modules do — if they
> stay bare, drop the `@impl true` lines to match. Verify with `mise exec -- mix credo --strict`.

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

- [ ] **Step 9: Run the unit tests to confirm they pass**

```bash
mise exec -- mix test test/image_pipe/cache_test.exs
```

Expected: all green including the two new tests.

- [ ] **Step 10: Add the wire-level body-delivery test**

The unit tests above prove `Cache.commit_sink/2` returns `:ok` on a raise, but the issue's
actual user-visible symptom is a **truncated streamed response** when `commit_sink` raises
after the body was fully encoded. Prove the complete body still reaches the client by
comparing the raising-adapter response against a clean-adapter baseline for the same URL —
byte-identical bodies means no truncation, and no image decode is needed.

Add a raising-commit probe alongside the other probe modules at the top of
`test/image_pipe/cdn_http_cache_wire_test.exs`:

```elixir
  defmodule RaisingCommitProbe do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, _metadata, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: raise("commit boom")
    def abort_sink(_state, _opts), do: :ok
  end
```

Then add this test after the #181 regression test:

```elixir
  test "commit_sink raise still delivers the complete body, byte-identical to a clean cache (#183)" do
    url = "/_/rs:fill:50:50/f:jpeg/plain/beach.jpg"

    clean =
      ImagePipe.Plug.call(
        conn(:get, url),
        ImagePipe.Plug.init(
          parser: ImagePipe.Parser.Imgproxy,
          sources: [path: {StableSource, test_pid: self()}],
          cache: {CacheProbe, test_pid: self()},
          http_cache: [mode: :enabled]
        )
      )

    raising =
      ImagePipe.Plug.call(
        conn(:get, url),
        ImagePipe.Plug.init(
          parser: ImagePipe.Parser.Imgproxy,
          sources: [path: {StableSource, test_pid: self()}],
          cache: {RaisingCommitProbe, []},
          http_cache: [mode: :enabled]
        )
      )

    assert clean.status == 200
    assert raising.status == 200
    assert byte_size(raising.resp_body) > 0
    assert raising.resp_body == clean.resp_body
  end
```

- [ ] **Step 11: Run the wire test to confirm it passes**

```bash
mise exec -- mix test test/image_pipe/cdn_http_cache_wire_test.exs
```

Expected: green. (Before the Step 6 fix this test would 500 / truncate on the raising path;
with the fix the bodies match.)

- [ ] **Step 12: Commit**

```bash
git add lib/image_pipe/cache.ex lib/image_pipe/cache/sink.ex test/image_pipe/cache_test.exs test/image_pipe/cdn_http_cache_wire_test.exs
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
- Modify: `docs/cdn-http-cache.md` — clarify that detector/model identity is part of *both* the key and the ETag

> **Why an edit is required (not just a verify):** the #181 fix changes a doc-relevant fact.
> Pre-fix, detector identity reached the cache key but not the ETag — an accidental key/ETag
> divergence. Post-fix it's folded into both. The divergence section currently names only the
> cachebuster and "configured cache key inputs" as key-only, which a reader could wrongly read
> as also covering detector identity. The compatibility reviewer flagged this as a required
> `cdn-http-cache.md` edit; `docs/imgproxy_support_matrix.md` needs **no** change (#184 restores
> the already-documented "host plugs can add fixed response headers" promise; #181 is an
> ImagePipe-internal cache concern with no imgproxy surface).

- [ ] **Step 1: Edit the key-vs-ETag divergence section in `docs/cdn-http-cache.md`**

Find the "Cache Key Relationship" section (around line 223). After the sentence:

> For example, `cachebuster` changes the internal cache key but leaves the generated ETag unchanged.

add a new sentence:

```markdown
Detector and model identity, by contrast, are part of *both* the internal cache key and the
generated ETag: swapping a detector or model changes the rendition, so it must change the
validator too — a conditional GET will not return `304` against a rendition produced by a
different detector.
```

Re-read the surrounding paragraph after editing to confirm it still flows and that no other
sentence now contradicts it (e.g. any wording implying detector identity is key-only).

- [ ] **Step 2: Run the full precommit gate**

```bash
mise run precommit
```

Expected: format ✓, compile ✓, credo ✓, tests ✓.

- [ ] **Step 3: Commit the doc edit**

```bash
git add docs/cdn-http-cache.md
git commit -m "docs(cache): note detector identity is part of both cache key and ETag (#181)"
```

- [ ] **Step 4: Rename the branch**

```bash
git branch -m fix/cache-etag-detector-raising-adapter-content-disposition
```

- [ ] **Step 5: Push to remote**

```bash
git push -u origin fix/cache-etag-detector-raising-adapter-content-disposition
```
