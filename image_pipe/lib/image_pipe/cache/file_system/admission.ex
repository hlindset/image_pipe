defmodule ImagePipe.Cache.FileSystem.Admission do
  @moduledoc false

  use GenServer

  alias ImagePipe.Cache.FileSystem.Doorkeeper
  alias ImagePipe.Cache.FileSystem.Policy
  alias ImagePipe.Cache.FileSystem.Sketch
  alias ImagePipe.Cache.FileSystem.Store, as: FileSystem
  alias ImagePipe.Cache.FileSystem.Sweep
  alias ImagePipe.Telemetry

  defmodule State do
    @moduledoc false
    # Configuration, ETS handles, byte counters, and scan lifecycle state.
    # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
    defstruct [
      :registry,
      :root,
      :max_size_bytes,
      :window_budget,
      :sketch_depth,
      :sketch_width,
      :aging_sample_size,
      :doorkeeper_cardinality,
      :doorkeeper_fpr,
      :eviction_victim_limit,
      :sketch,
      # %Talan.BloomFilter{}
      :doorkeeper,
      :reconcile_interval_ms,
      :rescan_interval_ms,
      # Lifecycle events use the prefix captured at init, without request options.
      telemetry_prefix: [:image_pipe],
      pool: :output,
      path_prefix: "",
      window: nil,
      probationary: nil,
      protected: nil,
      # key_hash -> {queue, position}, so hash lookups avoid scanning the
      # position-ordered queues.
      index: nil,
      # Keys dropped, deleted or committed while the startup scan or a re-scan
      # runs, so a stale scanned descriptor for them is skipped. nil between
      # scans.
      scan_changes: nil,
      window_bytes: 0,
      probationary_bytes: 0,
      protected_bytes: 0,
      next_position: 1,
      # Monitor the scan so a crash releases await_scan/2 callers. scan_waiters
      # holds their GenServer.call `from` tags until completion or failure.
      scan_task: nil,
      scan_task_ref: nil,
      scan_complete?: false,
      scan_waiters: [],
      rescan_task_ref: nil,
      reconciling?: false,
      reconcile_waiters: [],
      reconcile_tick_pending?: false,
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

  # A node evicting an entry renames its metadata aside for a moment to check
  # it (Store.delete_victims/2), so a miss is checked again later rather than
  # trusted at once.
  @gone_recheck_ms 1_000

  # Takes options normalized by `Store.admission_options/2`.
  @impl true
  def init(opts) do
    max_size = Keyword.fetch!(opts, :max_size_bytes)
    sketch_depth = Keyword.fetch!(opts, :sketch_depth)
    sketch_width = Keyword.fetch!(opts, :sketch_width)
    # Aging cadence is decoupled from width (Sketch.new/1 docs).
    aging_sample_size = Keyword.fetch!(opts, :aging_sample_size)
    doorkeeper_cardinality = Keyword.fetch!(opts, :doorkeeper_cardinality)
    doorkeeper_fpr = Keyword.fetch!(opts, :doorkeeper_fpr)

    state = %State{
      registry: Keyword.fetch!(opts, :registry),
      root: Keyword.fetch!(opts, :root),
      # Scan the same partition root the cache writes to.
      path_prefix: Keyword.fetch!(opts, :path_prefix),
      max_size_bytes: max_size,
      window_budget: trunc(max_size * Keyword.fetch!(opts, :window_ratio)),
      sketch_depth: sketch_depth,
      sketch_width: sketch_width,
      aging_sample_size: aging_sample_size,
      doorkeeper_cardinality: doorkeeper_cardinality,
      doorkeeper_fpr: doorkeeper_fpr,
      eviction_victim_limit: Keyword.fetch!(opts, :eviction_victim_limit),
      sketch:
        Sketch.new(depth: sketch_depth, width: sketch_width, sample_size: aging_sample_size),
      doorkeeper: Doorkeeper.new(doorkeeper_cardinality, doorkeeper_fpr),
      reconcile_interval_ms: Keyword.fetch!(opts, :reconcile_interval_ms),
      rescan_interval_ms: Keyword.fetch!(opts, :rescan_interval_ms),
      telemetry_prefix: Keyword.get(opts, :telemetry_prefix, Telemetry.default_prefix()),
      pool: Keyword.get(opts, :pool, :output),
      # Only the GenServer writes; :protected permits cross-process inspection.
      window: :ets.new(:window, [:ordered_set, :protected]),
      probationary: :ets.new(:probationary, [:ordered_set, :protected]),
      protected: :ets.new(:protected, [:ordered_set, :protected]),
      index: :ets.new(:index, [:set, :protected]),
      scan_changes: :ets.new(:scan_changes, [:set, :private])
    }

    {:ok, state, {:continue, :schedule_tickers}}
  end

  # Lifecycle telemetry opts. Admission has no per-request telemetry opts, so
  # events fire under the prefix captured at init.
  defp tel_opts(state), do: [telemetry_prefix: state.telemetry_prefix]

  @impl true
  def handle_continue(:schedule_tickers, state) do
    # Capture Admission's pid before spawning. An unlinked, monitored scan can
    # fail without crashing Admission; its :DOWN releases await_scan waiters.
    # This short-lived worker needs no per-cache Task.Supervisor registration.
    admission_pid = self()
    {scan_pid, scan_ref} = spawn_monitor(fn -> scan_directory(state, admission_pid) end)
    state = %{state | scan_task: scan_pid, scan_task_ref: scan_ref}

    Process.send_after(self(), :reconcile, state.reconcile_interval_ms)
    schedule_rescan(state)
    {:noreply, state}
  end

  @doc """
  Block until the background directory scan has reported completion.
  Test/diagnostic helper — production callers never need to wait. Returns
  `:ok` once the scan finishes (or has already finished); the call times
  out normally if the scan exceeds `timeout`.
  """
  @spec await_scan(GenServer.server(), timeout()) :: :ok
  def await_scan(server, timeout \\ 5_000) do
    GenServer.call(server, :await_scan, timeout)
  end

  defp scan_directory(state, admission_pid) do
    entry_root = Path.join(state.root, state.path_prefix)
    {listings, descriptor_map} = read_entries(entry_root, fn _key_hash -> true end)

    # Phase A: put every entry on probation in mtime order, oldest first. A
    # hit promotes it, so entries requested after a restart regain their
    # place. Batches of 100 bound per-call latency.
    descriptor_map
    |> Map.values()
    |> Enum.sort_by(fn %{mtime: mtime} -> mtime end)
    |> Enum.chunk_every(100)
    |> Enum.each(&GenServer.call(admission_pid, {:apply_scan_batch, &1}, :infinity))

    # Phase B: post-scan reconciliation. If total bytes ended up over
    # cap (operator lowered cap, previous run wrote past soft cap),
    # evict by LRU until under budget. No score gate — these are
    # already-cached entries with no candidate to compare against.
    GenServer.call(admission_pid, :reconcile_to_cap, :infinity)

    # Phase C: remove files a VM that died left behind.
    Sweep.run_listings(listings, state.pool, tel_opts(state))

    GenServer.call(admission_pid, :scan_complete, :infinity)
  end

  # Nodes sharing a root write and evict entries this node doesn't see, so it
  # lists the root again every interval: it adopts entries peers wrote, checks
  # the ones whose files are gone, evicts down to the cap, and sweeps leftover
  # files. Admission checks a tracked entry the listing missed against the
  # disk before it stops counting it. An entry a peer removes between the
  # descriptor read and adoption is counted until the next re-scan.
  defp rescan_directory(state, admission_pid) do
    Telemetry.span(tel_opts(state), [:cache, :rescan], %{pool: state.pool}, fn ->
      entry_root = Path.join(state.root, state.path_prefix)
      untracked? = &(not :ets.member(state.index, &1))
      {listings, descriptor_map} = read_entries(entry_root, untracked?)

      changed = changed_tracked_hashes(listings, state)
      # A peer evicting a key renames its metadata aside for a moment, so the
      # disk check waits, as a reported miss does.
      if changed != [], do: Process.sleep(@gone_recheck_ms)

      {dropped, resynced} =
        changed
        |> Enum.chunk_every(100)
        |> Enum.reduce({0, 0}, fn hashes, {dropped, resynced} ->
          {more_dropped, more_resynced} =
            GenServer.call(admission_pid, {:rescan_resync, hashes}, :infinity)

          {dropped + more_dropped, resynced + more_resynced}
        end)

      adopted =
        descriptor_map
        |> Map.values()
        |> Enum.sort_by(fn %{mtime: mtime} -> mtime end)
        |> Enum.chunk_every(100)
        |> Enum.reduce(0, &(&2 + GenServer.call(admission_pid, {:rescan_adopt, &1}, :infinity)))

      GenServer.call(admission_pid, :reconcile_to_cap, :infinity)
      Sweep.run_listings(listings, state.pool, tel_opts(state))
      GenServer.call(admission_pid, :rescan_complete, :infinity)

      {:ok, %{result: :ok, adopted: adopted, dropped: dropped, resynced: resynced}}
    end)
  end

  # Tracked keys whose metadata or tracked body is missing from the listing.
  defp changed_tracked_hashes(listings, state) do
    present = for {_dir, names} <- listings, name <- names, into: MapSet.new(), do: name

    :ets.foldl(
      fn {key_hash, queue, pos}, acc ->
        if unlisted?(state, present, queue, pos, key_hash), do: [key_hash | acc], else: acc
      end,
      [],
      state.index
    )
  end

  defp unlisted?(state, present, queue, pos, key_hash) do
    case :ets.lookup(Map.fetch!(state, queue), {pos, key_hash}) do
      [{_key, %{body_sha256: body_sha256}}] ->
        not (MapSet.member?(present, key_hash <> ".meta") and
               MapSet.member?(present, "#{key_hash}.#{body_sha256}.body"))

      # Moved since the index read. Its next re-scan checks it.
      [] ->
        false
    end
  end

  # Replicas started together would otherwise re-scan in step and each evict
  # the same excess.
  defp schedule_rescan(state) do
    spread = div(state.rescan_interval_ms, 5)
    jitter = :rand.uniform(2 * spread + 1) - 1 - spread
    Process.send_after(self(), :rescan, state.rescan_interval_ms + jitter)
  end

  defp start_rescan(state) do
    admission_pid = self()
    {_pid, ref} = spawn_monitor(fn -> rescan_directory(state, admission_pid) end)
    %{state | rescan_task_ref: ref, scan_changes: :ets.new(:scan_changes, [:set, :private])}
  end

  defp finish_rescan(state) do
    :ets.delete(state.scan_changes)
    schedule_rescan(state)
    %{state | rescan_task_ref: nil, scan_changes: nil}
  end

  # One pass lists each two-level partition once, a first-level group per
  # task. The listings feed both the descriptor reads and the leftover sweep.
  # `read?` picks the keys whose metadata is read.
  defp read_entries(entry_root, read?) do
    entry_root
    |> Sweep.partitions()
    |> Task.async_stream(&read_partition_group(&1, read?),
      max_concurrency: System.schedulers_online(),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce({[], %{}}, fn {:ok, {listings, descriptors}}, {all_listings, all} ->
      {listings ++ all_listings, Map.merge(all, descriptors)}
    end)
  end

  defp read_partition_group(dir, read?) do
    listings = for partition <- Sweep.partitions(dir), do: Sweep.listing(partition)

    descriptors =
      for {partition, names} <- listings,
          name <- names,
          String.ends_with?(name, ".meta"),
          read?.(Path.basename(name, ".meta")),
          {:ok, descriptor, mtime} <- [FileSystem.read_descriptor(Path.join(partition, name))],
          into: %{},
          do: {descriptor.key_hash, Map.put(descriptor, :mtime, mtime)}

    {listings, descriptors}
  end

  # mtime determines scan insertion order but is not part of queued descriptors.
  defp insert_scan_descriptor(state, entry) do
    descriptor = Map.delete(entry, :mtime)
    {pos, state} = next_position(state)
    put_entry(state, :probationary, pos, descriptor)
    Map.update!(state, :probationary_bytes, &(&1 + descriptor.size_bytes))
  end

  @impl true
  def handle_info({:recheck_gone, key_hash}, state) do
    case locate(state, key_hash) do
      nil -> {:noreply, state}
      located -> {:noreply, resync(state, located)}
    end
  end

  # The running re-scan schedules the next one when it finishes.
  def handle_info(:rescan, state) do
    if state.scan_complete? do
      {:noreply, start_rescan(state)}
    else
      schedule_rescan(state)
      {:noreply, state}
    end
  end

  def handle_info(:reconcile, state) do
    {:noreply, start_reconciliation(%{state | reconcile_tick_pending?: true})}
  end

  def handle_info(:reconcile_batch, state) do
    case reconcile_batch(state, state.eviction_victim_limit, []) do
      {:more, state} ->
        send(self(), :reconcile_batch)
        {:noreply, state}

      {:done, state} ->
        {:noreply, finish_reconciliation(state)}
    end
  end

  # Release waiters if the scan dies before reporting completion. Normal exit
  # after :scan_complete needs no action; spawn_monitor sends no result message.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{scan_task_ref: ref} = state) do
    if reason != :normal and not state.scan_complete? do
      require Logger
      Logger.warning("cache: directory scan crashed before completion: reason=#{inspect(reason)}")
      Enum.each(state.scan_waiters, &GenServer.reply(&1, :ok))
      :ets.delete(state.scan_changes)

      {:noreply,
       %{
         state
         | scan_complete?: true,
           scan_waiters: [],
           scan_task: nil,
           scan_task_ref: nil,
           scan_changes: nil
       }}
    else
      {:noreply, %{state | scan_task: nil, scan_task_ref: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{rescan_task_ref: ref} = state) do
    require Logger
    Logger.warning("cache: directory re-scan crashed: reason=#{inspect(reason)}")
    {:noreply, finish_rescan(state)}
  end

  @doc """
  Notify Admission of a cache hit. `descriptor` carries the same shape
  as an admit-time descriptor (key_hash, size_bytes, body_sha256,
  cost_us) so Admission can synthesize a probationary entry for hits
  that arrive before the boot scan reaches the corresponding key.
  """
  @spec hit(pid() | GenServer.name(), map()) :: :ok
  def hit(server, descriptor) when is_map(descriptor) do
    GenServer.cast(server, {:hit, descriptor})
  end

  @doc """
  Reports a read that found no entry for `key_hash`. If this node still counts
  the entry, it checks the disk and stops counting it when it's gone.
  """
  def gone(server, key_hash) when is_binary(key_hash) do
    GenServer.cast(server, {:gone, key_hash})
  end

  @impl true
  def handle_cast({:gone, key_hash}, state) do
    if already_tracked?(state, key_hash),
      do: Process.send_after(self(), {:recheck_gone, key_hash}, @gone_recheck_ms)

    {:noreply, state}
  end

  def handle_cast({:hit, descriptor}, state) do
    state = sighting(state, descriptor.key_hash)
    {:noreply, on_hit_promote_or_synthesize(state, descriptor)}
  end

  defp on_hit_promote_or_synthesize(state, descriptor) do
    case locate(state, descriptor.key_hash) do
      nil ->
        case current_descriptor?(state, descriptor) do
          true -> insert_scan_descriptor(state, descriptor)
          false -> state
        end

      {_queue, _pos, %{body_sha256: body_sha256}} = located
      when body_sha256 == descriptor.body_sha256 ->
        promote_on_hit(state, located)

      located ->
        state = resync(state, located)

        case locate(state, descriptor.key_hash) do
          nil -> state
          located -> promote_on_hit(state, located)
        end
    end
  end

  defp current_descriptor?(state, descriptor) do
    stored_descriptor(state, descriptor.key_hash) == {:ok, Map.delete(descriptor, :mtime)}
  end

  # Another node sharing the root may have deleted or replaced an entry this
  # node counts. The stored metadata decides: the entry is forgotten when its
  # metadata is gone, and takes the stored size when it names another body.
  defp resync(state, {queue, pos, tracked}) do
    case stored_descriptor(state, tracked.key_hash) do
      {:ok, ^tracked} ->
        state

      {:ok, stored} ->
        put_entry(state, queue, pos, stored)
        Map.update!(state, :"#{queue}_bytes", &(&1 + stored.size_bytes - tracked.size_bytes))

      :missing ->
        remove_descriptor(state, tracked)
    end
  end

  defp stored_descriptor(state, key_hash) do
    opts = [root: state.root, path_prefix: state.path_prefix]

    with {:ok, paths} <- FileSystem.paths_from_hash(key_hash, opts),
         {:ok, descriptor, _mtime} <- FileSystem.read_descriptor(paths.meta_path) do
      {:ok, descriptor}
    else
      _missing_or_unreadable -> :missing
    end
  end

  # A timed-out commit stays queued, and Admission still publishes it.
  def commit(server, prepared, body_filename, timeout) do
    GenServer.call(server, {:commit, prepared, body_filename}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :admission_timeout}
    :exit, _reason -> {:error, :admission_unavailable}
  end

  def delete(server, paths), do: call(server, {:delete, paths})

  def refresh_source_record(server, paths, previous, record),
    do: call(server, {:refresh_source_record, paths, previous, record})

  defp call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> {:error, :admission_unavailable}
  end

  defp admit_descriptor(state, descriptor) do
    # Increment sighting first (commit is itself a sighting of the key)
    state = sighting(state, descriptor.key_hash)

    Telemetry.span(tel_opts(state), [:cache, :admission], %{pool: state.pool}, fn ->
      {result, new_state} = decide_admission(state, descriptor)
      {{result, new_state}, admission_meta(result)}
    end)
  end

  defp finish_commit({:admit, victims}, _descriptor, opts) do
    FileSystem.delete_victims(victims, opts)
    :ok
  end

  defp finish_commit({:reject, _reason, victims}, descriptor, opts) do
    FileSystem.delete_victims([full_eviction_victim(descriptor) | victims], opts)
    {:ok, :rejected}
  end

  defp finish_commit({:reject, reason}, descriptor, opts),
    do: finish_commit({:reject, reason, []}, descriptor, opts)

  @impl true
  def handle_call({:refresh_source_record, paths, previous, record}, _from, state) do
    {:reply, FileSystem.refresh_entry(paths, previous, record), state}
  end

  def handle_call({:delete, paths}, _from, state) do
    note_scan_change(state, paths.hash)

    case FileSystem.delete_entry(paths) do
      {:ok, result} -> {:reply, result, forget_entry(state, paths.hash)}
      :miss -> {:reply, :miss, forget_entry(state, paths.hash)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:commit, prepared, body_filename}, _from, state) do
    # Publication, accounting and eviction share the same serialized owner.
    # Failed publication leaves admission queues unchanged.
    note_scan_change(state, prepared.paths.hash)

    case FileSystem.publish_sink(prepared, body_filename) do
      {:ok, descriptor} ->
        {result, state} = admit_descriptor(state, descriptor)
        opts = [root: state.root, path_prefix: state.path_prefix]
        {:reply, finish_commit(result, descriptor, opts), state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:await_scan, from, state) do
    if state.scan_complete? do
      {:reply, :ok, state}
    else
      {:noreply, %{state | scan_waiters: [from | state.scan_waiters]}}
    end
  end

  def handle_call(:scan_complete, _from, state) do
    Enum.each(state.scan_waiters, &GenServer.reply(&1, :ok))
    :ets.delete(state.scan_changes)
    {:reply, :ok, %{state | scan_complete?: true, scan_waiters: [], scan_changes: nil}}
  end

  def handle_call({:apply_scan_batch, batch}, _from, state) do
    {state, _adopted} = adopt_scanned(state, batch)
    {:reply, :ok, state}
  end

  def handle_call({:rescan_adopt, batch}, _from, state) do
    {state, adopted} = adopt_scanned(state, batch)
    {:reply, adopted, state}
  end

  def handle_call({:rescan_resync, hashes}, _from, state) do
    {state, counts} = Enum.reduce(hashes, {state, {0, 0}}, &rescan_resync/2)
    {:reply, counts, state}
  end

  def handle_call(:rescan_complete, _from, state) do
    Process.demonitor(state.rescan_task_ref, [:flush])
    {:reply, :ok, finish_rescan(state)}
  end

  def handle_call(:reconcile_to_cap, from, state) do
    state = %{state | reconcile_waiters: [from | state.reconcile_waiters]}
    {:noreply, start_reconciliation(state)}
  end

  defp adopt_scanned(state, batch) do
    Enum.reduce(batch, {state, 0}, fn entry, {acc, adopted} ->
      if already_tracked?(acc, entry.key_hash) or scan_changed?(acc, entry.key_hash) do
        {acc, adopted}
      else
        {insert_scan_descriptor(acc, entry), adopted + 1}
      end
    end)
  end

  # Returns the dropped and resynced counts, from what the disk holds now.
  defp rescan_resync(key_hash, {state, {dropped, resynced} = counts}) do
    case locate(state, key_hash) do
      nil ->
        {state, counts}

      {_queue, _pos, tracked} = located ->
        state = resync(state, located)

        case locate(state, key_hash) do
          nil -> {state, {dropped + 1, resynced}}
          {_queue, _pos, ^tracked} -> {state, counts}
          _resynced -> {state, {dropped, resynced + 1}}
        end
    end
  end

  defp decide_admission(state, descriptor) do
    case locate(state, descriptor.key_hash) do
      nil -> admit_new(state, descriptor)
      located -> same_key_replace(state, descriptor, located)
    end
  end

  defp admit_new(state, descriptor) do
    if descriptor.size_bytes > state.max_size_bytes do
      {{:reject, :over_cap}, state}
    else
      do_admit(state, descriptor)
    end
  end

  # Low-cardinality outcome tags. `victim_count` is bounded by
  # `eviction_victim_limit`; no key hashes, sizes, or paths.
  defp admission_meta({:admit, victims}), do: %{result: :admitted, victim_count: length(victims)}

  defp admission_meta({:reject, reason}),
    do: %{result: :rejected, reason: reason, victim_count: 0}

  defp admission_meta({:reject, reason, victims}),
    do: %{result: :rejected, reason: reason, victim_count: length(victims)}

  defp do_admit(state, descriptor) when descriptor.size_bytes > state.window_budget,
    do: run_main_gate(state, descriptor)

  defp do_admit(state, descriptor), do: insert_into_window(state, descriptor)

  defp insert_into_window(state, descriptor) do
    {position, state} = next_position(state)
    put_entry(state, :window, position, descriptor)
    state = %{state | window_bytes: state.window_bytes + descriptor.size_bytes}
    drain_window_overflow(state, [])
  end

  defp drain_window_overflow(state, victims) do
    cond do
      state.window_bytes <= state.window_budget ->
        {{:admit, victims}, state}

      # Defensive: byte counter says we are over budget but the table is
      # empty. This should not happen if accounting is consistent, but a
      # blind `:ets.first/1` + `:ets.lookup/2` on an empty table would
      # match `[]` against `[{...}]` and crash the GenServer. Stop draining.
      :ets.first(state.window) == :"$end_of_table" ->
        {{:admit, victims}, state}

      true ->
        # Pop window LRU
        first_key = :ets.first(state.window)
        [{{pos, hash}, descriptor}] = :ets.lookup(state.window, first_key)
        drop_entry(state, :window, pos, hash)
        state = %{state | window_bytes: state.window_bytes - descriptor.size_bytes}

        {gate_result, state} = run_main_gate(state, descriptor)

        drain_after_gate(state, descriptor, gate_result, victims)
    end
  end

  defp drain_after_gate(state, descriptor, gate_result, victims) do
    case gate_result do
      {:admit, more_victims} ->
        drain_window_overflow(state, victims ++ more_victims)

      {:reject, _} ->
        # Window evictee lost main gate; its files must be deleted
        # (body and meta).
        evictee_victim = full_eviction_victim(descriptor)
        drain_window_overflow(state, victims ++ [evictee_victim])
    end
  end

  defp full_eviction_victim(descriptor) do
    %{
      key_hash: descriptor.key_hash,
      body_sha256: descriptor.body_sha256,
      size_bytes: descriptor.size_bytes,
      delete_body?: true,
      delete_meta?: true
    }
  end

  defp already_tracked?(state, key_hash), do: :ets.member(state.index, key_hash)

  defp run_main_gate(state, descriptor) do
    needed_bytes =
      state.probationary_bytes + state.protected_bytes + descriptor.size_bytes -
        (state.max_size_bytes - state.window_budget)

    case needed_bytes > 0 do
      true -> identify_and_score(state, descriptor, needed_bytes)
      false -> insert_into_probationary(state, descriptor)
    end
  end

  defp insert_into_probationary(state, descriptor) do
    {position, state} = next_position(state)
    put_entry(state, :probationary, position, descriptor)
    state = %{state | probationary_bytes: state.probationary_bytes + descriptor.size_bytes}
    {{:admit, []}, state}
  end

  defp identify_and_score(state, descriptor, needed_bytes) do
    limit = state.eviction_victim_limit

    case Policy.victim_walk(
           lru_descriptors(state.probationary),
           lru_descriptors(state.protected),
           needed_bytes,
           limit
         ) do
      {:error, :no_evictable_victims} ->
        {{:reject, :no_evictable_victims}, state}

      {:error, :victim_limit_exceeded} ->
        {{:reject, :victim_limit_exceeded}, state}

      {:ok, victim_descriptors} ->
        if Policy.admit?(descriptor, victim_descriptors, &frequency(state, &1)) or
             random_admit?(state, descriptor) do
          admit_evicting(state, descriptor, victim_descriptors)
        else
          {{:reject, :score_too_low}, state}
        end
    end
  end

  # A candidate that loses the gate is admitted anyway, rarely, once it has
  # been requested a few times, as in Caffeine. Without it, keys that become
  # popular keep losing to entries whose counts haven't aged yet
  # (bench/cache_policy.exs, `shift`).
  @random_admission_min_frequency 6

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

  # Evict at most `eviction_victim_limit` victims now. Reconciliation evicts
  # the rest in batches, reaching them in the same LRU order.
  defp admit_evicting(state, descriptor, victims) do
    {evict_now, evict_later} = Enum.split(victims, state.eviction_victim_limit)
    state = remove_victims(state, evict_now)
    {_result, state} = insert_into_probationary(state, descriptor)
    state = if evict_later == [], do: state, else: start_reconciliation(state)
    # Tag victims with full-eviction flags for the adapter.
    {{:admit, Enum.map(evict_now, &full_eviction_victim/1)}, state}
  end

  # Lazy LRU-first stream, so the victim walk reads only the entries it needs.
  # Consume it before changing the table.
  defp lru_descriptors(table) do
    Stream.unfold(:ets.first(table), fn
      :"$end_of_table" ->
        nil

      key ->
        [{_key, descriptor}] = :ets.lookup(table, key)
        {descriptor, :ets.next(table, key)}
    end)
  end

  defp remove_victims(state, victims) do
    Enum.reduce(victims, state, fn descriptor, acc ->
      remove_descriptor(acc, descriptor)
    end)
  end

  defp forget_entry(state, key_hash) do
    case locate(state, key_hash) do
      nil -> state
      {_queue, _position, descriptor} -> remove_descriptor(state, descriptor)
    end
  end

  defp remove_descriptor(state, descriptor) do
    case locate(state, descriptor.key_hash) do
      nil ->
        state

      {queue, pos, _descriptor} ->
        drop_entry(state, queue, pos, descriptor.key_hash)
        Map.update!(state, :"#{queue}_bytes", &(&1 - descriptor.size_bytes))
    end
  end

  defp same_key_replace(state, descriptor, {queue, old_position, old_descriptor}) do
    # Remove the old entry's bytes from accounting.
    bytes_field = :"#{queue}_bytes"
    state = Map.update!(state, bytes_field, &(&1 - old_descriptor.size_bytes))
    drop_entry(state, queue, old_position, descriptor.key_hash)

    # Body-only victim when content changed; otherwise no victim.
    victims =
      if descriptor.body_sha256 == old_descriptor.body_sha256 do
        []
      else
        [
          %{
            key_hash: old_descriptor.key_hash,
            body_sha256: old_descriptor.body_sha256,
            size_bytes: old_descriptor.size_bytes,
            delete_body?: true,
            delete_meta?: false
          }
        ]
      end

    {result, state} =
      case descriptor.size_bytes <= old_descriptor.size_bytes do
        true ->
          {position, state} = next_position(state)
          put_entry(state, queue, position, descriptor)
          state = Map.update!(state, bytes_field, &(&1 + descriptor.size_bytes))
          {{:admit, []}, state}

        false ->
          admit_new(state, descriptor)
      end

    case result do
      {:admit, evictions} -> {{:admit, victims ++ evictions}, state}
      {:reject, reason} -> {{:reject, reason, victims}, state}
    end
  end

  defp sighting(state, key_hash) do
    state =
      if Talan.BloomFilter.member?(state.doorkeeper, key_hash) do
        %{state | sketch: Sketch.increment(state.sketch, key_hash)}
      else
        # talan's put/2 mutates the underlying :atomics ref in place and
        # returns :ok.
        :ok = Talan.BloomFilter.put(state.doorkeeper, key_hash)
        state
      end

    if Sketch.should_age?(state.sketch) do
      # Doorkeeper reset = discard the current filter and allocate a
      # fresh one. The old :atomics ref becomes unreferenced and is
      # garbage-collected. This is cheap (one allocation per aging cycle,
      # which is itself infrequent).
      fresh_doorkeeper = Doorkeeper.new(state.doorkeeper_cardinality, state.doorkeeper_fpr)

      %{state | sketch: Sketch.age(state.sketch), doorkeeper: fresh_doorkeeper}
    else
      state
    end
  end

  # Return `{queue, position, descriptor}` for a tracked key_hash, or nil when
  # the key is untracked. The queue atom lets callers (e.g. promote_on_hit/2)
  # act on the located entry's home queue.
  defp locate(state, key_hash) do
    case :ets.lookup(state.index, key_hash) do
      [] ->
        nil

      [{^key_hash, queue, pos}] ->
        [{_key, descriptor}] = :ets.lookup(Map.fetch!(state, queue), {pos, key_hash})
        {queue, pos, descriptor}
    end
  end

  # Every queue write goes through these two helpers so the index stays in
  # step with the queues.
  defp put_entry(state, queue, pos, descriptor) do
    :ets.insert(Map.fetch!(state, queue), {{pos, descriptor.key_hash}, descriptor})
    :ets.insert(state.index, {descriptor.key_hash, queue, pos})
  end

  defp drop_entry(state, queue, pos, key_hash) do
    note_scan_change(state, key_hash)
    :ets.delete(Map.fetch!(state, queue), {pos, key_hash})
    :ets.delete(state.index, key_hash)
  end

  defp note_scan_change(%{scan_changes: nil}, _key_hash), do: :ok
  defp note_scan_change(state, key_hash), do: :ets.insert(state.scan_changes, {key_hash})

  defp scan_changed?(%{scan_changes: nil}, _key_hash), do: false
  defp scan_changed?(state, key_hash), do: :ets.member(state.scan_changes, key_hash)

  defp next_position(state),
    do: {state.next_position, %{state | next_position: state.next_position + 1}}

  defp promote_on_hit(state, located) do
    case located do
      {:window, pos, descriptor} ->
        move_to_mru(state, :window, pos, descriptor)

      {:probationary, pos, descriptor} ->
        drop_entry(state, :probationary, pos, descriptor.key_hash)
        state = Map.update!(state, :probationary_bytes, &(&1 - descriptor.size_bytes))
        insert_into_protected(state, descriptor)

      {:protected, pos, descriptor} ->
        move_to_mru(state, :protected, pos, descriptor)
    end
  end

  defp move_to_mru(state, queue, old_pos, descriptor) do
    drop_entry(state, queue, old_pos, descriptor.key_hash)
    {pos, state} = next_position(state)
    put_entry(state, queue, pos, descriptor)
    state
  end

  defp insert_into_protected(state, descriptor) do
    {pos, state} = next_position(state)
    put_entry(state, :protected, pos, descriptor)
    state = Map.update!(state, :protected_bytes, &(&1 + descriptor.size_bytes))
    enforce_protected_target(state)
  end

  # Protected keeps 80% of the main budget, as in W-TinyLFU. Entries vary in
  # size, so one promotion can need several demotions. The entry just promoted
  # is protected's MRU and is demoted last.
  defp enforce_protected_target(state) do
    main_budget = state.max_size_bytes - state.window_budget
    target = trunc(main_budget * 0.80)

    if state.protected_bytes > target and :ets.info(state.protected, :size) > 0 do
      first_key = :ets.first(state.protected)
      [{{old_pos, key_hash}, descriptor}] = :ets.lookup(state.protected, first_key)
      drop_entry(state, :protected, old_pos, key_hash)
      state = Map.update!(state, :protected_bytes, &(&1 - descriptor.size_bytes))

      {pos, state} = next_position(state)
      put_entry(state, :probationary, pos, descriptor)

      state
      |> Map.update!(:probationary_bytes, &(&1 + descriptor.size_bytes))
      |> enforce_protected_target()
    else
      state
    end
  end

  defp start_reconciliation(%{reconciling?: true} = state), do: state

  defp start_reconciliation(state) do
    send(self(), :reconcile_batch)
    %{state | reconciling?: true}
  end

  defp finish_reconciliation(state) do
    Enum.each(state.reconcile_waiters, &GenServer.reply(&1, :ok))

    if state.reconcile_tick_pending? do
      Process.send_after(self(), :reconcile, state.reconcile_interval_ms)
    end

    %{state | reconciling?: false, reconcile_waiters: [], reconcile_tick_pending?: false}
  end

  defp reconcile_batch(state, 0, descriptors) do
    emit_reconciliation_evictions(state, descriptors)

    case over_cap?(state) do
      true -> {:more, state}
      false -> {:done, state}
    end
  end

  defp reconcile_batch(state, remaining, descriptors) do
    case over_cap?(state) do
      true ->
        {evicted, state} = evict_one_lru(state)

        case evicted do
          nil ->
            require Logger
            Logger.warning("cache: reconciliation cannot bring usage under cap")
            emit_reconciliation_evictions(state, descriptors)
            {:done, state}

          descriptor ->
            reconcile_batch(state, remaining - 1, [descriptor | descriptors])
        end

      false ->
        emit_reconciliation_evictions(state, descriptors)
        {:done, state}
    end
  end

  defp over_cap?(state),
    do:
      state.window_bytes + state.probationary_bytes + state.protected_bytes > state.max_size_bytes

  defp evict_one_lru(state) do
    cond do
      :ets.info(state.probationary, :size) > 0 ->
        evict_lru_from(state, :probationary)

      :ets.info(state.protected, :size) > 0 ->
        evict_lru_from(state, :protected)

      true ->
        {nil, state}
    end
  end

  defp evict_lru_from(state, queue) do
    table = Map.fetch!(state, queue)
    bytes_field = :"#{queue}_bytes"
    {pos, hash} = :ets.first(table)
    [{_key, descriptor}] = :ets.lookup(table, {pos, hash})
    drop_entry(state, queue, pos, hash)
    state = Map.update!(state, bytes_field, &(&1 - descriptor.size_bytes))
    {descriptor, state}
  end

  defp emit_reconciliation_evictions(_state, []), do: :ok

  defp emit_reconciliation_evictions(state, descriptors) do
    # Select and delete together before yielding to replacements and hits.
    victims = Enum.map(descriptors, &full_eviction_victim/1)
    opts = [root: state.root, path_prefix: state.path_prefix]
    FileSystem.delete_victims(victims, opts)

    bytes = Enum.reduce(descriptors, 0, fn descriptor, acc -> acc + descriptor.size_bytes end)

    Telemetry.execute(
      tel_opts(state),
      [:cache, :eviction, :stop],
      %{count: length(descriptors), bytes: bytes},
      %{trigger: :reconcile, pool: state.pool}
    )

    :ok
  end
end
