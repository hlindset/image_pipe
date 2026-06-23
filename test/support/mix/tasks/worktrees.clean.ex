defmodule Mix.Tasks.Worktrees.Clean do
  @shortdoc "Remove regenerable dirs (deps, _build, fiddle deps/build/node_modules, .dexter, .expert) from every worktree"

  @moduledoc """
  Reclaims disk by deleting the regenerable build/dependency directories from
  every git worktree under `.worktrees` and `.claude/worktrees` (the native and
  harness worktree roots). Everything removed is rebuildable with `mise run setup`
  / a fresh `mix deps.get`.

  Run it from anywhere inside the repo; it resolves the shared git common dir, so
  it always cleans the worktrees of the *main* checkout regardless of which
  worktree you invoke it from.

      mise exec -- mix worktrees.clean

  Lives under `test/support/mix/tasks` (compiled only in `MIX_ENV=test`, never
  shipped in the `lib` package) and auto-selects `MIX_ENV=test` via `mix.exs`
  `preferred_envs`, like the other repo-internal tasks.

  ## Safety

  A target is removed only when `Path.safe_relative/2` accepts it on two counts,
  after resolving every path segment's symlinks: the target stays inside *its
  worktree* (so a symlinked target can't redirect the delete elsewhere — not even
  to a sibling worktree's sources inside the same git root), and the worktree
  itself stays inside the git root (so an escaping worktree-dir symlink is
  refused). Anything that fails either check is skipped and reported, never
  deleted. This is the Mix equivalent of the former `worktrees:clean` mise task.
  """

  use Mix.Task
  use Boundary, top_level?: true, deps: []

  @bases [".worktrees", ".claude/worktrees"]

  @regenerable ~w(
    deps _build
    fiddle/deps fiddle/_build fiddle/node_modules fiddle/assets/node_modules
    .dexter .expert
  )

  @impl Mix.Task
  def run(_args) do
    %{root: root, removed: removed, skipped: skipped} = clean(git_root())

    for path <- skipped do
      Mix.shell().error("skip (outside git root): #{path}")
    end

    for path <- removed do
      Mix.shell().info("rm -rf #{Path.relative_to(path, root)}")
    end

    Mix.shell().info("Cleaned #{length(removed)} director(ies).")
  end

  @doc """
  Removes the regenerable directories under `root`'s worktree bases and returns
  `%{root:, removed:, skipped:}` with the paths it deleted and the paths it
  refused to delete (because they canonicalize outside `root`).
  """
  def clean(root) do
    root = Path.expand(root)

    candidates =
      for base <- @bases,
          base_dir = Path.join(root, base),
          File.dir?(base_dir),
          worktree <- Path.wildcard(Path.join(base_dir, "*")),
          File.dir?(worktree),
          target <- @regenerable,
          File.exists?(Path.join(worktree, target)),
          do: {worktree, target}

    {safe, skipped} = Enum.split_with(candidates, &removable?(root, &1))

    to_abs = fn {worktree, target} -> Path.join(worktree, target) end
    removed = Enum.map(safe, to_abs)
    Enum.each(removed, &File.rm_rf!/1)
    %{root: root, removed: removed, skipped: Enum.map(skipped, to_abs)}
  end

  # Safe to delete only if `target` resolves inside its `worktree` (a symlinked
  # target can't redirect the delete out of the worktree we're cleaning) and the
  # worktree resolves inside the git root (an escaping worktree-dir symlink is
  # refused). `Path.safe_relative/2` resolves each segment's symlinks for us.
  defp removable?(root, {worktree, target}) do
    match?({:ok, _}, Path.safe_relative(Path.relative_to(worktree, root), root)) and
      match?({:ok, _}, Path.safe_relative(target, worktree))
  end

  defp git_root do
    case System.cmd("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> out |> String.trim() |> Path.dirname()
      {out, _} -> Mix.raise("could not resolve git root: #{String.trim(out)}")
    end
  end
end
