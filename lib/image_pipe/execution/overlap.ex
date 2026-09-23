defmodule ImagePipe.Execution.Overlap do
  @moduledoc false
  alias ImagePipe.Plan.Request
  alias ImagePipe.Processing
  alias ImagePipe.ProcessingPool
  alias ImagePipe.Source.{Download, Origin, Response}
  alias ImagePipe.Telemetry.Trace.Stack

  @minimum_prefix 256 * 1024
  @maximum_prefix 1024 * 1024
  @observation_us 5_000
  @remaining_us 30_000

  def with_session(response, preparation, config, path, fun) do
    case candidate(response, preparation, config) do
      {:ok, expected, request, policy} ->
        {:ok, download} = Download.start(path, 0)
        trace = Stack.context()

        task =
          Task.Supervisor.async_nolink(ImagePipe.ProcessingPool.Tasks, fn ->
            Stack.adopt(trace)

            receive do
              {:prepare, prefix} ->
                prepare(download, prefix, request, policy, config)
            end
          end)

        Download.watch(download, task.pid)

        try do
          fun.(%{
            download: download,
            task: task,
            expected: expected,
            first: nil,
            status: :observing
          })
        after
          Download.close(download)
          Task.ignore(task)
        end

      :skip ->
        fun.(nil)
    end
  end

  def observe(nil, _io, _size), do: nil
  def observe(%{status: :skip} = state, _io, _size), do: state
  def observe(%{status: {:ready, _}} = state, _io, _size), do: state

  def observe(%{status: :observing, first: nil} = state, _io, size),
    do: %{state | first: {System.monotonic_time(:microsecond), size}}

  def observe(%{status: :observing, first: {first_at, first_size}} = state, io, size) do
    elapsed = System.monotonic_time(:microsecond) - first_at

    cond do
      size >= state.expected ->
        %{state | status: :skip}

      size >= @minimum_prefix and elapsed >= @observation_us ->
        remaining = elapsed * (state.expected - size) / (size - first_size)
        select(state, io, size, remaining)

      size >= @maximum_prefix ->
        %{state | status: :skip}

      true ->
        state
    end
  end

  def observe(%{status: :running} = state, _io, size) do
    Download.advance(state.download, size)
    poll(state)
  end

  def finish(nil), do: nil
  def finish(%{status: status}) when status in [:observing, :skip], do: nil
  def finish(%{status: {:ready, result}}), do: result

  def finish(%{status: :running} = state) do
    Download.finish(state.download)

    state = completed(state, Task.yield(state.task, 60_000))
    finish(state)
  end

  def cancel(nil), do: nil

  def cancel(state) do
    Download.close(state.download)
    Task.ignore(state.task)
    nil
  end

  defp candidate(
         %Response{path: nil, origin: %Origin{headers: headers}},
         {%Request{output: %{terminal: :image}} = request, policy},
         config
       ) do
    limit = Keyword.fetch!(config, :max_body_bytes)

    with [value] <- Map.get(headers, "content-length"),
         {size, ""} when size > @maximum_prefix and size <= limit <- Integer.parse(value) do
      {:ok, size, request, policy}
    else
      _ -> :skip
    end
  end

  defp candidate(_response, _preparation, _config), do: :skip

  defp select(state, io, size, remaining) when remaining >= @remaining_us do
    {:ok, prefix} = :file.pread(io, 0, min(size, @maximum_prefix))

    case Processing.streamable_source?(prefix) do
      true ->
        Download.advance(state.download, size)
        send(state.task.pid, {:prepare, prefix})
        %{state | status: :running}

      false ->
        %{state | status: :skip}
    end
  end

  defp select(state, _io, _size, _remaining), do: %{state | status: :skip}

  defp poll(state) do
    case Task.yield(state.task, 0) do
      nil -> state
      result -> completed(state, result)
    end
  end

  defp completed(state, {:ok, {:error, {:processing, reason}}})
       when reason in [:overloaded, :queue_timeout], do: %{state | status: :skip}

  defp completed(state, {:ok, result}), do: %{state | status: {:ready, result}}

  defp completed(state, {:exit, _reason}),
    do: %{state | status: {:ready, {:error, {:processing, :worker_down}}}}

  defp completed(state, nil),
    do: %{state | status: {:ready, {:error, {:session, :timeout}}}}

  defp prepare(download, prefix, request, policy, config) do
    ProcessingPool.within(Keyword.get(config, :processing_pool), download, config, fn ->
      Processing.prepare_download(request, {:download, download, prefix}, policy, config)
    end)
  catch
    :exit, {:shutdown, {:processing, _} = reason} -> {:error, reason}
  end
end
