defmodule ImagePipe.Cache.SharedFileSystem.Discovery do
  @moduledoc false

  alias ImagePipe.Cache.SharedFileSystem.{Directory, Partition}

  # Execute through the isolated I/O helper.
  def partitions(root, limit) do
    with {:ok, names, status, _inspected} <- names(Path.join(root, "partitions"), limit) do
      partitions =
        Enum.map(names, fn id ->
          %Partition{root: root, id: id, path: Path.join([root, "partitions", id])}
        end)

      {:ok, partitions, status}
    end
  end

  def candidates(partitions, kind, key, limit) do
    collect(partitions, kind, key, limit, [])
  end

  defp collect([], _kind, _key, _remaining, found), do: {:ok, Enum.reverse(found), :complete}
  defp collect(_partitions, _kind, _key, 0, found), do: {:ok, Enum.reverse(found), :limited}

  defp collect([partition | rest], kind, key, remaining, found) do
    parent = Partition.key_directory(partition, kind, key)

    with {:ok, names, status, inspected} <- names(parent, remaining) do
      found = Enum.reduce(names, found, &[Partition.location(parent, kind, key, &1) | &2])

      case status do
        :complete -> collect(rest, kind, key, remaining - inspected, found)
        :limited -> {:ok, Enum.reverse(found), :limited}
      end
    end
  end

  defp names(path, limit) do
    case Directory.list(path, limit) do
      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:ok, [], :complete, 0}

      result ->
        result
    end
  end
end
