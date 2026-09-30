defmodule ImagePipe.Source.Download do
  @moduledoc false
  use GenServer, restart: :temporary

  @chunk_size 65_536

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def start(path, available) do
    DynamicSupervisor.start_child(
      ImagePipe.Source.Downloads,
      {__MODULE__, owner: self(), path: path, available: available}
    )
  end

  def advance(download, available), do: GenServer.call(download, {:advance, available})
  def finish(download), do: GenServer.call(download, :finish)
  def watch(download, worker), do: GenServer.call(download, {:watch, worker})

  def close(download) do
    GenServer.stop(download)
  catch
    :exit, {:noproc, _} -> :ok
  end

  # Readers pull at most one chunk at a time. The coordinator carries positions
  # and waiters, while encoded bytes live in the staged file.
  def stream(download) do
    Stream.resource(
      fn ->
        path = GenServer.call(download, {:reader, self()})
        {:ok, io} = File.open(path, [:read, :binary, :raw])
        {io, 0}
      end,
      fn {io, offset} = state ->
        case GenServer.call(download, {:available, offset}, :infinity) do
          :eof ->
            {:halt, state}

          count ->
            read(io, offset, count)
        end
      end,
      fn {io, _offset} ->
        File.close(io)
        GenServer.cast(download, {:reader_done, self()})
      end
    )
  end

  defp read(io, offset, count) do
    case :file.pread(io, offset, count) do
      {:ok, bytes} -> {[bytes], {io, offset + byte_size(bytes)}}
      _error -> raise ImagePipe.Source.StreamError, reason: :invalid_body
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       owner: Process.monitor(Keyword.fetch!(opts, :owner)),
       path: Keyword.fetch!(opts, :path),
       available: Keyword.fetch!(opts, :available),
       complete?: false,
       worker: nil,
       readers: %{},
       waiting: []
     }}
  end

  @impl true
  def handle_call({:reader, pid}, _from, state) do
    {:reply, state.path, %{state | readers: Map.put(state.readers, Process.monitor(pid), pid)}}
  end

  def handle_call({:watch, pid}, _from, state) do
    {:reply, :ok, %{state | worker: {Process.monitor(pid), pid}}}
  end

  def handle_call({:available, offset}, from, state) do
    case available(state, offset) do
      :wait -> {:noreply, %{state | waiting: [{from, offset} | state.waiting]}}
      count -> {:reply, count, state}
    end
  end

  def handle_call({:advance, count}, _from, state),
    do: {:reply, :ok, wake(%{state | available: count})}

  def handle_call(:finish, _from, state),
    do: {:reply, :ok, wake(%{state | complete?: true})}

  @impl true
  def handle_cast({:reader_done, pid}, state) do
    readers =
      Map.reject(state.readers, fn {ref, reader} ->
        case reader == pid do
          true -> Process.demonitor(ref, [:flush])
          false -> false
        end
      end)

    {:noreply, %{state | readers: readers}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{worker: {ref, pid}} = state) do
    stop_readers(state.readers)
    {:noreply, %{state | worker: nil, readers: %{}, waiting: []}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {:noreply,
     %{
       state
       | readers: Map.delete(state.readers, ref),
         waiting: Enum.reject(state.waiting, fn {{reader, _tag}, _offset} -> reader == pid end)
     }}
  end

  @impl true
  def terminate(_reason, state) do
    case state.worker do
      nil -> :ok
      {_ref, pid} -> Process.exit(pid, :shutdown)
    end

    stop_readers(state.readers)
  end

  @impl true
  def format_status(_status), do: %{state: :redacted}

  defp available(%{available: size}, offset) when size > offset,
    do: min(@chunk_size, size - offset)

  defp available(%{complete?: true}, _offset), do: :eof
  defp available(_state, _offset), do: :wait

  defp wake(state) do
    waiting =
      Enum.filter(state.waiting, fn {from, offset} ->
        case available(state, offset) do
          :wait ->
            true

          count ->
            GenServer.reply(from, count)
            false
        end
      end)

    %{state | waiting: waiting}
  end

  defp stop_readers(readers) do
    Enum.each(readers, fn {ref, pid} ->
      Process.demonitor(ref, [:flush])
      Process.exit(pid, :shutdown)
    end)
  end
end
