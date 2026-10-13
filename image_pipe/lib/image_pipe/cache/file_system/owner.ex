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
  # A refused root is recorded in `RefusedRoots`, and requests run without
  # its cache (see `ImagePipe.Cache.drop_refused/1`). An owner can find its
  # root taken over, by a node on its own host or after its heartbeats
  # stalled for a whole watch, as on a hung network mount. It refuses the root and stops, which
  # stops the root's cache processes. Their restart watches even a file from
  # its own host, so two nodes on one host don't take the root from each
  # other.
  @moduledoc false

  use GenServer

  require Logger

  alias ImagePipe.Cache.FileSystem.RefusedRoots

  @file_name ".image-pipe-owner"
  @heartbeat_ms 5_000
  @watch_ms 25_000

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

  # A file that vanishes between the failed link and the read can be another
  # node's, deleted or replaced as it claims, so the claim retries the link,
  # which creates the file only if none exists. A file that keeps vanishing
  # is left to a watch.
  @create_attempts 5

  defp create(claim, attempts \\ @create_attempts) do
    with :ok <- File.mkdir_p(claim.dir) do
      case publish(claim, &File.ln/2) do
        :ok -> {:ok, claim}
        {:error, :eexist} -> found(claim, attempts)
        {:error, _reason} = error -> error
      end
    end
  end

  defp found(claim, attempts) do
    case File.read(claim.path) do
      {:ok, found} ->
        if restart?(claim, found), do: write(claim), else: {:watch, host(found), claim}

      {:error, :enoent} when attempts > 1 ->
        create(claim, attempts - 1)

      {:error, :enoent} ->
        {:watch, nil, claim}

      {:error, _reason} = error ->
        error
    end
  end

  # A file from this host was left by this node's previous run, unless this
  # node lost the root to another node on its host.
  defp restart?(claim, found),
    do: host(found) == claim.host and not refused?(claim.dir)

  @doc """
  Writes `claim` into a root an `OwnerWatch` found free. Nodes that found the
  same file free both write it, and the last write wins, so the watch checks
  with `confirm/1` a heartbeat later.
  """
  def write_claim(claim), do: write(claim)

  @doc """
  Confirms a claim `write_claim/1` wrote. When the file still holds it, the
  claim waits for the restarted `Root`. Otherwise returns the host that wrote
  the file since.
  """
  def confirm(claim) do
    with {:ok, found} <- File.read(claim.path) do
      if found == contents(claim), do: hand_off(claim), else: {:owned, host(found)}
    end
  end

  @doc "Deletes the owner file if it still holds `claim`."
  def release(claim) do
    if File.read(claim.path) == {:ok, contents(claim)}, do: File.rm(claim.path)
    :ok
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

  @doc "Whether this node refused the root at `dir`."
  defdelegate refused?(dir), to: RefusedRoots
  @doc false
  defdelegate refuse(dir), to: RefusedRoots
  @doc false
  defdelegate accept(dir), to: RefusedRoots

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

  def terminate(_reason, state), do: release(state)

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
