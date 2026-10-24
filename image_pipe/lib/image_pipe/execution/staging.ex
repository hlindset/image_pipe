defmodule ImagePipe.Execution.Staging do
  # Where originals are staged while requests use them: a directory only this
  # VM's user can read, under the system's temporary directory. `Resources`
  # tracks each staged file for the process that uses it and deletes it when
  # that process stops. The sweep removes files a VM that died left behind.
  @moduledoc false

  alias ImagePipe.Cache.FileSystem.PeriodicSweep
  alias ImagePipe.RawFile
  alias ImagePipe.Telemetry

  require Logger

  @grace_ms 3_600_000
  @staged ~r/\A\.image-pipe-[A-Za-z0-9_-]+\.tmp\z/

  # Staged originals live in their own directory, so the sweep lists only
  # them, not the whole tmp directory.
  def dir, do: Path.join(System.tmp_dir!(), "image_pipe")

  def temporary_path(dir), do: Path.join(dir, ".image-pipe-#{random()}.tmp")

  @doc """
  Makes `dir` a directory only this VM's user can read or write, creating it
  if needed. Returns `:error` for a symlink, a file, or another user's
  directory, which on a shared tmp directory could expose or replace staged
  originals, and logs a warning the first time. A directory found private
  once stays so for the VM's lifetime.
  """
  @spec private_dir(Path.t()) :: :ok | :error
  def private_dir(dir) do
    key = {__MODULE__, :private_dir, dir}

    case :persistent_term.get(key, false) do
      true -> :ok
      found -> check_private(key, dir, found)
    end
  end

  defp check_private(key, dir, found) do
    case make_private(dir) do
      :ok -> :persistent_term.put(key, true)
      :error -> refuse(key, dir, found)
    end
  end

  # Only the first refusal of a directory is logged.
  defp refuse(_key, _dir, :refused), do: :error

  defp refuse(key, dir, false) do
    :persistent_term.put(key, :refused)

    Logger.warning(
      "image_pipe cache: can't stage originals in #{dir}, which must be a directory " <>
        "only this user can access. Originals are held in memory instead, and a slow " <>
        "client keeps its processing turn while it downloads."
    )

    :error
  end

  defp make_private(dir) do
    _result = RawFile.make_dir(dir)

    with {:ok, %File.Stat{type: :directory, uid: uid}} <- RawFile.lstat(dir),
         {:ok, ^uid} <- own_uid(),
         :ok <- RawFile.set_mode(dir, 0o700) do
      :ok
    else
      _other -> :error
    end
  end

  # The VM's user owns a file it just created.
  defp own_uid do
    probe = Path.join(System.tmp_dir!(), ".image-pipe-#{random()}.uid")

    with :ok <- RawFile.write(probe, "", [:exclusive]) do
      try do
        with {:ok, %File.Stat{uid: uid}} <- RawFile.lstat(probe), do: {:ok, uid}
      after
        RawFile.delete(probe)
      end
    end
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  @doc false
  # Sweeps the staging directory at start and once a day after.
  def sweep_spec, do: {PeriodicSweep, id: {__MODULE__, :sweep}, sweep: {__MODULE__, :sweep, []}}

  @doc false
  # Removes the staged files older than an hour. No request holds one for
  # anywhere near that long.
  def sweep do
    Telemetry.span([], [:cache, :sweep], %{pool: :staging}, fn ->
      counts = sweep(dir(), System.os_time(:millisecond) - @grace_ms)
      {counts, Map.put(counts, :result, :ok)}
    end)
  end

  defp sweep(dir, cutoff) do
    names =
      case RawFile.list_dir(dir) do
        {:ok, names} -> names
        {:error, _reason} -> []
      end

    for name <- names, Regex.match?(@staged, name), reduce: %{staged: 0, bytes: 0} do
      counts ->
        path = Path.join(dir, name)

        with {:ok, %{mtime: mtime, size: size}} when mtime * 1000 < cutoff <-
               RawFile.stat(path, time: :posix),
             :ok <- RawFile.delete(path) do
          %{counts | staged: counts.staged + 1, bytes: counts.bytes + size}
        else
          _fresh_gone_or_failed -> counts
        end
    end
  end
end
