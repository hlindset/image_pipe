defmodule ImagePipe.Source.HTTP.PinnedPools do
  @moduledoc false

  # Pinned pools are keyed by address, and rotating DNS answers keep adding
  # addresses, so pools that stay idle are stopped. Finch's own idle limit
  # can't do this: it checks only idle connections the pool still holds, and
  # origins close those first.
  #
  # Finch.stop_pool/2 fails any request using the pool, so a pool is stopped
  # in two sweeps. The first retires its generation, so new fetches start a
  # new pool. A later sweep stops the old pool once Finch reports no request
  # in use. A sweep interval of grace covers a fetch that read the generation
  # just before it was retired.

  use GenServer

  @table __MODULE__
  @idle 60_000
  @interval 30_000

  @type key ::
          {Finch.name(), :http | :https, String.t(), :inet.port_number(), String.t()}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Returns the live generation for a pool and marks it used, starting a new
  generation if the last one was retired.
  """
  @spec generation(key()) :: pos_integer()
  def generation(key) do
    now = now()

    case :ets.lookup(@table, key) do
      [{^key, generation, _used, _connected}] ->
        # The update fails if a sweep retired the row after the lookup.
        if :ets.update_element(@table, key, {3, now}),
          do: generation,
          else: generation(key)

      [] ->
        generation = System.unique_integer([:positive, :monotonic])

        if :ets.insert_new(@table, {key, generation, now, false}),
          do: generation,
          else: generation(key)
    end
  end

  @doc "Records whether the last connection attempt through a pool succeeded."
  @spec connected(key(), boolean()) :: :ok
  def connected(key, connected?) do
    :ets.update_element(@table, key, {4, connected?})
    :ok
  end

  @doc """
  Whether an address has a live pool for this scheme, hostname, and port whose
  last connection attempt succeeded.
  """
  @spec live?(:http | :https, String.t(), :inet.port_number(), String.t()) :: boolean()
  def live?(scheme, address, port, hostname) do
    spec = [{{{:_, scheme, address, port, hostname}, :_, :_, true}, [], [true]}]
    :ets.select_count(@table, spec) > 0
  end

  @doc false
  # Runs a sweep as of `now`, in monotonic milliseconds.
  def sweep(now), do: GenServer.call(__MODULE__, {:sweep, now})

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    schedule()
    {:ok, []}
  end

  @impl true
  def handle_call({:sweep, now}, _from, retired), do: {:reply, :ok, run_sweep(retired, now)}

  @impl true
  def handle_info(:sweep, retired) do
    schedule()
    {:noreply, run_sweep(retired, now())}
  end

  defp run_sweep(retired, now) do
    remaining = Enum.reject(retired, &stopped?(&1, now))
    retire(now) ++ remaining
  end

  defp stopped?({finch, pool, retired_at}, now) do
    now - retired_at >= @interval and idle?(finch, pool) and stop(finch, pool)
  end

  defp idle?(finch, pool) do
    case Finch.get_pool_status(finch, pool) do
      {:ok, metrics} -> Enum.all?(metrics, &(in_use(&1) == 0))
      {:error, :not_found} -> true
    end
  end

  defp in_use(%Finch.HTTP1.PoolMetrics{in_use_connections: count}), do: count
  defp in_use(%Finch.HTTP2.PoolMetrics{in_flight_requests: count}), do: count

  defp stop(finch, pool) do
    Finch.stop_pool(finch, pool)
    true
  end

  # A row is retired only if no fetch touched it since it was read.
  defp retire(now) do
    for {key, generation, used, _connected} = row <- :ets.tab2list(@table),
        now - used > @idle,
        :ets.select_delete(@table, [{row, [], [true]}]) == 1 do
      {finch, scheme, address, port, hostname} = key
      {finch, pool(scheme, address, port, hostname, generation), now}
    end
  end

  defp pool(scheme, address, port, hostname, generation) do
    %URI{scheme: Atom.to_string(scheme), host: address, port: port}
    |> URI.to_string()
    |> Finch.Pool.new(tag: tag(hostname, generation))
  end

  @doc "The Finch pool tag for a generation."
  def tag(hostname, generation), do: {:image_pipe, hostname, generation}

  defp schedule, do: Process.send_after(self(), :sweep, @interval)

  defp now, do: System.monotonic_time(:millisecond)
end
