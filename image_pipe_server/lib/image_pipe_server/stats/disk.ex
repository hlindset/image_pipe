defmodule ImagePipeServer.Stats.Disk do
  @moduledoc false
  # Reads the free and total space of each cache root's filesystem with POSIX
  # `df` every `:interval` milliseconds and keeps the last good result in an
  # ETS table named after the process, so a stats request reads it without
  # waiting for `df`. A `df` stuck on a dead mount can't be killed from here,
  # so no other starts for that root until it ends, and requests keep the
  # last good sizes meanwhile, with their age.

  use GenServer

  @interval 15_000
  @unknown %{disk_free_bytes: nil, disk_total_bytes: nil, disk_age_seconds: nil}

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @doc false
  # The last good sizes of the filesystem that holds `root`, and how many
  # seconds ago `df` read them. All are nil until a `df` for it succeeds.
  @spec read(atom(), Path.t()) :: %{
          disk_free_bytes: non_neg_integer() | nil,
          disk_total_bytes: pos_integer() | nil,
          disk_age_seconds: non_neg_integer() | nil
        }
  def read(name, root) do
    case :ets.lookup(name, root) do
      [{^root, sizes, read_at}] ->
        age = System.convert_time_unit(System.monotonic_time() - read_at, :native, :second)
        Map.put(sizes, :disk_age_seconds, age)

      [] ->
        @unknown
    end
  rescue
    # The table goes with its process, while that restarts.
    ArgumentError -> @unknown
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])

    state = %{
      name: name,
      roots: Keyword.fetch!(opts, :roots),
      command: Keyword.get(opts, :command, "df"),
      interval: Keyword.get(opts, :interval, @interval),
      running: %{},
      timer: nil
    }

    {:ok, refresh(state)}
  end

  @impl GenServer
  def handle_info(:refresh, state), do: {:noreply, refresh(state)}

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    {root, running} =
      Enum.find_value(state.running, fn {root, worker} ->
        if worker == pid, do: {root, Map.delete(state.running, root)}
      end)

    with {:df, %{} = sizes} <- reason do
      :ets.insert(state.name, {root, sizes, System.monotonic_time()})
    end

    {:noreply, %{state | running: running}}
  end

  defp refresh(state) do
    running =
      Enum.reduce(state.roots, state.running, fn root, running ->
        Map.put_new_lazy(running, root, fn -> start_df(state.command, root) end)
      end)

    if state.timer, do: Process.cancel_timer(state.timer)

    timer =
      if state.interval != :infinity, do: Process.send_after(self(), :refresh, state.interval)

    %{state | running: running, timer: timer}
  end

  # The worker exits with the sizes it read, so its monitor brings them. It
  # runs `df` without a shell, and without `-l`, so a network or FUSE volume
  # reports too. Sizes are in KiB. Its stderr is captured, so a warning or
  # error doesn't reach the server's log.
  defp start_df(command, root) do
    {pid, _ref} =
      spawn_monitor(fn ->
        result =
          try do
            System.cmd(command, ["-kP", "--", root], stderr_to_stdout: true)
          rescue
            _missing_or_failed -> :error
          end

        exit({:df, sizes(result)})
      end)

    pid
  end

  defp sizes({output, 0}), do: parse_df(output)
  defp sizes(_failed), do: nil

  # The last line with sizes: filesystem, total, used, available, capacity,
  # mount point. A warning on stderr can come after it. The filesystem name or
  # mount point can hold spaces, so the sizes are the three fields before the
  # capacity percentage.
  defp parse_df(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(&parse_line/1)
  end

  defp parse_line(line) do
    with [total, _used, available, _capacity | _mount] <- from_sizes(String.split(line)),
         {total, ""} when total > 0 <- Integer.parse(total),
         {available, ""} <- Integer.parse(available) do
      %{disk_free_bytes: available * 1024, disk_total_bytes: total * 1024}
    else
      _unreadable -> nil
    end
  end

  defp from_sizes([_total, _used, _available, capacity | _rest] = fields) do
    if String.ends_with?(capacity, "%"),
      do: fields,
      else: from_sizes(tl(fields))
  end

  defp from_sizes(_fields), do: nil
end
