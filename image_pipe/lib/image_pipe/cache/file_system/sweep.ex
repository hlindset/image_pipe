defmodule ImagePipe.Cache.FileSystem.Sweep do
  # Removes files a VM that died left behind: temp files whose owner is gone,
  # and bodies no metadata names. It also removes metadata files the cache
  # can't decode, such as ones another ImagePipe version wrote, and their
  # bodies then go as unnamed. That check reads every metadata file, so it
  # runs only when `.metadata-version` at the root is missing or names
  # another version than `Store.metadata_version/0`. A sweep that ran it and
  # left no metadata it can't decode writes the current version there. A
  # metadata file it can't read, as on a permission or I/O error, stays. A
  # sweep returns the entries it removed, so Admission stops counting them.
  # A file counts only once it is older than the grace period, so the sweep
  # leaves alone what this node's requests are still writing. No request
  # holds a temp file for anywhere near an hour.
  @moduledoc false

  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.RawFile
  alias ImagePipe.Telemetry

  @grace_ms 3_600_000
  @marker ".metadata-version"

  @temp ~r/\A\.[0-9a-f]{64}\.[A-Za-z0-9_-]+\.tmp\z/
  # Bodies stored before their names carried size and cost end at the digest.
  @body ~r/\A([0-9a-f]{64})\.[0-9a-f]{64}(?:\.\d+\.\d+)?\.body\z/
  @meta ~r/\A[0-9a-f]{64}\.meta\z/
  @partition ~r/\A[0-9a-f]{2}\z/

  @doc false
  # Sweeps the cache at `root` and tells its Admission, found in `registry`,
  # what it removed.
  def run(root, pool, telemetry_opts, registry) do
    removed = span(pool, telemetry_opts, fn -> sweep_root(root) end)

    case Registry.lookup(registry, root) do
      [{admission, _value}] -> GenServer.cast(admission, {:swept, removed})
      [] -> :ok
    end
  end

  @doc false
  # Sweeps `listings`, the `{partition_dir, names}` of the tree at `root`, so a
  # caller that already listed the tree doesn't list it again. Returns the
  # removed entries, as `{key_hash, body_filename | :meta}`.
  def run_listings(root, listings, pool, telemetry_opts),
    do: span(pool, telemetry_opts, fn -> sweep_listings(root, listings) end)

  defp span(pool, telemetry_opts, sweep) do
    Telemetry.span(telemetry_opts, [:cache, :sweep], %{pool: pool}, fn ->
      {removed, counts} = Map.pop(sweep.(), :removed)
      {removed, Map.put(counts, :result, :ok)}
    end)
  end

  @doc false
  def sweep_root(root) do
    sweep_listings(
      root,
      for(dir <- partitions(root), partition <- partitions(dir), do: listing(partition))
    )
  end

  defp sweep_listings(root, listings) do
    cutoff = cutoff()
    counts = %{temps: 0, bodies: 0, unreadable: 0, bytes: 0, removed: []}
    check_decode? = marked_version(root) != Store.metadata_version()

    {counts, pending?} =
      Enum.reduce(listings, {counts, false}, fn {dir, names}, {counts, pending?} ->
        {names, counts, partition_pending?} =
          if check_decode?,
            do: remove_unreadable(dir, names, cutoff, counts),
            else: {names, counts, false}

        {sweep_partition(dir, names, cutoff, counts), pending? or partition_pending?}
      end)

    if check_decode? and not pending?, do: mark_version(root)
    counts
  end

  defp marked_version(root) do
    with {:ok, contents} <- RawFile.read(Path.join(root, @marker)),
         {version, ""} <- Integer.parse(contents) do
      version
    else
      _missing_or_invalid -> nil
    end
  end

  # Written under a fixed second name and renamed, so a crash leaves the old
  # marker or none, and the next write replaces what it left. A marker that
  # can't be written only means the next sweep checks every metadata file
  # again.
  defp mark_version(root) do
    marker = Path.join(root, @marker)
    temp = marker <> ".new"

    with :ok <- RawFile.write(temp, Integer.to_string(Store.metadata_version())),
         do: RawFile.rename(temp, marker)
  end

  # Returns the names still present, so the leftover pass sees the removed
  # metadata's bodies as unnamed, and whether an unreadable metadata file was
  # too new to remove, which keeps the version unmarked so the next sweep
  # checks again. The age check runs after the read, since a rewrite moves
  # the mtime.
  defp remove_unreadable(dir, names, cutoff, counts) do
    Enum.reduce(names, {[], counts, false}, fn name, {kept, counts, pending?} ->
      path = Path.join(dir, name)

      cond do
        not String.ends_with?(name, ".meta") or not unreadable?(path) ->
          {[name | kept], counts, pending?}

        older?(path, cutoff) ->
          {kept, remove(path, :unreadable, counts), pending?}

        true ->
          {[name | kept], counts, true}
      end
    end)
  end

  defp unreadable?(path) do
    case Store.read_descriptor(path) do
      {:error, {:invalid_metadata, _reason}} -> true
      _readable_missing_or_failed -> false
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

  defp cutoff, do: System.os_time(:millisecond) - @grace_ms

  defp list(dir) do
    case RawFile.list_dir(dir) do
      {:ok, names} -> names
      {:error, _reason} -> []
    end
  end

  # A key's only body, with its meta beside it, is the body the meta names,
  # as Admission's count assumes, so it needs no read. Only a key with
  # several bodies, or a body without a meta, is checked.
  defp sweep_partition(dir, names, cutoff, counts) do
    classified = Enum.map(names, &{&1, classify(&1)})
    present = MapSet.new(names)

    bodies =
      Enum.frequencies(for {_name, {:bodies, meta}} <- classified, do: meta)

    Enum.reduce(classified, counts, fn
      {name, :temps}, counts ->
        path = Path.join(dir, name)
        if older?(path, cutoff), do: remove(path, :temps, counts), else: counts

      {name, {:bodies, meta}}, counts ->
        if Map.fetch!(bodies, meta) == 1 and MapSet.member?(present, meta),
          do: counts,
          else: sweep_body(Path.join(dir, name), Path.join(dir, meta), cutoff, counts)

      {_name, :unrelated}, counts ->
        counts
    end)
  end

  defp classify(name) do
    cond do
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
  # can't read keeps its body until the meta is old enough to remove. A commit
  # can rename a fresh body over an old one and name it in a new meta at any
  # moment, so the meta is read after the listing rather than taken from it,
  # and the body's age is checked again just before the unlink: a commit
  # renames its body before its meta, so a body it replaces is fresh by then.
  defp sweep_body(path, meta_path, cutoff, counts) do
    if older?(path, cutoff) and unnamed?(path, meta_path) and older?(path, cutoff),
      do: remove(path, :bodies, counts),
      else: counts
  end

  defp unnamed?(path, meta_path) do
    case Store.read_descriptor(meta_path) do
      {:ok, %{body_filename: named}, _mtime} -> Path.basename(path) != named
      {:error, :enoent} -> true
      {:error, _unreadable} -> false
    end
  end

  defp older?(path, cutoff) do
    case RawFile.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime * 1000 < cutoff
      {:error, _reason} -> false
    end
  end

  defp remove(path, kind, counts) do
    with {:ok, %{size: size}} <- RawFile.stat(path),
         :ok <- RawFile.delete(path) do
      counts
      |> Map.update!(kind, &(&1 + 1))
      |> Map.update!(:bytes, &(&1 + size))
      |> removed(kind, Path.basename(path))
    else
      _gone_or_failed -> counts
    end
  end

  # A meta file whose name isn't a key hash was never an entry, so it's
  # removed without telling Admission about it.
  defp removed(counts, :unreadable, name) do
    if Regex.match?(@meta, name),
      do: Map.update!(counts, :removed, &[{Path.rootname(name), :meta} | &1]),
      else: counts
  end

  defp removed(counts, :bodies, name),
    do: Map.update!(counts, :removed, &[{key_hash(name), name} | &1])

  defp removed(counts, _kind, _name), do: counts

  defp key_hash(name), do: name |> String.split(".", parts: 2) |> hd()
end
