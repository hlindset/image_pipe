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
      :node_id,
      :state_dir,
      :max_size_bytes,
      :window_budget,
      :sketch_depth,
      :sketch_width,
      :aging_sample_size,
      :doorkeeper_cardinality,
      :doorkeeper_fpr,
      :eviction_victim_limit,
      :local_cms,
      :boot_cms,
      # %Talan.BloomFilter{}
      :doorkeeper,
      :flush_interval_ms,
      :cleanup_interval_ms,
      :reconcile_interval_ms,
      :state_ttl_ms,
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
      # Keys dropped, deleted or committed while the startup scan runs, so a
      # stale scanned descriptor for them is skipped. nil once the scan ends.
      scan_changes: nil,
      window_bytes: 0,
      probationary_bytes: 0,
      protected_bytes: 0,
      next_position: 1,
      state_dirty: false,
      # Restored at warm-start and consumed by the directory scan.
      persisted_protected_hashes: [],
      # Monitor the scan so a crash releases await_scan/2 callers. scan_waiters
      # holds their GenServer.call `from` tags until completion or failure.
      scan_task: nil,
      scan_task_ref: nil,
      scan_complete?: false,
      scan_waiters: [],
      reconciling?: false,
      reconcile_waiters: [],
      reconcile_tick_pending?: false
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :root), Keyword.fetch!(opts, :node_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  defp via_tuple(opts) do
    registry = Keyword.fetch!(opts, :registry)
    root = Keyword.fetch!(opts, :root)
    node_id = Keyword.fetch!(opts, :node_id)
    {:via, Registry, {registry, {root, node_id}}}
  end

  @impl true
  def init(opts) do
    # Trap exits so terminate/2 runs on a supervisor :shutdown and can
    # flush dirty state synchronously. A plain GenServer does not call
    # terminate/2 on shutdown unless it is trapping exits.
    Process.flag(:trap_exit, true)

    max_size = Keyword.fetch!(opts, :max_size_bytes)
    window_ratio = Keyword.fetch!(opts, :window_ratio)
    sketch_depth = Keyword.fetch!(opts, :sketch_depth)
    sketch_width = Keyword.fetch!(opts, :sketch_width)
    # Aging cadence is decoupled from width (Sketch.new/1 docs). Fall back to
    # width * 10 only for direct-start unit tests that don't pass it.
    aging_sample_size = Keyword.get(opts, :aging_sample_size, sketch_width * 10)
    doorkeeper_cardinality = Keyword.fetch!(opts, :doorkeeper_cardinality)
    doorkeeper_fpr = Keyword.fetch!(opts, :doorkeeper_fpr)

    state = %State{
      registry: Keyword.fetch!(opts, :registry),
      root: Keyword.fetch!(opts, :root),
      node_id: Keyword.fetch!(opts, :node_id),
      state_dir: Keyword.fetch!(opts, :state_dir),
      # Scan the same partition root the adapter writes to.
      path_prefix: Keyword.get(opts, :path_prefix, ""),
      max_size_bytes: max_size,
      window_budget: trunc(max_size * window_ratio),
      sketch_depth: sketch_depth,
      sketch_width: sketch_width,
      aging_sample_size: aging_sample_size,
      doorkeeper_cardinality: doorkeeper_cardinality,
      doorkeeper_fpr: doorkeeper_fpr,
      # Bound eviction fan-out, including direct starts without adapter defaults.
      eviction_victim_limit: Keyword.get(opts, :eviction_victim_limit, 64),
      local_cms:
        Sketch.new(depth: sketch_depth, width: sketch_width, sample_size: aging_sample_size),
      boot_cms:
        Sketch.new(depth: sketch_depth, width: sketch_width, sample_size: aging_sample_size),
      doorkeeper: Doorkeeper.new(doorkeeper_cardinality, doorkeeper_fpr),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, 30_000),
      cleanup_interval_ms: Keyword.get(opts, :cleanup_interval_ms, 3_600_000),
      reconcile_interval_ms: Keyword.get(opts, :reconcile_interval_ms, 60_000),
      state_ttl_ms: Keyword.get(opts, :state_ttl_ms, 604_800_000),
      telemetry_prefix: Keyword.get(opts, :telemetry_prefix, Telemetry.default_prefix()),
      pool: Keyword.get(opts, :pool, :output),
      # Only the GenServer writes; :protected permits cross-process inspection.
      window: :ets.new(:window, [:ordered_set, :protected]),
      probationary: :ets.new(:probationary, [:ordered_set, :protected]),
      protected: :ets.new(:protected, [:ordered_set, :protected]),
      index: :ets.new(:index, [:set, :protected]),
      scan_changes: :ets.new(:scan_changes, [:set, :private])
    }

    state =
      Telemetry.span(tel_opts(state), [:cache, :warm_start], %{pool: state.pool}, fn ->
        {own_state, loaded?} = load_own_state(state)
        {load_peer_state(own_state), warm_start_meta(state, loaded?)}
      end)

    {:ok, state, {:continue, :schedule_tickers}}
  end

  # Lifecycle telemetry opts. Admission has no per-request telemetry opts, so
  # events fire under the prefix captured at init.
  defp tel_opts(state), do: [telemetry_prefix: state.telemetry_prefix]

  defp warm_start_meta(state, own_loaded?) do
    own = "#{state.node_id}.state"

    peer_count =
      case File.ls(state.state_dir) do
        {:ok, files} ->
          Enum.count(files, &(String.ends_with?(&1, ".state") and &1 != own))

        {:error, _} ->
          0
      end

    %{own_state_loaded: own_loaded?, peer_state_files: peer_count}
  end

  defp load_own_state(state) do
    path = Path.join(state.state_dir, "#{state.node_id}.state")

    case File.read(path) do
      {:ok, binary} ->
        case decode_state_payload(binary, state) do
          {:ok, payload} ->
            {apply_own_state(state, payload), true}

          {:error, reason} ->
            require Logger
            # Reason only: the state filename embeds node_id + storage root.
            Logger.warning(
              "cache: own state file decode failed: reason=#{inspect(reason)}; cold boot"
            )

            {state, false}
        end

      {:error, :enoent} ->
        {state, false}

      {:error, reason} ->
        require Logger
        Logger.warning("cache: own state file read failed: reason=#{inspect(reason)}; cold boot")
        {state, false}
    end
  end

  defp load_peer_state(state) do
    case File.ls(state.state_dir) do
      {:ok, files} ->
        own = "#{state.node_id}.state"
        now = System.system_time(:millisecond)
        Enum.reduce(files, state, &maybe_merge_peer_file(&1, &2, own, now))

      {:error, _} ->
        state
    end
  end

  defp maybe_merge_peer_file(filename, state, own, now) do
    if String.ends_with?(filename, ".state") and filename != own and
         within_ttl?(state, filename, now) do
      merge_peer_file(state, filename)
    else
      state
    end
  end

  defp within_ttl?(state, filename, now_ms) do
    case File.stat(Path.join(state.state_dir, filename), time: :posix) do
      {:ok, %{mtime: mtime}} -> now_ms - mtime * 1000 < state.state_ttl_ms
      _ -> false
    end
  end

  defp merge_peer_file(state, filename) do
    path = Path.join(state.state_dir, filename)

    with {:ok, binary} <- File.read(path),
         {:ok, payload} <- decode_state_payload(binary, state) do
      %{state | boot_cms: Sketch.sum(state.boot_cms, payload.sketch)}
    else
      {:error, reason} ->
        require Logger
        # Path omitted (embeds peer node_id + storage root). Reason only.
        Logger.warning("cache: peer state merge failed: reason=#{inspect(reason)}")
        state
    end
  end

  defp decode_state_payload(binary, state) do
    payload = :erlang.binary_to_term(binary, [:safe])

    with {:ok, payload} <- validate_state_payload(payload),
         {:ok, sketch} <-
           Sketch.deserialize(payload.sketch,
             depth: state.sketch_depth,
             width: state.sketch_width,
             sample_size: state.aging_sample_size
           ) do
      {:ok, %{payload | sketch: sketch}}
    end
  rescue
    ArgumentError -> {:error, :decode_failed}
  end

  defp validate_state_payload(
         %{
           format_version: 1,
           node_id: node_id,
           written_at: written_at,
           aging_epoch: aging_epoch,
           increments_since_reset: increments_since_reset,
           sketch: sketch,
           protected_hashes: protected_hashes
         } = payload
       )
       when is_binary(node_id) and is_integer(written_at) and
              is_integer(aging_epoch) and aging_epoch >= 0 and
              is_integer(increments_since_reset) and increments_since_reset >= 0 and
              is_binary(sketch) and is_list(protected_hashes) do
    if Enum.all?(protected_hashes, &is_binary/1) do
      {:ok, payload}
    else
      {:error, :invalid_protected_hashes}
    end
  end

  defp validate_state_payload(%{format_version: v}),
    do: {:error, {:unsupported_format_version, v}}

  defp validate_state_payload(_other), do: {:error, :invalid_shape}

  defp apply_own_state(state, payload) do
    # Rebuild the doorkeeper from traffic. The directory scan restores protected
    # hashes into ETS.
    %{state | local_cms: payload.sketch, persisted_protected_hashes: payload.protected_hashes}
  end

  @impl true
  def handle_continue(:schedule_tickers, state) do
    # Only this process writes its own state temps, and it hasn't flushed yet,
    # so any left over are from a previous run.
    remove_own_state_temps(state)

    # Capture Admission's pid before spawning. An unlinked, monitored scan can
    # fail without crashing Admission; its :DOWN releases await_scan waiters.
    # This short-lived worker needs no per-cache Task.Supervisor registration.
    admission_pid = self()
    {scan_pid, scan_ref} = spawn_monitor(fn -> scan_directory(state, admission_pid) end)
    state = %{state | scan_task: scan_pid, scan_task_ref: scan_ref}

    Process.send_after(self(), :flush, state.flush_interval_ms)
    Process.send_after(self(), :cleanup, state.cleanup_interval_ms)
    Process.send_after(self(), :reconcile, state.reconcile_interval_ms)
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
    {listings, descriptor_map} = read_entries(entry_root)

    # Phase A: insert protected entries in persisted LRU→MRU order.
    protected_hashes = state.persisted_protected_hashes

    GenServer.call(
      admission_pid,
      {:apply_protected_batch, protected_hashes, descriptor_map},
      :infinity
    )

    # Phase B: insert remaining entries (those not in protected_hashes)
    # in mtime order. Batches of 100 to bound per-call latency.
    protected_set = MapSet.new(protected_hashes)

    remaining =
      descriptor_map
      |> Enum.reject(fn {hash, _entry} -> MapSet.member?(protected_set, hash) end)
      |> Enum.map(fn {_hash, entry} -> entry end)
      |> Enum.sort_by(fn %{mtime: mtime} -> mtime end)

    Enum.chunk_every(remaining, 100)
    |> Enum.each(&GenServer.call(admission_pid, {:apply_scan_batch, &1}, :infinity))

    # Phase C: post-scan reconciliation. If total bytes ended up over
    # cap (operator lowered cap, previous run wrote past soft cap),
    # evict by LRU until under budget. No score gate — these are
    # already-cached entries with no candidate to compare against.
    GenServer.call(admission_pid, :reconcile_to_cap, :infinity)

    # Phase D: remove files a VM that died left behind.
    Sweep.run_listings(listings, state.pool, tel_opts(state))

    GenServer.call(admission_pid, :scan_complete, :infinity)
  end

  # One pass lists each two-level partition once, a first-level group per
  # task. The listings feed both the descriptor reads and the leftover sweep.
  defp read_entries(entry_root) do
    entry_root
    |> Sweep.partitions()
    |> Task.async_stream(&read_partition_group/1,
      max_concurrency: System.schedulers_online(),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce({[], %{}}, fn {:ok, {listings, descriptors}}, {all_listings, all} ->
      {listings ++ all_listings, Map.merge(all, descriptors)}
    end)
  end

  defp read_partition_group(dir) do
    listings = for partition <- Sweep.partitions(dir), do: Sweep.listing(partition)

    descriptors =
      for {partition, names} <- listings,
          name <- names,
          String.ends_with?(name, ".meta"),
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
  def handle_info(:flush, state) do
    state = maybe_flush(state)
    Process.send_after(self(), :flush, state.flush_interval_ms)
    {:noreply, state}
  end

  def handle_info(:cleanup, state) do
    state = cleanup_stale_peer_files(state)
    Process.send_after(self(), :cleanup, state.cleanup_interval_ms)
    {:noreply, state}
  end

  def handle_info({:recheck_gone, key_hash}, state) do
    case locate(state, key_hash) do
      nil -> {:noreply, state}
      located -> {:noreply, resync(state, located)}
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
  # A node evicting an entry renames its metadata aside for a moment to check
  # it (Store.delete_victims/2), so a miss is checked again later rather than
  # trusted at once.
  @gone_recheck_ms 1_000

  def handle_cast({:gone, key_hash}, state) do
    if already_tracked?(state, key_hash),
      do: Process.send_after(self(), {:recheck_gone, key_hash}, @gone_recheck_ms)

    {:noreply, state}
  end

  def handle_cast({:hit, descriptor}, state) do
    state = sighting(state, descriptor.key_hash)
    state = on_hit_promote_or_synthesize(state, descriptor)
    {:noreply, %{state | state_dirty: true}}
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
    state =
      Enum.reduce(batch, state, fn entry, acc ->
        if already_tracked?(acc, entry.key_hash) or scan_changed?(acc, entry.key_hash) do
          acc
        else
          insert_scan_descriptor(acc, entry)
        end
      end)

    {:reply, :ok, state}
  end

  def handle_call({:apply_protected_batch, hashes, descriptor_map}, _from, state) do
    state = Enum.reduce(hashes, state, &apply_protected_hash(&1, &2, descriptor_map))
    {:reply, :ok, state}
  end

  def handle_call(:reconcile_to_cap, from, state) do
    state = %{state | reconcile_waiters: [from | state.reconcile_waiters]}
    {:noreply, start_reconciliation(state)}
  end

  defp apply_protected_hash(hash, state, descriptor_map) do
    case Map.fetch(descriptor_map, hash) do
      {:ok, entry} ->
        if already_tracked?(state, hash) or scan_changed?(state, hash) do
          state
        else
          # Drop the scan-only `:mtime` field so queued descriptors
          # have the same shape regardless of which queue they land in.
          descriptor = Map.delete(entry, :mtime)
          {pos, state} = next_position(state)
          put_entry(state, :protected, pos, descriptor)
          Map.update!(state, :protected_bytes, &(&1 + descriptor.size_bytes))
        end

      :error ->
        # Persisted protected hash whose meta no longer exists on
        # disk. Skip silently — same-key delete or external sweep.
        state
    end
  end

  defp decide_admission(state, descriptor) do
    {result, state} =
      case locate(state, descriptor.key_hash) do
        nil -> admit_new(state, descriptor)
        located -> same_key_replace(state, descriptor, located)
      end

    {result, %{state | state_dirty: true}}
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
        freq_fn = fn key_hash ->
          Sketch.estimate(state.local_cms, key_hash) + Sketch.estimate(state.boot_cms, key_hash)
        end

        if Policy.admit?(descriptor, victim_descriptors, freq_fn) do
          admit_evicting(state, descriptor, victim_descriptors)
        else
          {{:reject, :score_too_low}, state}
        end
    end
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

  defp ordered_set_to_list(table) do
    :ets.foldr(fn {_pos_and_hash, descriptor}, acc -> [descriptor | acc] end, [], table)
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
        %{state | local_cms: Sketch.increment(state.local_cms, key_hash)}
      else
        # talan's put/2 mutates the underlying :atomics ref in place and
        # returns :ok.
        :ok = Talan.BloomFilter.put(state.doorkeeper, key_hash)
        state
      end

    if Sketch.should_age?(state.local_cms) do
      # Doorkeeper reset = discard the current filter and allocate a
      # fresh one. The old :atomics ref becomes unreferenced and is
      # garbage-collected. This is cheap (one allocation per aging cycle,
      # which is itself infrequent).
      fresh_doorkeeper = Doorkeeper.new(state.doorkeeper_cardinality, state.doorkeeper_fpr)

      %{
        state
        | local_cms: Sketch.age(state.local_cms),
          boot_cms: Sketch.age(state.boot_cms),
          doorkeeper: fresh_doorkeeper,
          state_dirty: true
      }
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

  defp enforce_protected_target(state) do
    main_budget = state.max_size_bytes - state.window_budget
    target = trunc(main_budget * 0.20)

    if state.protected_bytes > target and :ets.info(state.protected, :size) > 0 do
      first_key = :ets.first(state.protected)
      [{{old_pos, key_hash}, descriptor}] = :ets.lookup(state.protected, first_key)
      drop_entry(state, :protected, old_pos, key_hash)
      state = Map.update!(state, :protected_bytes, &(&1 - descriptor.size_bytes))

      {pos, state} = next_position(state)
      put_entry(state, :probationary, pos, descriptor)
      Map.update!(state, :probationary_bytes, &(&1 + descriptor.size_bytes))
    else
      state
    end
  end

  defp maybe_flush(state) do
    if state.state_dirty do
      path = Path.join(state.state_dir, "#{state.node_id}.state")
      tmp_path = path <> ".tmp.#{System.unique_integer([:positive])}"
      payload = serialize_state(state)

      with :ok <- File.mkdir_p(state.state_dir),
           :ok <- File.write(tmp_path, payload, [:binary]),
           :ok <- File.rename(tmp_path, path) do
        Telemetry.execute(
          tel_opts(state),
          [:cache, :flush, :stop],
          %{bytes: byte_size(payload)},
          %{
            result: :ok,
            pool: state.pool
          }
        )

        %{state | state_dirty: false}
      else
        {:error, reason} ->
          require Logger
          # Log the reason without exposing the host's storage root and node ID.
          Logger.warning("cache: state flush failed: reason=#{inspect(reason)}")
          # Best-effort cleanup of orphaned tmp file
          _ = File.rm(tmp_path)
          # Keep state_dirty: true so the next flush tick retries
          state
      end
    else
      state
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Synchronous flush on shutdown to preserve any state since the
    # last periodic flush. Errors here are logged but do not affect
    # shutdown (we're terminating anyway).
    _ = maybe_flush(state)
    :ok
  end

  defp serialize_state(state) do
    protected_hashes = ordered_set_to_list(state.protected) |> Enum.map(& &1.key_hash)

    # Rebuild the doorkeeper from post-restart traffic; each previously known
    # key's first sighting delays its CMS increment once.
    :erlang.term_to_binary(
      %{
        format_version: 1,
        node_id: state.node_id,
        written_at: System.system_time(:millisecond),
        aging_epoch: state.local_cms.aging_epoch,
        increments_since_reset: state.local_cms.increments_since_reset,
        sketch: Sketch.serialize(state.local_cms),
        protected_hashes: protected_hashes
      },
      [:deterministic]
    )
  end

  defp cleanup_stale_peer_files(state) do
    removed =
      case File.ls(state.state_dir) do
        {:ok, files} ->
          now = System.system_time(:millisecond)
          own = "#{state.node_id}.state"
          Enum.count(files, &maybe_remove_stale_peer_file(state, &1, own, now))

        {:error, _} ->
          0
      end

    Telemetry.execute(tel_opts(state), [:cache, :cleanup, :stop], %{removed: removed}, %{
      pool: state.pool
    })

    state
  end

  # Returns true when a stale peer file was removed (so the caller can count
  # removals for telemetry), false otherwise.
  defp remove_own_state_temps(state) do
    prefix = "#{state.node_id}.state.tmp."

    for file <- ls(state.state_dir),
        String.starts_with?(file, prefix),
        do: File.rm(Path.join(state.state_dir, file))
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, files} -> files
      {:error, _reason} -> []
    end
  end

  defp maybe_remove_stale_peer_file(state, file, own, now) do
    if peer_state_file?(file, own) do
      remove_if_stale(Path.join(state.state_dir, file), now, state.state_ttl_ms)
    else
      false
    end
  end

  # A peer's state file, or a temp a peer left mid-flush.
  defp peer_state_file?(file, own) do
    (String.ends_with?(file, ".state") and file != own) or
      (String.contains?(file, ".state.tmp.") and not String.starts_with?(file, own <> ".tmp."))
  end

  defp remove_if_stale(path, now, ttl_ms) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        age_ms = now - mtime * 1000

        if age_ms > ttl_ms do
          File.rm(path)
          true
        else
          false
        end

      _ ->
        false
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
