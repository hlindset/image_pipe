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

  test "reports filesystem capacity separately from directory contents", %{root: root} do
    assert {:ok, stats} = Directory.space(root)
    assert stats.filesystem_total_bytes > 0
    assert stats.filesystem_free_bytes <= stats.filesystem_total_bytes
    assert stats.filesystem_available_bytes <= stats.filesystem_free_bytes
    assert stats.filesystem_available_bytes >= 0
    assert File.ls!(root) == []
    assert {:error, :enoent} = Directory.space(Path.join(root, "missing"))

    file = Path.join(root, "file")
    File.touch!(file)
    assert {:error, :enotdir} = Directory.space(file)
  end

  test "trash cleanup makes bounded progress and preserves symlink targets", %{root: root} do
    trash = Path.join(root, "trash")
    File.mkdir!(trash)
    outside = Path.join(root, "outside")
    File.mkdir!(outside)
    File.write!(Path.join(outside, "keep"), "untouched")
    File.ln_s!(outside, Path.join(trash, "linked-directory"))

    for n <- 1..30 do
      directory = Path.join([trash, Integer.to_string(n), "nested"])
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "body"), "body")
      File.write!(Path.join(directory, "meta"), "meta")
    end

    assert {:ok, %{inspected: 8, limited: true}} = Directory.sweep(trash, 8)

    for _ <- 1..30 do
      assert {:ok, %{inspected: inspected, errors: 0}} = Directory.sweep(trash, 8)
      assert inspected <= 8
    end

    assert File.ls!(trash) == []
    assert File.read!(Path.join(outside, "keep")) == "untouched"
    assert {:ok, %{inspected: 0, removed: 0, limited: false}} = Directory.sweep(trash, 8)
  end

  test "overlapping trash passes tolerate files disappearing", %{root: root} do
    for n <- 1..100, do: File.write!(Path.join(root, Integer.to_string(n)), "body")
    tasks = start_supervised!(Task.Supervisor)

    results =
      for _ <- 1..2 do
        Task.Supervisor.async_nolink(tasks, fn -> Directory.sweep(root, 200) end)
      end
      |> Enum.map(&Task.await/1)

    assert Enum.all?(results, &match?({:ok, %{errors: 0}}, &1))
    assert File.ls!(root) == []
  end

  test "a symlink cannot be used as the trash root", %{root: root} do
    target = Path.join(root, "target")
    File.mkdir!(target)
    File.write!(Path.join(target, "keep"), "untouched")
    link = Path.join(root, "link")
    File.ln_s!(target, link)
    assert {:error, _reason} = Directory.sweep(link, 100)
    assert File.read!(Path.join(target, "keep")) == "untouched"
  end
end
