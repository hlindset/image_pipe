defmodule ImagePipe.Cache.SharedFileSystem.Lifecycle do
  @moduledoc false
  use GenServer

  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO
  alias ImagePipe.Cache.SharedFileSystem.{Partition, Retainer, Runtime}
  alias ImagePipe.Telemetry

  def start_link(table, opts), do: GenServer.start_link(__MODULE__, {table, opts})

  @impl true
  def init({table, opts}) do
    previous =
      case Runtime.fetch(table, :state) do
        {:ready, partition} -> partition
        _unavailable -> nil
      end

    state = %{table: table, opts: opts, partition: previous, job: nil, span: start_span(opts)}
    state = apply_result(state, maintain(state))
    schedule(state)
    {:ok, state}
  end

  # Invoked only inside the isolated filesystem helper.
  def ensure_partition(previous, root, readers) do
    with {:ok, partition} <- recover(previous, root),
         :ok <- File.mkdir_p(readers),
         :ok <- Partition.heartbeat(partition) do
      {:ok, partition}
    end
  end

  defp recover(nil, root), do: Partition.create(root)
  defp recover(partition, _root), do: Partition.recover(partition)

  @impl true
  def handle_info(:heartbeat, %{job: nil} = state) do
    state = %{state | span: start_span(state.opts)}

    task =
      Task.Supervisor.async_nolink(Runtime.fetch(state.table, :tasks), fn -> maintain(state) end)

    {:noreply, %{state | job: task.ref}}
  end

  def handle_info({ref, result}, %{job: ref} = state) do
    Process.demonitor(ref, [:flush])
    state = apply_result(%{state | job: nil}, result)
    schedule(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{job: ref} = state) do
    state = apply_result(%{state | job: nil}, {:error, :unavailable})
    schedule(state)
    {:noreply, state}
  end

  defp maintain(state) do
    CacheIO.run(
      Runtime.fetch(state.table, :pool),
      {__MODULE__, :ensure_partition,
       [state.partition, state.opts[:root], Runtime.fetch(state.table, :readers)]},
      65_536,
      state.opts[:timeout]
    )
  end

  defp apply_result(state, {:ok, {:ok, partition}}) do
    operation = operation(state.partition, partition)
    state = %{state | partition: partition}

    case Retainer.rotate(Runtime.fetch(state.table, :retainer), partition, state.opts[:timeout]) do
      :ok ->
        :ets.insert(state.table, {:state, {:ready, partition}})
        emit(state, operation, :ok)
        state

      error ->
        apply_result(state, error)
    end
  end

  defp apply_result(state, _error) do
    :ets.insert(state.table, {:state, :unavailable})
    emit(state, :unavailable, :cache_error)
    state
  end

  defp operation(nil, _partition), do: :created
  defp operation(partition, partition), do: :heartbeat
  defp operation(_previous, _partition), do: :rotated

  defp emit(state, operation, result),
    do:
      Telemetry.stop_span(state.span, %{
        operation: operation,
        result: result
      })

  defp start_span(opts), do: Telemetry.start_span(opts, [:cache, :shared_lifecycle], %{})

  defp schedule(state),
    do: Process.send_after(self(), :heartbeat, state.opts[:heartbeat_interval])

  @impl true
  def format_status(_status), do: %{state: :redacted}
end
