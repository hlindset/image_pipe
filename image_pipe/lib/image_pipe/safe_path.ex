defmodule ImagePipe.SafePath do
  # `Path.safe_relative/2` without the file server.
  #
  # A port of OTP's `filelib:safe_relative_path/2`, which resolves each segment's
  # symlinks with `file:read_link/1`, a call through the VM-wide file server that
  # serializes every caller. This reads links with `:prim_file` in the calling
  # process instead, with the same rules: `..` may not climb above `relative_to`,
  # and absolute paths and links are unsafe. A path that follows more than
  # `@max_links` links is unsafe, like `ELOOP`; that catches every link loop,
  # including one OTP's check misses and follows forever.
  @moduledoc false

  use Boundary, top_level?: true, deps: [], exports: []

  @max_links 40

  @doc "Like `Path.safe_relative/2`."
  @spec relative(Path.t(), Path.t()) :: {:ok, Path.t()} | :error
  def relative(path, relative_to) do
    case walk(Path.split(path), relative_to, @max_links, []) do
      :unsafe -> :error
      relative -> {:ok, relative}
    end
  end

  defp walk([], _cwd, _links_left, []), do: ""
  defp walk([], _cwd, _links_left, acc), do: Path.join(acc)
  defp walk(["." | segments], cwd, links_left, acc), do: walk(segments, cwd, links_left, acc)
  defp walk([".." | _segments], _cwd, _links_left, []), do: :unsafe

  defp walk([".." | segments], cwd, links_left, acc),
    do: walk(segments, cwd, links_left, List.delete_at(acc, -1))

  defp walk([segment | _] = segments, cwd, links_left, acc) do
    case Path.type(segment) do
      :relative -> walk_segment(segments, cwd, links_left, acc)
      _absolute -> :unsafe
    end
  end

  defp walk_segment([segment | segments], cwd, links_left, acc) do
    case :prim_file.read_link(Path.join([cwd | acc] ++ [segment])) do
      {:ok, _link} when links_left == 0 ->
        :unsafe

      {:ok, link} ->
        walk(Path.split(IO.chardata_to_string(link)) ++ segments, cwd, links_left - 1, acc)

      {:error, _reason} ->
        walk(segments, cwd, links_left, acc ++ [segment])
    end
  end
end
