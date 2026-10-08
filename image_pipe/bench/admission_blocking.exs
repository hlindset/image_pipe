# Investigation for image_plug-e4a.13.14; run from image_pipe/:
# mise exec -- mix run bench/admission_blocking.exs hash 64 10
# mise exec -- mix run bench/admission_blocking.exs hash-kib 1 40
# mise exec -- mix run bench/admission_blocking.exs timeout
# mise exec -- mix run bench/admission_blocking.exs reconcile 1000
# mise exec -- mix run bench/admission_blocking.exs scan-timeout 100
# Hash timings exclude source creation/hash and linked-sink opening. Timeout
# cases inject a delay; they do not measure the likelihood of a slow disk.
defmodule AdmissionBlockingBench do
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Store

  def run(args) do
    random = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    root = Path.join(System.tmp_dir!(), "admission-blocking-#{random}")

    File.mkdir_p!(root)

    try do
      execute(args, root)
    after
      File.rm_rf!(root)
    end
  end

  defp execute([mode, size, rounds], root) when mode in ["hash", "hash-kib"] do
    unit =
      case mode do
        "hash" -> 1024 * 1024
        "hash-kib" -> 1024
      end

    bytes = String.to_integer(size) * unit
    rounds = String.to_integer(rounds)
    source = Path.join(root, "source")
    body = :binary.copy("a", bytes)
    File.write!(source, body)
    sha = :crypto.hash(:sha256, body)
    opts = bounded_opts(root, bytes * 4)
    {supervisor, admission} = start_cache(opts)

    try do
      cache_key = key("large")
      cold = linked_commit(cache_key, source, sha, opts)
      warm = Enum.map(1..rounds, fn _ -> linked_commit(cache_key, source, sha, opts) end)

      :erlang.trace_pattern({Store, :file_sha256, 1}, true, [:local])
      :erlang.trace_pattern({Store, :publish_sink, 2}, true, [:local])
      :erlang.trace(admission, true, [:call, {:tracer, self()}])
      large = Task.async(fn -> linked_commit(cache_key, source, sha, opts) end)

      receive do
        {:trace, ^admission, :call, {Store, :publish_sink, [_, _]}} -> :ok
      after
        5000 -> raise "did not observe Admission publishing the body"
      end

      {:ok, small} = Store.open_sink(key("small"), metadata(), opts)
      {:ok, small} = Store.write_chunk(small, "small", opts)
      blocked_small = timed_commit(small, opts)
      large_result = Task.await(large, :infinity)
      :erlang.trace(admission, false, [:call])
      await_trace(admission)
      hash_calls = hash_calls(admission, 0)

      {mixed_us, mixed} =
        :timer.tc(fn ->
          1..64
          |> Task.async_stream(
            fn index ->
              case rem(index, 4) do
                0 ->
                  linked_commit(cache_key, source, sha, opts)

                _ ->
                  {:ok, sink} = Store.open_sink(key("mixed-#{index}"), metadata(), opts)
                  {:ok, sink} = Store.write_chunk(sink, "small", opts)
                  timed_commit(sink, opts)
              end
            end,
            max_concurrency: 8,
            timeout: :infinity
          )
          |> Enum.map(fn {:ok, latency} -> latency end)
        end)

      :ok = Store.verify(cache_key, opts)
      state = :sys.get_state(admission)
      bodies = Path.wildcard(Path.join(root, "**/*.body"))

      output(%{
        scenario: "hash",
        body_bytes: bytes,
        rounds: rounds,
        cold_commit_ms: cold,
        warm_commit_ms: warm,
        warm_median_ms: median(warm),
        traced_large_commit_ms: large_result,
        small_commit_after_publication_started_ms: blocked_small,
        existing_body_hash_calls: hash_calls,
        mixed_commits: length(mixed),
        mixed_concurrency: 8,
        mixed_ms: mixed_us / 1000,
        mixed_commits_per_second: length(mixed) * 1_000_000 / mixed_us,
        mixed_commit_median_ms: median(mixed),
        mixed_commit_p95_ms: percentile(mixed, 0.95),
        accounted_bytes: state.window_bytes + state.probationary_bytes + state.protected_bytes,
        disk_body_bytes: Enum.sum(Enum.map(bodies, &File.stat!(&1).size)),
        temporary_files: length(Path.wildcard(Path.join(root, "**/*.tmp"), match_dot: true)),
        publication_process: "Admission"
      })
    after
      :erlang.trace_pattern({Store, :file_sha256, 1}, false, [:local])
      :erlang.trace_pattern({Store, :publish_sink, 2}, false, [:local])
      Supervisor.stop(supervisor)
    end
  end

  defp execute(["timeout"], root) do
    opts = bounded_opts(root, 1000)
    {supervisor, admission} = start_cache(opts)
    cache_key = key("timeout")
    parent = self()
    :sys.suspend(admission)

    try do
      task =
        Task.async(fn ->
          {:ok, sink} = Store.open_sink(cache_key, metadata(), opts)
          {:ok, sink} = Store.write_chunk(sink, "body", opts)
          :erlang.trace(self(), true, [:send, {:tracer, parent}])
          :timer.tc(fn -> Store.commit_sink(sink, opts) end)
        end)

      prepared =
        receive do
          {:trace, _, :send, {:"$gen_call", _, {:commit, prepared, _}}, ^admission} -> prepared
        after
          5000 -> raise "commit was not queued"
        end

      {elapsed, result} = Task.await(task, :infinity)
      temporary_body_exists = File.exists?(prepared.temp_body_path)
      temporary_metadata_exists = File.exists?(prepared.temp_meta_path)
      {:messages, messages} = Process.info(admission, :messages)
      queued = Enum.count(messages, &match?({:"$gen_call", _, {:commit, _, _}}, &1))
      :sys.resume(admission)
      state = :sys.get_state(admission, :infinity)

      output(%{
        scenario: "timeout",
        injected_delay: "Admission suspended until caller timed out",
        elapsed_ms: elapsed / 1000,
        result: inspect(result),
        temporary_body_exists: temporary_body_exists,
        temporary_metadata_exists: temporary_metadata_exists,
        queued_commits_after_timeout: queued,
        metadata_published: File.exists?(prepared.paths.meta_path),
        temporary_files_after_resume:
          length(Path.wildcard(Path.join(root, "**/*.tmp"), match_dot: true)),
        accounted_bytes: state.window_bytes + state.probationary_bytes + state.protected_bytes
      })
    after
      :sys.resume(admission)
      Supervisor.stop(supervisor)
    end
  end

  defp execute([mode, count], root) when mode in ["reconcile", "scan-timeout"] do
    count = String.to_integer(count)

    Enum.each(1..count, fn n ->
      opts = [root: root]
      {:ok, sink} = Store.open_sink(key("entry-#{n}"), metadata(), opts)
      {:ok, sink} = Store.write_chunk(sink, "body", opts)
      :ok = Store.commit_sink(sink, opts)
    end)

    {:ok, paths} = FileSystem.paths(key("orphan"), root: root)
    File.mkdir_p!(paths.dir)
    orphan = Path.join(paths.dir, "#{paths.hash}.#{digest("orphan")}.body")
    File.write!(orphan, "orphan")
    File.touch!(orphan, System.os_time(:second) - 7200)
    prefix = [:admission_blocking_bench]
    handler = make_ref()
    parent = self()
    delay_gate = :atomics.new(1, [])

    :ok =
      :telemetry.attach(
        handler,
        prefix ++ [:cache, :eviction, :stop],
        fn _, measurements, _, _ ->
          send(
            parent,
            {:evicted, self(), measurements.count, System.monotonic_time(:microsecond)}
          )

          hold_reconcile(mode, delay_gate)
        end,
        nil
      )

    opts = bounded_opts(root, 4) |> Keyword.put(:telemetry_prefix, prefix)
    trace_reconciliation(parent)
    started = System.monotonic_time(:microsecond)
    {supervisor, admission} = start_cache(opts, false)
    :erlang.trace(:new, false, [:call, :monotonic_timestamp])

    try do
      first_batch =
        receive do
          {:evicted, ^admission, count, at} -> {count, at}
        after
          30_000 -> raise "reconciliation did not finish deleting victims"
        end

      scan_exit =
        try do
          observe_scan_exit(mode, admission)
        after
          if mode == "scan-timeout" do
            send(admission, :release_reconcile)
          end
        end

      :ok = Admission.await_scan(admission, :infinity)
      :erlang.trace(admission, false, [:call, :monotonic_timestamp])
      await_trace(admission)
      evictions = evictions(admission, [first_batch])
      callbacks = callback_times(admission, nil, [])

      output(%{
        scenario: mode,
        entries_before_scan: count,
        evictions: Enum.sum(Enum.map(evictions, &elem(&1, 0))),
        eviction_batches: length(evictions),
        largest_eviction_batch: evictions |> Enum.map(&elem(&1, 0)) |> Enum.max(),
        boot_through_deletion_ms: (Enum.max(Enum.map(evictions, &elem(&1, 1))) - started) / 1000,
        first_batch_ms: (elem(first_batch, 1) - started) / 1000,
        reconcile_callback_ms: callbacks,
        median_reconcile_callback_ms: median(callbacks),
        p95_reconcile_callback_ms: percentile(callbacks, 0.95),
        max_reconcile_callback_ms: Enum.max(callbacks),
        scan_exit: inspect(scan_exit),
        orphan_swept: not File.exists?(orphan)
      })
    after
      :telemetry.detach(handler)
      :erlang.trace(:new, false, [:call, :monotonic_timestamp])
      :erlang.trace_pattern({Admission, :handle_call, 3}, false, [:local])
      :erlang.trace_pattern({Admission, :handle_info, 2}, false, [:local])
      Supervisor.stop(supervisor)
    end
  end

  defp hold_reconcile("reconcile", _gate), do: :ok

  defp hold_reconcile("scan-timeout", gate) do
    if :atomics.compare_exchange(gate, 1, 0, 1) == :ok do
      receive do
        :release_reconcile -> :ok
      end
    end
  end

  defp observe_scan_exit("reconcile", _admission), do: :not_injected

  defp observe_scan_exit("scan-timeout", admission) do
    {:monitors, [{:process, scan}]} = Process.info(admission, :monitors)
    ref = Process.monitor(scan)

    receive do
      {:DOWN, ^ref, :process, ^scan, reason} -> reason
    after
      6000 ->
        Process.demonitor(ref, [:flush])
        :alive_after_six_seconds
    end
  end

  defp trace_reconciliation(parent) do
    Code.ensure_loaded!(Admission)

    :erlang.trace_pattern(
      {Admission, :handle_call, 3},
      [{[:reconcile_to_cap, :_, :_], [], [{:return_trace}]}],
      [:local]
    )

    :erlang.trace_pattern(
      {Admission, :handle_info, 2},
      [{[:reconcile_batch, :_], [], [{:return_trace}]}],
      [:local]
    )

    :erlang.trace(:new, true, [:call, :arity, :monotonic_timestamp, {:tracer, parent}])
  end

  defp await_trace(pid) do
    ref = :erlang.trace_delivered(pid)

    receive do
      {:trace_delivered, ^pid, ^ref} -> :ok
    end
  end

  defp hash_calls(pid, count) do
    receive do
      {:trace, ^pid, :call, {Store, :file_sha256, [_]}} -> hash_calls(pid, count + 1)
    after
      0 -> count
    end
  end

  defp evictions(pid, collected) do
    receive do
      {:evicted, ^pid, count, at} -> evictions(pid, [{count, at} | collected])
    after
      0 -> collected
    end
  end

  defp callback_times(pid, started, collected) do
    receive do
      {:trace_ts, ^pid, :call, {Admission, _, _}, at} ->
        callback_times(pid, at, collected)

      {:trace_ts, ^pid, :return_from, {Admission, _, _}, _result, at} ->
        ms = System.convert_time_unit(at - started, :native, :microsecond) / 1000
        callback_times(pid, nil, [ms | collected])
    after
      0 -> collected
    end
  end

  defp start_cache(opts, await? \\ true) do
    {:ok, supervisor} =
      Supervisor.start_link([FileSystem.child_spec(opts)], strategy: :one_for_one)

    root = Keyword.fetch!(opts, :root)
    [{admission, _}] = Registry.lookup(FileSystem.registry_name(root), {root, "bench"})
    if await?, do: Admission.await_scan(admission, :infinity)
    {supervisor, admission}
  end

  defp bounded_opts(root, cap),
    do: [root: root, node_id: "bench", max_size_bytes: cap, window_ratio: 0.01]

  defp linked_commit(key, source, sha, opts) do
    {:ok, sink} = Store.open_linked_sink(key, metadata(), source, sha, opts)
    timed_commit(sink, opts)
  end

  defp timed_commit(sink, opts) do
    {us, :ok} = :timer.tc(fn -> Store.commit_sink(sink, opts) end)
    us / 1000
  end

  defp metadata do
    %Entry.Metadata{
      content_type: "image/webp",
      headers: [],
      created_at: ~U[2026-10-07 00:00:00Z],
      output_format: :webp
    }
    |> Map.from_struct()
    |> Map.update!(:created_at, &DateTime.to_iso8601/1)
  end

  defp key(seed), do: %ImagePipe.Cache.Key{hash: digest(seed), data: []}
  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp median(values) do
    sorted = Enum.sort(values)
    middle = div(length(sorted), 2)

    case rem(length(sorted), 2) do
      0 -> (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
      1 -> Enum.at(sorted, middle)
    end
  end

  defp percentile(values, fraction),
    do: values |> Enum.sort() |> Enum.at(ceil(length(values) * fraction) - 1)

  defp output(value) do
    value
    |> Map.merge(%{
      elixir: System.version(),
      otp: List.to_string(:erlang.system_info(:otp_release)),
      schedulers: System.schedulers_online(),
      os: inspect(:os.type())
    })
    |> JSON.encode!()
    |> IO.puts()
  end
end

AdmissionBlockingBench.run(System.argv())
