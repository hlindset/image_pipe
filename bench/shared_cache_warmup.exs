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
          concurrency: :integer,
          io_operations: :integer,
          hot_passes: :integer,
          inventory_percent: :integer,
          concurrent_warmup: :boolean,
          root: :string,
          output: :string
        ]
      )

    opts =
      Keyword.merge(
        [
          partitions: 8,
          entries: 64,
          rounds: 3,
          bytes: 16_384,
          concurrency: 1,
          io_operations: 4,
          hot_passes: 1,
          inventory_percent: 100,
          concurrent_warmup: false
        ],
        opts
      )

    if Enum.any?(
         [:partitions, :entries, :rounds, :bytes, :concurrency, :hot_passes, :io_operations],
         &(opts[&1] <= 0)
       ),
       do: raise(ArgumentError, "counts and body bytes must be positive")

    if opts[:inventory_percent] not in 0..100,
      do: raise(ArgumentError, "inventory percentage must be in 0..100")

    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    root = Path.join(opts[:root] || System.tmp_dir!(), "shared-bench-#{id}")
    local = Path.join(System.tmp_dir!(), "shared-bench-readers-#{id}")
    File.mkdir_p!(local)
    Mix.Task.run("image_pipe.shared_cache.build")

    try do
      keys = prepare(root, local, opts)

      samples =
        for round <- 1..opts[:rounds], mode <- modes(round, opts) do
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
        concurrency: opts[:concurrency],
        hot_passes: opts[:hot_passes],
        inventory_percent: opts[:inventory_percent],
        inventoried_keys: inventoried_count(opts),
        concurrent_warmup: opts[:concurrent_warmup],
        io_max_operations: opts[:io_operations],
        scope:
          "Cache lookup, verified local reader acquisition, extra body read/SHA-256 verification and release; index-cold, OS-page-cache warm. No HTTP or transformation. Adoption disabled by a one-byte budget. Closed-loop callers; no retries or origin fallback for bypasses. Latency includes all attempts; hit-only latency and outcomes reported separately. An untimed serial pass primes every key before repeated traffic. Traced counts are submitted isolated-I/O operations, not OS syscalls. Concurrent-mode first_operations includes warmup through completion.",
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

      inventoried = Enum.take(entries, inventoried_count(opts))

      for {owner, entries} <- Enum.group_by(inventoried, &elem(&1, 0), &elem(&1, 1)) do
        :ok = Inventory.publish(pool, owner, entries, 1_000, inventory_limits(opts), 10_000)
      end

      Enum.map(entries, fn {_owner, location} -> location.key end)
    after
      Supervisor.stop(supervisor)
    end
  end

  defp trial(root, local, keys, opts, mode, round) do
    {:ok, supervisor} =
      Supervisor.start_link(
        [{CacheIO, max_operations: opts[:io_operations]}, Task.Supervisor, {__MODULE__, :trace}],
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

      [%{result: :hit}] =
        traverse(context, Enum.take(keys, 1), Keyword.put(opts, :concurrency, 1))

      :ok = Supervisor.terminate_child(supervisor, Locations)
      {:ok, fresh_locations} = Supervisor.restart_child(supervisor, Locations)
      context = %{context | locations: Locations.client(fresh_locations)}
      :erlang.trace(pool.pid, true, [:receive, {:tracer, tracer}])
      warmup = start_warmup(mode, tasks, context, opts)
      warmup_ops = if mode == :concurrent_inventory, do: nil, else: counts(pool.pid, tracer)
      first_start = System.monotonic_time(:microsecond)
      {first_us, first_results} = :timer.tc(fn -> traverse(context, keys, opts) end)
      first_end = System.monotonic_time(:microsecond)
      warmup = finish_warmup(warmup)
      first_ops = counts(pool.pid, tracer)
      primed = traverse(context, keys, Keyword.put(opts, :concurrency, 1))

      if Enum.any?(primed, &(&1.result != :hit)),
        do: raise("steady-state priming did not hit every key")

      _priming_ops = counts(pool.pid, tracer)
      hot_keys = List.duplicate(keys, opts[:hot_passes]) |> List.flatten()
      {hot_us, hot_results} = :timer.tc(fn -> traverse(context, hot_keys, opts) end)
      hot_ops = counts(pool.pid, tracer)

      %{
        mode: mode,
        round: round,
        warmup_ms: warmup.elapsed / 1_000,
        warmup: warmup.result,
        warmup_request_overlap_ms:
          max(0, min(first_end, warmup.finish) - max(first_start, warmup.start)) / 1_000,
        warmup_operations: warmup_ops,
        first_pass_ms: first_us / 1_000,
        first_lookup_us: Enum.map(first_results, & &1.elapsed_us),
        first: workload_stats(first_results, first_us),
        first_operations: first_ops,
        hot_pass_ms: hot_us / 1_000,
        hot_lookup_us: Enum.map(hot_results, & &1.elapsed_us),
        hot: workload_stats(hot_results, hot_us),
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

  defp start_warmup(:concurrent_inventory, tasks, context, opts),
    do: Task.Supervisor.async_nolink(tasks, fn -> timed_warmup(:inventory, context, opts) end)

  defp start_warmup(mode, _tasks, context, opts), do: timed_warmup(mode, context, opts)

  defp finish_warmup(%Task{} = task), do: Task.await(task, 15_000)
  defp finish_warmup(result), do: result

  defp timed_warmup(mode, context, opts) do
    start = System.monotonic_time(:microsecond)
    {elapsed, result} = :timer.tc(fn -> warm(mode, context, opts) end)
    %{start: start, finish: System.monotonic_time(:microsecond), elapsed: elapsed, result: result}
  end

  defp warm(:disk_first, _context, _opts), do: :disabled

  defp warm(:inventory, context, opts) do
    case Warmup.run(
           context,
           1_000,
           %{
             partitions: opts[:partitions] + 1,
             candidates: opts[:entries],
             inventory: inventory_limits(opts)
           },
           10_000
         ) do
      {:ok, stats} -> stats
      {:error, reason} -> %{result: "error:#{inspect(reason)}"}
    end
  end

  defp traverse(context, keys, opts) do
    bytes = opts[:bytes]
    expected = :crypto.hash(:sha256, String.duplicate("x", bytes))

    lookup = fn key ->
      {elapsed, result} = :timer.tc(fn -> read(context, key, bytes, expected) end)
      %{elapsed_us: elapsed, result: result}
    end

    if opts[:concurrency] == 1 do
      Enum.map(keys, lookup)
    else
      keys
      |> Task.async_stream(lookup, max_concurrency: opts[:concurrency], timeout: :infinity)
      |> Enum.map(fn {:ok, result} -> result end)
    end
  end

  defp read(context, key, bytes, expected) do
    case Lookup.output(context, key, 10_000) do
      {:hit, reader} ->
        try do
          body = File.read!(reader.path)

          if byte_size(body) != bytes or :crypto.hash(:sha256, body) != expected,
            do: raise("cached bytes differ")

          :hit
        after
          :ok = Generation.release(context.pool, reader, 10_000)
        end

      :miss ->
        :miss

      {:error, reason} ->
        "bypass:#{inspect(reason)}"
    end
  end

  defp workload_stats(results, elapsed) do
    hits = Enum.filter(results, &(&1.result == :hit))
    timings = Enum.map(hits, & &1.elapsed_us)

    %{
      outcomes: Enum.frequencies_by(results, & &1.result),
      attempts_per_second: length(results) * 1_000_000 / max(elapsed, 1),
      hits_per_second: length(hits) * 1_000_000 / max(elapsed, 1),
      hit_median_us: percentile(timings, 0.5),
      hit_p95_us: percentile(timings, 0.95)
    }
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
         hot_hits_per_second: percentile(Enum.map(trials, & &1.hot.hits_per_second), 0.5),
         warmup_median_ms: percentile(Enum.map(trials, & &1.warmup_ms), 0.5),
         first_pass_median_ms: percentile(Enum.map(trials, & &1.first_pass_ms), 0.5)
       }}
    end)
  end

  defp percentile([], _fraction), do: nil

  defp percentile(values, fraction),
    do: values |> Enum.sort() |> Enum.at(ceil(length(values) * fraction) - 1)

  defp modes(round, opts) do
    modes = [:disk_first, :inventory]
    modes = if opts[:concurrent_warmup], do: modes ++ [:concurrent_inventory], else: modes
    {before, rest} = Enum.split(modes, rem(round - 1, length(modes)))
    rest ++ before
  end

  defp inventoried_count(opts), do: div(opts[:entries] * opts[:inventory_percent], 100)

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
