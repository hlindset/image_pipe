defmodule ImagePipe.Execution.Output do
  @moduledoc false
  @enforce_keys [:context, :value, :cache, :cache_us]
  @derive {Inspect, only: [:cache, :cache_us]}
  defstruct @enforce_keys ++ [extra_lease: nil, degraded?: false]

  alias ImagePipe.Cache
  alias ImagePipe.Debug.Info
  alias ImagePipe.Delivery.StreamPull

  # The bytes, their content type, and the image's width and height when
  # the request recorded them.
  def buffer(%__MODULE__{} = output), do: buffer_value(output.value)

  # A remembered body has no descriptor yet. One evicted since won't open,
  # and opening it forgets the remembered entry, so a second lookup reads it
  # from disk or misses.
  defp buffer_value({:entry, %{body: %Cache.File{io: nil} = file} = entry}) do
    case Cache.File.ensure_open(file) do
      {:ok, opened} ->
        try do
          buffer_value({:entry, %{entry | body: opened}})
        after
          Cache.File.close(opened)
        end

      _gone ->
        {:error, {:cache_read, :body_gone}}
    end
  end

  defp buffer_value({:entry, entry}) do
    StreamPull.translate(fn ->
      bytes =
        case entry.body do
          %Cache.File{} = file ->
            file |> Cache.File.stream() |> Enum.to_list() |> IO.iodata_to_binary()

          bytes ->
            bytes
        end

      {:ok, bytes, entry.content_type, entry.dimensions}
    end)
  end

  defp buffer_value({:body, bytes, type, debug}), do: {:ok, bytes, type, Info.dimensions(debug)}

  defp buffer_value({:stream, stream}) do
    with {:ok, chunks} <- collect(stream, [stream.first_chunk]) do
      {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), stream.content_type,
       Info.dimensions(stream.debug)}
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
