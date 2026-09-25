# mise exec -- mix run bench/shared_cache_warmup.exs --output bench/shared_cache_warmup_samples.json
# --root selects a disposable parent on the volume to measure; readers stay node-local.
defmodule SharedCacheWarmupBench do
  use GenServer

  alias ImagePipe.Cache.Entry.Metadata

  alias ImagePipe.Cache.SharedFileSystem.{
    Generation,
    Inventory,
    Locations,
    Lookup,
    Partition,
    Retainer,
    Warmup
  }

  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  def start_link(:trace), do: GenServer.start_link(__MODULE__, %{})
  @impl true
  def init(counts), do: {:ok, counts}
  @impl true
  def handle_call(:take, _from, counts), do: {:reply, counts, %{}}
  @impl true
  def handle_info(
        {:trace, _pid, :receive,
         {:"$gen_call", _from,
          {:admitted, _ticket, {:run, {module, function, _args}, _bytes, _deadline, _lease}}}},
        counts
      ) do
    key = "#{inspect(module)}.#{function}"
    {:noreply, Map.update(counts, key, 1, &(&1 + 1))}
  end

  def handle_info(_message, counts), do: {:noreply, counts}

  def run(args) do
    {opts, []} =
      OptionParser.parse!(args,
        strict: [
          partitions: :integer,
          entries: :integer,
          rounds: :integer,
          bytes: :integer,
          root: :string,
          output: :string
        ]
      )

    opts = Keyword.merge([partitions: 8, entries: 64, rounds: 3, bytes: 16_384], opts)

    if Enum.any?([:partitions, :entries, :rounds, :bytes], &(opts[&1] <= 0)),
      do: raise(ArgumentError, "counts and body bytes must be positive")

    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    root = Path.join(opts[:root] || System.tmp_dir!(), "shared-bench-#{id}")
    local = Path.join(System.tmp_dir!(), "shared-bench-readers-#{id}")
    File.mkdir_p!(local)
    Mix.Task.run("image_pipe.shared_cache.build")

    try do
      keys = prepare(root, local, opts)

      samples =
        for round <- 1..opts[:rounds], mode <- modes(round) do
          trial(root, local, keys, opts, mode, round)
        end

      report = %{
        measured_at: DateTime.to_iso8601(DateTime.utc_now()),
        platform: inspect(:os.type()),
        elixir: System.version(),
        otp: System.otp_release(),
        partitions: opts[:partitions],
        entries: opts[:entries],
        body_bytes: opts[:bytes],
        rounds: opts[:rounds],
        concurrency: 1,
        scope:
          "Cache lookup/verified reader acquisition; index-cold, OS-page-cache warm. No HTTP or transformation. Adoption disabled by a one-byte budget. All measured keys are inventoried. Traced counts are submitted isolated-I/O operations, not OS syscalls.",
        samples: samples,
        summary: summarize(samples)
      }

      encoded = JSON.encode!(report)
      if path = opts[:output], do: File.write!(path, encoded <> "\n")
      IO.puts(encoded)
    after
      File.rm_rf!(root)
      File.rm_rf!(local)
    end
  end

  defp prepare(root, local, opts) do
    {:ok, supervisor} = Supervisor.start_link([CacheIO], strategy: :one_for_one)
    pool = supervisor |> child(CacheIO) |> CacheIO.client()
    limits = %{body: opts[:bytes], metadata: 4_096}
    path = Path.join(local, "source")
    File.write!(path, String.duplicate("x", opts[:bytes]))

    try do
      partitions = for _ <- 1..opts[:partitions], do: partition(pool, root)

      metadata = %Metadata{
        content_type: "text/plain",
        headers: [],
        created_at: DateTime.utc_now(),
        representation: {:complete_body, "text/plain"},
        output_format: nil
      }

      entries =
        for n <- 1..opts[:entries] do
          key = Base.encode16(:crypto.hash(:sha256, Integer.to_string(n)), case: :lower)
          owner = Enum.at(partitions, rem(n - 1, length(partitions)))

          {:ok, location} =
            Generation.publish(
              pool,
              Partition.plan(owner, :outputs, key),
              path,
              metadata,
              limits,
              10_000
            )

          {owner, location}
        end

      for {owner, entries} <- Enum.group_by(entries, &elem(&1, 0), &elem(&1, 1)) do
        :ok = Inventory.publish(pool, owner, entries, 1_000, inventory_limits(opts), 10_000)
      end

      Enum.map(entries, fn {_owner, location} -> location.key end)
    after
      Supervisor.stop(supervisor)
    end
  end

  defp trial(root, local, keys, opts, mode, round) do
    {:ok, supervisor} =
      Supervisor.start_link([CacheIO, Task.Supervisor, {__MODULE__, :trace}],
        strategy: :one_for_one
      )

    pool = supervisor |> child(CacheIO) |> CacheIO.client()
    tasks = child(supervisor, Task.Supervisor)
    tracer = child(supervisor, __MODULE__)
    owner = partition(pool, root)
    readers = Path.join(local, owner.id)
    File.mkdir!(readers)
    limits = %{body: opts[:bytes], metadata: 4_096}

    {:ok, locations} =
      Supervisor.start_child(
        supervisor,
        {Locations,
         pool: pool,
         root: root,
         tasks: tasks,
         max_partitions: opts[:partitions] + 1,
         max_keys: max(4_096, opts[:entries] * 4)}
      )

    {:ok, retainer} =
      Supervisor.start_child(
        supervisor,
        {Retainer, pool: pool, tasks: tasks, partition: owner, limits: limits, max_bytes: 1}
      )

    context = %{
      pool: pool,
      locations: Locations.client(locations),
      retainer: Retainer.client(retainer),
      partition: owner,
      readers: readers,
      limits: limits,
      max_attempts: 16
    }

    try do
      preload(pool)
      [_preloaded] = traverse(context, Enum.take(keys, 1), opts[:bytes])
      :ok = Supervisor.terminate_child(supervisor, Locations)
      {:ok, fresh_locations} = Supervisor.restart_child(supervisor, Locations)
      context = %{context | locations: Locations.client(fresh_locations)}
      :erlang.trace(pool.pid, true, [:receive, {:tracer, tracer}])
      {warmup_us, warmup} = :timer.tc(fn -> warm(mode, context, opts) end)
      warmup_ops = counts(pool.pid, tracer)
      {first_us, first_latencies} = :timer.tc(fn -> traverse(context, keys, opts[:bytes]) end)
      first_ops = counts(pool.pid, tracer)
      {hot_us, hot_latencies} = :timer.tc(fn -> traverse(context, keys, opts[:bytes]) end)
      hot_ops = counts(pool.pid, tracer)

      %{
        mode: mode,
        round: round,
        warmup_ms: warmup_us / 1_000,
        warmup: warmup,
        warmup_operations: warmup_ops,
        first_pass_ms: first_us / 1_000,
        first_lookup_us: first_latencies,
        first_operations: first_ops,
        hot_pass_ms: hot_us / 1_000,
        hot_lookup_us: hot_latencies,
        hot_operations: hot_ops,
        index: Locations.stats(context.locations, 1_000)
      }
    after
      :erlang.trace(pool.pid, false, [:receive])
      Supervisor.stop(supervisor)
      File.rm_rf!(owner.path)
      File.rm_rf!(readers)
    end
  end

  defp warm(:disk_first, _context, _opts), do: :disabled

  defp warm(:inventory, context, opts) do
    {:ok, stats} =
      Warmup.run(
        context,
        1_000,
        %{
          partitions: opts[:partitions] + 1,
          candidates: opts[:entries],
          inventory: inventory_limits(opts)
        },
        10_000
      )

    if stats.imported != opts[:entries], do: raise("warmup did not import every measured key")
    stats
  end

  defp traverse(context, keys, bytes) do
    expected = :crypto.hash(:sha256, String.duplicate("x", bytes))

    Enum.map(keys, fn key ->
      {elapsed, :ok} =
        :timer.tc(fn ->
          {:hit, reader} = Lookup.output(context, key, 10_000)

          try do
            body = File.read!(reader.path)

            if byte_size(body) != bytes or :crypto.hash(:sha256, body) != expected,
              do: raise("cached bytes differ")

            :ok
          after
            :ok = Generation.release(context.pool, reader, 10_000)
          end
        end)

      elapsed
    end)
  end

  defp counts(pid, tracer) do
    ref = :erlang.trace_delivered(pid)

    receive do
      {:trace_delivered, ^pid, ^ref} -> GenServer.call(tracer, :take)
    after
      10_000 -> raise("trace collection timed out")
    end
  end

  defp preload(pool) do
    {:ok, modules} = :application.get_key(:image_pipe, :modules)

    modules =
      Enum.filter(modules, fn module ->
        String.starts_with?(Atom.to_string(module), [
          "Elixir.ImagePipe.Cache",
          "Elixir.ImagePipe.Source",
          "Elixir.ImagePipe.Debug"
        ])
      end) ++ [DateTime, Calendar.ISO]

    Enum.each(modules, &Code.ensure_loaded!/1)

    {:ok, :ok} =
      CacheIO.run(pool, {Enum, :each, [modules, &Code.ensure_loaded!/1]}, 1_000_000, 10_000)
  end

  defp summarize(samples) do
    samples
    |> Enum.group_by(& &1.mode)
    |> Map.new(fn {mode, trials} ->
      first = Enum.flat_map(trials, & &1.first_lookup_us)
      hot = Enum.flat_map(trials, & &1.hot_lookup_us)

      {mode,
       %{
         first_median_us: percentile(first, 0.5),
         first_p95_us: percentile(first, 0.95),
         hot_median_us: percentile(hot, 0.5),
         hot_p95_us: percentile(hot, 0.95),
         warmup_median_ms: percentile(Enum.map(trials, & &1.warmup_ms), 0.5),
         first_pass_median_ms: percentile(Enum.map(trials, & &1.first_pass_ms), 0.5)
       }}
    end)
  end

  defp percentile(values, fraction),
    do: values |> Enum.sort() |> Enum.at(ceil(length(values) * fraction) - 1)

  defp modes(round),
    do: if(rem(round, 2) == 1, do: [:disk_first, :inventory], else: [:inventory, :disk_first])

  defp inventory_limits(opts),
    do: %{entries: opts[:entries], bytes: 65_536, max_age: 300, clock_skew: 5}

  defp partition(pool, root) do
    {:ok, {:ok, partition}} = CacheIO.run(pool, {Partition, :create, [root]}, 65_536, 10_000)
    partition
  end

  defp child(supervisor, id),
    do: supervisor |> Supervisor.which_children() |> List.keyfind(id, 0) |> elem(1)
end

SharedCacheWarmupBench.run(System.argv())
