defmodule ImagePipe.Test.Caches do
  @moduledoc false
  # Starts the processes for the caches a configuration names, as an instance
  # would, so a test can mount an inline configuration or call `run/4` with
  # it. Caches without a size cap get a large one. Call it from the test
  # process: the processes stop with the test.

  use Boundary, top_level?: true, check: [out: false]

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias ImagePipe.Cache
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Writers

  @max_size_bytes 1_000_000_000

  @doc """
  Starts the caches in `options`, or in a configuration built with
  `ImagePipe.config/1`, and returns it, with the caps added to `options`.
  """
  def start!(options) when is_list(options) do
    options = cap(options)
    options |> Cache.validate_config!() |> start_validated!()
    options
  end

  def start!(%ImagePipe.Config{} = config) do
    start_validated!(config.options)
    config
  end

  @doc "Adds the size cap to the caches in `options` that don't set one."
  def cap(options) do
    Enum.map(options, fn
      {key, cache} when key in [:cache, :input_cache] and is_list(cache) ->
        {key, Keyword.put_new(cache, :max_size_bytes, @max_size_bytes)}

      other ->
        other
    end)
  end

  @doc """
  Stores `body` under `key` in the cache `cache_opts` configures, as an
  earlier run would have left it. Without a running cache on that root, one
  runs just for the write. Returns the paths of the stored entry.
  """
  def write!(cache_opts, key, metadata, body) do
    {:ok, opts} =
      cache_opts
      |> Keyword.put_new(:max_size_bytes, @max_size_bytes)
      |> FileSystem.validate_options()

    # A test can run Admission without a Root, so its registry marks a cache.
    if Process.whereis(FileSystem.registry_name(Keyword.fetch!(opts, :root))),
      do: commit!(opts, key, metadata, body),
      else: commit_once!(opts, key, metadata, body)

    {:ok, paths} = FileSystem.paths(key, opts)
    paths
  end

  defp commit_once!(opts, key, metadata, body) do
    {:ok, supervisor} =
      Supervisor.start_link([FileSystem.child_spec(opts)], strategy: :one_for_one)

    try do
      commit!(opts, key, metadata, body)
    after
      Supervisor.stop(supervisor)
    end
  end

  defp commit!(opts, key, metadata, body) do
    {:ok, sink} = FileSystem.open_sink(key, metadata, opts)
    {:ok, sink} = FileSystem.write_chunk(sink, body, opts)
    :ok = FileSystem.commit_sink(sink, opts)
  end

  @doc """
  Waits until the writers of the caches in `options`, or in a configuration,
  have finished, including writers those writers start.
  """
  def await_writes(%ImagePipe.Config{} = config), do: await_writes(config.options)

  def await_writes(options) when is_list(options) do
    roots =
      for key <- [:cache, :input_cache], cache = options[key], cache != nil, do: cache[:root]

    await_roots(roots, System.monotonic_time(:millisecond) + 10_000)
  end

  defp await_roots(roots, deadline) do
    case Enum.flat_map(roots, &Writers.writers/1) do
      [] ->
        :ok

      writers ->
        Enum.each(writers, &await_writer(&1, deadline))
        await_roots(roots, deadline)
    end
  end

  defp await_writer(pid, deadline) do
    ref = Process.monitor(pid)
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout -> raise "cache writer #{inspect(pid)} still running"
    end
  end

  defp start_validated!(options) do
    for key <- [:cache, :input_cache], cache = Keyword.get(options, key), cache != nil do
      start_supervised!(FileSystem.child_spec(cache))
    end
  end
end
