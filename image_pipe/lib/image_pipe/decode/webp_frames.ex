defmodule ImagePipe.Decode.WebpFrames do
  @moduledoc false

  import Bitwise

  # libvips' WebP loader visits every animation frame while reading the header,
  # at a cost that grows quadratically with the frame count. This walk counts
  # the `ANMF` chunks first so an oversized animation is rejected before any
  # libvips open. It reads 8-byte chunk headers and never frame payloads.
  # https://developers.google.com/speed/webp/docs/riff_container

  @animation_flag 0x02
  @first_chunk 12

  @doc "Whether the peek is an extended-format WebP with the animation flag set."
  @spec animated?(binary()) :: boolean()
  def animated?(<<"RIFF", _size::32, "WEBP", "VP8X", _length::32, flags, _rest::binary>>),
    do: band(flags, @animation_flag) != 0

  def animated?(_peek), do: false

  @doc """
  Counts `ANMF` chunks, stopping once the count exceeds `limit`.

  A truncated or malformed chunk ends the walk; libvips then decides whether
  the body opens at all.
  """
  @spec count({:buffer, binary()} | {:path, Path.t()}, pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count({:buffer, binary}, limit),
    do: {:ok, walk(&buffer_header(binary, &1), @first_chunk, 0, limit)}

  def count({:path, path}, limit) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, device} ->
        try do
          {:ok, walk(&file_header(device, &1), @first_chunk, 0, limit)}
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, {:frame_count_failed, reason}}
    end
  end

  defp walk(_read, _position, count, limit) when count > limit, do: count

  defp walk(read, position, count, limit) do
    case read.(position) do
      <<id::binary-size(4), size::little-32>> ->
        count = if id == "ANMF", do: count + 1, else: count
        walk(read, position + 8 + size + band(size, 1), count, limit)

      _short ->
        count
    end
  end

  defp buffer_header(binary, position) when position + 8 <= byte_size(binary),
    do: binary_part(binary, position, 8)

  defp buffer_header(_binary, _position), do: :eof

  defp file_header(device, position) do
    case :file.pread(device, position, 8) do
      {:ok, header} -> header
      _eof_or_error -> :eof
    end
  end
end
