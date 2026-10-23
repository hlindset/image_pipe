defmodule ImagePipe.Cache.Writer do
  # Writes one cache entry off the request. The request's sink sends it the
  # body's chunks as messages, then a commit or an abort, and moves on
  # without waiting for the disk. The writer opens the temp body itself, as a
  # raw file, and owns it until the commit, so the write, sync and close run
  # here: a raw handle can't move between processes, a new descriptor can
  # miss a writeback error, and on NFS/EFS closing a file flushes it.
  #
  # The write's counters (an `:atomics` array) hold the bytes the writer
  # confirmed, which the sink reads to drop a write the client gets too far
  # ahead of, the bytes counted as pending for the write, and whether the
  # writer has finished. A write still unfinished after its maximum age is
  # dropped. The limit is a guess (image_plug-sole).
  @moduledoc false

  use GenServer, restart: :temporary

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Writers
  alias ImagePipe.Cache.Lookups
  alias ImagePipe.Cache.OutputWork
  alias ImagePipe.Cache.Sink
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.RequestContext

  @max_age 30_000

  @confirmed 1
  @reserved 2
  @finished 3

  @doc "New counters for a write."
  def counters, do: :atomics.new(3, [])

  @doc "The bytes the writer has written."
  def confirmed(counters), do: :atomics.get(counters, @confirmed)

  @doc "Whether the writer has finished, by committing, dropping or failing the write."
  def finished?(counters), do: :atomics.get(counters, @finished) == 1

  @doc """
  Counts `bytes` as pending for the write, on its root's `pending` counter
  (`Writers.counter/1`). Returns `:finished`, counting nothing, when the
  writer has already finished, and `:full` past the root's pending limit.
  """
  def reserve(counters, pending, bytes) do
    with :ok <- Writers.reserve(pending, bytes) do
      :atomics.add(counters, @reserved, bytes)

      # The writer releases what's counted when it finishes. A reservation
      # that lands after that releases itself.
      if :atomics.get(counters, @finished) == 1 do
        release(counters, pending)
        :finished
      else
        :ok
      end
    end
  end

  defp release(counters, pending),
    do: Writers.release(pending, :atomics.exchange(counters, @reserved, 0))

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  # The temp body is opened after the writer starts, so the request doesn't
  # wait for the disk, and neither do other writers starting on the root.
  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    RequestContext.adopt(args.request_context)
    {:ok, Map.put(args, :store, nil), {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    case FileSystem.open_sink(state.key, state.metadata, state.cache_opts) do
      {:ok, store} ->
        Process.send_after(self(), :expire, @max_age)
        {:noreply, %{state | store: store}}

      {:error, reason} ->
        Lookups.count(state.cache_opts, :write_error)
        Sink.open_failed(state, reason)
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:chunk, chunk}, state) do
    case FileSystem.write_chunk(state.store, chunk, state.cache_opts) do
      {:ok, store} ->
        :atomics.add(state.counters, @confirmed, byte_size(chunk))
        {:noreply, %{state | store: store}}

      {:error, reason, store} ->
        Lookups.count(state.cache_opts, :write_error)
        Sink.write_failed(state, reason)
        {:stop, :normal, %{state | store: store}}
    end
  end

  def handle_info({:commit, lease}, state) do
    commit(state, lease)
    {:stop, :normal, %{state | store: nil}}
  end

  def handle_info({:abort, _reason}, state), do: {:stop, :normal, state}

  def handle_info(:expire, state) do
    Sink.dropped(state, :deadline)
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.store, do: FileSystem.abort_sink(state.store, state.cache_opts)
    :atomics.put(state.counters, @finished, 1)
    release(state.counters, state.pending)
  end

  defp commit(state, lease) do
    start_metadata = %{pool: :output, cache_key: state.key.hash}

    Telemetry.span(state.telemetry_opts, [:cache, :write], start_metadata, fn ->
      Writers.hold(:atomics.get(state.counters, @reserved))
      result = FileSystem.commit_sink(state.store, state.cache_opts)
      if match?({:error, _reason}, result), do: Lookups.count(state.cache_opts, :write_error)
      size = confirmed(state.counters)
      cost_us = state.metadata.cost_us
      {:ok, Sink.commit_metadata(result, state.key, state.output_format, size, cost_us)}
    end)

    OutputWork.complete(lease, :ready)
  end
end
