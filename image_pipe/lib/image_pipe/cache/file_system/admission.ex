defmodule ImagePipe.Cache.FileSystem.Admission do
  # Decides which entries a FileSystem cache keeps, and publishes and evicts
  # them, serialized for its root. It counts the stored bytes and keeps one
  # row per entry with its size, cost and body filename. The startup scan
  # reads those from body filenames, so it reads no metadata.
  #
  # A write that doesn't fit takes victims by sampled eviction: sample
  # @sample entries, evict the lowest-scoring one, and repeat until the write
  # fits. The write is then gated against its victims: score = frequency ×
  # cost / size, with the frequency from a count-min sketch behind a
  # doorkeeper, as in W-TinyLFU. Admission evicts the victims before it
  # publishes the write, or rejects the write without publishing it, so once
  # the startup scan has counted the entries on disk, the stored bytes never
  # pass the cap.
  @moduledoc false

  use GenServer

  alias ImagePipe.Cache.FileSystem.Doorkeeper
  alias ImagePipe.Cache.FileSystem.Memo
  alias ImagePipe.Cache.FileSystem.Policy
  alias ImagePipe.Cache.FileSystem.Sketch
  alias ImagePipe.Cache.FileSystem.Store, as: FileSystem
  alias ImagePipe.Cache.FileSystem.Sweep
  alias ImagePipe.Cache.FileSystem.Writers
  alias ImagePipe.Cache.Lookups
  alias ImagePipe.Telemetry

  @sample 16

  # A candidate that loses the gate is admitted anyway, rarely, once it has
  # been requested a few times, as in Caffeine. Without it, keys that become
  # popular keep losing to entries whose counts haven't aged yet
  # (bench/cache_policy.exs, `shift`).
  @random_admission_min_frequency 6

  defmodule State do
    @moduledoc false
    # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
    defstruct [
      :registry,
      :root,
      :max_size_bytes,
      # The startup pass evicts to a lowered cap in batches this size, so
      # commits and hits run between them.
      :reconcile_batch,
      :doorkeeper_cardinality,
      :doorkeeper_fpr,
      :sketch,
      # %Talan.BloomFilter{}
      :doorkeeper,
      # key hash -> {size, cost, body SHA-256}, ordered so a random key's
      # successor samples an entry. Both hashes are raw 32-byte binaries,
      # not the hex the rest of the cache uses, and the body filename is
      # rebuilt from the row: a large cache tracks millions of entries.
      :entries,
      # Lifecycle events use the prefix captured at init, without request options.
      telemetry_prefix: [:image_pipe],
      pool: :output,
      # The entries' charged bytes (`Policy.charged_bytes/1`).
      stored_bytes: 0,
      # Keys dropped, deleted or committed while the startup scan runs, so a
      # stale scanned entry for them is skipped. nil after the scan.
      scan_changes: nil,
      # The linked startup scan, whose exit releases await_scan/2 callers.
      scan_pid: nil,
      # The scan has counted the entries on disk. Its sweep may still run.
      counted?: false,
      scan_complete?: false,
      scan_waiters: [],
      reconciling?: false,
      reconcile_waiters: [],
      # Odds of random admission (see random_admit?/2). State rather than a
      # module attribute so tests can make the draw deterministic.
      random_admission_one_in: 128
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :root)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  defp via_tuple(opts) do
    {:via, Registry, {Keyword.fetch!(opts, :registry), Keyword.fetch!(opts, :root)}}
  end

  # Takes options normalized by `Store.admission_options/2`.
  @impl true
  def init(opts) do
    doorkeeper_cardinality = Keyword.fetch!(opts, :doorkeeper_cardinality)
    doorkeeper_fpr = Keyword.fetch!(opts, :doorkeeper_fpr)
    :ok = Lookups.ensure(Keyword.fetch!(opts, :root))
    max_size_bytes = Keyword.fetch!(opts, :max_size_bytes)

    limit =
      Keyword.get_lazy(opts, :max_remembered_entries, fn -> Memo.limit_for(max_size_bytes) end)

    :ok = Memo.start(Keyword.fetch!(opts, :root), limit)

    state = %State{
      registry: Keyword.fetch!(opts, :registry),
      root: Keyword.fetch!(opts, :root),
      max_size_bytes: Keyword.fetch!(opts, :max_size_bytes),
      reconcile_batch: Keyword.fetch!(opts, :reconcile_batch),
      doorkeeper_cardinality: doorkeeper_cardinality,
      doorkeeper_fpr: doorkeeper_fpr,
      # Aging cadence is decoupled from width (Sketch.new/1 docs).
      sketch:
        Sketch.new(
          depth: Keyword.fetch!(opts, :sketch_depth),
          width: Keyword.fetch!(opts, :sketch_width),
          sample_size: Keyword.fetch!(opts, :aging_sample_size)
        ),
      doorkeeper: Doorkeeper.new(doorkeeper_cardinality, doorkeeper_fpr),
      telemetry_prefix: Keyword.get(opts, :telemetry_prefix, Telemetry.default_prefix()),
      pool: :output,
      # Only the GenServer writes; :protected permits cross-process inspection.
      entries: :ets.new(:entries, [:ordered_set, :protected]),
      scan_changes: :ets.new(:scan_changes, [:set, :private])
    }

    {:ok, state, {:continue, :scan}}
  end

  # Lifecycle telemetry opts. Admission has no per-request telemetry opts, so
  # events fire under the prefix captured at init.
  defp tel_opts(state), do: [telemetry_prefix: state.telemetry_prefix]

  @impl true
  def handle_continue(:scan, state) do
    # The scan is linked, so it stops with Admission. Admission traps its
    # exit, so a failed scan doesn't crash Admission, and the exit releases
    # await_scan waiters.
    Process.flag(:trap_exit, true)
    admission_pid = self()
    pid = spawn_link(fn -> scan_directory(state, admission_pid) end)
    {:noreply, %{state | scan_pid: pid}}
  end

  @doc """
  Block until the background directory scan has reported completion.
  Test/diagnostic helper — production callers never need to wait.
  """
  @spec await_scan(GenServer.server(), timeout()) :: :ok
  def await_scan(server, timeout \\ 5_000), do: GenServer.call(server, :await_scan, timeout)

  @doc """
  The stored bytes and entries, the size cap, and whether the startup scan
  is still counting the entries on disk.
  """
  @spec usage(GenServer.server(), timeout()) :: %{
          bytes: non_neg_integer(),
          entries: non_neg_integer(),
          max_bytes: pos_integer(),
          counting?: boolean()
        }
  def usage(server, timeout), do: GenServer.call(server, :usage, timeout)

  defp scan_directory(state, admission_pid) do
    {listings, entries} = list_entries(state.root)

    entries
    |> Enum.chunk_every(500)
    |> Enum.each(&GenServer.call(admission_pid, {:apply_scan_batch, &1}, :infinity))

    # Evict to the cap, in case it was lowered. No gate: these are cached
    # entries with no candidate to compare against.
    GenServer.call(admission_pid, :reconcile_to_cap, :infinity)
    GenServer.call(admission_pid, :counted, :infinity)

    # Remove files a VM that died left behind.
    removed = Sweep.run_listings(state.root, listings, state.pool, tel_opts(state))
    GenServer.cast(admission_pid, {:swept, removed})

    GenServer.call(admission_pid, :scan_complete, :infinity)
  end

  # One pass lists each two-level partition once, a first-level group per
  # task. The listings feed both the entries and the leftover sweep.
  defp list_entries(root) do
    root
    |> Sweep.partitions()
    |> Task.async_stream(&list_partition_group/1,
      max_concurrency: System.schedulers_online(),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce({[], []}, fn {:ok, {listings, entries}}, {all_listings, all_entries} ->
      {listings ++ all_listings, entries ++ all_entries}
    end)
  end

  defp list_partition_group(dir) do
    listings = for partition <- Sweep.partitions(dir), do: Sweep.listing(partition)
    {listings, Enum.flat_map(listings, &partition_entries/1)}
  end

  # An entry is a metadata file and the body it names. A key with one body
  # beside its metadata needs no read. Two bodies, as after two commits for
  # one key raced, are told apart by reading the metadata.
  defp partition_entries({partition, names}) do
    metas = for name <- names, String.ends_with?(name, ".meta"), into: MapSet.new(), do: name

    names
    |> Enum.flat_map(&body_entry(&1, metas))
    |> Enum.group_by(& &1.key_hash)
    |> Enum.flat_map(fn
      {_hash, [entry]} -> [entry]
      {hash, entries} -> named_entry(partition, hash, entries)
    end)
  end

  defp body_entry(name, metas) do
    case FileSystem.parse_body_filename(name) do
      {:ok, entry} -> if MapSet.member?(metas, entry.key_hash <> ".meta"), do: [entry], else: []
      {:error, _invalid} -> []
    end
  end

  defp named_entry(partition, hash, entries) do
    case FileSystem.read_descriptor(Path.join(partition, hash <> ".meta")) do
      {:ok, %{body_filename: named}, _mtime} -> Enum.filter(entries, &(&1.body_filename == named))
      {:error, _reason} -> []
    end
  end

  @impl true
  def handle_info(:reconcile_batch, state) do
    case reconcile_batch(state, state.reconcile_batch, []) do
      {:more, state} ->
        send(self(), :reconcile_batch)
        {:noreply, state}

      {:done, state} ->
        {:noreply, finish_reconciliation(state)}
    end
  end

  # Release waiters if the scan dies before reporting completion.
  def handle_info({:EXIT, pid, reason}, %{scan_pid: pid} = state) do
    if reason != :normal and not state.scan_complete? do
      require Logger
      Logger.warning("cache: directory scan crashed before completion: reason=#{inspect(reason)}")

      {:noreply, state |> Map.put(:scan_pid, nil) |> complete_scan() |> reconcile_if_over_cap()}
    else
      {:noreply, %{state | scan_pid: nil}}
    end
  end

  @doc """
  Notify Admission of a cache hit. `descriptor` carries the entry's
  `key_hash`, `size_bytes`, `cost_us` and `body_filename`, so Admission can
  count an entry read before the startup scan reached it.
  """
  @spec hit(pid() | GenServer.name(), map()) :: :ok
  def hit(server, descriptor) when is_map(descriptor),
    do: GenServer.cast(server, {:hit, descriptor})

  @doc """
  Notify Admission that a request missed `key_hash`. Each request that
  misses counts as a sighting, including one that then waits for another
  request to write the entry, so demand is counted rather than writes.
  """
  @spec miss(pid() | GenServer.name(), binary()) :: :ok
  def miss(server, key_hash) when is_binary(key_hash),
    do: GenServer.cast(server, {:miss, key_hash})

  @impl true
  def handle_cast({:miss, key_hash}, state), do: {:noreply, sighting(state, key_hash)}

  # A hit on an untracked key, read before the startup scan reached it, is
  # counted when its entry is still stored, and evicts back under the cap if
  # that passes it. A hit read before an eviction finds it gone and is dropped.
  def handle_cast({:hit, descriptor}, state) do
    state = sighting(state, descriptor.key_hash)

    if tracked?(state, descriptor.key_hash) or not stored?(state, descriptor),
      do: {:noreply, state},
      else: {:noreply, state |> put(descriptor) |> reconcile_if_over_cap()}
  end

  # The sweep removed these files, so their entries no longer count: an
  # entry whose metadata went, or whose counted body went. The sweep reports
  # once it has finished, so a key committed again since keeps its entry.
  def handle_cast({:swept, removed}, state) do
    Memo.forget(state.root, Enum.map(removed, &elem(&1, 0)))
    {:noreply, Enum.reduce(removed, state, &forget_swept/2)}
  end

  defp forget_swept({key_hash, :meta}, state) do
    case entry(state, key_hash) do
      nil -> state
      entry -> if stored?(state, entry), do: state, else: forget(state, key_hash)
    end
  end

  defp forget_swept({key_hash, body_filename}, state) do
    case entry(state, key_hash) do
      %{body_filename: ^body_filename} -> forget(state, key_hash)
      _other -> state
    end
  end

  defp stored?(state, descriptor) do
    with {:ok, paths} <- FileSystem.paths_from_hash(descriptor.key_hash, root: state.root),
         {:ok, %{body_filename: named}, _mtime} <- FileSystem.read_descriptor(paths.meta_path) do
      named == descriptor.body_filename
    else
      _missing_or_unreadable -> false
    end
  end

  # Decides whether a write is kept, once its body is written but before it
  # is synced, so a rejected body is deleted without ever being synced.
  # Returns `{:admit, victims}`, the key hashes and body filenames of the
  # entries the write was judged against, which the writer passes back with
  # its commit. `held` is the writer's own pending bytes.
  def decide(server, body_filename, held, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    GenServer.call(server, {:decide, body_filename, held, deadline}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :admission_timeout}
    :exit, _reason -> {:error, :admission_unavailable}
  end

  # A commit follows an admit from decide/4, with its victims in the
  # prepared write's `:victims`. A timed-out commit stays queued, and
  # Admission still publishes it.
  def commit(server, prepared, body_filename, timeout) do
    GenServer.call(server, {:commit, prepared, body_filename}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :admission_timeout}
    :exit, _reason -> {:error, :admission_unavailable}
  end

  @impl true
  # A decision reached after the writer stopped waiting is skipped: the
  # writer dropped the write, so it's neither a sighting nor an admission.
  def handle_call({:decide, body_filename, held, deadline}, _from, state) do
    if System.monotonic_time(:millisecond) >= deadline,
      do: {:reply, {:error, :admission_timeout}, state},
      else: decide_write(body_filename, held, state)
  end

  # The decision was made before the body was synced, so the commit evicts
  # the victims it was judged against rather than judging again, which
  # would keep a new key less often.
  def handle_call({:commit, prepared, body_filename}, _from, state) do
    descriptor = FileSystem.descriptor(prepared, body_filename)
    pending = pending(state, Map.get(prepared, :held, 0))
    result = room(state, descriptor, pending, Map.fetch!(prepared, :victims))
    {reply, state} = finish_commit(result, prepared, descriptor, state)
    {:reply, reply, state}
  end

  def handle_call(:await_scan, from, state) do
    if state.scan_complete?,
      do: {:reply, :ok, state},
      else: {:noreply, %{state | scan_waiters: [from | state.scan_waiters]}}
  end

  def handle_call(:usage, _from, state) do
    usage = %{
      bytes: state.stored_bytes,
      entries: :ets.info(state.entries, :size),
      max_bytes: state.max_size_bytes,
      counting?: not state.counted?,
      remembered_entries: Memo.size(state.root),
      max_remembered_entries: Memo.limit(state.root)
    }

    {:reply, usage, state}
  end

  def handle_call(:counted, _from, state), do: {:reply, :ok, %{state | counted?: true}}

  def handle_call(:scan_complete, _from, state), do: {:reply, :ok, complete_scan(state)}

  def handle_call({:apply_scan_batch, batch}, _from, state) do
    state =
      Enum.reduce(batch, state, fn entry, acc ->
        if tracked?(acc, entry.key_hash) or scan_changed?(acc, entry.key_hash),
          do: acc,
          else: put(acc, entry)
      end)

    {:reply, :ok, state}
  end

  def handle_call(:reconcile_to_cap, from, state) do
    state = %{state | reconcile_waiters: [from | state.reconcile_waiters]}
    {:noreply, start_reconciliation(state)}
  end

  defp decide_write(body_filename, held, state) do
    descriptor = FileSystem.descriptor(nil, body_filename)
    # The request that wrote it already counted as a sighting when it
    # missed. A write no request missed still counts once.
    state = seen(state, descriptor.key_hash)

    result =
      Telemetry.span(tel_opts(state), [:cache, :admission], %{pool: state.pool}, fn ->
        result = decide(state, descriptor, pending(state, held))
        {result, admission_meta(result)}
      end)

    reply =
      case result do
        {:admit, victims} -> {:admit, Enum.map(victims, &{&1.key_hash, &1.body_filename})}
        {:reject, _reason} -> result
      end

    {:reply, reply, state}
  end

  defp complete_scan(state) do
    Enum.each(state.scan_waiters, &GenServer.reply(&1, :ok))
    :ets.delete(state.scan_changes)
    %{state | counted?: true, scan_complete?: true, scan_waiters: [], scan_changes: nil}
  end

  # A write replacing its key's entry doesn't count the bytes it replaces. A
  # cache already over its cap, as after the cap was lowered, frees only the
  # bytes the write adds, and the startup scan's batches evict the rest, so
  # one write doesn't evict the whole excess while every request waits.
  defp decide(state, descriptor, pending) do
    needed = needed(state, descriptor, pending)

    cond do
      charged(descriptor) > state.max_size_bytes ->
        {:reject, :over_cap}

      needed <= 0 ->
        {:admit, []}

      true ->
        state
        |> sample_victims(MapSet.new([descriptor.key_hash]), needed, [])
        |> gate(state, descriptor)
    end
  end

  # The room an admitted write needs now. Its decided victims still stored
  # with the same body give it first. Only when they no longer cover it,
  # after the cache changed while the body synced, are more sampled, and the
  # write is judged against all of them.
  defp room(state, descriptor, pending, decided) do
    needed = needed(state, descriptor, pending)

    victims =
      for {key_hash, body_filename} <- decided,
          %{body_filename: ^body_filename} = victim <- [entry(state, key_hash)],
          do: victim

    covered = victims |> Enum.map(&charged/1) |> Enum.sum()

    cond do
      needed <= 0 ->
        {:admit, []}

      covered >= needed ->
        {:admit, victims}

      true ->
        taken = MapSet.new([descriptor.key_hash | Enum.map(victims, & &1.key_hash)])

        state
        |> sample_victims(taken, needed - covered, victims)
        |> gate(state, descriptor)
    end
  end

  defp needed(state, descriptor, pending) do
    replaced = state |> entry(descriptor.key_hash) |> entry_size()
    added = pending + charged(descriptor) - replaced
    min(state.stored_bytes + added - state.max_size_bytes, added)
  end

  # The write's own pending bytes aren't another write's.
  defp pending(state, held), do: max(Writers.pending(state.root) - held, 0)

  defp gate(:error, _state, _descriptor), do: {:reject, :no_evictable_victims}

  defp gate({:ok, victims}, state, descriptor) do
    if Policy.admit?(descriptor, victims, &frequency(state, &1)) or
         random_admit?(state, descriptor),
       do: {:admit, victims},
       else: {:reject, :score_too_low}
  end

  # Low-cardinality outcome tags: no key hashes, sizes, or paths.
  defp admission_meta({:admit, victims}), do: %{result: :admitted, victim_count: length(victims)}

  defp admission_meta({:reject, reason}),
    do: %{result: :rejected, reason: reason, victim_count: 0}

  # The victims are deleted before the write is published, so the stored
  # bytes never pass the cap. A body the write replaces goes after the
  # publish, so a read of the old metadata never finds it missing. A failed
  # publish leaves the replaced entry in place and counted.
  defp finish_commit({:admit, victims}, prepared, descriptor, state) do
    evict(state, victims, :admission)
    state = Enum.reduce(victims, state, &forget(&2, &1.key_hash))
    replaced = entry(state, descriptor.key_hash) || unscanned_entry(state, prepared)

    case FileSystem.publish_prepared(prepared, descriptor.body_filename) do
      :ok ->
        Memo.forget(state.root, [descriptor.key_hash])
        delete_replaced_body(state, replaced, descriptor)
        {:ok, put(state, descriptor)}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  # A rejected write is never published, and an entry it would have
  # replaced stays.
  defp finish_commit({:reject, _reason}, prepared, _descriptor, state) do
    FileSystem.discard_prepared(prepared)
    {{:ok, :rejected}, state}
  end

  # While the scan runs, an entry the write replaces may be on disk but not
  # yet counted. Its metadata names the body to delete; the scan then skips
  # the key, which the write's put/2 notes.
  defp unscanned_entry(%{scan_changes: nil}, _prepared), do: nil

  defp unscanned_entry(_state, prepared) do
    case FileSystem.read_descriptor(prepared.paths.meta_path) do
      {:ok, descriptor, _mtime} -> descriptor
      {:error, _missing_or_unreadable} -> nil
    end
  end

  defp delete_replaced_body(_state, nil, _descriptor), do: :ok

  defp delete_replaced_body(_state, %{body_filename: same}, %{body_filename: same}), do: :ok

  defp delete_replaced_body(state, replaced, _descriptor),
    do: FileSystem.delete_victims([victim(replaced, false)], root: state.root)

  # Repeatedly takes the lowest-scoring entry of a sample, until the victims
  # free `needed` bytes. `taken` holds keys already chosen or excluded.
  defp sample_victims(_state, _taken, needed, victims) when needed <= 0,
    do: {:ok, Enum.reverse(victims)}

  defp sample_victims(state, taken, needed, victims) do
    case sample(state, taken) do
      [] ->
        :error

      sample ->
        victim = Enum.min_by(sample, &Policy.victim_score(&1, frequency(state, &1.key_hash)))
        taken = MapSet.put(taken, victim.key_hash)
        sample_victims(state, taken, needed - charged(victim), [victim | victims])
    end
  end

  # Up to @sample distinct entries outside `taken`. Keys are uniform hashes,
  # so the successor of a random key is a uniformly sampled entry. A cache
  # with few entries left is sampled whole.
  defp sample(state, taken) do
    if :ets.info(state.entries, :size) <= @sample + MapSet.size(taken) do
      state.entries
      |> :ets.tab2list()
      |> Enum.map(&to_entry/1)
      |> Enum.reject(&MapSet.member?(taken, &1.key_hash))
    else
      draw(state, taken, %{}, 4 * @sample)
    end
  end

  defp draw(_state, _taken, picked, tries) when map_size(picked) == @sample or tries == 0,
    do: Map.values(picked)

  defp draw(state, taken, picked, tries) do
    random = :crypto.strong_rand_bytes(32)

    key =
      case :ets.next(state.entries, random) do
        :"$end_of_table" -> :ets.first(state.entries)
        key -> key
      end

    picked =
      if MapSet.member?(taken, hex(key)),
        do: picked,
        else:
          Map.put_new_lazy(picked, key, fn -> to_entry(hd(:ets.lookup(state.entries, key))) end)

    draw(state, taken, picked, tries - 1)
  end

  defp random_admit?(state, descriptor) do
    frequency(state, descriptor.key_hash) >= @random_admission_min_frequency and
      :rand.uniform(state.random_admission_one_in) == 1
  end

  # A key's first sighting only sets its doorkeeper bit, so the bit counts as
  # one sighting.
  defp frequency(state, key_hash) do
    doorkeeper = if Talan.BloomFilter.member?(state.doorkeeper, key_hash), do: 1, else: 0
    doorkeeper + Sketch.estimate(state.sketch, key_hash)
  end

  defp seen(state, key_hash) do
    if not Talan.BloomFilter.member?(state.doorkeeper, key_hash),
      do: :ok = Talan.BloomFilter.put(state.doorkeeper, key_hash)

    state
  end

  defp sighting(state, key_hash) do
    state =
      if Talan.BloomFilter.member?(state.doorkeeper, key_hash) do
        %{state | sketch: Sketch.increment(state.sketch, key_hash)}
      else
        # talan's put/2 mutates the underlying :atomics ref in place.
        :ok = Talan.BloomFilter.put(state.doorkeeper, key_hash)
        state
      end

    if Sketch.should_age?(state.sketch) do
      # Aging discards the doorkeeper too; the old filter is garbage.
      fresh_doorkeeper = Doorkeeper.new(state.doorkeeper_cardinality, state.doorkeeper_fpr)
      %{state | sketch: Sketch.age(state.sketch), doorkeeper: fresh_doorkeeper}
    else
      state
    end
  end

  defp tracked?(state, key_hash), do: :ets.member(state.entries, raw(key_hash))

  defp entry(state, key_hash) do
    case :ets.lookup(state.entries, raw(key_hash)) do
      [row] -> to_entry(row)
      [] -> nil
    end
  end

  defp entry_size(nil), do: 0
  defp entry_size(entry), do: charged(entry)

  defp charged(entry), do: Policy.charged_bytes(entry.size_bytes)

  defp to_entry({key, size, cost, body_sha256}) do
    key_hash = hex(key)

    %{
      key_hash: key_hash,
      size_bytes: size,
      cost_us: cost,
      body_filename: FileSystem.body_filename(key_hash, hex(body_sha256), size, cost)
    }
  end

  # Every entry write goes through put/2 and forget/2, so the stored bytes
  # stay in step with the table. A descriptor's body filename was parsed
  # when its metadata or listing was read, so its parts rebuild it.
  defp put(state, descriptor) do
    state = forget(state, descriptor.key_hash)
    {:ok, %{body_sha256: body_sha256}} = FileSystem.parse_body_filename(descriptor.body_filename)

    :ets.insert(
      state.entries,
      {raw(descriptor.key_hash), descriptor.size_bytes, descriptor.cost_us, raw(body_sha256)}
    )

    %{state | stored_bytes: state.stored_bytes + charged(descriptor)}
  end

  defp forget(state, key_hash) do
    note_scan_change(state, key_hash)

    case :ets.take(state.entries, raw(key_hash)) do
      [{_key, size, _cost, _body_sha256}] ->
        %{state | stored_bytes: state.stored_bytes - Policy.charged_bytes(size)}

      [] ->
        state
    end
  end

  defp raw(hex), do: Base.decode16!(hex, case: :lower)
  defp hex(raw), do: Base.encode16(raw, case: :lower)

  defp victim(entry, delete_meta?),
    do: %{
      key_hash: entry.key_hash,
      body_filename: entry.body_filename,
      delete_meta?: delete_meta?
    }

  defp note_scan_change(%{scan_changes: nil}, _key_hash), do: :ok
  defp note_scan_change(state, key_hash), do: :ets.insert(state.scan_changes, {key_hash})

  defp scan_changed?(%{scan_changes: nil}, _key_hash), do: false
  defp scan_changed?(state, key_hash), do: :ets.member(state.scan_changes, key_hash)

  defp start_reconciliation(%{reconciling?: true} = state), do: state

  defp start_reconciliation(state) do
    send(self(), :reconcile_batch)
    %{state | reconciling?: true}
  end

  defp finish_reconciliation(state) do
    Enum.each(state.reconcile_waiters, &GenServer.reply(&1, :ok))
    %{state | reconciling?: false, reconcile_waiters: []}
  end

  # Evicts sampled lowest-scoring entries until the cache is at or under its
  # cap, at most `remaining` per batch.
  defp reconcile_batch(state, 0, victims) do
    evict(state, victims, :startup)
    if over_cap?(state), do: {:more, state}, else: {:done, state}
  end

  defp reconcile_batch(state, remaining, victims) do
    with true <- over_cap?(state),
         [_ | _] = sample <- sample(state, MapSet.new()) do
      victim = Enum.min_by(sample, &Policy.victim_score(&1, frequency(state, &1.key_hash)))
      reconcile_batch(forget(state, victim.key_hash), remaining - 1, [victim | victims])
    else
      _under_cap_or_empty ->
        evict(state, victims, :startup)
        {:done, state}
    end
  end

  defp over_cap?(state), do: state.stored_bytes > state.max_size_bytes

  defp reconcile_if_over_cap(state),
    do:
      if(state.scan_complete? and over_cap?(state), do: start_reconciliation(state), else: state)

  defp evict(_state, [], _trigger), do: :ok

  defp evict(state, victims, trigger) do
    FileSystem.delete_victims(Enum.map(victims, &victim(&1, true)), root: state.root)
    Memo.forget(state.root, Enum.map(victims, & &1.key_hash))
    bytes = Enum.reduce(victims, 0, &(&1.size_bytes + &2))

    Telemetry.execute(
      tel_opts(state),
      [:cache, :eviction, :stop],
      %{count: length(victims), bytes: bytes},
      %{trigger: trigger, pool: state.pool}
    )
  end
end
