defmodule ImagePipe.Cache.FileSystem.Sweep do
  # Removes files a VM that died left behind: temp files and pins whose owner
  # is gone, and bodies no metadata names. A file counts as left behind only
  # once it is older than the grace period, so nodes sharing a root can all
  # sweep it without touching each other's live files. No request holds a temp
  # file for anywhere near an hour.
  #
  # It also expires entries: with `{:all, max_age}`, every entry whose
  # metadata mtime, its last read (see `Toucher`), is older than `max_age`
  # seconds. A bounded cache passes `{:unreadable, max_age}`: its Admission
  # evicts unread entries it counts, so the sweep only expires metadata it
  # can't read, which Admission never counts. Either way an expired entry's
  # body is then left behind and goes with the other leftovers.
  @moduledoc false

  alias ImagePipe.Cache.FileSystem.Store
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
  def run(root, pool, telemetry_opts, expiry \\ nil),
    do: span(pool, telemetry_opts, fn -> sweep_root(root, expiry) end)

  @doc false
  # Sweeps `listings`, the `{partition_dir, names}` of a pool's tree, so a
  # caller that already listed the tree doesn't list it again.
  def run_listings(listings, pool, telemetry_opts, expiry \\ nil),
    do: span(pool, telemetry_opts, fn -> sweep_listings(listings, expiry) end)

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
  def sweep_root(root, expiry \\ nil) do
    sweep_listings(
      for(dir <- partitions(root), partition <- partitions(dir), do: listing(partition)),
      expiry
    )
  end

  defp sweep_listings(listings, expiry) do
    cutoff = cutoff()
    expiry = expiry_cutoff(expiry)
    counts = %{pins: 0, temps: 0, bodies: 0, expired: 0, bytes: 0}

    Enum.reduce(listings, counts, fn {dir, names}, counts ->
      {names, counts} = expire_partition(dir, names, expiry, counts)
      sweep_partition(dir, names, cutoff, counts)
    end)
  end

  defp expiry_cutoff(nil), do: nil
  defp expiry_cutoff({_mode, nil}), do: nil
  defp expiry_cutoff({mode, max_age}), do: {mode, System.os_time(:second) - max_age}

  # Returns the names still present, so the leftover pass sees expired
  # entries' bodies as unnamed.
  defp expire_partition(_dir, names, nil, counts), do: {names, counts}

  defp expire_partition(dir, names, {mode, cutoff}, counts) do
    Enum.reduce(names, {[], counts}, fn name, {kept, counts} ->
      path = Path.join(dir, name)

      if String.ends_with?(name, ".meta") and idle?(path, cutoff) and expires?(path, mode) and
           idle?(path, cutoff) do
        {kept, remove(path, :expired, counts)}
      else
        {[name | kept], counts}
      end
    end)
  end

  # A read or a rewrite moves the mtime, so the idle check runs again just
  # before the unlink.
  defp idle?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime < cutoff
      {:error, _reason} -> false
    end
  end

  defp expires?(_path, :all), do: true

  defp expires?(path, :unreadable) do
    case Store.read_descriptor(path) do
      {:ok, _descriptor, _mtime} -> false
      {:error, :enoent} -> false
      {:error, _unreadable} -> true
    end
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

  # A body is left behind when its key has no meta, or when the meta names
  # another body, as after two commits for one key race. A meta this node
  # can't read keeps its body: it may be corrupt, or written by a newer version
  # sharing the root. A commit can rename a fresh body over an old one and name
  # it in a new meta at any moment, so the checks run again just before the
  # unlink.
  defp sweep_body(path, meta_path, metas, cutoff, counts) do
    listed? = MapSet.member?(metas, Path.basename(meta_path))

    if older?(path, cutoff) and unnamed?(path, meta_path, listed?) and
         unnamed?(path, meta_path, true) and older?(path, cutoff),
       do: remove(path, :bodies, counts),
       else: counts
  end

  defp unnamed?(_path, _meta_path, false = _listed?), do: true

  defp unnamed?(path, meta_path, true = _listed?) do
    case Store.read_descriptor(meta_path) do
      {:ok, %{body_sha256: sha}, _mtime} -> not String.ends_with?(path, ".#{sha}.body")
      {:error, :enoent} -> true
      {:error, _unreadable} -> false
    end
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
