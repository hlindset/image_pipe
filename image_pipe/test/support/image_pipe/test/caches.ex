defmodule ImagePipe.Test.Caches do
  @moduledoc false
  # Starts an ImagePipe instance for the caches a test's options name, since
  # a cache runs only on an instance. A test keeps passing the same options to
  # the cache functions, mounts the instance with `plug/1`, and passes
  # `instance/1` to `ImagePipe.run/4`. Caches without a size cap get a large
  # one. Call it from the test process: the instance stops with the test.

  use Boundary, top_level?: true, check: [out: false]

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Writers

  @max_size_bytes 1_000_000_000

  @doc """
  Starts an instance with the shared options in `options`, and returns
  `options` with the caps added. Mount-only options, such as
  `allow_origin`, are left for `plug/1`.
  """
  def start!(options) when is_list(options) do
    options = cap(options)
    name = instance(options)
    {_mount, shared} = Keyword.split(options, mount_keys())

    start_supervised!(
      Supervisor.child_spec(
        {ImagePipe, Keyword.put_new([name: name] ++ shared, :allow_unsigned, true)},
        id: name
      )
    )

    options
  end

  @doc "The name of the instance `start!/1` started for `options`."
  def instance(options) do
    roots =
      for key <- [:cache], cache = options[key], cache != nil, do: cache[:root]

    hash = :crypto.hash(:sha256, Enum.join(roots, "\n")) |> Base.encode16() |> binary_part(0, 16)
    Module.concat(__MODULE__, hash)
  end

  @doc "Plug options mounting the instance for `options`, with its mount-only options."
  def plug(options) do
    {mount, _shared} = Keyword.split(options, mount_keys())
    ImagePipe.Plug.init([instance: instance(options)] ++ mount)
  end

  @doc """
  The instance's options as a request sees them, for a test that calls an
  internal function or adds test-only keys to a mount.
  """
  def options(options), do: ImagePipe.Config.fetch_instance!(instance(options)).options

  @doc "The resolved options of `plug/1`'s mount, as `ImagePipe.Plug.call/2` gets them."
  def plug_options(options), do: options |> plug() |> ImagePipe.Plug.Config.resolve()

  defp mount_keys, do: Keyword.keys(ImagePipe.Plug.Config.options_schema())

  @doc "Adds the size cap to the caches in `options` that don't set one."
  def cap(options) do
    Enum.map(options, fn
      {:cache, cache} when is_list(cache) ->
        {:cache, Keyword.put_new(cache, :max_size_bytes, @max_size_bytes)}

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
      for key <- [:cache], cache = options[key], cache != nil, do: cache[:root]

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
end
