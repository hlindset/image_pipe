defmodule ImagePipe.RawFileTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.RawFile

  @moduletag :tmp_dir

  describe "make_dir_p/1" do
    test "makes every missing directory", %{tmp_dir: dir} do
      path = Path.join([dir, "a", "b", "c"])

      assert RawFile.make_dir_p(path) == :ok
      assert File.dir?(path)
      assert RawFile.make_dir_p(path) == :ok
    end

    test "fails where a file is in the way", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "file"), "")

      assert RawFile.make_dir_p(Path.join(dir, "file")) == {:error, :enotdir}
      assert RawFile.make_dir_p(Path.join([dir, "file", "below"])) == {:error, :enotdir}
    end

    property "agrees with File.mkdir_p/1", %{tmp_dir: dir} do
      check all(
              existing <- list_of(segment(), max_length: 3),
              file <- one_of([constant(nil), segment()]),
              wanted <- list_of(segment(), max_length: 4)
            ) do
        for {root, mkdir_p} <- [{"raw", &RawFile.make_dir_p/1}, {"elixir", &File.mkdir_p/1}] do
          base = Path.join([dir, root, "#{System.unique_integer([:positive])}"])
          File.mkdir_p!(Path.join([base | existing]))
          if file && file != List.first(existing), do: File.write!(Path.join(base, file), "")
          path = Path.join([base | wanted])
          {mkdir_p.(path), File.dir?(path)}
        end
        |> then(fn [raw, elixir] -> assert raw == elixir end)
      end
    end
  end

  test "rename/2, make_link/2 and delete/1 return :file's results", %{tmp_dir: dir} do
    a = Path.join(dir, "a")
    File.write!(a, "x")

    assert RawFile.make_link(a, Path.join(dir, "b")) == :ok
    assert RawFile.make_link(a, Path.join(dir, "b")) == {:error, :eexist}
    assert RawFile.rename(Path.join(dir, "b"), Path.join(dir, "c")) == :ok
    assert File.read!(Path.join(dir, "c")) == "x"
    assert RawFile.delete(Path.join(dir, "c")) == :ok
    assert RawFile.delete(Path.join(dir, "c")) == {:error, :enoent}
  end

  test "stat/2 and lstat/2 return File.Stat structs", %{tmp_dir: dir} do
    file = Path.join(dir, "file")
    File.write!(file, "abc")
    File.ln_s!(file, Path.join(dir, "link"))

    assert {:ok, %File.Stat{type: :regular, size: 3}} = RawFile.stat(file)
    assert {:ok, %File.Stat{mtime: mtime}} = RawFile.stat(file, time: :posix)
    assert is_integer(mtime)
    assert {:ok, %File.Stat{type: :symlink}} = RawFile.lstat(Path.join(dir, "link"))
    assert RawFile.stat(Path.join(dir, "missing")) == {:error, :enoent}
  end

  test "set_times/2 and set_mode/2 change the file", %{tmp_dir: dir} do
    file = Path.join(dir, "file")
    File.write!(file, "")

    assert RawFile.set_times(file, 1_700_000_000) == :ok
    assert File.stat!(file, time: :posix).mtime == 1_700_000_000
    assert RawFile.set_mode(file, 0o600) == :ok
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
  end

  test "read/1, write/3 and list_dir/1 use binaries", %{tmp_dir: dir} do
    file = Path.join(dir, "file")

    assert RawFile.write(file, "abc") == :ok
    assert RawFile.write(file, "abc", [:exclusive]) == {:error, :eexist}
    assert RawFile.read(file) == {:ok, "abc"}
    assert RawFile.list_dir(dir) == {:ok, ["file"]}
    assert RawFile.read(Path.join(dir, "missing")) == {:error, :enoent}
  end

  defp segment, do: string(?a..?c, length: 1)
end
