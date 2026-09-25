defmodule ImagePipe.Cache.SharedFileSystem.InventoryWorker do
  @moduledoc false
  use GenServer

  alias ImagePipe.Cache.SharedFileSystem.{
    Inventory,
    MaintenanceTelemetry,
    Pressure,
    Reclamation,
    Retainer,
    Runtime,
    Warmup
  }

  def start_link(table, opts), do: GenServer.start_link(__MODULE__, {table, opts})

  @impl true
  def init({table, opts}) do
    send(self(), :tick)
    {:ok, %{table: table, opts: opts, phase: :warmup, job: nil}}
  end

  @impl true
  def handle_info(:tick, %{job: nil} = state) do
    task =
      Task.Supervisor.async_nolink(Runtime.fetch(state.table, :tasks), fn ->
        run(state.table, state.opts, state.phase)
      end)

    {:noreply, %{state | job: task.ref}}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({ref, _result}, %{job: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, schedule(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{job: ref} = state),
    do: {:noreply, schedule(state)}

  def run(table, opts, phase) do
    limits = %{
      entries: opts[:inventory_max_entries],
      bytes: opts[:inventory_max_bytes],
      max_age: max(div(opts[:inventory_interval] * 3, 1_000), 1),
      clock_skew: opts[:clock_skew]
    }

    case Runtime.context(table) do
      {:ok, context} ->
        execute(phase, context, opts, limits)

      error ->
        operation = if phase == :warmup, do: :warmup, else: :inventory
        MaintenanceTelemetry.run(opts, operation, fn -> error end)
    end
  end

  defp execute(:warmup, context, opts, limits) do
    MaintenanceTelemetry.run(opts, :warmup, fn ->
      Warmup.run(
        context,
        opts[:clock].(),
        %{
          inventory: limits,
          partitions: opts[:warmup_max_partitions],
          candidates: opts[:warmup_max_candidates]
        },
        opts[:warmup_timeout]
      )
    end)
  end

  defp execute(:publish, context, opts, limits) do
    publication = publish(context, opts, limits)

    reclamation =
      MaintenanceTelemetry.run(opts, :reclamation, fn ->
        Reclamation.run(context, opts, opts[:timeout])
      end)

    case {publication, reclamation} do
      {{:ok, publication}, {:ok, reclamation}} ->
        {:ok, %{publication: publication, reclamation: reclamation}}

      {publication, reclamation} ->
        {:error, %{publication: publication, reclamation: reclamation}}
    end
  end

  defp publish(context, opts, limits) do
    deadline = System.monotonic_time(:millisecond) + opts[:timeout]

    with {:ok, partition, locations} <-
           Retainer.inventory(context.retainer, limits.entries, remaining(deadline)),
         :ok <-
           MaintenanceTelemetry.run(opts, :inventory, fn ->
             Inventory.publish(
               context.pool,
               partition,
               locations,
               opts[:clock].(),
               limits,
               remaining(deadline)
             )
           end) do
      MaintenanceTelemetry.run(opts, :pressure, fn ->
        Pressure.run(context, opts, remaining(deadline))
      end)
    end
  end

  defp schedule(state) do
    interval = state.opts[:inventory_interval]
    jitter = :rand.uniform(max(div(interval, 10), 1)) - 1
    Process.send_after(self(), :tick, interval + jitter)
    %{state | phase: :publish, job: nil}
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @impl true
  def format_status(_status), do: %{state: :redacted}
end
