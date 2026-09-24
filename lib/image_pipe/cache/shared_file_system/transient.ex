defmodule ImagePipe.Cache.SharedFileSystem.Transient do
  @moduledoc false

  # Directories are unique lease destinations; cleanup runs only after all of
  # that lease's issued operations complete. No operation recreates ancestors.
  def create(path), do: File.mkdir(path)

  def remove(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end
end
