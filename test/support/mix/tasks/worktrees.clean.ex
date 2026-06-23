defmodule Mix.Tasks.Worktrees.Clean do
  @shortdoc "Remove regenerable dirs (deps, _build, fiddle deps/build/node_modules, .dexter, .expert) from idle worktrees"

  @moduledoc """
  Reclaims disk by deleting the regenerable build/dependency directories from
  every git worktree under `.worktrees` and `.claude/worktrees` (the native and
  harness worktree roots). Everything removed is rebuildable with `mise run setup`
  / a fresh `mix deps.get`.

  Run it from anywhere inside the repo; it resolves the shared git common dir, so
  it always cleans the worktrees of the *main* checkout regardless of which
  worktree you invoke it from.

      mise exec -- mix worktrees.clean
      mise exec -- mix worktrees.clean --hours 12

  Lives under `test/support/mix/tasks` (compiled only in `MIX_ENV=test`, never
  shipped in the `lib` package) and auto-selects `MIX_ENV=test` via `mix.exs`
  `preferred_envs`, like the other repo-internal tasks.

  ## Age gate

  A worktree is cleaned only when it has been idle longer than `--hours` (default
  48). "Idle" is measured from the newest mtime of its **source** files — the
  walk skips the regenerable directories themselves and `.git`, so an abandoned
  tree that was merely recompiled (which rewrites `_build`/`deps`) still counts as
  idle and gets reclaimed. A worktree edited within the window is left fully
  intact and reported as active. The gate is per-worktree: a tree is either fresh
  (all targets kept) or stale (all targets eligible, subject to the safety check
  below).

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

  @default_max_age_hours 48

  # Subtrees ignored when measuring a worktree's "last edited" time: the
  # regenerable targets (rewritten by builds, not by you) and git's own metadata.
  @ignored_for_age @regenerable ++ [".git"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [hours: :integer])
    max_age_hours = Keyword.get(opts, :hours, @default_max_age_hours)

    unless max_age_hours > 0 do
      Mix.raise("--hours must be a positive integer, got: #{max_age_hours}")
    end

    %{root: root, removed: removed, skipped: skipped, fresh: fresh} =
      clean(git_root(), max_age_hours: max_age_hours)

    for path <- skipped do
      Mix.shell().error("skip (outside git root): #{path}")
    end

    for worktree <- fresh do
      Mix.shell().info("skip (active < #{max_age_hours}h): #{Path.relative_to(worktree, root)}")
    end

    for path <- removed do
      Mix.shell().info("rm -rf #{Path.relative_to(path, root)}")
    end

    Mix.shell().info("Cleaned #{length(removed)} director(ies).")
  end

  @doc """
  Removes the regenerable directories under `root`'s worktree bases and returns
  `%{root:, removed:, skipped:, fresh:}`: the paths it deleted, the paths it
  refused to delete (because they canonicalize outside `root`), and the worktrees
  it left intact because they were edited within `max_age_hours` (default
  `#{@default_max_age_hours}`) — only worktrees that actually held a regenerable
  dir are reported as `fresh`.
  """
  def clean(root, opts \\ []) do
    root = Path.expand(root)
    max_age_hours = Keyword.get(opts, :max_age_hours, @default_max_age_hours)
    cutoff = System.os_time(:second) - max_age_hours * 3600

    worktrees =
      for base <- @bases,
          base_dir = Path.join(root, base),
          File.dir?(base_dir),
          worktree <- Path.wildcard(Path.join(base_dir, "*")),
          File.dir?(worktree),
          do: worktree

    {stale, fresh} = Enum.split_with(worktrees, &stale?(&1, cutoff))

    candidates =
      for worktree <- stale,
          target <- @regenerable,
          File.exists?(Path.join(worktree, target)),
          do: {worktree, target}

    {safe, skipped} = Enum.split_with(candidates, &removable?(root, &1))

    to_abs = fn {worktree, target} -> Path.join(worktree, target) end
    removed = Enum.map(safe, to_abs)
    Enum.each(removed, &File.rm_rf!/1)

    %{
      root: root,
      removed: removed,
      skipped: Enum.map(skipped, to_abs),
      fresh: Enum.filter(fresh, &has_regenerable?/1)
    }
  end

  defp has_regenerable?(worktree),
    do: Enum.any?(@regenerable, &File.exists?(Path.join(worktree, &1)))

  # Stale once the worktree's newest source mtime predates `cutoff`. A tree with
  # no surviving source (mtime 0) is always stale.
  defp stale?(worktree, cutoff), do: newest_source_mtime(worktree) <= cutoff

  defp newest_source_mtime(worktree) do
    ignored = MapSet.new(@ignored_for_age, &Path.join(worktree, &1))
    max_mtime(worktree, ignored, 0)
  end

  # Walks `path` with `File.lstat` (never following symlinks, so it can't loop or
  # escape), pruning `ignored` subtrees, and returns the largest file/symlink
  # mtime seen. Directory mtimes are not counted — only the files themselves —
  # because a build creating/removing `deps`/`_build` bumps the containing dir's
  # mtime even though no source changed.
  defp max_mtime(path, ignored, acc) do
    if MapSet.member?(ignored, path) do
      acc
    else
      case File.lstat(path, time: :posix) do
        {:ok, %File.Stat{type: :directory}} ->
          path
          |> File.ls!()
          |> Enum.reduce(acc, &max_mtime(Path.join(path, &1), ignored, &2))

        {:ok, %File.Stat{mtime: mtime}} ->
          max(acc, mtime)

        {:error, _} ->
          acc
      end
    end
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
