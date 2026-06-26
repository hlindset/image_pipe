# S3 IAM Credential Providers — Refresh Cache + IMDS + ECS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the S3 source obtain credentials from an EC2 instance role (IMDSv2) or ECS/Fargate/EKS container-credentials endpoint, with a generic refresh cache that fetches once per credential lifetime instead of per request.

**Architecture:** The existing `{:provider, Module, opts}` credential mechanism is the integration point — no signing changes. Two new provider modules (`InstanceRole`, `ContainerCredentials`) implement an extended `fetch_credentials/3` that returns an expiry. A generic, value-agnostic `RefreshCache` (Registry + DynamicSupervisor + per-key `Entry` GenServer) sits between `Credentials.fetch/3` and the providers, giving single-flight fetches, background refresh-before-expiry, warm-on-entry-start, and fail-closed semantics on expired credentials. The cache infrastructure is auto-started under `ImagePipe.Application`, mirroring `SourceSessionSupervisor`.

**Tech Stack:** Elixir, `Req` (HTTP, via the `plug:` option for hermetic tests), `Jason` (JSON decode of metadata responses), `Registry` + `DynamicSupervisor` + `GenServer` (cache), `NimbleOptions` (provider option validation), ExUnit.

**Scope note:** This is host-config capability parity, **not** wire conformance — imgproxy's `IMGPROXY_S3_*` env vars are its host config, not part of the URL dialect. No support-matrix pixel/stage/order change. STS `AssumeRole` (#8) and IRSA web-identity (#7) are **Plan 2**, built on this cache.

**Flagged design decisions (confirm during plan review):**
1. **Cache boundary home** — homed under `ImagePipe.Source.S3.RefreshCache` (inside the existing `Source` boundary), written value-agnostically. Promote to a dedicated util boundary only when a second consumer appears (YAGNI). Requires `ImagePipe.Application` to add `ImagePipe.Source` to its `deps` and `Source` to export `RefreshCache` — the architecture reviewer should confirm this edit.
2. **Provider contract** — `fetch_credentials/3` returns `{:ok, credentials, expiry}` where `expiry` is a `DateTime.t()` or `:never`. Greenfield, so the existing test provider is updated in place (no back-compat shim).

---

## File Structure

**Create:**
- `lib/image_pipe/source/s3/refresh_cache.ex` — facade + supervisor/registry wiring (`fetch/3`, `child_spec/1`). Generic, value-agnostic.
- `lib/image_pipe/source/s3/refresh_cache/entry.ex` — per-key `GenServer`: single-flight, TTL freshness, warm-on-init, background refresh, fail-closed.
- `lib/image_pipe/source/s3/credential_provider.ex` — the `@behaviour` (formalizes `fetch_credentials/3` + expiry contract).
- `lib/image_pipe/source/s3/instance_role.ex` — IMDSv2 provider (#5).
- `lib/image_pipe/source/s3/container_credentials.ex` — ECS/EKS container-credentials provider (#6).
- `test/image_pipe/source/s3/refresh_cache_test.exs`
- `test/image_pipe/source/s3/instance_role_test.exs`
- `test/image_pipe/source/s3/container_credentials_test.exs`

**Modify:**
- `lib/image_pipe/source/s3/credentials.ex` — route the `:provider` clause through `RefreshCache`; expose `normalize/1`.
- `lib/image_pipe/source.ex` — add `RefreshCache` and `CredentialProvider` to `exports`.
- `lib/application.ex` — add `ImagePipe.Source` to `deps`; add `ImagePipe.Source.S3.RefreshCache` to `children`.
- `test/support/image_pipe/source_test/credential_provider.ex` — update to the 3-tuple expiry contract.
- `test/image_pipe/source/s3_test.exs` — update provider-path assertions for the new contract/caching.
- `test/image_pipe/imgproxy_wire_conformance_test.exs` — same provider-path reconciliation (also drives `CredentialProvider`).
- `docs/s3.md` (or the S3 section of the README/source docs — see Task 7) — document the two providers + env-var→static recipe.

---

## Task 1: Generic refresh-cache Entry (single-flight, TTL, warm-on-init, background refresh, fail-closed)

This is pure OTP — no HTTP. The Entry caches an opaque `value` with an `expires_at`, fetched by a 0-arity `fetch_fun` returning `{:ok, value, expiry}` or `{:error, reason}`.

**Files:**
- Create: `lib/image_pipe/source/s3/refresh_cache/entry.ex`
- Test: `test/image_pipe/source/s3/refresh_cache_test.exs`

- [ ] **Step 1: Write the failing test — miss then hit, single fetch**

Create `test/image_pipe/source/s3/refresh_cache_test.exs`:

```elixir
defmodule ImagePipe.Source.S3.RefreshCacheTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.RefreshCache.Entry

  defp start_entry(opts) do
    key = Keyword.get(opts, :key, make_ref())
    opts = Keyword.put_new(opts, :key, key)
    opts = Keyword.put_new(opts, :name, nil)
    start_supervised!({Entry, opts})
  end

  test "fetches once on warm-up and serves the cached value on get" do
    test = self()

    fetch_fun = fn ->
      send(test, :fetched)
      {:ok, :creds, :never}
    end

    pid = start_entry(fetch_fun: fetch_fun)

    assert {:ok, :creds} = Entry.get(pid)
    assert_received :fetched
    # second get does not re-fetch
    assert {:ok, :creds} = Entry.get(pid)
    refute_received :fetched
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/s3/refresh_cache_test.exs`
Expected: FAIL — `ImagePipe.Source.S3.RefreshCache.Entry` is undefined.

- [ ] **Step 3: Implement the Entry GenServer**

Create `lib/image_pipe/source/s3/refresh_cache/entry.ex`:

```elixir
defmodule ImagePipe.Source.S3.RefreshCache.Entry do
  @moduledoc false
  # Per-key cache process for the generic RefreshCache.
  #
  # Holds an opaque `value` with an `expires_at` (`DateTime.t()` or `:never`),
  # produced by a 0-arity `fetch_fun` returning `{:ok, value, expiry}` or
  # `{:error, reason}`. Properties:
  #   * single-flight: concurrent `get/2` callers during an in-flight fetch all
  #     wait on the one fetch (they queue as waiters),
  #   * warm-on-init: a fetch is kicked in `init/1`, so the process warms as soon
  #     as it is created,
  #   * background refresh: a timer fires `refresh_margin_ms` before expiry,
  #   * fail-closed: an expired value is never served; if refresh fails while the
  #     value is still fresh, the fresh value is served.
  use GenServer

  # Refresh this far before expiry (matches the AWS SDK's default 5-minute
  # ExpiryWindow rather than a tighter margin that risks serving a credential
  # S3 rejects mid-flight).
  @default_refresh_margin_ms 300_000
  # After a failed background refresh that served a still-fresh value, retry on
  # this bounded interval (never past expiry) so a transient blip doesn't disable
  # all future refresh.
  @refresh_retry_ms 5_000
  @default_call_timeout 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :key)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @spec get(GenServer.server(), timeout()) :: {:ok, term()} | {:error, term()}
  def get(server, timeout \\ @default_call_timeout) do
    GenServer.call(server, :get, timeout)
  end

  @impl true
  def init(opts) do
    state = %{
      key: Keyword.fetch!(opts, :key),
      fetch_fun: Keyword.fetch!(opts, :fetch_fun),
      refresh_margin_ms: Keyword.get(opts, :refresh_margin_ms, @default_refresh_margin_ms),
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      value: nil,
      expires_at: nil,
      task: nil,
      waiters: [],
      refresh_timer: nil
    }

    {:ok, start_fetch(state)}
  end

  @impl true
  def handle_call(:get, from, state) do
    if fresh?(state) do
      {:reply, {:ok, state.value}, state}
    else
      {:noreply, start_fetch(%{state | waiters: [from | state.waiters]})}
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    {:noreply, start_fetch(%{state | refresh_timer: nil})}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_result(result, %{state | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, handle_result({:error, {:crash, reason}}, %{state | task: nil})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Redact the cached value from crash reports / observer — it holds credentials.
  @impl true
  def format_status(%{state: state} = status),
    do: %{status | state: %{state | value: :redacted}}

  def format_status(status), do: status

  # --- internals ---

  # single-flight: never run two fetches at once
  defp start_fetch(%{task: %Task{}} = state), do: state

  defp start_fetch(state) do
    fun = state.fetch_fun
    task = Task.async(fn -> safe_call(fun) end)
    %{state | task: task}
  end

  # A crashing fetch_fun is mapped to an OPAQUE error — never carry a raw
  # exception or HTTP body here, since it may embed credential material that
  # would leak into a crash log. (`Process.exit(_, :kill)` is uncatchable; if the
  # task is killed, the link brings the entry down and the supervisor restarts
  # it — losing the cached value and re-fetching, which is correct.)
  defp safe_call(fun) do
    fun.()
  rescue
    _exception -> {:error, :fetch_crashed}
  catch
    _kind, _value -> {:error, :fetch_crashed}
  end

  defp handle_result({:ok, value, expires_at}, state) do
    state = %{state | value: value, expires_at: expires_at}
    state = reply_waiters({:ok, value}, state)
    schedule_refresh(state)
  end

  defp handle_result({:error, reason}, state) do
    if fresh?(state) do
      # refresh failed but the current value is still valid: serve it AND re-arm
      # a bounded retry, so a transient failure does not disable all future
      # background refresh (otherwise the entry sits idle until expiry, then
      # fails closed on the next get).
      state = reply_waiters({:ok, state.value}, state)
      schedule_retry(state)
    else
      reply_waiters({:error, reason}, state)
    end
  end

  defp reply_waiters(reply, state) do
    Enum.each(state.waiters, fn from -> GenServer.reply(from, reply) end)
    %{state | waiters: []}
  end

  defp fresh?(%{value: nil}), do: false
  defp fresh?(%{expires_at: :never}), do: true
  defp fresh?(%{expires_at: nil}), do: false

  defp fresh?(%{expires_at: %DateTime{} = expires_at, now_fun: now_fun}) do
    DateTime.compare(now_fun.(), expires_at) == :lt
  end

  defp schedule_refresh(%{expires_at: %DateTime{} = expires_at} = state) do
    state = cancel_timer(state)
    diff_ms = DateTime.diff(expires_at, state.now_fun.(), :millisecond)
    ms = max(0, diff_ms - state.refresh_margin_ms)
    %{state | refresh_timer: Process.send_after(self(), :refresh, ms)}
  end

  defp schedule_refresh(state), do: state

  defp schedule_retry(%{expires_at: %DateTime{} = expires_at} = state) do
    state = cancel_timer(state)
    ms_to_expiry = max(0, DateTime.diff(expires_at, state.now_fun.(), :millisecond))
    ms = min(@refresh_retry_ms, ms_to_expiry)
    %{state | refresh_timer: Process.send_after(self(), :refresh, ms)}
  end

  defp schedule_retry(state), do: state

  defp cancel_timer(%{refresh_timer: nil} = state), do: state

  defp cancel_timer(%{refresh_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | refresh_timer: nil}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/source/s3/refresh_cache_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/source/s3/refresh_cache/entry.ex test/image_pipe/source/s3/refresh_cache_test.exs
git commit -m "feat(s3): generic refresh-cache entry with warm-on-init"
```

- [ ] **Step 6: Write the single-flight test**

Append to `test/image_pipe/source/s3/refresh_cache_test.exs` (inside the module). The warm-on-init fetch blocks on `:release`; the concurrent `get/2` calls must join it as waiters so only one fetch runs. `wait_for_waiters/2` busy-waits via `:sys.get_state` (no `Process.sleep`, per the test guidelines) and proves the waiters actually enqueued:

```elixir
  test "concurrent gets during an in-flight fetch trigger only one fetch" do
    test = self()
    {:ok, gate} = Agent.start_link(fn -> 0 end)

    fetch_fun = fn ->
      Agent.update(gate, &(&1 + 1))
      send(test, {:fetch_started, self()})

      receive do
        :release -> :ok
      after
        1_000 -> :ok
      end

      {:ok, :creds, :never}
    end

    pid = start_entry(fetch_fun: fetch_fun)

    # the warm-on-init fetch has started and is blocked on :release
    assert_receive {:fetch_started, fetch_pid}

    callers = for _ <- 1..5, do: Task.async(fn -> Entry.get(pid) end)

    # ensure the 5 gets have enqueued as waiters before releasing the one fetch
    wait_for_waiters(pid, 5)
    send(fetch_pid, :release)

    results = Task.await_many(callers)
    assert Enum.all?(results, &(&1 == {:ok, :creds}))
    assert Agent.get(gate, & &1) == 1
  end

  defp wait_for_waiters(pid, n) do
    if length(:sys.get_state(pid).waiters) >= n do
      :ok
    else
      wait_for_waiters(pid, n)
    end
  end
```

- [ ] **Step 7: Run the single-flight test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/source/s3/refresh_cache_test.exs`
Expected: PASS (the Entry already implements single-flight via `start_fetch/1`).

- [ ] **Step 8: Write the fail-closed + serve-on-refresh-failure tests**

Append (inside the module):

```elixir
  test "fails closed when there is no fresh value and the fetch errors" do
    fetch_fun = fn -> {:error, :unavailable} end
    pid = start_entry(fetch_fun: fetch_fun)
    assert {:error, :unavailable} = Entry.get(pid)
  end

  test "serves the still-fresh value when a refresh fails" do
    test = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    # now is fixed; expiry is in the future so value stays fresh.
    now = ~U[2026-06-26 00:00:00Z]
    future = ~U[2026-06-26 01:00:00Z]

    fetch_fun = fn ->
      n = Agent.get_and_update(calls, fn n -> {n, n + 1} end)
      send(test, {:call, n})
      case n do
        0 -> {:ok, :good, future}
        _ -> {:error, :transient}
      end
    end

    pid =
      start_entry(
        fetch_fun: fetch_fun,
        now_fun: fn -> now end,
        # margin larger than the hour-to-expiry forces an immediate :refresh
        refresh_margin_ms: 3_600_001
      )

    assert_receive {:call, 0}
    # background refresh fires (and fails), but value is still fresh:
    assert_receive {:call, 1}
    # force the failed-refresh result to be applied before asserting, so this
    # actually exercises the serve-stale-on-error branch (not just the pre-error
    # state).
    _ = :sys.get_state(pid)
    assert {:ok, :good} = Entry.get(pid)
  end

  test "does not serve an expired value; re-fetches on get" do
    test = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    # now advances: first fetch expiry already in the past relative to a later get
    past = ~U[2026-06-26 00:00:00Z]
    later = ~U[2026-06-26 02:00:00Z]
    {:ok, clock} = Agent.start_link(fn -> past end)

    fetch_fun = fn ->
      n = Agent.get_and_update(calls, fn n -> {n, n + 1} end)
      send(test, {:call, n})
      {:ok, {:creds, n}, ~U[2026-06-26 00:30:00Z]}
    end

    pid =
      start_entry(
        fetch_fun: fetch_fun,
        now_fun: fn -> Agent.get(clock, & &1) end,
        refresh_margin_ms: 0
      )

    assert_receive {:call, 0}
    assert {:ok, {:creds, 0}} = Entry.get(pid)

    # advance the clock past expiry; the cached value is now stale
    Agent.update(clock, fn _ -> later end)
    assert {:ok, {:creds, 1}} = Entry.get(pid)
    assert_received {:call, 1}
  end
```

- [ ] **Step 9: Run the full Entry test file**

Run: `mise exec -- mix test test/image_pipe/source/s3/refresh_cache_test.exs`
Expected: PASS (all tests). If "serve-on-refresh-failure" flakes on timer ordering, confirm `schedule_refresh/1` computes `ms = 0` for the large-margin case so `:refresh` is delivered promptly.

- [ ] **Step 10: Commit**

```bash
git add test/image_pipe/source/s3/refresh_cache_test.exs
git commit -m "test(s3): cover single-flight, fail-closed, refresh-failure, expiry"
```

---

## Task 2: Refresh-cache facade + Registry/DynamicSupervisor + auto-start

Adds the lookup-or-start facade and wires the infrastructure into the application tree.

**Files:**
- Create: `lib/image_pipe/source/s3/refresh_cache.ex`
- Modify: `lib/image_pipe/source.ex` (exports), `lib/application.ex` (deps + children)
- Test: `test/image_pipe/source/s3/refresh_cache_test.exs`

- [ ] **Step 1: Write the failing facade test**

Append to `test/image_pipe/source/s3/refresh_cache_test.exs`:

```elixir
  describe "facade" do
    alias ImagePipe.Source.S3.RefreshCache

    setup do
      # the facade's Registry + DynamicSupervisor are started by the application;
      # in test they are available because :image_pipe is started.
      :ok
    end

    test "fetch/3 lazily starts one entry per key and caches across calls" do
      test = self()
      key = {:unit, make_ref()}

      fun = fn ->
        send(test, :fetched)
        {:ok, :v, :never}
      end

      assert {:ok, :v} = RefreshCache.fetch(key, fun)
      assert_received :fetched
      assert {:ok, :v} = RefreshCache.fetch(key, fun)
      refute_received :fetched
    end

    test "distinct keys get distinct entries" do
      k1 = {:unit, make_ref()}
      k2 = {:unit, make_ref()}
      assert {:ok, 1} = RefreshCache.fetch(k1, fn -> {:ok, 1, :never} end)
      assert {:ok, 2} = RefreshCache.fetch(k2, fn -> {:ok, 2, :never} end)
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/s3/refresh_cache_test.exs`
Expected: FAIL — `ImagePipe.Source.S3.RefreshCache` undefined.

- [ ] **Step 3: Implement the facade**

Create `lib/image_pipe/source/s3/refresh_cache.ex`:

```elixir
defmodule ImagePipe.Source.S3.RefreshCache do
  @moduledoc false
  # Generic, value-agnostic refresh cache.
  #
  # `fetch(key, fetch_fun)` returns `{:ok, value}` or `{:error, reason}`, starting
  # a per-key `Entry` process on first use (registered in `@registry`, supervised
  # by `@supervisor`). The cache itself never interprets `value` — credential
  # specifics live in `ImagePipe.Source.S3.Credentials`.
  #
  # The `child_spec/1` returned here starts the Registry + DynamicSupervisor pair;
  # `ImagePipe.Application` lists this module as a single child.
  use Supervisor

  alias ImagePipe.Source.S3.RefreshCache.Entry

  @registry __MODULE__.Registry
  @supervisor __MODULE__.DynamicSupervisor
  @default_call_timeout 10_000

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @spec fetch(term(), (-> {:ok, term(), term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def fetch(key, fetch_fun, opts \\ []) when is_function(fetch_fun, 0) do
    case ensure_entry(key, fetch_fun, opts) do
      {:ok, server} ->
        Entry.get(server, Keyword.get(opts, :call_timeout, @default_call_timeout))

      :error ->
        {:error, :cache_entry_unavailable}
    end
  end

  defp ensure_entry(key, fetch_fun, opts) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        entry_opts =
          opts
          |> Keyword.take([:refresh_margin_ms, :now_fun, :call_timeout])
          |> Keyword.merge(
            key: key,
            fetch_fun: fetch_fun,
            name: {:via, Registry, {@registry, key}}
          )

        case DynamicSupervisor.start_child(@supervisor, {Entry, entry_opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          # lost a start race after a crash, or init failed: re-look up once,
          # never raise into the request process (the caller maps :error to
          # {:source, :credentials_unavailable}).
          {:error, _reason} -> relookup(key)
        end
    end
  end

  defp relookup(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end
end
```

- [ ] **Step 4: Wire the facade into the application tree**

Modify `lib/application.ex` — add `ImagePipe.Source` to `deps` and the cache to `children`:

```elixir
  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Output,
      ImagePipe.Request,
      ImagePipe.Source,
      ImagePipe.Telemetry
    ]
```

```elixir
    children = [
      ImagePipe.Telemetry.Trace.OtelReplay,
      ImagePipe.Source.S3.RefreshCache,
      ImagePipe.Request.SourceSessionSupervisor
    ]
```

- [ ] **Step 5: Export the facade from the Source boundary**

Modify `lib/image_pipe/source.ex` `exports:` list — add `RefreshCache`:

```elixir
    exports: [
      CacheSemantics,
      Resolved,
      Response,
      StreamError,
      HTTP,
      File,
      S3,
      RefreshCache
    ]
```

- [ ] **Step 6: Run the facade tests + boundary check**

Run: `mise exec -- mix test test/image_pipe/source/s3/refresh_cache_test.exs`
Expected: PASS.

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean (Boundary is enforced at compile time; a missing export or dep edge fails here).

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/source/s3/refresh_cache.ex lib/image_pipe/source.ex lib/application.ex test/image_pipe/source/s3/refresh_cache_test.exs
git commit -m "feat(s3): refresh-cache facade auto-started under application tree"
```

---

## Task 3: Provider behaviour + expiry contract + route credentials through the cache

Formalizes the provider contract and makes the existing `{:provider, …}` path cache transparently.

**Files:**
- Create: `lib/image_pipe/source/s3/credential_provider.ex`
- Modify: `lib/image_pipe/source/s3/credentials.ex`, `lib/image_pipe/source.ex` (export the behaviour), `test/support/image_pipe/source_test/credential_provider.ex`, `test/image_pipe/source/s3_test.exs`
- Test: `test/image_pipe/source/s3/credentials_cache_test.exs` (new)

- [ ] **Step 1: Define the behaviour**

Create `lib/image_pipe/source/s3/credential_provider.ex`:

```elixir
defmodule ImagePipe.Source.S3.CredentialProvider do
  @moduledoc """
  Behaviour for host-pluggable S3 credential providers.

  A provider resolves temporary or permanent AWS credentials for a given scope
  (the bucket name). It is selected via the source config:

      credentials: {:provider, MyApp.S3.InstanceRole, []}

  Results are cached by `ImagePipe.Source.S3.RefreshCache` keyed by
  `{provider, opts, scope}`, so `fetch_credentials/3` is invoked once per
  credential lifetime, not per request. Because results are cached across
  requests, the provider MUST derive its behaviour from `scope` and `opts` only;
  `runtime_opts` is reserved and is currently passed as `[]`.

  The returned `expiry` is a `DateTime.t()` for temporary credentials (the cache
  refreshes shortly before it) or `:never` for permanent credentials (cached for
  the process lifetime, never refreshed).
  """

  @type scope :: String.t()
  @type credentials :: keyword()
  @type expiry :: DateTime.t() | :never

  @callback fetch_credentials(scope(), keyword(), keyword()) ::
              {:ok, credentials(), expiry()} | {:error, term()}

  @doc """
  Validate host-supplied provider options at config time. Optional; when
  implemented, `ImagePipe.Source.S3.Credentials.validate/1` calls it during
  source-config validation so malformed options fail at startup, not per request.
  """
  @callback validate_options(keyword()) :: :ok | {:error, term()}

  @optional_callbacks validate_options: 1
end
```

- [ ] **Step 2: Write the failing cache-integration test**

Create `test/image_pipe/source/s3/credentials_cache_test.exs`:

```elixir
defmodule ImagePipe.Source.S3.CredentialsCacheTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.Credentials

  defmodule CountingProvider do
    @behaviour ImagePipe.Source.S3.CredentialProvider

    @impl true
    def fetch_credentials(scope, opts, _runtime_opts) do
      send(Keyword.fetch!(opts, :test), {:fetched, scope})

      {:ok,
       [access_key_id: "AKIA", secret_access_key: "SECRET", token: "TOK"],
       :never}
    end
  end

  test "provider results are cached per scope and normalized" do
    opts = [test: self()]
    provider = {:provider, CountingProvider, opts}
    # the RefreshCache is application-global and this suite is async: true, so
    # scopes MUST be unique per test or assert/refute_received pass tautologically.
    bucket_a = "bucket-a-#{System.unique_integer([:positive])}"
    bucket_b = "bucket-b-#{System.unique_integer([:positive])}"

    assert {:ok, creds} = Credentials.fetch(bucket_a, provider, [])
    assert creds[:access_key_id] == "AKIA"
    assert creds[:token] == "TOK"
    assert_received {:fetched, ^bucket_a}

    # cached: no second fetch for the same scope
    assert {:ok, _} = Credentials.fetch(bucket_a, provider, [])
    refute_received {:fetched, ^bucket_a}

    # different scope → separate entry → fetched
    assert {:ok, _} = Credentials.fetch(bucket_b, provider, [])
    assert_received {:fetched, ^bucket_b}
  end

  test "fails closed as :credentials_unavailable when the provider errors" do
    defmodule FailingProvider do
      @behaviour ImagePipe.Source.S3.CredentialProvider
      @impl true
      def fetch_credentials(_scope, _opts, _runtime), do: {:error, :nope}
    end

    provider = {:provider, FailingProvider, []}
    assert {:error, {:source, :credentials_unavailable}} =
             Credentials.fetch("bucket-c-#{System.unique_integer()}", provider, [])
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/s3/credentials_cache_test.exs`
Expected: FAIL — the `:provider` path does not yet cache or expect a 3-tuple.

- [ ] **Step 4: Route the provider path through the cache and validate provider options at config time**

Modify `lib/image_pipe/source/s3/credentials.ex`.

**(a)** Add the alias and replace the existing `fetch(scope, {:provider, provider, opts}, runtime_opts)` clause with:

```elixir
  alias ImagePipe.Source.S3.RefreshCache

  def fetch(scope, {:provider, provider, opts}, _runtime_opts) do
    key = {:s3_credentials, provider, opts, scope}

    fetch_fun = fn ->
      case provider.fetch_credentials(scope, opts, []) do
        {:ok, credentials, expiry} ->
          case normalize(credentials) do
            {:ok, normalized} -> {:ok, normalized, expiry}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}

        _other ->
          {:error, :invalid_credential_provider_result}
      end
    end

    case RefreshCache.fetch(key, fetch_fun) do
      {:ok, credentials} -> {:ok, credentials}
      {:error, _reason} -> {:error, {:source, :credentials_unavailable}}
    end
  end
```

`normalize/1` stays `defp` — the closure above is in the same module, so no visibility change is needed (exposing it would be an implementation-detail leak, and no external caller needs it).

**(b)** Extend the existing `validate({:provider, provider, opts})` clause to call the provider's optional `validate_options/1`, so malformed host config fails at startup (the source-config validation boundary) rather than per request:

```elixir
  def validate({:provider, provider, opts})
      when is_atom(provider) and is_list(opts) do
    cond do
      not (Code.ensure_loaded?(provider) and
             function_exported?(provider, :fetch_credentials, 3)) ->
        {:error, {:invalid_source_config, :invalid_credential_provider}}

      function_exported?(provider, :validate_options, 1) ->
        case provider.validate_options(opts) do
          :ok -> {:ok, {:provider, provider, opts}}
          {:error, reason} -> {:error, {:invalid_source_config, reason}}
        end

      true ->
        {:ok, {:provider, provider, opts}}
    end
  end
```

- [ ] **Step 5: Export the behaviour from Source**

Modify `lib/image_pipe/source.ex` `exports:` — add `CredentialProvider`:

```elixir
      S3,
      RefreshCache,
      CredentialProvider
```

- [ ] **Step 6: Update the test support provider to the 3-tuple contract**

Modify `test/support/image_pipe/source_test/credential_provider.ex`:

```elixir
defmodule ImagePipe.SourceTest.CredentialProvider do
  @moduledoc false

  @behaviour ImagePipe.Source.S3.CredentialProvider

  @impl true
  def fetch_credentials(scope, provider_opts, runtime_opts) do
    send(message_target(), {:fetch_credentials, scope, provider_opts, runtime_opts})

    {:ok,
     [
       access_key_id: "AKIA_TEST",
       secret_access_key: "SECRET_TEST",
       token: "TOKEN_TEST"
     ],
     :never}
  end

  defp message_target do
    case Process.get(:"$callers") do
      [pid | _rest] when is_pid(pid) -> pid
      _callers -> self()
    end
  end
end
```

- [ ] **Step 7: Reconcile existing provider-path tests (`s3_test.exs` AND `imgproxy_wire_conformance_test.exs`)**

Both `test/image_pipe/source/s3_test.exs` and `test/image_pipe/imgproxy_wire_conformance_test.exs` drive `ImagePipe.SourceTest.CredentialProvider` and assert on the old `{:fetch_credentials, scope, opts, runtime_opts}` shape and per-request invocation.

Run: `mise exec -- mix test test/image_pipe/source/s3_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: failures in those provider-path tests. Update them:
- **`runtime_opts` is now `[]`.** Concretely, `s3_test.exs:179`'s `assert_receive {:fetch_credentials, "tenant-b", [role: "tenant-b"], [max_body_bytes: 20]}` becomes `{:fetch_credentials, "tenant-b", [role: "tenant-b"], []}`. Apply the same `[]` change to the conformance-test assertions (e.g. around `imgproxy_wire_conformance_test.exs:2168`).
- **Invoked once per `{provider, opts, scope}`**, not once per request — adjust any "called on each fetch" assertions.
- **Unique scope per test.** The `RefreshCache` is application-global and these suites run `async: true`, so fixed scopes (`tenant-a`/`tenant-b`) collide across tests and make `assert_received`/`refute_received` pass or fail tautologically. Give each such test a unique scope (`"tenant-#{System.unique_integer([:positive])}"`).

Make the minimal edits needed for green; do not assert on caching internals here (the cache has its own tests).

- [ ] **Step 8: Run both files**

Run: `mise exec -- mix test test/image_pipe/source/s3/credentials_cache_test.exs test/image_pipe/source/s3_test.exs`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/image_pipe/source/s3/credential_provider.ex lib/image_pipe/source/s3/credentials.ex lib/image_pipe/source.ex test/support/image_pipe/source_test/credential_provider.ex test/image_pipe/source/s3_test.exs test/image_pipe/source/s3/credentials_cache_test.exs
git commit -m "feat(s3): cache provider credentials with expiry contract"
```

---

## Task 4: IMDSv2 instance-role provider (#5)

EC2 instance metadata service, IMDSv2 (token-first). Hermetic via Req's `plug:` option; base URL injectable.

IMDSv2 protocol:
1. `PUT {base}/latest/api/token` with header `x-aws-ec2-metadata-token-ttl-seconds: 21600` → body is the session token (text).
2. `GET {base}/latest/meta-data/iam/security-credentials/` with header `x-aws-ec2-metadata-token: <token>` → role name (text; first line if multiple).
3. `GET {base}/latest/meta-data/iam/security-credentials/{role}` with the token header → JSON body:
   `{"Code":"Success","AccessKeyId":"…","SecretAccessKey":"…","Token":"…","Expiration":"2026-06-26T12:00:00Z"}`

**Files:**
- Create: `lib/image_pipe/source/s3/instance_role.ex`
- Test: `test/image_pipe/source/s3/instance_role_test.exs`

- [ ] **Step 1: Write the failing happy-path test**

Create `test/image_pipe/source/s3/instance_role_test.exs`:

```elixir
defmodule ImagePipe.Source.S3.InstanceRoleTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.InstanceRole

  # A Req plug emulating IMDSv2: token PUT, role listing, creds GET.
  defp imds_plug(creds_json) do
    fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.request_path} do
        {"PUT", "/latest/api/token"} ->
          assert ["21600"] =
                   Plug.Conn.get_req_header(conn, "x-aws-ec2-metadata-token-ttl-seconds")

          Plug.Conn.send_resp(conn, 200, "session-token-xyz")

        {"GET", "/latest/meta-data/iam/security-credentials/"} ->
          assert ["session-token-xyz"] =
                   Plug.Conn.get_req_header(conn, "x-aws-ec2-metadata-token")

          Plug.Conn.send_resp(conn, 200, "image-server-role")

        {"GET", "/latest/meta-data/iam/security-credentials/image-server-role"} ->
          assert ["session-token-xyz"] =
                   Plug.Conn.get_req_header(conn, "x-aws-ec2-metadata-token")

          Plug.Conn.send_resp(conn, 200, creds_json)
      end
    end
  end

  test "fetches temporary credentials via IMDSv2 and parses the expiry" do
    creds_json =
      ~s({"Code":"Success","AccessKeyId":"AKIAIMDS","SecretAccessKey":"shh","Token":"sess","Expiration":"2026-06-26T12:00:00Z"})

    opts = [plug: imds_plug(creds_json)]

    assert {:ok, creds, expiry} = InstanceRole.fetch_credentials("any-bucket", opts, [])
    assert creds[:access_key_id] == "AKIAIMDS"
    assert creds[:secret_access_key] == "shh"
    assert creds[:token] == "sess"
    assert expiry == ~U[2026-06-26 12:00:00Z]
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/s3/instance_role_test.exs`
Expected: FAIL — `ImagePipe.Source.S3.InstanceRole` undefined.

- [ ] **Step 3: Implement the provider**

Create `lib/image_pipe/source/s3/instance_role.ex`:

```elixir
defmodule ImagePipe.Source.S3.InstanceRole do
  @moduledoc """
  Credential provider for an EC2 instance role via IMDSv2.

  Use on EC2 (incl. Elastic Beanstalk) where a role is attached to the instance:

      credentials: {:provider, ImagePipe.Source.S3.InstanceRole, []}

  Options:
    * `:base_url` — IMDS base, default `"http://169.254.169.254"`.
    * `:ttl_seconds` — token TTL requested from IMDS, default `21600`.
    * `:plug` — test-only Req plug; routes requests to a `Plug` instead of the network.
    * `:receive_timeout` / `:connect_timeout` — bounded HTTP timeouts (ms), default 2000.
  """
  @behaviour ImagePipe.Source.S3.CredentialProvider

  @base_url "http://169.254.169.254"
  @ttl_seconds 21_600
  @default_timeout_ms 2_000

  @opts_schema NimbleOptions.new!(
                 base_url: [type: :string],
                 ttl_seconds: [type: :pos_integer],
                 # test-only Req hook; :any so the schema doesn't reject a fn
                 plug: [type: :any],
                 receive_timeout: [type: :non_neg_integer],
                 connect_timeout: [type: :non_neg_integer]
               )

  @impl true
  def validate_options(opts) do
    case NimbleOptions.validate(opts, @opts_schema) do
      {:ok, _validated} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  # NOTE: a fresh IMDSv2 token is fetched on every call, milliseconds before the
  # role/creds GET (TTL @ttl_seconds), so the token cannot expire mid-call — we
  # do NOT need the AWS SDK's "re-fetch token on 401" retry (the SDK needs it
  # because it caches the token across calls; we don't).
  @impl true
  def fetch_credentials(_scope, opts, _runtime_opts) do
    with {:ok, token} <- imds_token(opts),
         {:ok, role} <- role_name(opts, token),
         {:ok, body} <- role_credentials(opts, token, role) do
      parse_credentials(body)
    end
  end

  defp imds_token(opts) do
    case request(opts,
           method: :put,
           url: base_url(opts) <> "/latest/api/token",
           headers: [{"x-aws-ec2-metadata-token-ttl-seconds", Integer.to_string(ttl(opts))}]
         ) do
      {:ok, %{status: 200, body: token}} -> {:ok, to_string(token)}
      _other -> {:error, :imds_token_unavailable}
    end
  end

  defp role_name(opts, token) do
    case request(opts,
           method: :get,
           url: base_url(opts) <> "/latest/meta-data/iam/security-credentials/",
           headers: token_header(token)
         ) do
      {:ok, %{status: 200, body: body}} ->
        case body |> to_string() |> String.split("\n", trim: true) do
          [role | _] -> {:ok, role}
          [] -> {:error, :imds_no_role}
        end

      _other ->
        {:error, :imds_no_role}
    end
  end

  defp role_credentials(opts, token, role) do
    case request(opts,
           method: :get,
           url:
             base_url(opts) <>
               "/latest/meta-data/iam/security-credentials/" <> URI.encode(role),
           headers: token_header(token)
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      _other -> {:error, :imds_credentials_unavailable}
    end
  end

  defp parse_credentials(body) do
    with {:ok, map} <- decode_json(body),
         # IMDS returns "Code":"Success" on the happy path; a non-Success body
         # omits the key material, so this match fails closed AND distinguishes
         # the success shape explicitly.
         %{
           "Code" => "Success",
           "AccessKeyId" => access_key_id,
           "SecretAccessKey" => secret_access_key,
           "Token" => token,
           "Expiration" => expiration
         } <- map,
         {:ok, expiry, _offset} <- DateTime.from_iso8601(expiration) do
      {:ok,
       [access_key_id: access_key_id, secret_access_key: secret_access_key, token: token],
       expiry}
    else
      _other -> {:error, :imds_invalid_credentials}
    end
  end

  defp decode_json(body) when is_map(body), do: {:ok, body}

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, :imds_invalid_credentials}
    end
  end

  defp decode_json(_), do: {:error, :imds_invalid_credentials}

  defp token_header(token), do: [{"x-aws-ec2-metadata-token", token}]

  defp request(opts, req_opts) do
    base =
      [
        retry: false,
        redirect: false,
        receive_timeout: timeout(opts, :receive_timeout),
        connect_options: [timeout: timeout(opts, :connect_timeout)]
      ]
      |> maybe_plug(opts)

    try do
      {:ok, Req.request!(Keyword.merge(base, req_opts))}
    rescue
      _exception -> {:error, :imds_unreachable}
    end
  end

  defp maybe_plug(req_opts, opts) do
    case Keyword.get(opts, :plug) do
      nil -> req_opts
      plug -> Keyword.put(req_opts, :plug, plug)
    end
  end

  defp base_url(opts), do: Keyword.get(opts, :base_url, @base_url)
  defp ttl(opts), do: Keyword.get(opts, :ttl_seconds, @ttl_seconds)

  defp timeout(opts, key), do: Keyword.get(opts, key, @default_timeout_ms)
end
```

- [ ] **Step 4: Run the happy-path test**

Run: `mise exec -- mix test test/image_pipe/source/s3/instance_role_test.exs`
Expected: PASS.

- [ ] **Step 5: Write failure-path tests**

Append to `test/image_pipe/source/s3/instance_role_test.exs`:

```elixir
  test "returns an error when IMDS is unreachable" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end
    assert {:error, :imds_token_unavailable} =
             InstanceRole.fetch_credentials("b", [plug: plug], [])
  end

  test "returns an error on malformed credentials JSON" do
    plug = fn conn ->
      case {conn.method, conn.request_path} do
        {"PUT", "/latest/api/token"} -> Plug.Conn.send_resp(conn, 200, "t")
        {"GET", "/latest/meta-data/iam/security-credentials/"} ->
          Plug.Conn.send_resp(conn, 200, "role")
        {"GET", "/latest/meta-data/iam/security-credentials/role"} ->
          Plug.Conn.send_resp(conn, 200, "not json")
      end
    end

    assert {:error, :imds_invalid_credentials} =
             InstanceRole.fetch_credentials("b", [plug: plug], [])
  end

  test "parses a fractional-second expiration" do
    creds_json =
      ~s({"Code":"Success","AccessKeyId":"AK","SecretAccessKey":"s","Token":"t","Expiration":"2026-06-26T12:00:00.123Z"})

    plug = fn conn ->
      case {conn.method, conn.request_path} do
        {"PUT", "/latest/api/token"} ->
          Plug.Conn.send_resp(conn, 200, "tok")

        {"GET", "/latest/meta-data/iam/security-credentials/"} ->
          Plug.Conn.send_resp(conn, 200, "role")

        {"GET", "/latest/meta-data/iam/security-credentials/role"} ->
          Plug.Conn.send_resp(conn, 200, creds_json)
      end
    end

    assert {:ok, _creds, ~U[2026-06-26 12:00:00.123Z]} =
             InstanceRole.fetch_credentials("b", [plug: plug], [])
  end

  test "validate_options rejects unknown options and accepts known ones" do
    assert {:error, _message} = InstanceRole.validate_options(bogus: 1)
    assert :ok = InstanceRole.validate_options(ttl_seconds: 900)
  end
```

- [ ] **Step 6: Run the full file**

Run: `mise exec -- mix test test/image_pipe/source/s3/instance_role_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/source/s3/instance_role.ex test/image_pipe/source/s3/instance_role_test.exs
git commit -m "feat(s3): IMDSv2 instance-role credential provider"
```

---

## Task 5: ECS/EKS container-credentials provider (#6)

ECS/Fargate inject `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` (joined to `http://169.254.170.2`) or `AWS_CONTAINER_CREDENTIALS_FULL_URI`; an optional `AWS_CONTAINER_AUTHORIZATION_TOKEN` is sent as the `Authorization` header. A single GET returns the same JSON shape as IMDS.

**Files:**
- Create: `lib/image_pipe/source/s3/container_credentials.ex`
- Test: `test/image_pipe/source/s3/container_credentials_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/source/s3/container_credentials_test.exs`:

```elixir
defmodule ImagePipe.Source.S3.ContainerCredentialsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.ContainerCredentials

  @creds_json ~s({"AccessKeyId":"AKIAECS","SecretAccessKey":"shh","Token":"sess","Expiration":"2026-06-26T12:00:00Z"})

  test "fetches from the full URI and sends the auth token" do
    plug = fn conn ->
      assert conn.request_path == "/creds"
      assert ["Bearer abc"] = Plug.Conn.get_req_header(conn, "authorization")
      Plug.Conn.send_resp(conn, 200, @creds_json)
    end

    opts = [full_uri: "http://169.254.170.2/creds", auth_token: "Bearer abc", plug: plug]

    assert {:ok, creds, expiry} = ContainerCredentials.fetch_credentials("b", opts, [])
    assert creds[:access_key_id] == "AKIAECS"
    assert creds[:token] == "sess"
    assert expiry == ~U[2026-06-26 12:00:00Z]
  end

  test "joins the relative URI to the ECS base" do
    plug = fn conn ->
      assert conn.request_path == "/v2/credentials/abc"
      Plug.Conn.send_resp(conn, 200, @creds_json)
    end

    opts = [relative_uri: "/v2/credentials/abc", plug: plug]
    assert {:ok, _creds, _expiry} = ContainerCredentials.fetch_credentials("b", opts, [])
  end

  test "errors when no URI is configured" do
    assert {:error, :container_uri_missing} =
             ContainerCredentials.fetch_credentials("b", [], [])
  end

  test "validate_options enforces the full_uri loopback/https guard" do
    assert {:error, _message} =
             ContainerCredentials.validate_options(full_uri: "http://evil.example/creds")

    assert :ok = ContainerCredentials.validate_options(full_uri: "https://creds.example/x")
    assert :ok = ContainerCredentials.validate_options(full_uri: "http://169.254.170.2/creds")
    assert :ok = ContainerCredentials.validate_options(relative_uri: "/v2/credentials/abc")
    assert {:error, _message} = ContainerCredentials.validate_options(bogus: 1)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/s3/container_credentials_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the provider**

Create `lib/image_pipe/source/s3/container_credentials.ex`:

```elixir
defmodule ImagePipe.Source.S3.ContainerCredentials do
  @moduledoc """
  Credential provider for ECS/Fargate/EKS container credentials.

      credentials: {:provider, ImagePipe.Source.S3.ContainerCredentials,
                    relative_uri: System.get_env("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")}

  Options (the host typically wires these from the AWS-injected env vars):
    * `:relative_uri` — joined to `:base_url` (default `"http://169.254.170.2"`).
    * `:full_uri` — absolute URL (takes precedence over `:relative_uri`).
    * `:auth_token` — value for the `Authorization` header (optional).
    * `:base_url` — base for `:relative_uri`, default `"http://169.254.170.2"`.
    * `:plug` — test-only Req plug.
    * `:receive_timeout` / `:connect_timeout` — bounded HTTP timeouts (ms), default 2000.
  """
  @behaviour ImagePipe.Source.S3.CredentialProvider

  @base_url "http://169.254.170.2"
  @default_timeout_ms 2_000

  @opts_schema NimbleOptions.new!(
                 base_url: [type: :string],
                 full_uri: [type: :string],
                 relative_uri: [type: :string],
                 auth_token: [type: :string],
                 plug: [type: :any],
                 receive_timeout: [type: :non_neg_integer],
                 connect_timeout: [type: :non_neg_integer]
               )

  @impl true
  def validate_options(opts) do
    with {:ok, validated} <- schema_validate(opts),
         :ok <- validate_full_uri(validated) do
      :ok
    end
  end

  defp schema_validate(opts) do
    case NimbleOptions.validate(opts, @opts_schema) do
      {:ok, validated} -> {:ok, validated}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  # AWS only trusts AWS_CONTAINER_CREDENTIALS_FULL_URI when it targets a loopback
  # host or uses https; mirror that so a misconfigured full_uri can't exfiltrate
  # the auth token to an arbitrary host.
  defp validate_full_uri(opts) do
    case Keyword.get(opts, :full_uri) do
      nil ->
        :ok

      url ->
        uri = URI.parse(url)

        if uri.scheme == "https" or loopback_host?(uri.host) do
          :ok
        else
          {:error, "full_uri must use https or a loopback host"}
        end
    end
  end

  defp loopback_host?(host),
    do: host in ["localhost", "127.0.0.1", "::1", "169.254.170.2", "169.254.170.23"]

  @impl true
  def fetch_credentials(_scope, opts, _runtime_opts) do
    with {:ok, url} <- resolve_url(opts),
         {:ok, body} <- get(opts, url) do
      parse_credentials(body)
    end
  end

  defp resolve_url(opts) do
    cond do
      url = Keyword.get(opts, :full_uri) -> {:ok, url}
      rel = Keyword.get(opts, :relative_uri) -> {:ok, base_url(opts) <> rel}
      true -> {:error, :container_uri_missing}
    end
  end

  defp get(opts, url) do
    req_opts =
      [
        method: :get,
        url: url,
        retry: false,
        redirect: false,
        headers: auth_headers(opts),
        receive_timeout: timeout(opts, :receive_timeout),
        connect_options: [timeout: timeout(opts, :connect_timeout)]
      ]
      |> maybe_plug(opts)

    try do
      case Req.request!(req_opts) do
        %{status: 200, body: body} -> {:ok, body}
        _other -> {:error, :container_credentials_unavailable}
      end
    rescue
      _exception -> {:error, :container_unreachable}
    end
  end

  defp parse_credentials(body) do
    with {:ok, map} <- decode_json(body),
         %{
           "AccessKeyId" => access_key_id,
           "SecretAccessKey" => secret_access_key,
           "Token" => token,
           "Expiration" => expiration
         } <- map,
         {:ok, expiry, _offset} <- DateTime.from_iso8601(expiration) do
      {:ok,
       [access_key_id: access_key_id, secret_access_key: secret_access_key, token: token],
       expiry}
    else
      _other -> {:error, :container_invalid_credentials}
    end
  end

  defp decode_json(body) when is_map(body), do: {:ok, body}

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, :container_invalid_credentials}
    end
  end

  defp decode_json(_), do: {:error, :container_invalid_credentials}

  defp auth_headers(opts) do
    case Keyword.get(opts, :auth_token) do
      nil -> []
      token -> [{"authorization", token}]
    end
  end

  defp maybe_plug(req_opts, opts) do
    case Keyword.get(opts, :plug) do
      nil -> req_opts
      plug -> Keyword.put(req_opts, :plug, plug)
    end
  end

  defp base_url(opts), do: Keyword.get(opts, :base_url, @base_url)
  defp timeout(opts, key), do: Keyword.get(opts, key, @default_timeout_ms)
end
```

- [ ] **Step 4: Run the full file**

Run: `mise exec -- mix test test/image_pipe/source/s3/container_credentials_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/source/s3/container_credentials.ex test/image_pipe/source/s3/container_credentials_test.exs
git commit -m "feat(s3): ECS/EKS container-credentials provider"
```

---

## Task 6 (optional): Host-wired eager warm worker

The cache already warms on entry creation, so the *first* request for a provider+scope triggers (and joins) the fetch. To eliminate even that first-request latency, the host can pre-create the entry at boot via a `Detector.Warmup`-style worker that names the provider, opts, and scope.

> Build this only if the team wants boot-eager warming. It is purely additive — nothing in Tasks 1–5 depends on it.

**Files:**
- Create: `lib/image_pipe/source/s3/credential_warmup.ex`
- Modify: `lib/image_pipe/source.ex` (export `CredentialWarmup`)
- Test: `test/image_pipe/source/s3/credential_warmup_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/source/s3/credential_warmup_test.exs`:

```elixir
defmodule ImagePipe.Source.S3.CredentialWarmupTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.Credentials
  alias ImagePipe.Source.S3.CredentialWarmup

  defmodule OnceProvider do
    @behaviour ImagePipe.Source.S3.CredentialProvider
    @impl true
    def fetch_credentials(scope, opts, _runtime) do
      send(Keyword.fetch!(opts, :test), {:warmed, scope})
      {:ok, [access_key_id: "A", secret_access_key: "S", token: "T"], :never}
    end
  end

  test "warms the cache entry at start so a later fetch does not re-fetch" do
    scope = "bucket-#{System.unique_integer([:positive])}"
    opts = [test: self()]

    pid =
      start_supervised!(
        {CredentialWarmup, provider: OnceProvider, opts: opts, scope: scope}
      )

    ref = Process.monitor(pid)
    assert_receive {:warmed, ^scope}
    # the worker warms once then stops :normal
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    # cache is warm: fetching does not invoke the provider again
    assert {:ok, _} = Credentials.fetch(scope, {:provider, OnceProvider, opts}, [])
    refute_received {:warmed, ^scope}
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/s3/credential_warmup_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the warm worker**

Create `lib/image_pipe/source/s3/credential_warmup.ex`:

```elixir
defmodule ImagePipe.Source.S3.CredentialWarmup do
  @moduledoc """
  Optional one-shot worker that primes an S3 credential cache entry at boot, so
  the first image request for a bucket does not pay the provider round-trip.

  Host-wired (ImagePipe does not start it):

      {ImagePipe.Source.S3.CredentialWarmup,
       provider: ImagePipe.Source.S3.InstanceRole, opts: [], scope: "my-bucket"}

  Warms once in `handle_continue/2` (so host boot is never blocked) then stops
  `:normal`. A warm-up failure is non-fatal: the entry is left cold and the first
  real request falls through to the lazy path.
  """
  use GenServer, restart: :transient

  alias ImagePipe.Source.S3.Credentials

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      provider: Keyword.fetch!(opts, :provider),
      opts: Keyword.get(opts, :opts, []),
      scope: Keyword.fetch!(opts, :scope)
    }

    {:ok, state, {:continue, :warm_then_stop}}
  end

  @impl true
  def handle_continue(:warm_then_stop, state) do
    _ = Credentials.fetch(state.scope, {:provider, state.provider, state.opts}, [])
    {:stop, :normal, state}
  end
end
```

- [ ] **Step 4: Export it and run the test**

Modify `lib/image_pipe/source.ex` `exports:` — add `CredentialWarmup`.

Run: `mise exec -- mix test test/image_pipe/source/s3/credential_warmup_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/source/s3/credential_warmup.ex lib/image_pipe/source.ex test/image_pipe/source/s3/credential_warmup_test.exs
git commit -m "feat(s3): optional host-wired credential warm-up worker"
```

---

## Task 7: Documentation

Document the two providers, the env-var→static recipe, and the warm-up worker, in the S3 source docs. This is host-config capability parity — **no** `docs/imgproxy_support_matrix.md` pixel/stage/order change is required; if the matrix has an S3 *configuration surface* section, add a row noting provider-based credentials there.

**Files:**
- Modify/Create: the S3 source docs (locate with the check below)

- [ ] **Step 1: Locate the S3 docs**

Run: `ls docs/ && grep -rl "credentials" docs/ README.md 2>/dev/null`
Expected: identifies the canonical S3 config doc (e.g. `docs/s3.md` or a README section). Use whichever the repo already maintains; create `docs/s3_credentials.md` only if no S3 config doc exists.

- [ ] **Step 2: Write the credential-resolution section**

Add a "Credentials" section covering:
- `{:static, [access_key_id:, secret_access_key:, token:]}` (existing).
- **Env vars** — the host maps them to static (no library support needed):

  ```elixir
  credentials:
    {:static,
     [
       access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
       secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
       token: System.get_env("AWS_SESSION_TOKEN")
     ]}
  ```

- **Instance role (#5):** `{:provider, ImagePipe.Source.S3.InstanceRole, []}` — EC2 incl. Elastic Beanstalk.
- **ECS/EKS container creds (#6):** `{:provider, ImagePipe.Source.S3.ContainerCredentials, relative_uri: System.get_env("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"), auth_token: System.get_env("AWS_CONTAINER_AUTHORIZATION_TOKEN")}`.
  - `full_uri` is only accepted for a loopback host or over `https` (mirrors AWS), so a misconfigured URI cannot leak the auth token off-box.
  - If your platform injects `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` instead of an inline token, the host reads the file and passes its contents as `:auth_token` (re-read at the cadence the cache refreshes).
- **Caching:** provider results are cached by `{provider, opts, scope}` and refreshed before expiry; expired credentials are never sent to S3 (fail-closed → `{:source, :credentials_unavailable}`).
- **Optional warm-up:** the `CredentialWarmup` child for boot-eager priming.
- A forward note: STS `AssumeRole` (cross-account) and IRSA web-identity arrive in a follow-up (Plan 2).

- [ ] **Step 3: Commit**

```bash
git add docs/
git commit -m "docs(s3): document IAM instance-role and container-credential providers"
```

---

## Final verification

- [ ] **Step 1: Run the focused suite**

Run: `mise exec -- mix test test/image_pipe/source/`
Expected: PASS.

- [ ] **Step 2: Run the Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix test` all pass. (Boundary violations and the `ImagePipe.Application` → `ImagePipe.Source` dep edge are validated by `mix compile`.)

- [ ] **Step 3: Final commit if the gate produced formatting changes**

```bash
git add -A
git commit -m "chore(s3): satisfy precommit gate"
```

---

## Self-Review (completed during authoring)

**Spec coverage:** #5 IMDS → Task 4; #6 ECS/EKS container creds → Task 5; #11 refresh cache (single-flight, background refresh, warm-on-start, fail-closed) → Tasks 1–2; eager fetch → warm-on-init (Task 1) + optional boot worker (Task 6); provider contract + expiry + cache routing → Task 3; env-var→static → Task 7 docs. STS (#8) and IRSA (#7) are explicitly deferred to Plan 2.

**Type consistency:** `fetch_credentials/3` returns `{:ok, credentials, expiry}` everywhere (behaviour, both providers, test provider, warm worker). `RefreshCache.fetch/3` returns `{:ok, value} | {:error, reason}`; `Entry.get/2` matches. `expiry` is `DateTime.t() | :never` throughout. `Credentials.normalize/1` is `def` (used by the cache closure).

**Placeholder scan:** Task 1 Step 6 contains an explicitly-flagged awkward first draft followed by the corrected self-contained test to use — the implementer uses the second version. No `TBD`/`TODO`/"handle edge cases" placeholders remain.

**Open items for plan review:** (1) the `Application → Source` boundary edit; (2) keying credentials by `{provider, opts, scope}` where `opts` may contain a test `plug` fn (term-equality keying is acceptable but the reviewer should confirm no production opts carry non-deterministic terms that would fragment the cache). An AWS-protocol-fidelity reviewer should check the IMDSv2 token/role/creds sequence and the ECS URI/auth-header handling against the real metadata-service contract.

## Plan-review cycle (applied 2026-06-26)

Three disjoint reviewers (AWS protocol fidelity, OTP/concurrency, architecture/tests) ran against this plan. Accepted and folded in:
- **OTP:** failed background refresh now re-arms a bounded retry (`schedule_retry/1`) instead of going idle until expiry; `RefreshCache.fetch/3` returns `:error` via a relookup fallback instead of raising `CaseClauseError` in the request process; the serve-stale test forces the error result to apply before asserting; the single-flight test was rewritten to one clean version that proves waiters joined.
- **Architecture/security:** provider opts are now validated at config time via an optional `validate_options/1` callback (NimbleOptions); cache/provider crash errors are opaque atoms and the cached value is redacted from crash reports (`format_status/1`), so credential material can't leak to logs; `normalize/1` stays private; `imgproxy_wire_conformance_test.exs` added to provider-path reconciliation.
- **AWS fidelity:** explicit `"Code" => "Success"` match; refresh margin raised to 300s (SDK parity); `full_uri` restricted to loopback/https; fractional-second expiry covered.
- **Refuted (with rationale, kept as a code comment):** the SDK's "re-fetch IMDS token on 401" retry — unnecessary here because a fresh token is fetched per call, so it cannot expire mid-call.

---

## Follow-up plans

**Plan 2 — STS `AssumeRole` (#8) + EKS/IRSA web-identity (#7).** Cross-account assume-role (a composing wrapper provider that signs an STS `AssumeRole` call with a base provider's credentials, reusing the existing Req `aws_sigv4` step) and EKS/IRSA (`AssumeRoleWithWebIdentity` from a projected OIDC token file). Both return the same `Credentials` shape and cache through this plan's `RefreshCache`. STS is the AWS Query protocol (XML-only response); parse the fixed four-field shape. Built on this plan's cache + provider contract.

**Plan 3 (optional, low priority) — integration smoke lane.** A single opt-in, Docker-tagged test lane that exercises the real metadata/STS round-trip end-to-end against independent server implementations. **Deferred and skippable** — correctness is already covered hermetically by the `Req` `:plug` stub tests in Plans 1–2; this lane only adds confidence that a real AWS-compatible server accepts our request shapes. It is **not** a correctness gate (notably, LocalStack does not strictly verify SigV4, so it cannot prove signing — that is already proven by the live S3 GET path).

Do this once, **after Plan 2 lands**, so it can cover all providers together:
- A `@tag :aws_integration` lane, **excluded from the default `mix test`** (alongside the existing excluded tags such as `:imgproxy_triage`), opt-in only.
- Reuse the existing `testcontainers` dep (already used for the imgproxy bake). Local gotcha: set `TESTCONTAINERS_RYUK_DISABLED=true` (and run `MIX_ENV=test mix deps.get` first), same as the bake.
- Coverage: [`amazon-ec2-metadata-mock`](https://github.com/aws/amazon-ec2-metadata-mock) → IMDS (Plan 1); LocalStack STS → `AssumeRole` + `AssumeRoleWithWebIdentity` (Plan 2). **Skip ECS** — it is a trivial JSON endpoint, so a plug already *is* the mock and a container adds nothing.
- Frame it in-test as a protocol-fidelity smoke test, not a correctness gate.
