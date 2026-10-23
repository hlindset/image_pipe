defmodule ImagePipe.Cache.FileSystem.Root do
  # Runs one cache's processes on a root this node owns. Starting it claims
  # the root (see `Owner`), and the cache's processes start only once the
  # claim holds. When the root's owner file names another node, the root is
  # refused, requests run without this cache, and only an `OwnerWatch` runs
  # until the root is free. The owner or the watch stopping stops this
  # supervisor, as when the owner finds its root taken over or the watch
  # takes a free root over, and the restart claims the root again.
  @moduledoc false

  use Supervisor

  require Logger

  alias ImagePipe.Cache.FileSystem.Owner
  alias ImagePipe.Cache.FileSystem.OwnerWatch
  alias ImagePipe.Cache.FileSystem.Store

  @owner_options [:host, :heartbeat_ms, :watch_ms]

  # Tests pass `Owner` options alongside the cache options.
  def child_spec(opts) do
    %{
      id: {__MODULE__, Store.root_dir(opts)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  # A root this VM already runs belongs to another cache, such as another
  # instance's, so the second one raises before it touches the owner file.
  def start_link(opts) do
    case Supervisor.start_link(__MODULE__, opts, name: name(opts)) do
      {:error, {:already_started, _pid}} ->
        raise ArgumentError,
              "cache root #{Store.root_dir(opts)} is already used by another cache in this " <>
                "VM. Give each ImagePipe instance its own cache roots."

      started ->
        started
    end
  end

  @doc false
  # Named after the directory, so a root runs one cache per VM. Roots are
  # static host configuration, so the derived atoms are bounded.
  def name(opts) do
    hash =
      :crypto.hash(:sha256, Store.root_dir(opts))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    Module.concat(__MODULE__, hash)
  end

  @impl true
  def init(opts) do
    dir = Store.root_dir(opts)

    case Owner.claim(dir, Keyword.take(opts, @owner_options)) do
      {:ok, claim} ->
        if Owner.refused?(dir) do
          Logger.info("cache: cache root #{dir} is free. Requests use this cache again.")
        else
          Logger.info("cache: claimed cache root #{dir} as host #{inspect(claim.host)}")
        end

        Owner.accept(dir)
        start([{Owner, claim}, cache(opts)])

      {:watch, host, claim} ->
        Owner.refuse(dir)

        Logger.warning(
          "cache: cache root #{dir} belongs to #{owner(host)}. Requests run " <>
            "without this cache until it stops using it."
        )

        start([{OwnerWatch, claim}])

      # The cache reports its own I/O errors on use, so an unwritable root
      # doesn't turn the cache off.
      {:error, reason} ->
        Owner.accept(dir)

        Logger.error(
          "cache: can't use cache root #{dir}: #{:file.format_error(reason)}. " <>
            "Images are served without being stored until the root can be written."
        )

        start([cache(opts)])
    end
  end

  # A file that kept vanishing as it was read names no host.
  defp owner(nil), do: "another node"
  defp owner(host), do: "host #{inspect(host)}"

  defp start(children),
    do: Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)

  # The cache's processes run under their own supervisor with the usual
  # restart limits, so a crash restarts the crashed process and those after
  # it, not the claim, and doesn't spend the instance's restarts.
  defp cache(opts) do
    %{
      id: :cache,
      type: :supervisor,
      start: {Supervisor, :start_link, [Store.cache_children(opts), [strategy: :rest_for_one]]}
    }
  end
end
