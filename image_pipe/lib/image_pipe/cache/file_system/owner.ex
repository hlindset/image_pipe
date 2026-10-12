defmodule ImagePipe.Cache.FileSystem.Owner do
  # Claims a cache root for this node, since a root serves one node only. The
  # owner file names the owner's host and holds a counter this process
  # rewrites every heartbeat, and a clean stop deletes it. A node restarting
  # on the same host takes the root over at once. A file from another host
  # can belong to a live owner or to one that stopped abruptly, so the root is
  # refused and an `OwnerWatch` decides: a counter that keeps moving means a
  # live owner. One that stops moving, or a file that goes away, frees the
  # root, and the watch takes it over and hands the claim to the restarted
  # `Root`. Comparing contents rather than timestamps keeps clocks out of it.
  # Claiming never waits, so a contested root doesn't hold up the instance.
  #
  # A refused root is recorded here, and requests run without its cache (see
  # `ImagePipe.Cache.drop_refused/1`). An owner can find its root taken over,
  # by a node on its own host or after its heartbeats stalled for a whole
  # watch, as on a hung network mount. It refuses the root and stops, which
  # stops the root's cache processes. Their restart watches even a file from
  # its own host, so two nodes on one host don't take the root from each
  # other.
  @moduledoc false

  use GenServer

  require Logger

  @file_name ".image-pipe-owner"
  @heartbeat_ms 5_000
  @watch_ms 25_000
  @refused {__MODULE__, :refused}

  @doc false
  def file_name, do: @file_name

  @doc """
  Claims `dir` without waiting. Returns the claim to start the owner process
  with, or `{:watch, host, claim}` when the file names another host (or this
  host, after this node lost the root), for an `OwnerWatch` to decide on.
  Tests set `:host` and shorten `:heartbeat_ms` and `:watch_ms`.
  """
  def claim(dir, opts) do
    claim = %{
      dir: dir,
      path: Path.join(dir, @file_name),
      host: Keyword.get_lazy(opts, :host, &hostname/0),
      token: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      count: 0,
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, @heartbeat_ms),
      watch_ms: Keyword.get(opts, :watch_ms, @watch_ms)
    }

    case take_handoff(claim) do
      {:ok, _handed_off} = ok -> ok
      :none -> create(claim)
    end
  end

  defp create(claim) do
    with :ok <- File.mkdir_p(claim.dir) do
      case publish(claim, &File.ln/2) do
        :ok -> {:ok, claim}
        {:error, :eexist} -> found(claim)
        {:error, _reason} = error -> error
      end
    end
  end

  defp found(claim) do
    case File.read(claim.path) do
      {:ok, found} ->
        if restart?(claim, found), do: write(claim), else: {:watch, host(found), claim}

      {:error, :enoent} ->
        write(claim)

      {:error, _reason} = error ->
        error
    end
  end

  # A file from this host was left by this node's previous run, unless this
  # node lost the root to another node on its host.
  defp restart?(claim, found),
    do: host(found) == claim.host and not MapSet.member?(refused(), claim.dir)

  @doc """
  Takes a free root over for an `OwnerWatch`. Nodes that found the same file
  free both write it, and the last write wins, so the file is read back a
  heartbeat later. On success the claim waits for the restarted `Root`.
  """
  def take_over(claim) do
    with {:ok, claim} <- write(claim),
         :ok <- Process.sleep(claim.heartbeat_ms),
         {:ok, found} <- File.read(claim.path) do
      if found == contents(claim), do: hand_off(claim), else: {:owned, host(found)}
    end
  end

  defp hand_off(claim), do: :persistent_term.put({__MODULE__, :handoff, claim.dir}, claim)

  # A handed-off claim holds only while the file still names it.
  defp take_handoff(%{dir: dir} = claim) do
    key = {__MODULE__, :handoff, dir}

    case :persistent_term.get(key, nil) do
      nil ->
        :none

      handed_off ->
        :persistent_term.erase(key)

        if File.read(claim.path) == {:ok, contents(handed_off)},
          do: {:ok, handed_off},
          else: :none
    end
  end

  @doc "The roots this node refused, as a set of directories."
  def refused, do: :persistent_term.get(@refused, MapSet.new())

  @doc false
  def refuse(dir), do: update_refused(&MapSet.put(&1, dir))

  @doc false
  def accept(dir), do: update_refused(&MapSet.delete(&1, dir))

  # Each update replaces a persistent term, so it skips unchanged sets.
  defp update_refused(update) do
    refused = refused()
    updated = update.(refused)
    if updated != refused, do: :persistent_term.put(@refused, updated)
    :ok
  end

  def start_link(claim), do: GenServer.start_link(__MODULE__, claim)

  @impl true
  def init(claim) do
    Process.flag(:trap_exit, true)
    schedule(claim)
    {:ok, claim}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    ours = contents(state)

    case File.read(state.path) do
      {:ok, found} when found != ours ->
        Logger.error(
          "cache: host #{inspect(host(found))} took over cache root #{state.dir}. " <>
            "Requests run without this cache. Give each node its own cache root."
        )

        refuse(state.dir)
        {:stop, {:shutdown, :root_taken_over}, %{state | count: nil}}

      _ours_or_missing ->
        state = %{state | count: state.count + 1}
        publish(state, &File.rename/2)
        schedule(state)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, %{count: nil}), do: :ok

  def terminate(_reason, state) do
    if File.read(state.path) == {:ok, contents(state)}, do: File.rm(state.path)
    :ok
  end

  @doc false
  def host(contents), do: contents |> String.split("\n") |> hd()

  defp hostname do
    {:ok, host} = :inet.gethostname()
    List.to_string(host)
  end

  defp contents(claim), do: "#{claim.host}\n#{claim.token}\n#{claim.count}\n"

  defp schedule(claim), do: Process.send_after(self(), :heartbeat, claim.heartbeat_ms)

  defp write(claim) do
    with :ok <- publish(claim, &File.rename/2), do: {:ok, claim}
  end

  # The file is written beside the owner file and moved into place, so a
  # reader never sees it half written. Linking it creates the owner file
  # only if none exists, and renaming it replaces one.
  defp publish(claim, place) do
    temp = "#{claim.path}.#{claim.token}.tmp"

    with :ok <- File.write(temp, contents(claim)) do
      result = place.(temp, claim.path)
      File.rm(temp)
      result
    end
  end
end
