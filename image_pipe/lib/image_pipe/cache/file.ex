defmodule ImagePipe.Cache.File do
  # An open cache body whose size matches its metadata. Bodies are hashed when
  # written and never rewritten in place, so a hit checks only the size, which
  # catches truncation. Close it after delivery, including HEAD and 304.
  @moduledoc false
  @enforce_keys [:io, :size, :path]
  defstruct @enforce_keys
  @type t :: %__MODULE__{io: :file.io_device(), size: non_neg_integer(), path: Path.t()}
  @chunk_size 65_536

  @doc false
  def open(path, size) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, io} -> check_size(%__MODULE__{io: io, size: size, path: path})
      {:error, :enoent} -> :miss
      {:error, reason} -> {:error, {:body_read, reason}}
    end
  end

  defp check_size(file) do
    case :file.read_file_info(file.io) do
      {:ok, info} when elem(info, 1) == file.size ->
        {:ok, file}

      {:ok, _info} ->
        invalid(file, :body_byte_size_mismatch)

      {:error, _reason} ->
        invalid(file, :body_read_failed)
    end
  end

  defp invalid(file, reason) do
    close(file)
    {:error, {:invalid_metadata, reason}}
  end

  def stream(%__MODULE__{io: io}) do
    Stream.resource(
      fn -> io end,
      fn io ->
        case :file.read(io, @chunk_size) do
          {:ok, bytes} -> {[bytes], io}
          :eof -> {:halt, io}
          {:error, reason} -> raise File.Error, reason: reason, action: "read cached body"
        end
      end,
      fn _io -> :ok end
    )
  end

  def close(%__MODULE__{io: io}), do: :file.close(io)
end
