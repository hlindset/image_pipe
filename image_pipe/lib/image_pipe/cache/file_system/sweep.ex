defmodule ImagePipe.Cache.FileSystem.Sweep do
  # Removes files a VM that died left behind: temp files and pins whose owner
  # is gone, and bodies no metadata names. A file counts as left behind only
  # once it is older than the grace period, so nodes sharing a root can all
  # sweep it without touching each other's live files. No request holds a temp
  # file for anywhere near an hour.
  @moduledoc false

  alias ImagePipe.Telemetry

  @grace_ms 3_600_000

  # Pins are hard links that carry their target's timestamps, so their
  # creation time is in their name.
  @pin ~r/\A\.image-pipe-pin-(\d+)-[A-Za-z0-9_-]+\.tmp\z/
  @temp ~r/\A\.[0-9a-f]{64}\.[A-Za-z0-9_-]+\.tmp\z/
  @body ~r/\A([0-9a-f]{64})\.[0-9a-f]{64}\.body\z/
  @staged ~r/\A\.image-pipe-[A-Za-z0-9_-]+\.tmp\z/
  @partition ~r/\A[0-9a-f]{2}\z/

  @doc false
  def pin_name(random), do: ".image-pipe-pin-#{System.os_time(:millisecond)}-#{random}.tmp"

  @doc false
  def run(root, pool, telemetry_opts),
    do: span(pool, telemetry_opts, fn -> sweep_root(root) end)

  @doc false
  # Sweeps `listings`, the `{partition_dir, names}` of a pool's tree, so a
  # caller that already listed the tree doesn't list it again.
  def run_listings(listings, pool, telemetry_opts),
    do: span(pool, telemetry_opts, fn -> sweep_listings(listings) end)

  defp span(pool, telemetry_opts, sweep) do
    Telemetry.span(telemetry_opts, [:cache, :sweep], %{pool: pool}, fn ->
      counts = sweep.()
      {counts, Map.put(counts, :result, :ok)}
    end)
  end

  @doc false
  def run_staged(dir, telemetry_opts) do
    Telemetry.span(telemetry_opts, [:cache, :sweep], %{pool: :staging}, fn ->
      counts = sweep_staged(dir)
      {counts, Map.put(counts, :result, :ok)}
    end)
  end

  @doc false
  def sweep_root(root) do
    sweep_listings(
      for dir <- partitions(root), partition <- partitions(dir), do: listing(partition)
    )
  end

  defp sweep_listings(listings) do
    cutoff = cutoff()

    Enum.reduce(listings, %{pins: 0, temps: 0, bodies: 0, bytes: 0}, fn {dir, names}, counts ->
      sweep_partition(dir, names, cutoff, counts)
    end)
  end

  @doc false
  # The partition directories directly under `dir`, matched by name. A
  # non-directory with a partition name lists as empty.
  def partitions(dir) do
    for name <- list(dir), Regex.match?(@partition, name), do: Path.join(dir, name)
  end

  @doc false
  def listing(dir), do: {dir, list(dir)}

  @doc false
  def sweep_staged(dir) do
    cutoff = cutoff()

    dir
    |> list()
    |> Enum.filter(&Regex.match?(@staged, &1))
    |> Enum.reduce(%{staged: 0, bytes: 0}, fn name, counts ->
      path = Path.join(dir, name)
      if older?(path, cutoff), do: remove(path, :staged, counts), else: counts
    end)
  end

  defp cutoff, do: System.os_time(:millisecond) - @grace_ms

  defp list(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _reason} -> []
    end
  end

  defp sweep_partition(dir, names, cutoff, counts) do
    metas = for name <- names, String.ends_with?(name, ".meta"), into: MapSet.new(), do: name

    Enum.reduce(names, counts, fn name, counts ->
      sweep_file(dir, name, metas, cutoff, counts)
    end)
  end

  defp sweep_file(dir, name, metas, cutoff, counts) do
    path = Path.join(dir, name)

    case classify(name) do
      {:pins, created} when created < cutoff -> remove(path, :pins, counts)
      :temps -> if older?(path, cutoff), do: remove(path, :temps, counts), else: counts
      {:bodies, meta} -> sweep_body(path, Path.join(dir, meta), metas, cutoff, counts)
      _live_or_unrelated -> counts
    end
  end

  defp classify(name) do
    cond do
      match = Regex.run(@pin, name, capture: :all_but_first) ->
        {:pins, match |> hd() |> String.to_integer()}

      Regex.match?(@temp, name) ->
        :temps

      match = Regex.run(@body, name, capture: :all_but_first) ->
        {:bodies, hd(match) <> ".meta"}

      true ->
        :unrelated
    end
  end

  # Any meta file keeps its body, even one this node can't decode: it may be
  # corrupt, or written by a newer version sharing the root. A commit can adopt
  # an old body and name it in a new meta at any moment. It moves the body's
  # mtime first, so both checks run again just before the unlink.
  defp sweep_body(path, meta_path, metas, cutoff, counts) do
    if not MapSet.member?(metas, Path.basename(meta_path)) and older?(path, cutoff) and
         not File.exists?(meta_path) and older?(path, cutoff),
       do: remove(path, :bodies, counts),
       else: counts
  end

  defp older?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime * 1000 < cutoff
      {:error, _reason} -> false
    end
  end

  defp remove(path, kind, counts) do
    with {:ok, %{size: size}} <- File.stat(path),
         :ok <- File.rm(path) do
      counts |> Map.update!(kind, &(&1 + 1)) |> Map.update!(:bytes, &(&1 + size))
    else
      _gone_or_failed -> counts
    end
  end
end
