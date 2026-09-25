defmodule ImagePipe.Cache.SharedFileSystem.Body do
  @moduledoc false

  @chunk 64 * 1024
  def working_bytes, do: 2 * @chunk

  def adopt(source, destination, limit) do
    case File.ln(source, destination) do
      :ok -> digest(destination, limit)
      {:error, reason} -> reconcile_link(source, destination, limit, reason)
    end
  end

  defp reconcile_link(source, destination, limit, reason) do
    case digest(destination, limit) do
      {:error, :enoent} when reason in [:exdev, :enotsup, :eperm, :emlink] ->
        copy(source, destination, limit)

      {:error, :enoent} ->
        {:error, reason}

      result ->
        result
    end
  end

  def copy(source, destination, limit) do
    with_file(source, [:read, :binary, :raw], fn input ->
      with_file(destination, [:write, :binary, :raw, :exclusive], fn output ->
        transfer(input, output, limit, 0, :crypto.hash_init(:sha256))
      end)
    end)
  end

  def digest(source, limit) do
    with_file(source, [:read, :binary, :raw], fn input ->
      transfer(input, nil, limit, 0, :crypto.hash_init(:sha256))
    end)
  end

  defp transfer(input, output, limit, bytes, hash) do
    case :file.read(input, min(@chunk, limit - bytes + 1)) do
      :eof ->
        {:ok, %{bytes: bytes, sha256: :crypto.hash_final(hash)}}

      {:ok, chunk} when bytes + byte_size(chunk) <= limit ->
        with :ok <- write(output, chunk) do
          transfer(
            input,
            output,
            limit,
            bytes + byte_size(chunk),
            :crypto.hash_update(hash, chunk)
          )
        end

      {:ok, _chunk} ->
        {:error, :body_too_large}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write(nil, _chunk), do: :ok
  defp write(output, chunk), do: :file.write(output, chunk)

  defp with_file(path, modes, function) do
    case :file.open(String.to_charlist(path), modes) do
      {:ok, file} ->
        try do
          result = function.(file)

          case :file.close(file) do
            :ok -> result
            {:error, reason} -> {:error, reason}
          end
        after
          :file.close(file)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
