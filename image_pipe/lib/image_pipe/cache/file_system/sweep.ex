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
  @counts %{temps: 0, bodies: 0, unreadable: 0, bytes: 0, removed: [], pending?: false}

  @doc false
  # Sweeps the cache at `root` and tells its Admission, found in `registry`,
  # what it removed.
  def run(root, pool, telemetry_opts, registry) do
    removed = scan(root, pool, telemetry_opts, fn _partition, _names -> :ok end)

    case Registry.lookup(registry, root) do
      [{admission, _value}] -> GenServer.cast(admission, {:swept, removed})
      [] -> :ok
    end
  end

  @doc false
  # Sweeps the cache at `root` and returns the removed entries, as
  # `{key_hash, body_filename | :meta}`. Calls `on_partition` with each
  # partition directory once it is swept, and its names as `{name,
  # Store.classify(name)}`, from the task that listed it, so a caller that
  # counts the entries doesn't list the tree again. The names leave out
  # metadata files the sweep removed, but not other files it removed: a body
  # the sweep removes is one no metadata file names.
  def scan(root, pool, telemetry_opts, on_partition) do
    Telemetry.span(telemetry_opts, [:cache, :sweep], %{pool: pool}, fn ->
      {removed, counts} = Map.pop(sweep_root(root, on_partition), :removed)
      {removed, Map.put(counts, :result, :ok)}
    end)
  end

  @doc false
  # Each first-level partition group is swept in its own task, so the names
  # it lists are collected with that task rather than all in one heap.
  def sweep_root(root, on_partition \\ fn _partition, _names -> :ok end) do
    cutoff = cutoff()
    check_decode? = marked_version(root) != Store.metadata_version()

    {pending?, counts} =
      root
      |> partitions()
      |> Task.async_stream(&sweep_group(&1, cutoff, check_decode?, on_partition),
        max_concurrency: System.schedulers_online(),
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce(@counts, fn {:ok, group}, counts -> merge(counts, group) end)
      |> Map.pop(:pending?)

    if check_decode? and not pending?, do: mark_version(root)
    counts
  end

  defp sweep_group(dir, cutoff, check_decode?, on_partition) do
    Enum.reduce(partitions(dir), @counts, fn partition, counts ->
      names = list(partition)

      {names, counts} =
        if check_decode?,
          do: remove_unreadable(partition, names, cutoff, counts),
          else: {names, counts}

      classified = Enum.map(names, &{&1, Store.classify(&1)})
      counts = sweep_partition(partition, classified, cutoff, counts)
      on_partition.(partition, classified)
      counts
    end)
  end

  defp merge(counts, group) do
    Map.merge(counts, group, fn
      :removed, removed, more -> more ++ removed
      :pending?, pending?, more -> pending? or more
      _count, count, more -> count + more
    end)
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
  # metadata's bodies as unnamed. An unreadable metadata file too new to
  # remove sets `pending?`, which keeps the version unmarked so the next
  # sweep checks again. The age check runs after the read, since a rewrite
  # moves the mtime.
  defp remove_unreadable(dir, names, cutoff, counts) do
    Enum.reduce(names, {[], counts}, fn name, {kept, counts} ->
      path = Path.join(dir, name)

      cond do
        not String.ends_with?(name, ".meta") or not Store.undecodable?(path) ->
          {[name | kept], counts}

        older?(path, cutoff) ->
          {kept, remove(path, :unreadable, counts)}

        true ->
          {[name | kept], %{counts | pending?: true}}
      end
    end)
  end

  # The partition directories directly under `dir`, matched by name. A
  # non-directory with a partition name lists as empty.
  defp partitions(dir) do
    for <<a, b>> = name <- list(dir), hex?(a) and hex?(b), do: Path.join(dir, name)
  end

  defp hex?(char), do: char in ?0..?9 or char in ?a..?f

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
  defp sweep_partition(dir, classified, cutoff, counts) do
    metas = MapSet.new(for {_name, {:meta, hash}} <- classified, do: hash)
    bodies = Enum.frequencies(for {_name, {:body, hash, _row}} <- classified, do: hash)

    Enum.reduce(classified, counts, fn
      {name, :temp}, counts ->
        path = Path.join(dir, name)
        if older?(path, cutoff), do: remove(path, :temps, counts), else: counts

      {name, {:body, hash, _row}}, counts ->
        if Map.fetch!(bodies, hash) == 1 and MapSet.member?(metas, hash),
          do: counts,
          else: sweep_body(Path.join(dir, name), Path.join(dir, hash <> ".meta"), cutoff, counts)

      {_name, _meta_or_unrelated}, counts ->
        counts
    end)
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
    case Store.classify(name) do
      {:meta, hash} -> Map.update!(counts, :removed, &[{hash, :meta} | &1])
      _other -> counts
    end
  end

  defp removed(counts, :bodies, <<hash::binary-size(64), _rest::binary>> = name),
    do: Map.update!(counts, :removed, &[{hash, name} | &1])

  defp removed(counts, _kind, _name), do: counts
end
