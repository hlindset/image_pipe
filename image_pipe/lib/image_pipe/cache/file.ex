defmodule ImagePipe.Cache.File do
  # A cache body whose size matches its metadata. Bodies are hashed and
  # synced to disk when written and never rewritten in place, so a hit checks
  # only the size, which catches truncation. A decode failure re-hashes a
  # cached original. Close it after delivery, including HEAD and 304.
  #
  # A body read from disk is open. A remembered one is only stat'ed, since
  # delivery sends it by path. A body evicted between that stat and the send
  # has no descriptor to read it from, so `forget/1` drops the remembered row
  # and the request reads the entry again.
  @moduledoc false
  @enforce_keys [:io, :size, :path]
  defstruct @enforce_keys ++ [remembered: nil]

  @type t :: %__MODULE__{
          io: :file.io_device() | nil,
          size: non_neg_integer(),
          path: Path.t(),
          remembered: {Path.t(), String.t()} | nil
        }
  @chunk_size 65_536

  alias ImagePipe.Cache.FileSystem.Memo

  @doc false
  def open(path, size) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, io} -> check_size(%__MODULE__{io: io, size: size, path: path})
      {:error, :enoent} -> :miss
      {:error, reason} -> {:error, {:body_read, reason}}
    end
  end

  # A remembered body whose size still matches, or `:gone`.
  @doc false
  def remembered(path, size, root, key_hash) do
    case :file.read_file_info(path, [:raw]) do
      {:ok, info} when elem(info, 1) == size ->
        {:ok, %__MODULE__{io: nil, size: size, path: path, remembered: {root, key_hash}}}

      _gone_or_changed ->
        :gone
    end
  end

  # Opens a remembered body, forgetting it if it won't open.
  @doc false
  def ensure_open(%__MODULE__{io: nil} = file) do
    case open(file.path, file.size) do
      {:ok, opened} ->
        {:ok, opened}

      failure ->
        forget(file)
        failure
    end
  end

  def ensure_open(%__MODULE__{} = file), do: {:ok, file}

  @doc false
  def forget(%__MODULE__{remembered: {root, key_hash}}), do: Memo.drop(root, key_hash)
  def forget(%__MODULE__{}), do: :ok

  defp check_size(file) do
    case :file.read_file_info(file.io, time: :posix) do
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

  # A remembered body is opened for the stream and closed when it ends.
  def stream(%__MODULE__{io: nil} = file) do
    Stream.resource(
      fn ->
        case ensure_open(file) do
          {:ok, opened} ->
            opened.io

          _failure ->
            raise File.Error, reason: :enoent, action: "open cached body", path: file.path
        end
      end,
      &read_chunk/1,
      &:file.close/1
    )
  end

  def stream(%__MODULE__{io: io}),
    do: Stream.resource(fn -> io end, &read_chunk/1, fn _io -> :ok end)

  defp read_chunk(io) do
    case :file.read(io, @chunk_size) do
      {:ok, bytes} -> {[bytes], io}
      :eof -> {:halt, io}
      {:error, reason} -> raise File.Error, reason: reason, action: "read cached body"
    end
  end

  def close(%__MODULE__{io: nil}), do: :ok
  def close(%__MODULE__{io: io}), do: :file.close(io)
end
