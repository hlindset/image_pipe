defmodule Mix.Tasks.CacheScan.Bench do
  @shortdoc "Time a filesystem cache's startup scan over a generated cache"
  @moduledoc """
  Generates a filesystem cache of N valid entries, older than the sweep's
  grace period, then starts the cache on it and reports:

    * the time until `Admission.usage/2` stops reporting `counting?: true`;
    * the time until the startup scan, sweep included, completes;
    * with `--trace`, the `:prim_file` calls the scan made, such as file
      reads and stats. Tracing slows the scan, so time it without.

  The root is kept between runs, so later runs reuse the generated entries.
  The page cache stays warm: drop it yourself (`sudo purge` on macOS) for a
  cold run. Lives under `test/support/mix/tasks`, so it compiles only in
  `MIX_ENV=test`, which `mix.exs` selects for it.

      mise exec -- mix cache_scan.bench
      mise exec -- mix cache_scan.bench --entries 20000 --root /tmp/scan --runs 3
      mise exec -- mix cache_scan.bench --trace --runs 1
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Store

  @switches [entries: :integer, root: :string, runs: :integer, trace: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    entries = Keyword.get(opts, :entries, 100_000)
    root = Keyword.get(opts, :root, Path.join(System.tmp_dir!(), "image_pipe_scan_#{entries}"))

    Mix.Task.run("app.start")
    generate(root, entries)

    for run <- 1..Keyword.get(opts, :runs, 3) do
      Mix.shell().info("run #{run}: " <> format(measure(root, Keyword.get(opts, :trace, false))))
    end
  end

  defp generate(root, entries) do
    marker = Path.join(root, ".generated-#{entries}")

    unless File.exists?(marker) do
      Mix.shell().info("generating #{entries} entries in #{root}")
      File.rm_rf!(root)
      aged = System.os_time(:second) - 7_200

      1..entries
      |> Task.async_stream(&write_entry(root, &1, aged),
        max_concurrency: System.schedulers_online() * 2,
        ordered: false
      )
      |> Stream.run()

      File.write!(marker, "")
    end
  end

  defp write_entry(root, index, aged) do
    hash = :crypto.hash(:sha256, <<index::64>>) |> Base.encode16(case: :lower)
    body = <<index::64>>
    sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    body_filename = Store.body_filename(hash, sha, byte_size(body), 1_000)
    {:ok, paths} = FileSystem.paths_from_hash(hash, root: root)
    File.mkdir_p!(paths.dir)

    metadata = %{
      metadata_version: 2,
      content_type: "image/webp",
      headers: [],
      created_at: "2026-10-23T00:00:00Z",
      body_byte_size: byte_size(body),
      body_sha256: sha,
      body_filename: body_filename,
      cost_us: 1_000,
      debug: nil,
      representation: nil
    }

    body_path = Path.join(paths.dir, body_filename)
    File.write!(body_path, body)
    File.write!(paths.meta_path, :erlang.term_to_binary(metadata, [:deterministic]))
    File.touch!(body_path, aged)
    File.touch!(paths.meta_path, aged)
  end

  defp measure(root, trace?) do
    {:ok, opts} = FileSystem.validate_options(root: root, max_size_bytes: 10_000_000_000)
    if trace?, do: start_trace()
    started = System.monotonic_time(:millisecond)

    {:ok, supervisor} =
      Supervisor.start_link([FileSystem.child_spec(opts)], strategy: :one_for_one)

    admission = admission(supervisor)
    counted = wait_counted(admission, started)
    :ok = Admission.await_scan(admission, :infinity)
    scanned = System.monotonic_time(:millisecond) - started
    calls = if trace?, do: stop_trace(), else: %{}
    Supervisor.stop(supervisor)
    %{counted_ms: counted, scanned_ms: scanned, calls: calls}
  end

  defp admission(supervisor) do
    [{_id, root, :supervisor, _modules}] = Supervisor.which_children(supervisor)
    {:cache, cache, :supervisor, _} = List.keyfind(Supervisor.which_children(root), :cache, 0)
    [admission] = for {{Admission, _}, pid, _, _} <- Supervisor.which_children(cache), do: pid
    admission
  end

  defp wait_counted(admission, started) do
    case Admission.usage(admission, :infinity) do
      %{counting?: false} ->
        System.monotonic_time(:millisecond) - started

      _counting ->
        Process.sleep(5)
        wait_counted(admission, started)
    end
  end

  defp start_trace do
    :erlang.trace_pattern({:prim_file, :_, :_}, true, [:call_count])
    :erlang.trace(:all, true, [:call])
  end

  defp stop_trace do
    :erlang.trace(:all, false, [:call])
    calls = prim_file_calls()
    :erlang.trace_pattern({:prim_file, :_, :_}, false, [:call_count])
    calls
  end

  defp prim_file_calls do
    for {function, arity} <- :prim_file.module_info(:exports),
        {:call_count, count} = :erlang.trace_info({:prim_file, function, arity}, :call_count),
        is_integer(count) and count > 0,
        into: %{},
        do: {"#{function}/#{arity}", count}
  end

  defp format(%{counted_ms: counted, scanned_ms: scanned, calls: calls}) do
    calls =
      calls |> Enum.sort() |> Enum.map_join(", ", fn {name, count} -> "#{name}=#{count}" end)

    "counted #{counted} ms, scan done #{scanned} ms; #{calls}"
  end
end
