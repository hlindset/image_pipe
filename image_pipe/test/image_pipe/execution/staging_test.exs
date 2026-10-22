defmodule ImagePipe.Execution.StagingTest do
  # The sweep test sets TMPDIR, which every staging call reads.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  import ExUnit.CaptureLog

  alias ImagePipe.Execution.Staging

  defp mode(path), do: File.lstat!(path).mode |> Bitwise.band(0o777)

  test "creates the staging directory for this user only", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "staging")

    assert Staging.private_dir(dir) == :ok
    assert File.dir?(dir)
    assert mode(dir) == 0o700
  end

  test "closes an existing directory this user owns", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "staging")
    File.mkdir!(dir)
    File.chmod!(dir, 0o777)

    assert Staging.private_dir(dir) == :ok
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

    log =
      capture_log(fn ->
        assert Staging.private_dir(link) == :error
        assert Staging.private_dir(file) == :error
        assert Staging.private_dir(file) == :error
      end)

    assert mode(target) == 0o755
    assert log =~ "[warning] image_pipe cache: can't stage originals in #{link}"
    assert [_once] = Regex.scan(~r/can't stage originals in #{Regex.escape(file)}/, log)
  end

  test "the sweep removes expired staged originals and keeps fresh ones", %{tmp_dir: tmp_dir} do
    previous = System.get_env("TMPDIR")
    System.put_env("TMPDIR", tmp_dir)

    on_exit(fn ->
      if previous, do: System.put_env("TMPDIR", previous), else: System.delete_env("TMPDIR")
    end)

    dir = Staging.dir()
    File.mkdir_p!(dir)
    old = System.os_time(:second) - 7_200
    expired = write!(dir, ".image-pipe-Ab_c-dE.tmp", old)
    fresh = write!(dir, ".image-pipe-Fg_h-iJ.tmp", nil)
    other = write!(dir, "other.tmp", old)

    assert %{staged: 1, bytes: 5} = Staging.sweep()
    refute File.exists?(expired)
    assert File.exists?(fresh)
    assert File.exists?(other)
  end

  defp write!(dir, name, mtime) do
    path = Path.join(dir, name)
    File.write!(path, "bytes")
    if mtime, do: File.touch!(path, mtime)
    path
  end
end
