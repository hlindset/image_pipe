defmodule ImagePipe.Cache.FileSystem.OwnerWatch do
  # Watches the owner file of a root this node refused, while requests run
  # without that cache. A file that changes between checks belongs to a live
  # owner, logged once. A file that's gone, or unchanged since the last check,
  # means the owner stopped: the watch writes its claim, confirms it a
  # heartbeat later (see `Owner.confirm/1`) and stops, which stops its
  # `Root`, and the restart starts the cache with the claim. A watch stopped
  # before it confirmed removes its claim, so no one waits on a file nobody
  # rewrites. A file it can't read is watched on.
  @moduledoc false

  use GenServer

  require Logger

  alias ImagePipe.Cache.FileSystem.Owner

  def start_link(claim), do: GenServer.start_link(__MODULE__, claim)

  @impl true
  def init(claim) do
    Process.flag(:trap_exit, true)
    schedule(claim)
    {:ok, %{claim: claim, found: read(claim), logged?: false, written: nil}}
  end

  @impl true
  def handle_info(:check, %{claim: claim} = state) do
    case File.read(claim.path) do
      {:ok, found} when found != state.found ->
        {:noreply, live_owner(state, found)}

      {:error, reason} when reason != :enoent ->
        schedule(claim)
        {:noreply, state}

      _gone_or_unchanged ->
        take_over(state)
    end
  end

  def handle_info(:confirm, %{written: claim} = state) do
    state = %{state | written: nil}

    case Owner.confirm(claim) do
      :ok -> {:stop, {:shutdown, :root_free}, state}
      {:owned, _host} -> {:noreply, live_owner(state, read(claim))}
      {:error, _reason} -> {:noreply, live_owner(state, read(claim))}
    end
  end

  @impl true
  def terminate(_reason, %{written: nil}), do: :ok
  def terminate(_reason, %{written: claim}), do: Owner.release(claim)

  defp take_over(%{claim: claim} = state) do
    case Owner.write_claim(claim) do
      {:ok, claim} ->
        Process.send_after(self(), :confirm, claim.heartbeat_ms)
        {:noreply, %{state | written: claim}}

      {:error, _reason} ->
        {:noreply, live_owner(state, read(claim))}
    end
  end

  defp live_owner(state, found) do
    if not state.logged? and found != nil do
      Logger.error(
        "cache: host #{inspect(Owner.host(found))} is using cache root #{state.claim.dir}. " <>
          "Requests run without this cache until it stops. Give each node its own cache root."
      )
    end

    schedule(state.claim)
    %{state | found: found, logged?: state.logged? or found != nil}
  end

  defp read(claim) do
    case File.read(claim.path) do
      {:ok, found} -> found
      {:error, _reason} -> nil
    end
  end

  defp schedule(claim), do: Process.send_after(self(), :check, claim.watch_ms)
end
