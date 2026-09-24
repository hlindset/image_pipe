defmodule ImagePipe.Cache.SharedFileSystem.Partition do
  @moduledoc false
  @enforce_keys [:root, :id, :path]
  defstruct [:root, :id, :path]

  # Execute these operations through SharedFileSystem.IO, never in its caller.
  def create(root) do
    id = identifier()
    partition = %__MODULE__{root: root, id: id, path: Path.join([root, "partitions", id])}

    with :ok <- File.mkdir_p(root),
         :ok <- directory(Path.join(root, "partitions")),
         :ok <- directory(Path.join(root, "trash")),
         :ok <- File.mkdir(partition.path),
         :ok <- children(partition),
         :ok <- heartbeat(partition) do
      {:ok, partition}
    end
  end

  def recover(partition) do
    case File.stat(partition.path) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, partition}
      {:error, :enoent} -> create(partition.root)
      {:error, reason} -> {:error, reason}
      {:ok, _stat} -> {:error, :enotdir}
    end
  end

  def heartbeat(partition), do: File.touch(Path.join(partition.path, "heartbeat"))

  def stage(partition, kind, key) do
    namespace = Path.join(partition.path, Atom.to_string(kind))
    shard = Path.join(namespace, String.slice(key, 0, 2))
    parent = Path.join(shard, key)
    generation = identifier()
    staging = Path.join([partition.path, "staging", generation])

    with :ok <- directory(shard),
         :ok <- directory(parent),
         :ok <- File.mkdir(staging) do
      {:ok,
       %{
         generation: generation,
         stage: staging,
         destination: Path.join(parent, generation),
         incarnation: partition.id
       }}
    end
  end

  def retire(partition) do
    destination = Path.join([partition.root, "trash", partition.id])

    case File.rename(partition.path, destination) do
      :ok -> {:ok, destination}
      {:error, :enoent} -> {:ok, destination}
      {:error, reason} -> {:error, reason}
    end
  end

  defp children(partition) do
    Enum.reduce_while(["staging", "outputs", "sources", "originals"], :ok, fn child, :ok ->
      case File.mkdir(Path.join(partition.path, child)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp directory(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  defp identifier, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
