defmodule ImagePipe.Cache.InputStagingTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias ImagePipe.Cache.Input

  defp mode(path), do: File.lstat!(path).mode |> Bitwise.band(0o777)

  test "creates the staging directory for this user only", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "staging")

    assert Input.private_dir(dir) == :ok
    assert File.dir?(dir)
    assert mode(dir) == 0o700
  end

  test "closes an existing directory this user owns", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "staging")
    File.mkdir!(dir)
    File.chmod!(dir, 0o777)

    assert Input.private_dir(dir) == :ok
    assert mode(dir) == 0o700
  end

  test "refuses a symlink or a file in place of the directory", %{tmp_dir: tmp_dir} do
    target = Path.join(tmp_dir, "elsewhere")
    File.mkdir!(target)
    File.chmod!(target, 0o755)
    link = Path.join(tmp_dir, "link")
    File.ln_s!(target, link)
    file = Path.join(tmp_dir, "file")
    File.write!(file, "")

    assert Input.private_dir(link) == :error
    assert Input.private_dir(file) == :error
    assert mode(target) == 0o755
  end
end
