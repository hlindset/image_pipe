defmodule ImagePipe.SafePathPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :tmp_dir

  alias ImagePipe.SafePath

  # A root with directories, files and links that stay inside, climb out, are
  # absolute, chain, and loop.
  defp tree(tmp_dir) do
    root = Path.join(tmp_dir, "root")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(Path.join(root, "a/b"))
    File.mkdir_p!(outside)
    File.write!(Path.join(root, "a/file"), "")

    for {name, target} <- [
          {"in", "a"},
          {"a/up", ".."},
          {"a/out", "../../outside"},
          {"abs", outside},
          {"chain", "in"},
          {"loop1", "loop2"},
          {"loop2", "loop1"},
          {"a/b/self", "."}
        ] do
      File.ln_s!(target, Path.join(root, name))
    end

    root
  end

  property "agrees with Path.safe_relative/2", %{tmp_dir: tmp_dir} do
    root = tree(tmp_dir)
    segments = ~w(. .. a b file in up out abs chain loop1 self missing)

    check all parts <- list_of(member_of(segments), min_length: 1, max_length: 6),
              absolute? <- boolean(),
              max_runs: 1_000 do
      path = if(absolute?, do: "/", else: "") <> Path.join(parts)
      assert SafePath.relative(path, root) == Path.safe_relative(path, root), path
    end
  end
end
