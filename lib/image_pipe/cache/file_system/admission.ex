defmodule ImagePipe.Cache.FileSystem.Admission do
  @moduledoc false

  use GenServer

  alias ImagePipe.Cache.FileSystem.Policy
  alias ImagePipe.Cache.FileSystem.Sketch
  alias ImagePipe.Cache.FileSystem.Store, as: FileSystem
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
      scan_waiters: []
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
      doorkeeper:
        Talan.BloomFilter.new(doorkeeper_cardinality, false_positive_probability: doorkeeper_fpr),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, 30_000),
      cleanup_interval_ms: Keyword.get(opts, :cleanup_interval_ms, 3_600_000),
      reconcile_interval_ms: Keyword.get(opts, :reconcile_interval_ms, 60_000),
      state_ttl_ms: Keyword.get(opts, :state_ttl_ms, 604_800_000),
      telemetry_prefix: Keyword.get(opts, :telemetry_prefix, Telemetry.default_prefix()),
      pool: Keyword.get(opts, :pool, :output),
      # Only the GenServer writes; :protected permits cross-process inspection.
      window: :ets.new(:window, [:ordered_set, :protected]),
      probationary: :ets.new(:probationary, [:ordered_set, :protected]),
      protected: :ets.new(:protected, [:ordered_set, :protected])
    }

    state =
      Telemetry.span(tel_opts(state), [:cache, :warm_start], %{pool: state.pool}, fn ->
        warmed = warm_start(state)
        {warmed, warm_start_meta(state)}
      end)

    {:ok, state, {:continue, :schedule_tickers}}
  end

  # Lifecycle telemetry opts. Admission has no per-request telemetry opts, so
  # events fire under the prefix captured at init.
  defp tel_opts(state), do: [telemetry_prefix: state.telemetry_prefix]

  # Low-cardinality boot summary: whether an own-state file existed and how
  # many peer state files were present. No node ids, paths, or hashes.
  defp warm_start_meta(state) do
    own = "#{state.node_id}.state"

    {own_loaded?, peer_count} =
      case File.ls(state.state_dir) do
        {:ok, files} ->
          own_loaded? = Enum.member?(files, own)
          peer_count = Enum.count(files, &(String.ends_with?(&1, ".state") and &1 != own))
          {own_loaded?, peer_count}

        {:error, _} ->
          {false, 0}
      end

    %{own_state_loaded: own_loaded?, peer_state_files: peer_count}
  end

  defp warm_start(state) do
    state
    |> load_own_state()
    |> load_peer_state()
  end

  defp load_own_state(state) do
    path = Path.join(state.state_dir, "#{state.node_id}.state")

    case File.read(path) do
      {:ok, binary} ->
        case decode_state_payload(binary, state) do
          {:ok, payload} ->
            apply_own_state(state, payload)

          {:error, reason} ->
            require Logger
            # Reason only: the state filename embeds node_id + storage root.
            Logger.warning(
              "cache: own state file decode failed: reason=#{inspect(reason)}; cold boot"
            )

            state
        end

      {:error, :enoent} ->
        state

      {:error, reason} ->
        require Logger
        Logger.warning("cache: own state file read failed: reason=#{inspect(reason)}; cold boot")
        state
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
         {:ok, payload} <- decode_state_payload(binary, state),
         {:ok, peer_sketch} <-
           Sketch.deserialize(payload.sketch,
             depth: state.sketch_depth,
             width: state.sketch_width,
             sample_size: state.aging_sample_size
           ) do
      %{state | boot_cms: Sketch.sum(state.boot_cms, peer_sketch)}
    else
      {:error, reason} ->
        require Logger
        # Path omitted (embeds peer node_id + storage root). Reason only.
        Logger.warning("cache: peer state merge failed: reason=#{inspect(reason)}")
        state
    end
  end

  defp decode_state_payload(binary, _state) do
    payload = :erlang.binary_to_term(binary, [:safe])
    validate_state_payload(payload)
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
    {:ok, sketch} =
      Sketch.deserialize(payload.sketch,
        depth: state.sketch_depth,
        width: state.sketch_width,
        sample_size: state.aging_sample_size
      )

    persisted_protected = Map.get(payload, :protected_hashes, [])

    # Rebuild the doorkeeper from traffic. The directory scan restores protected
    # hashes into ETS.
    %{state | local_cms: sketch, persisted_protected_hashes: persisted_protected}
  end

  @impl true
  def handle_continue(:schedule_tickers, state) do
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
    descriptor_map = build_descriptor_map(entry_root)

    # Phase A: insert protected entries in persisted LRU→MRU order.
    protected_hashes = state.persisted_protected_hashes
    GenServer.call(admission_pid, {:apply_protected_batch, protected_hashes, descriptor_map})

    # Phase B: insert remaining entries (those not in protected_hashes)
    # in mtime order. Batches of 100 to bound per-call latency.
    protected_set = MapSet.new(protected_hashes)

    remaining =
      descriptor_map
      |> Enum.reject(fn {hash, _entry} -> MapSet.member?(protected_set, hash) end)
      |> Enum.map(fn {_hash, entry} -> entry end)
      |> Enum.sort_by(fn %{mtime: mtime} -> mtime end)

    Enum.chunk_every(remaining, 100)
    |> Enum.each(&GenServer.call(admission_pid, {:apply_scan_batch, &1}))

    # Phase C: post-scan reconciliation. If total bytes ended up over
    # cap (operator lowered cap, previous run wrote past soft cap),
    # evict by LRU until under budget. No score gate — these are
    # already-cached entries with no candidate to compare against.
    GenServer.call(admission_pid, :reconcile_to_cap)

    GenServer.call(admission_pid, :scan_complete)
  end

  defp build_descriptor_map(entry_root) do
    walk_meta_files(entry_root)
    |> Enum.flat_map(fn meta_path ->
      case FileSystem.read_descriptor(meta_path) do
        {:ok, descriptor, mtime} ->
          [{descriptor.key_hash, Map.put(descriptor, :mtime, mtime)}]

        {:error, _} ->
          []
      end
    end)
    |> Map.new()
  end

  defp walk_meta_files(entry_root) do
    # Recursively walk <entry_root>/AB/CD/ for *.meta files. Skip the
    # `.cache_state` subdirectory at the root (a sibling, not a child,
    # but defensively skipped in case path_prefix is empty).
    case File.ls(entry_root) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 == ".cache_state"))
        |> Enum.flat_map(&meta_files_in(entry_root, &1))

      {:error, _} ->
        []
    end
  end

  defp meta_files_in(entry_root, entry) do
    path = Path.join(entry_root, entry)

    cond do
      File.dir?(path) -> walk_meta_files(path)
      String.ends_with?(entry, ".meta") -> [path]
      true -> []
    end
  end

  # mtime determines scan insertion order but is not part of queued descriptors.
  defp insert_scan_descriptor(state, entry) do
    descriptor = Map.delete(entry, :mtime)
    {pos, state} = next_position(state)
    :ets.insert(state.probationary, {{pos, descriptor.key_hash}, descriptor})
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

  def handle_info(:reconcile, state) do
    # Reclaim soft-cap overshoot, especially larger same-key replacements that
    # bypass the main gate. Reconciliation evicts by LRU and deletes victim files
    # until usage is within max_size_bytes.
    state = reconcile_to_cap(state, [])
    Process.send_after(self(), :reconcile, state.reconcile_interval_ms)
    {:noreply, state}
  end

  # Release waiters if the scan dies before reporting completion. Normal exit
  # after :scan_complete needs no action; spawn_monitor sends no result message.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{scan_task_ref: ref} = state) do
    if reason != :normal and not state.scan_complete? do
      require Logger
      Logger.warning("cache: directory scan crashed before completion: reason=#{inspect(reason)}")
      Enum.each(state.scan_waiters, &GenServer.reply(&1, :ok))

      {:noreply,
       %{state | scan_complete?: true, scan_waiters: [], scan_task: nil, scan_task_ref: nil}}
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

  @impl true
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

      _located ->
        promote_on_hit(state, descriptor.key_hash)
    end
  end

  defp current_descriptor?(state, descriptor) do
    opts = [root: state.root, path_prefix: state.path_prefix]
    descriptor = Map.delete(descriptor, :mtime)

    with {:ok, paths} <- FileSystem.paths_from_hash(descriptor.key_hash, opts),
         {:ok, ^descriptor, _mtime} <- FileSystem.read_descriptor(paths.meta_path) do
      true
    else
      _missing_or_changed -> false
    end
  end

  @spec admit(pid() | GenServer.name(), map()) ::
          {:admit, [map()]}
          | {:reject, :over_cap | :score_too_low | :no_evictable_victims | :victim_limit_exceeded}
          | {:reject, atom(), [map()]}
  def admit(server, descriptor) do
    GenServer.call(server, {:admit, descriptor})
  end

  def commit(server, prepared, body_filename) do
    GenServer.call(server, {:commit, prepared, body_filename})
  end

  def delete(server, paths), do: GenServer.call(server, {:delete, paths})

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
  def handle_call({:delete, paths}, _from, state) do
    case FileSystem.delete_entry(paths) do
      {:ok, result} -> {:reply, result, forget_entry(state, paths.hash)}
      :miss -> {:reply, :miss, forget_entry(state, paths.hash)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:commit, prepared, body_filename}, _from, state) do
    # Publication, accounting and eviction share the same serialized owner.
    # Failed publication leaves admission queues unchanged.
    case FileSystem.publish_sink(prepared, body_filename) do
      {:ok, descriptor} ->
        {result, state} = admit_descriptor(state, descriptor)
        opts = [root: state.root, path_prefix: state.path_prefix]
        {:reply, finish_commit(result, descriptor, opts), state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:admit, descriptor}, _from, state) do
    {result, state} = admit_descriptor(state, descriptor)
    {:reply, result, state}
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
    {:reply, :ok, %{state | scan_complete?: true, scan_waiters: []}}
  end

  def handle_call({:apply_scan_batch, batch}, _from, state) do
    state =
      Enum.reduce(batch, state, fn entry, acc ->
        if already_tracked?(acc, entry.key_hash) or not current_descriptor?(acc, entry) do
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

  def handle_call(:reconcile_to_cap, _from, state) do
    {:reply, :ok, reconcile_to_cap(state, [])}
  end

  defp apply_protected_hash(hash, state, descriptor_map) do
    case Map.fetch(descriptor_map, hash) do
      {:ok, entry} ->
        if already_tracked?(state, hash) or not current_descriptor?(state, entry) do
          state
        else
          # Drop the scan-only `:mtime` field so queued descriptors
          # have the same shape regardless of which queue they land in.
          descriptor = Map.delete(entry, :mtime)
          {pos, state} = next_position(state)
          :ets.insert(state.protected, {{pos, hash}, descriptor})
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
    :ets.insert(state.window, {{position, descriptor.key_hash}, descriptor})
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
        :ets.delete(state.window, {pos, hash})
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

  defp already_tracked?(state, key_hash) do
    # Search across all queues.
    in_queue?(state.window, key_hash) or in_queue?(state.probationary, key_hash) or
      in_queue?(state.protected, key_hash)
  end

  defp in_queue?(table, key_hash) do
    :ets.match_object(table, {{:_, key_hash}, :_}) != []
  end

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
    :ets.insert(state.probationary, {{position, descriptor.key_hash}, descriptor})
    state = %{state | probationary_bytes: state.probationary_bytes + descriptor.size_bytes}
    {{:admit, []}, state}
  end

  defp identify_and_score(state, descriptor, needed_bytes) do
    probationary_list = ordered_set_to_list(state.probationary)
    protected_list = ordered_set_to_list(state.protected)
    limit = state.eviction_victim_limit

    case Policy.victim_walk(
           probationary_list,
           protected_list,
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
          state = remove_victims(state, victim_descriptors)
          {_result, state} = insert_into_probationary(state, descriptor)
          # Tag victims with full-eviction flags for the adapter.
          tagged = Enum.map(victim_descriptors, &full_eviction_victim/1)
          {{:admit, tagged}, state}
        else
          {{:reject, :score_too_low}, state}
        end
    end
  end

  defp ordered_set_to_list(table) do
    :ets.foldr(fn {_pos_and_hash, descriptor}, acc -> [descriptor | acc] end, [], table)
    |> Enum.reverse()
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
    # Search all queues for the descriptor and remove it. Update byte counters.
    Enum.reduce_while([:window, :probationary, :protected], state, fn queue, acc ->
      table = Map.fetch!(acc, queue)

      case :ets.match_object(table, {{:_, descriptor.key_hash}, :_}) do
        [] ->
          {:cont, acc}

        [{key, _value}] ->
          :ets.delete(table, key)
          bytes_field = :"#{queue}_bytes"
          acc = Map.update!(acc, bytes_field, &(&1 - descriptor.size_bytes))
          {:halt, acc}
      end
    end)
  end

  defp same_key_replace(state, descriptor, {queue, old_position, old_descriptor}) do
    table = Map.fetch!(state, queue)

    # Remove the old entry's bytes from accounting.
    bytes_field = :"#{queue}_bytes"
    state = Map.update!(state, bytes_field, &(&1 - old_descriptor.size_bytes))
    :ets.delete(table, {old_position, descriptor.key_hash})

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
          :ets.insert(table, {{position, descriptor.key_hash}, descriptor})
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
      fresh_doorkeeper =
        Talan.BloomFilter.new(state.doorkeeper_cardinality,
          false_positive_probability: state.doorkeeper_fpr
        )

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

  # Scan the three queues for a key_hash and return `{queue, position,
  # descriptor}`, or nil when the key is untracked. The queue atom lets
  # callers (e.g. promote_on_hit/2) act on the located entry's home queue.
  defp locate(state, key_hash) do
    Enum.find_value([:window, :probationary, :protected], fn queue ->
      table = Map.fetch!(state, queue)

      case :ets.match_object(table, {{:_, key_hash}, :_}) do
        [] -> nil
        [{{pos, _hash}, descriptor}] -> {queue, pos, descriptor}
      end
    end)
  end

  defp next_position(state),
    do: {state.next_position, %{state | next_position: state.next_position + 1}}

  defp promote_on_hit(state, key_hash) do
    case locate(state, key_hash) do
      nil ->
        state

      {:window, pos, descriptor} ->
        move_to_mru(state, :window, pos, descriptor)

      {:probationary, pos, descriptor} ->
        :ets.delete(state.probationary, {pos, key_hash})
        state = Map.update!(state, :probationary_bytes, &(&1 - descriptor.size_bytes))
        insert_into_protected(state, descriptor)

      {:protected, pos, descriptor} ->
        move_to_mru(state, :protected, pos, descriptor)
    end
  end

  defp move_to_mru(state, queue, old_pos, descriptor) do
    table = Map.fetch!(state, queue)
    :ets.delete(table, {old_pos, descriptor.key_hash})
    {pos, state} = next_position(state)
    :ets.insert(table, {{pos, descriptor.key_hash}, descriptor})
    state
  end

  defp insert_into_protected(state, descriptor) do
    {pos, state} = next_position(state)
    :ets.insert(state.protected, {{pos, descriptor.key_hash}, descriptor})
    state = Map.update!(state, :protected_bytes, &(&1 + descriptor.size_bytes))
    enforce_protected_target(state)
  end

  defp enforce_protected_target(state) do
    main_budget = state.max_size_bytes - state.window_budget
    target = trunc(main_budget * 0.20)

    if state.protected_bytes > target and :ets.info(state.protected, :size) > 0 do
      first_key = :ets.first(state.protected)
      [{key, descriptor}] = :ets.lookup(state.protected, first_key)
      :ets.delete(state.protected, key)
      state = Map.update!(state, :protected_bytes, &(&1 - descriptor.size_bytes))

      {pos, state} = next_position(state)
      :ets.insert(state.probationary, {{pos, descriptor.key_hash}, descriptor})
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
  defp maybe_remove_stale_peer_file(state, file, own, now) do
    if String.ends_with?(file, ".state") and file != own do
      remove_if_stale(Path.join(state.state_dir, file), now, state.state_ttl_ms)
    else
      false
    end
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

  defp reconcile_to_cap(state, evicted_descriptors) do
    total = state.window_bytes + state.probationary_bytes + state.protected_bytes

    if total <= state.max_size_bytes do
      # Delete the evicted entries' files. Admission owns deletion here
      # (no request process is in the loop for boot/periodic
      # reconciliation), calling the adapter's `delete_victims/2`
      # in-boundary. See `emit_reconciliation_evictions/2`.
      emit_reconciliation_evictions(state, evicted_descriptors)
      state
    else
      # Evict LRU from probationary first, then protected.
      {evicted, state} = evict_one_lru(state)

      case evicted do
        nil ->
          # No more entries to evict but still over cap. Bug or empty
          # cache with impossibly low max_size_bytes; log and stop.
          require Logger
          Logger.warning("cache: reconciliation cannot bring usage under cap")
          emit_reconciliation_evictions(state, evicted_descriptors)
          state

        descriptor ->
          reconcile_to_cap(state, [descriptor | evicted_descriptors])
      end
    end
  end

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
    :ets.delete(table, {pos, hash})
    state = Map.update!(state, bytes_field, &(&1 - descriptor.size_bytes))
    {descriptor, state}
  end

  defp emit_reconciliation_evictions(_state, []), do: :ok

  defp emit_reconciliation_evictions(state, descriptors) do
    # Reconciliation evictions are full evictions: both body and meta
    # files must go. Admission deletes them directly through the adapter's
    # path helper (both modules live in the `cache` boundary). This is the
    # same inline-I/O posture as `maybe_flush/1`; reconciliation batches
    # are small (bounded by recent overshoot), so blocking the GenServer
    # briefly is acceptable.
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
