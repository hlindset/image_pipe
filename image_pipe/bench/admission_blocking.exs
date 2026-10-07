# Investigation for image_plug-e4a.13.14; run from image_pipe/:
# mise exec -- mix run bench/admission_blocking.exs hash 64 10
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

  defp execute(["hash", mib, rounds], root) do
    bytes = String.to_integer(mib) * 1024 * 1024
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
      :erlang.trace(admission, true, [:call, {:tracer, self()}])
      large = Task.async(fn -> linked_commit(cache_key, source, sha, opts) end)

      receive do
        {:trace, ^admission, :call, {Store, :file_sha256, [_]}} -> :ok
      after
        5000 -> raise "did not observe Admission hashing the existing body"
      end

      :erlang.trace(admission, false, [:call])
      :erlang.trace_pattern({Store, :file_sha256, 1}, false, [:local])
      {:ok, small} = Store.open_sink(key("small"), metadata(), opts)
      {:ok, small} = Store.write_chunk(small, "small", opts)
      blocked_small = timed_commit(small, opts)
      large_result = Task.await(large, :infinity)

      output(%{
        scenario: "hash",
        body_bytes: bytes,
        rounds: rounds,
        cold_commit_ms: cold,
        warm_commit_ms: warm,
        warm_median_ms: median(warm),
        traced_large_commit_ms: large_result,
        small_commit_queued_during_hash_ms: blocked_small,
        hash_process: "Admission"
      })
    after
      :erlang.trace_pattern({Store, :file_sha256, 1}, false, [:local])
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

    :ok =
      :telemetry.attach(
        handler,
        prefix ++ [:cache, :eviction, :stop],
        fn _, measurements, _, _ ->
          send(parent, {:evicted, self(), measurements.count})
          hold_reconcile(mode)
        end,
        nil
      )

    opts = bounded_opts(root, 4) |> Keyword.put(:telemetry_prefix, prefix)
    started = System.monotonic_time(:microsecond)
    {supervisor, admission} = start_cache(opts, false)

    try do
      evicted =
        receive do
          {:evicted, ^admission, evicted} -> evicted
        after
          30_000 -> raise "reconciliation did not finish deleting victims"
        end

      deletion_ms = (System.monotonic_time(:microsecond) - started) / 1000

      scan_exit =
        try do
          observe_scan_exit(mode, admission)
        after
          :telemetry.detach(handler)
          if mode == "scan-timeout", do: send(admission, :release_reconcile)
        end

      :ok = Admission.await_scan(admission, :infinity)

      output(%{
        scenario: mode,
        entries_before_scan: count,
        evictions_in_one_callback: evicted,
        boot_through_deletion_ms: deletion_ms,
        scan_exit: inspect(scan_exit),
        orphan_swept: not File.exists?(orphan)
      })
    after
      :telemetry.detach(handler)
      Supervisor.stop(supervisor)
    end
  end

  defp hold_reconcile("reconcile"), do: :ok

  defp hold_reconcile("scan-timeout") do
    receive do
      :release_reconcile -> :ok
    end
  end

  defp observe_scan_exit("reconcile", _admission), do: :not_injected

  defp observe_scan_exit("scan-timeout", admission) do
    {:monitors, [{:process, scan}]} = Process.info(admission, :monitors)
    ref = Process.monitor(scan)

    receive do
      {:DOWN, ^ref, :process, ^scan, reason} -> reason
    after
      6000 -> raise "scan did not time out"
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
