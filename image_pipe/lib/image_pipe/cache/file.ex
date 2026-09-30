defmodule ImagePipe.Cache.File do
  @moduledoc "A verified, open cache body. Close it after delivery, including HEAD and 304."
  @enforce_keys [:io, :size, :sha256, :path]
  defstruct @enforce_keys
  @type t :: %__MODULE__{io: pid(), size: non_neg_integer(), sha256: String.t(), path: Path.t()}
  @chunk_size 65_536

  @doc false
  def open(path, size, sha256) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} -> verify(%__MODULE__{io: io, size: size, sha256: sha256, path: path})
      {:error, :enoent} -> :miss
      {:error, reason} -> {:error, {:body_read, reason}}
    end
  end

  defp verify(file) do
    {size, hash} =
      Enum.reduce(stream(file), {0, :crypto.hash_init(:sha256)}, fn chunk, {size, hash} ->
        {size + byte_size(chunk), :crypto.hash_update(hash, chunk)}
      end)

    digest = hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

    cond do
      size != file.size ->
        invalid(file, :body_byte_size_mismatch)

      digest != file.sha256 ->
        invalid(file, :body_digest_mismatch)

      true ->
        {:ok, 0} = :file.position(file.io, 0)
        {:ok, file}
    end
  rescue
    _exception -> invalid(file, :body_read_failed)
  end

  defp invalid(file, reason) do
    close(file)
    {:error, {:invalid_metadata, reason}}
  end

  def stream(%__MODULE__{io: io}), do: IO.binstream(io, @chunk_size)
  def close(%__MODULE__{io: io}), do: File.close(io)
end
