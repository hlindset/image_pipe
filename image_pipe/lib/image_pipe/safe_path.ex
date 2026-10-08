defmodule ImagePipe.SafePath do
  # `Path.safe_relative/2` without the file server.
  #
  # A port of OTP's `filelib:safe_relative_path/2`, which resolves each segment's
  # symlinks with `file:read_link/1`, a call through the VM-wide file server that
  # serializes every caller. This reads links with `:prim_file` in the calling
  # process instead, with the same rules: `..` may not climb above `relative_to`,
  # absolute paths and links are unsafe, and a link loop is unsafe.
  @moduledoc false

  use Boundary, top_level?: true, deps: [], exports: []

  @doc "Like `Path.safe_relative/2`."
  @spec relative(Path.t(), Path.t()) :: {:ok, Path.t()} | :error
  def relative(path, relative_to) do
    case walk(Path.split(path), relative_to, %{}, []) do
      :unsafe -> :error
      relative -> {:ok, relative}
    end
  end

  defp walk([], _cwd, _seen, []), do: ""
  defp walk([], _cwd, _seen, acc), do: Path.join(acc)
  defp walk(["." | segments], cwd, seen, acc), do: walk(segments, cwd, seen, acc)
  defp walk([".." | _segments], _cwd, _seen, []), do: :unsafe

  defp walk([".." | segments], cwd, seen, acc),
    do: walk(segments, cwd, seen, List.delete_at(acc, -1))

  defp walk([:clear | segments], cwd, _seen, acc), do: walk(segments, cwd, %{}, acc)

  defp walk([segment | _] = segments, cwd, seen, acc) do
    case Path.type(segment) do
      :relative -> walk_segment(segments, cwd, seen, acc)
      _absolute -> :unsafe
    end
  end

  defp walk_segment([segment | segments], cwd, seen, acc) do
    parent = Path.join([cwd | acc])

    case :prim_file.read_link(Path.join(parent, segment)) do
      {:ok, link} -> walk_link(parent, IO.chardata_to_string(link), segments, cwd, seen, acc)
      {:error, _reason} -> walk(segments, cwd, seen, acc ++ [segment])
    end
  end

  defp walk_link(parent, link, segments, cwd, seen, acc) do
    full_link = :filename.join(parent, link)

    case Map.has_key?(seen, full_link) do
      true ->
        :unsafe

      false ->
        walk(Path.split(link) ++ [:clear | segments], cwd, Map.put(seen, full_link, true), acc)
    end
  end
end
