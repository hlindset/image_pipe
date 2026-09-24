defmodule ImagePipe.Cache.SharedFileSystem.DirectoryTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.SharedFileSystem.Directory

  setup_all do
    Mix.Task.run("image_pipe.shared_cache.build")
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "shared_directory_#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "stops enumeration at the name budget", %{root: root} do
    for n <- 1..100 do
      File.touch!(Path.join(root, Base.encode16(<<n::128>>, case: :lower)))
    end

    assert {:ok, names, :limited, 7} = Directory.list(root, 7)
    assert length(names) == 7
    assert {:ok, all, :complete, 100} = Directory.list(root, 100)
    assert length(all) == 100
  end

  test "unusable names consume enumeration budget", %{root: root} do
    File.touch!(Path.join(root, "invalid-name"))
    File.touch!(Path.join(root, "also-invalid"))
    assert {:ok, [], :limited, 1} = Directory.list(root, 1)
    assert {:ok, [], :complete, 2} = Directory.list(root, 2)
  end

  test "missing and non-directory paths return filesystem errors", %{root: root} do
    assert {:error, :enoent} = Directory.list(Path.join(root, "missing"), 10)
    file = Path.join(root, "file")
    File.touch!(file)
    assert {:error, :enotdir} = Directory.list(file, 10)
  end
end
