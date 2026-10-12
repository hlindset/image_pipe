defmodule ImagePipe.Cache.FileSystem.Root do
  # Runs one cache's processes on a root this node owns. Starting it claims
  # the root (see `Owner`), and the cache's processes start only once the
  # claim holds. When the root's owner file names another node, the root is
  # refused, requests run without this cache, and only an `OwnerWatch` runs
  # until the root is free. Any child stopping stops this supervisor,
  # including the owner finding its root taken over and the watch taking a
  # free root over, and the restart claims the root again.
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

  # Named after the directory, so a second cache on a root this VM already
  # runs fails to start before it touches the owner file. Roots are static
  # host configuration, so the derived atoms are bounded.
  def start_link(opts) do
    dir = Store.root_dir(opts)
    hash = :crypto.hash(:sha256, dir) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    Supervisor.start_link(__MODULE__, opts, name: Module.concat(__MODULE__, hash))
  end

  @impl true
  def init(opts) do
    dir = Store.root_dir(opts)

    case Owner.claim(dir, Keyword.take(opts, @owner_options)) do
      {:ok, claim} ->
        Owner.accept(dir)
        start([{Owner, claim} | Store.cache_children(opts)])

      {:watch, host, claim} ->
        Owner.refuse(dir)

        Logger.warning(
          "cache: cache root #{dir} belongs to host #{inspect(host)}. Requests run " <>
            "without this cache until that host stops using it."
        )

        start([{OwnerWatch, claim}])

      # The cache reports its own I/O errors on use, so an unwritable root
      # doesn't turn the cache off.
      {:error, reason} ->
        Owner.accept(dir)
        Logger.warning("cache: could not claim cache root #{dir}: reason=#{inspect(reason)}")
        start(Store.cache_children(opts))
    end
  end

  defp start(children),
    do: Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
end
