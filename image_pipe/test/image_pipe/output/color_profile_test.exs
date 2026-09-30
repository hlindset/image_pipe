defmodule ImagePipe.Output.ColorProfileTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.ColorProfile

  test "path!/1 returns an existing file for each built-in target" do
    for target <- [:srgb, :display_p3, :adobe_rgb] do
      path = ColorProfile.path!(target)
      assert File.exists?(path), "expected #{path} to exist for #{target}"
      assert Path.extname(path) == ".icc"
    end
  end
end
