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
  #   * background refresh: a timer fires `refresh_margin_ms` before expiry; a
  #     refresh that fails while the value is still fresh re-arms a bounded retry,
  #   * fail-closed: an expired value is never served.
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
