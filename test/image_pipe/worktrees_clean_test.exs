defmodule ImagePipe.WorktreesCleanTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Worktrees.Clean

  @bases [".worktrees", ".claude/worktrees"]
  @regenerable ~w(
    deps _build
    fiddle/deps fiddle/_build fiddle/node_modules fiddle/assets/node_modules
    .dexter .expert
  )

  setup do
    root = Path.join(System.tmp_dir!(), "wtclean_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp populate_dir(path) do
    File.mkdir_p!(path)
    File.write!(Path.join(path, ".keep"), "x")
  end

  # These tests cover *what* gets removed and the safety boundary, independent of
  # the age gate, so they disable it with `max_age_hours: 0` (clean anything idle
  # ≥ 0h, i.e. every worktree). The age gate has its own `describe` block below.

  test "removes every regenerable dir from each worktree under both bases, leaving sources alone",
       %{root: root} do
    for base <- @bases, name <- ~w(a b) do
      wt = Path.join([root, base, name])
      for target <- @regenerable, do: populate_dir(Path.join(wt, target))
      # Source files that must survive.
      populate_dir(Path.join(wt, "lib"))
      File.write!(Path.join(wt, "mix.exs"), "x")
    end

    %{removed: removed, skipped: skipped} = Clean.clean(root, max_age_hours: 0)

    assert skipped == []
    # 8 regenerable targets × 2 worktree names × 2 bases.
    assert length(removed) == 32

    for base <- @bases, name <- ~w(a b) do
      wt = Path.join([root, base, name])
      for target <- @regenerable, do: refute(File.exists?(Path.join(wt, target)))
      # The fiddle dir itself stays — only its regenerable children are removed.
      assert File.dir?(Path.join(wt, "fiddle"))
      assert File.dir?(Path.join(wt, "fiddle/assets"))
      # Sources untouched.
      assert File.dir?(Path.join(wt, "lib"))
      assert File.exists?(Path.join(wt, "mix.exs"))
    end
  end

  test "ignores a base directory that does not exist", %{root: root} do
    wt = Path.join([root, ".claude/worktrees", "only"])
    populate_dir(Path.join(wt, "deps"))

    # `.worktrees` is absent; the task must just skip it, not crash.
    %{removed: removed} = Clean.clean(root, max_age_hours: 0)

    assert removed == [Path.join(wt, "deps")]
    refute File.exists?(Path.join(wt, "deps"))
  end

  test "does not delete content reached through a worktree symlink that escapes the root",
       %{root: root} do
    # An intermediate symlink: <root>/.claude/worktrees/escape -> <outside>/realwt,
    # whose `deps` lives entirely outside the git root.
    outside =
      Path.join(System.tmp_dir!(), "wtclean_outside_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(outside) end)
    real_wt = Path.join(outside, "realwt")
    populate_dir(Path.join(real_wt, "deps"))

    link = Path.join([root, ".claude/worktrees", "escape"])
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!(real_wt, link)

    %{removed: removed, skipped: skipped} = Clean.clean(root, max_age_hours: 0)

    assert removed == []
    assert Path.join(link, "deps") in skipped
    # The real content outside the root is untouched.
    assert File.exists?(Path.join([real_wt, "deps", ".keep"]))
  end

  test "does not delete a sibling worktree's sources via a target symlink that stays inside the root",
       %{root: root} do
    base = ".claude/worktrees"
    bar_lib = Path.join([root, base, "bar", "lib"])
    populate_dir(bar_lib)

    foo = Path.join([root, base, "foo"])
    File.mkdir_p!(foo)
    # foo/deps -> ../bar/lib: inside the git root, but escapes foo's own worktree.
    File.ln_s!("../bar/lib", Path.join(foo, "deps"))

    %{removed: removed, skipped: skipped} = Clean.clean(root, max_age_hours: 0)

    assert removed == []
    assert Path.join(foo, "deps") in skipped
    # The sibling worktree's sources survive.
    assert File.exists?(Path.join(bar_lib, ".keep"))
  end

  describe "age gate" do
    # Write a source file with a controlled mtime (seconds before now). Avoids
    # `populate_dir`, whose `.keep` would carry a fresh mtime and defeat the gate.
    defp write_source(path, age_seconds) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "x")
      File.touch!(path, System.os_time(:second) - age_seconds)
    end

    test "keeps regenerable dirs in a worktree edited within the window", %{root: root} do
      wt = Path.join([root, ".claude/worktrees", "active"])
      populate_dir(Path.join(wt, "deps"))
      # Edited "just now" — well within the 48h window.
      write_source(Path.join(wt, "lib/foo.ex"), 0)

      %{removed: removed, fresh: fresh} = Clean.clean(root, max_age_hours: 48)

      assert removed == []
      assert wt in fresh
      assert File.exists?(Path.join(wt, "deps"))
    end

    test "removes regenerable dirs in a worktree idle past the window", %{root: root} do
      wt = Path.join([root, ".claude/worktrees", "stale"])
      populate_dir(Path.join(wt, "deps"))
      write_source(Path.join(wt, "lib/foo.ex"), 100 * 3600)

      %{removed: removed, fresh: fresh} = Clean.clean(root, max_age_hours: 48)

      assert removed == [Path.join(wt, "deps")]
      assert fresh == []
      refute File.exists?(Path.join(wt, "deps"))
    end

    test "build churn inside regenerable dirs does not count as activity", %{root: root} do
      wt = Path.join([root, ".claude/worktrees", "built"])
      # Source last edited days ago...
      write_source(Path.join(wt, "lib/foo.ex"), 100 * 3600)
      # ...but a build wrote into _build and deps moments ago (fresh mtimes).
      populate_dir(Path.join(wt, "_build"))
      populate_dir(Path.join(wt, "deps"))

      %{removed: removed, fresh: fresh} = Clean.clean(root, max_age_hours: 48)

      # The fresh build output must not keep the tree alive — only source mtime gates.
      assert fresh == []
      assert Path.join(wt, "deps") in removed
      assert Path.join(wt, "_build") in removed
    end

    test "a worktree with no surviving source counts as stale", %{root: root} do
      wt = Path.join([root, ".claude/worktrees", "onlybuild"])
      populate_dir(Path.join(wt, "deps"))

      %{removed: removed, fresh: fresh} = Clean.clean(root, max_age_hours: 48)

      assert removed == [Path.join(wt, "deps")]
      assert fresh == []
    end
  end
end
