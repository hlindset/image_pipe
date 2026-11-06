defmodule ImagePipe.Cache.MemoryLimitTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache
  alias ImagePipe.Cache.FileSystem.Memo
  alias ImagePipe.Cache.MemoryLimit

  @moduletag :tmp_dir

  describe "bytes/1" do
    test "reads a cgroup v2 limit", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "memory.max"), "1073741824\n")
      assert MemoryLimit.bytes(dir) == 1_073_741_824
    end

    test "reads a cgroup v1 limit", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "memory"))
      File.write!(Path.join(dir, "memory/memory.limit_in_bytes"), "536870912\n")
      assert MemoryLimit.bytes(dir) == 536_870_912
    end

    test "is nil without a limit", %{tmp_dir: dir} do
      assert MemoryLimit.bytes(dir) == nil

      File.write!(Path.join(dir, "memory.max"), "max\n")
      assert MemoryLimit.bytes(dir) == nil

      File.rm!(Path.join(dir, "memory.max"))
      File.mkdir_p!(Path.join(dir, "memory"))
      File.write!(Path.join(dir, "memory/memory.limit_in_bytes"), "9223372036854771712\n")
      assert MemoryLimit.bytes(dir) == nil
    end
  end

  # One memo row per 50 KB of the cache and of the memory limit, whichever
  # is fewer, from 1,000 to 50,000.
  test "the memo's default limit" do
    assert Memo.limit_for(10_000_000_000, nil) == 50_000
    assert Memo.limit_for(1_000_000_000, nil) == 20_000
    assert Memo.limit_for(10_000_000_000, 1_000_000_000) == 20_000
    assert Memo.limit_for(1_000_000_000, 10_000_000_000) == 20_000
    assert Memo.limit_for(10_000_000_000, 10_000_000) == 1_000
  end

  # One original per 50 KB of the cache, and at most one per 20 KB of the
  # memory limit, from 10,000 to 200,000.
  test "the default number of remembered originals" do
    assert Cache.remembered_originals(10_000_000_000, nil) == 200_000
    assert Cache.remembered_originals(0, nil) == 10_000
    assert Cache.remembered_originals(10_000_000_000, 1_000_000_000) == 50_000
    assert Cache.remembered_originals(1_000_000_000, 10_000_000_000) == 20_000
    assert Cache.remembered_originals(10_000_000_000, 100_000_000) == 10_000
  end
end
