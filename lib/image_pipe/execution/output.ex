defmodule ImagePipe.Execution.Output do
  @moduledoc false
  @enforce_keys [:context, :value, :cache, :cache_us]
  @derive {Inspect, only: [:cache, :cache_us]}
  defstruct @enforce_keys ++ [extra_lease: nil]

  alias ImagePipe.Cache
  alias ImagePipe.Delivery.StreamPull

  def buffer(%__MODULE__{} = output), do: buffer_value(output.value)

  defp buffer_value({:entry, entry}) do
    StreamPull.translate(fn ->
      bytes =
        case entry.body do
          %Cache.File{} = file ->
            file |> Cache.File.stream() |> Enum.to_list() |> IO.iodata_to_binary()

          bytes ->
            bytes
        end

      {:ok, bytes, entry.content_type, entry.debug}
    end)
  end

  defp buffer_value({:body, bytes, type, debug}), do: {:ok, bytes, type, debug}

  defp buffer_value({:stream, stream}) do
    with {:ok, chunks} <- collect(stream, [stream.first_chunk]) do
      {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), stream.content_type, stream.debug}
    end
  end

  defp collect(stream, chunks) do
    case stream.next.() do
      {:chunk, chunk} -> collect(stream, [chunk | chunks])
      :done -> {:ok, chunks}
      {:error, _reason} = error -> error
    end
  end

  def consume(%__MODULE__{value: {:stream, stream}}), do: drain(stream)

  def consume(%__MODULE__{}), do: {:ok, :done}

  defp drain(stream) do
    case stream.next.() do
      {:chunk, _chunk} -> drain(stream)
      :done -> {:ok, :done}
      {:error, _reason} = error -> error
    end
  end
end
