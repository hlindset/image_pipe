defmodule ImagePipe.Cache.SharedFileSystem.Discovery do
  @moduledoc false

  alias ImagePipe.Cache.SharedFileSystem.Partition

  # Execute through the isolated I/O helper. Limits bound inspected names and
  # returned candidates; File.ls still materializes the underlying directory.
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
    case File.ls(path) do
      {:ok, entries} ->
        {selected, rest} = Enum.split(entries, limit)
        names = selected |> Enum.filter(&identifier?/1) |> Enum.sort()

        status =
          case rest do
            [] -> :complete
            [_ | _] -> :limited
          end

        {:ok, names, status, length(selected)}

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:ok, [], :complete, 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp identifier?(name), do: Regex.match?(~r/\A[0-9a-f]{32}\z/, name)
end
