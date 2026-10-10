defmodule ImagePipe.Test.WorkCount do
  @moduledoc """
  Counts the work a function does across every process: the libvips
  operations ImagePipe calls through Vix, its memory copies, and the bytes it
  reads from files through Erlang.

      {conn, work} = WorkCount.measure(fn -> ImagePipe.Plug.call(conn, config) end)
      work.loads #=> 1

  It traces all processes, so call it only from an `async: false` test, which
  ExUnit runs after the async tests, with nothing else running. Calls inside
  libvips, such as its own file reads, aren't counted, so the counts don't
  depend on the libvips build.
  """
  use Boundary, top_level?: true, check: [out: false]

  @type t :: %{
          operations: %{String.t() => pos_integer()},
          loads: non_neg_integer(),
          copies: non_neg_integer(),
          icc: non_neg_integer(),
          file_bytes: %{String.t() => non_neg_integer()}
        }

  @traced [
    {Vix.Nif, :nif_vips_operation_call, 2},
    {Vix.Nif, :nif_image_copy_memory, 1}
  ]
  # File reads are matched to their path through the device `open` returns.
  @returned [{:file, :open, 2}, {:file, :read, 2}]
  @return_trace [{:_, [], [{:return_trace}]}]

  @spec measure((-> result)) :: {result, t()} when result: var
  def measure(fun) do
    tracer = spawn_link(fn -> collect([]) end)
    :erlang.trace(:all, true, [:call, {:tracer, tracer}])
    Enum.each(@traced, &:erlang.trace_pattern(&1, true, [:local]))
    Enum.each(@returned, &:erlang.trace_pattern(&1, @return_trace, [:local]))

    result =
      try do
        fun.()
      after
        :erlang.trace(:all, false, [:call])
        Enum.each(@traced ++ @returned, &:erlang.trace_pattern(&1, false, [:local]))
      end

    ref = :erlang.trace_delivered(:all)
    receive do: ({:trace_delivered, :all, ^ref} -> :ok)
    send(tracer, {:done, self()})
    calls = receive do: ({:calls, calls} -> calls)

    {result, summarize(calls)}
  end

  defp collect(calls) do
    receive do
      {:trace, pid, :call, call} -> collect([{pid, call} | calls])
      {:trace, pid, :return_from, mfa, result} -> collect([{pid, {:return, mfa, result}} | calls])
      {:done, from} -> send(from, {:calls, Enum.reverse(calls)})
    end
  end

  defp summarize(calls) do
    operations =
      for {_pid, {Vix.Nif, :nif_vips_operation_call, [name | _]}} <- calls,
          do: to_string(name)

    %{
      operations: Enum.frequencies(operations),
      loads: Enum.count(operations, &String.starts_with?(&1, "VipsForeignLoad")),
      copies: Enum.count(calls, &match?({_pid, {Vix.Nif, :nif_image_copy_memory, _}}, &1)),
      icc: Enum.count(operations, &String.starts_with?(&1, "icc_")),
      file_bytes: file_bytes(calls)
    }
  end

  # A call and its return arrive in order from the process that made them, so
  # each process's open path and read device are held until the return.
  defp file_bytes(calls) do
    {_pending, _devices, bytes} =
      Enum.reduce(calls, {%{}, %{}, %{}}, fn
        {pid, {:file, :open, [path | _]}}, {pending, devices, bytes} ->
          {Map.put(pending, pid, IO.chardata_to_string(path)), devices, bytes}

        {pid, {:return, {:file, :open, 2}, {:ok, device}}}, {pending, devices, bytes} ->
          {path, pending} = Map.pop(pending, pid)
          {pending, Map.put(devices, device, path), Map.put_new(bytes, path, 0)}

        {pid, {:file, :read, [device | _]}}, {pending, devices, bytes} ->
          {Map.put(pending, pid, device), devices, bytes}

        {pid, {:return, {:file, :read, 2}, {:ok, data}}}, {pending, devices, bytes} ->
          {device, pending} = Map.pop(pending, pid)

          case Map.fetch(devices, device) do
            {:ok, path} -> {pending, devices, Map.update!(bytes, path, &(&1 + byte_size(data)))}
            :error -> {pending, devices, bytes}
          end

        {pid, {:return, _mfa, _other}}, {pending, devices, bytes} ->
          {Map.delete(pending, pid), devices, bytes}

        _call, acc ->
          acc
      end)

    bytes
  end
end
