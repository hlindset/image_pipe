defmodule ImagePipe.Cache.SharedFileSystem.Inventory.Storage do
  @moduledoc false

  # Execute only through the isolated filesystem helper.
  def publish(partition, stage, encoded, name \\ "inventory") do
    temporary = Path.join(stage, name)
    destination = Path.join(partition, name)

    with :ok <- File.mkdir(stage),
         :ok <- File.write(temporary, encoded, [:exclusive]) do
      commit(temporary, destination, encoded)
    end
  end

  def commit(temporary, destination, encoded) do
    case File.rename(temporary, destination) do
      :ok ->
        :ok

      {:error, reason} ->
        case read(destination, byte_size(encoded)) do
          {:ok, ^encoded} -> :ok
          _missing_or_replaced -> {:error, reason}
        end
    end
  end

  def read(path, limit) do
    case File.open(path, [:read, :binary], &IO.binread(&1, limit + 1)) do
      {:ok, encoded} when is_binary(encoded) and byte_size(encoded) <= limit -> {:ok, encoded}
      {:ok, encoded} when is_binary(encoded) -> {:error, :inventory_too_large}
      {:ok, :eof} -> {:error, :corrupt_inventory}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
