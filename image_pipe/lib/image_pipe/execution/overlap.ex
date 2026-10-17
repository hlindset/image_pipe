defmodule ImagePipe.Execution.Overlap do
  @moduledoc false
  alias ImagePipe.Decode
  alias ImagePipe.Plan.Spec
  alias ImagePipe.Processing
  alias ImagePipe.ProcessingPool
  alias ImagePipe.Source.{Download, Origin, Response}
  alias ImagePipe.Telemetry.RequestContext

  @minimum_prefix 256 * 1024
  @maximum_prefix 1024 * 1024
  @observation_us 5_000
  @remaining_us 30_000

  # Starts a session when the download is a candidate for overlapped
  # processing, or returns nil. The caller closes it with close/1 on failure;
  # finish/1 closes it on success.
  def start(response, preparation, config, path) do
    case candidate(response, preparation, config) do
      {:ok, expected, request, policy} ->
        {:ok, download} = Download.start(path, 0)
        request_context = RequestContext.capture()
        # The pool reports a processing timeout here, where finish/1 and poll/1 wait.
        notification = :erlang.alias()

        task =
          Task.Supervisor.async_nolink(ImagePipe.ProcessingPool.Tasks, fn ->
            RequestContext.adopt(request_context)

            receive do
              {:prepare, prefix} ->
                prepare(download, notification, prefix, request, policy, config)
            end
          end)

        Download.watch(download, task.pid)

        %{
          download: download,
          task: task,
          notification: notification,
          expected: expected,
          first: nil,
          status: :observing
        }

      :skip ->
        nil
    end
  end

  def close(nil), do: nil

  def close(state) do
    :erlang.unalias(state.notification)
    Download.close(state.download)
    Task.ignore(state.task)
    nil
  end

  def observe(nil, _io, _size), do: nil
  def observe(%{status: :skip} = state, _io, _size), do: state
  def observe(%{status: {:ready, _}} = state, _io, _size), do: state

  def observe(%{status: :observing, first: nil} = state, _io, size),
    do: %{state | first: {System.monotonic_time(:microsecond), size}}

  def observe(%{status: :observing, first: {_first_at, size}} = state, _io, size),
    do: state

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

  # Called when the download is complete. A session that never started
  # processing ends here. A running one keeps going, so that the caller can
  # release the source's work before it waits in finish/1.
  def complete(nil), do: nil
  def complete(%{status: status} = state) when status in [:observing, :skip], do: close(state)

  def complete(%{status: :running} = state) do
    Download.finish(state.download)
    state
  end

  def complete(%{status: {:ready, _result}} = state), do: state

  def finish(nil), do: nil
  def finish(%{status: :skip} = state), do: close(state)

  def finish(%{status: {:ready, result}} = state) do
    close(state)
    result
  end

  def finish(%{status: :running} = state),
    do: state |> completed(await(state.task, 60_000)) |> finish()

  def cancel(state), do: close(state)

  # Overlap holds a processing slot while the download arrives, only to save
  # time, which a low-priority request doesn't need.
  defp candidate(_response, {%Spec{priority: :low}, _policy}, _config), do: :skip

  defp candidate(
         %Response{path: nil, origin: %Origin{headers: headers}},
         {%Spec{output: %{terminal: :image}} = request, policy},
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

    case Decode.streamable_source?(prefix) do
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
    case await(state.task, 0) do
      nil -> state
      result -> completed(state, result)
    end
  end

  defp await(%Task{ref: ref, pid: worker}, timeout) do
    receive do
      {:processing_timeout, ^worker} ->
        :timeout

      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, ^worker, reason} ->
        {:exit, reason}
    after
      timeout -> nil
    end
  end

  defp completed(state, {:ok, {:error, {:processing, reason}}})
       when reason in [:overloaded, :queue_timeout], do: %{state | status: :skip}

  defp completed(state, :timeout),
    do: %{state | status: {:ready, {:error, {:processing, :timeout}}}}

  defp completed(state, {:ok, result}), do: %{state | status: {:ready, result}}

  defp completed(state, {:exit, _reason}),
    do: %{state | status: {:ready, {:error, {:processing, :worker_down}}}}

  defp completed(state, nil),
    do: %{state | status: {:ready, {:error, {:session, :timeout}}}}

  defp prepare(download, notification, prefix, request, policy, config) do
    pool = Keyword.get(config, :processing_pool)

    ProcessingPool.within(pool, download, notification, config, fn ->
      Processing.prepare_download(request, {:download, download, prefix}, policy, config)
    end)
  catch
    :exit, {:shutdown, {:processing, _} = reason} -> {:error, reason}
  end
end
