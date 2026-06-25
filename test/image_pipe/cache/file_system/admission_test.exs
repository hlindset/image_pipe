defmodule ImagePipe.Cache.FileSystem.AdmissionTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Sketch
  alias ImagePipe.Cache.Key

  setup do
    # Start the per-test Registry and a private tmp cache root. A single setup
    # callback supplies both keys so every test gets a consistent context;
    # there is no second tag-gated setup to race with.
    registry_name = :"#{__MODULE__}.Registry"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    tmp_dir = Path.join(System.tmp_dir!(), "admission_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{registry: registry_name, tmp_dir: tmp_dir}
  end

  test "start_link registers the process under {root, node_id}", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    opts = [
      registry: registry,
      root: tmp_dir,
      node_id: "test-node",
      max_size_bytes: 1_000_000,
      window_ratio: 0.01,
      sketch_depth: 4,
      sketch_width: 256,
      doorkeeper_cardinality: 1024,
      doorkeeper_fpr: 0.01,
      state_dir: Path.join(tmp_dir, ".cache_state")
    ]

    pid = start_supervised!({Admission, opts})
    assert is_pid(pid)

    assert [{^pid, _}] = Registry.lookup(registry, {tmp_dir, "test-node"})
  end

  test "hit/2 marks the key in doorkeeper on first sighting, increments CMS on second",
       %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, sketch_width: 64)
    pid = start_supervised!({Admission, opts})

    descriptor = %{key_hash: "key-1", size_bytes: 100, body_sha256: "s", cost_us: 1_000}

    Admission.hit(pid, descriptor)
    state = :sys.get_state(pid)
    assert Talan.BloomFilter.member?(state.doorkeeper, "key-1")
    assert Sketch.estimate(state.local_cms, "key-1") == 0

    Admission.hit(pid, descriptor)
    state = :sys.get_state(pid)
    assert Sketch.estimate(state.local_cms, "key-1") >= 1
  end

  test "hit/2 on untracked key synthesizes a probationary entry from the descriptor",
       %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    descriptor = %{key_hash: "cold", size_bytes: 5_000, body_sha256: "s", cost_us: 1_000}
    Admission.hit(pid, descriptor)
    state = :sys.get_state(pid)

    assert in_queue?(state.probationary, "cold")
    assert state.probationary_bytes == 5_000
  end

  test "admit/2 inserts a candidate at window MRU when window has room",
       %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    descriptor = %{
      key_hash: "h1",
      size_bytes: 5_000,
      body_sha256: "sha1",
      cost_us: 1_000
    }

    assert {:admit, []} = Admission.admit(pid, descriptor)

    state = :sys.get_state(pid)
    assert state.window_bytes == 5_000
  end

  test "admit/2 hard-rejects candidates larger than max_size_bytes",
       %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    descriptor = %{
      key_hash: "huge",
      # > 1_000_000 cap
      size_bytes: 10_000_000,
      body_sha256: "sha",
      cost_us: 1_000
    }

    assert {:reject, :over_cap} = Admission.admit(pid, descriptor)
  end

  test "window overflow pushes LRU into main; with free main, evictee goes to probationary", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    # Tiny window so we can force overflow quickly.
    opts =
      base_opts(registry: registry, tmp_dir: tmp_dir, max_size_bytes: 100_000, window_ratio: 0.1)

    pid = start_supervised!({Admission, opts})

    # window_budget = 10_000. Insert 3 × 5_000-byte entries; the third pushes the first out.
    Admission.admit(pid, %{key_hash: "a", size_bytes: 5_000, body_sha256: "sa", cost_us: 1_000})
    Admission.admit(pid, %{key_hash: "b", size_bytes: 5_000, body_sha256: "sb", cost_us: 1_000})

    {:admit, victims} =
      Admission.admit(pid, %{key_hash: "c", size_bytes: 5_000, body_sha256: "sc", cost_us: 1_000})

    # No victims: main had room for "a".
    assert victims == []

    state = :sys.get_state(pid)
    # "b" and "c"
    assert state.window_bytes == 10_000
    # "a" moved into main
    assert state.probationary_bytes == 5_000
  end

  test "same-key re-commit returns body-only victim when body_sha256 differs", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    {:admit, []} =
      Admission.admit(pid, %{
        key_hash: "k",
        size_bytes: 1_000,
        body_sha256: "sha_old",
        cost_us: 1_000
      })

    {:admit, victims} =
      Admission.admit(pid, %{
        key_hash: "k",
        size_bytes: 1_500,
        body_sha256: "sha_new",
        cost_us: 2_000
      })

    # The victim must point at the OLD body (for deletion) but NOT
    # delete the meta — the meta path is identical for old and new
    # entries, and the adapter has just renamed the new meta into
    # place. Deleting the meta would destroy the new entry.
    assert [
             %{
               key_hash: "k",
               body_sha256: "sha_old",
               delete_body?: true,
               delete_meta?: false
             }
           ] = victims
  end

  test "same-key re-commit emits NO victim when body_sha256 matches", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    {:admit, []} =
      Admission.admit(pid, %{
        key_hash: "k",
        size_bytes: 1_000,
        body_sha256: "same_sha",
        cost_us: 1_000
      })

    {:admit, victims} =
      Admission.admit(pid, %{
        key_hash: "k",
        size_bytes: 1_000,
        body_sha256: "same_sha",
        cost_us: 1_500
      })

    # Content-identical rewrite: nothing to delete (the body file path
    # is the same as the just-renamed candidate body).
    assert victims == []
  end

  test "same-key replacement rejected when new size exceeds max_size_bytes", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, max_size_bytes: 10_000)
    pid = start_supervised!({Admission, opts})

    {:admit, []} =
      Admission.admit(pid, %{key_hash: "k", size_bytes: 1_000, body_sha256: "sa", cost_us: 1_000})

    assert {:reject, :over_cap} =
             Admission.admit(pid, %{
               key_hash: "k",
               size_bytes: 20_000,
               body_sha256: "sb",
               cost_us: 1_000
             })

    state = :sys.get_state(pid)
    # Old entry still tracked
    assert in_queue?(state.window, "k") or in_queue?(state.probationary, "k") or
             in_queue?(state.protected, "k")
  end

  test "hit on probationary promotes to protected", %{registry: registry, tmp_dir: tmp_dir} do
    # Use small main budget so we can observe queue movement
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, max_size_bytes: 100_000)
    pid = start_supervised!({Admission, opts})

    descriptor = %{key_hash: "k", size_bytes: 5_000, body_sha256: "s", cost_us: 1_000}
    {:admit, []} = Admission.admit(pid, descriptor)

    # Force window→main by overflowing window
    Admission.admit(pid, %{
      key_hash: "filler",
      size_bytes: 1_000,
      body_sha256: "f",
      cost_us: 1_000
    })

    # hit/2 takes a full descriptor (Task 13); on a tracked key the
    # promote path uses the located descriptor and ignores these fields.
    # Promotion probationary → protected is not frequency-gated, so the
    # first hit already moves "k"; the second hit exercises the
    # protected → protected MRU path. `_ = :sys.get_state(pid)` between
    # casts ensures the first cast is processed before the second.
    Admission.hit(pid, descriptor)
    _ = :sys.get_state(pid)

    Admission.hit(pid, descriptor)
    state = :sys.get_state(pid)

    assert in_queue?(state.protected, "k")
    refute in_queue?(state.probationary, "k")
  end

  test "aging triggers when local CMS sample threshold is hit", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, sketch_width: 4)
    pid = start_supervised!({Admission, opts})

    # Threshold = 4 * 10 = 40 sightings
    # First sighting goes to doorkeeper; subsequent 39+ go to CMS.
    descriptor = %{key_hash: "k", size_bytes: 100, body_sha256: "s", cost_us: 1_000}
    Enum.each(1..50, fn _ -> Admission.hit(pid, descriptor) end)

    # synchronize
    state = :sys.get_state(pid)
    assert state.local_cms.aging_epoch >= 1
  end

  test "flush ticker writes the state file when state is dirty", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, flush_interval_ms: 50)
    pid = start_supervised!({Admission, opts})

    Admission.hit(pid, %{key_hash: "k1", size_bytes: 100, body_sha256: "s", cost_us: 1_000})
    send(pid, :flush)
    :sys.get_state(pid)

    state_file = Path.join([tmp_dir, ".cache_state", "test-node.state"])
    assert File.exists?(state_file)
  end

  test "flush errors log + emit telemetry without crashing Admission", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    # Configure state_dir to a path that can't be written to (e.g., a
    # file masquerading as a directory). Trigger flush; assert Admission
    # is still alive and serving.
    bad_state_dir = Path.join(tmp_dir, "blocker")
    # regular file, not a directory
    File.touch!(bad_state_dir)

    opts =
      base_opts(registry: registry, tmp_dir: tmp_dir)
      |> Keyword.put(:state_dir, bad_state_dir)

    pid = start_supervised!({Admission, opts})

    Admission.hit(pid, %{key_hash: "k1", size_bytes: 100, body_sha256: "s", cost_us: 1_000})
    send(pid, :flush)
    # process still alive
    assert :sys.get_state(pid)
  end

  test "terminate/2 flushes dirty state synchronously", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    Admission.hit(pid, %{key_hash: "k1", size_bytes: 100, body_sha256: "s", cost_us: 1_000})
    # Ensure the hit cast (which marks state_dirty) is processed before stop.
    _ = :sys.get_state(pid)

    # Cleanly stop the supervisor and assert the state file landed.
    # child_spec/1 sets a composite id {module, root, node_id}, so
    # stop_supervised/1 must use that id rather than the bare module.
    ref = Process.monitor(pid)
    :ok = stop_supervised({Admission, tmp_dir, "test-node"})
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    state_file = Path.join([tmp_dir, ".cache_state", "test-node.state"])
    assert File.exists?(state_file)
  end

  test "boot warm-starts from own state file (CMS restored; doorkeeper starts empty)", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    state_dir = Keyword.fetch!(opts, :state_dir)
    File.mkdir_p!(state_dir)

    sketch =
      Sketch.new(depth: 4, width: 256)
      |> Sketch.increment("hot-key")
      |> Sketch.increment("hot-key")

    payload =
      :erlang.term_to_binary(
        %{
          format_version: 1,
          node_id: "test-node",
          written_at: System.system_time(:millisecond),
          aging_epoch: 0,
          increments_since_reset: 2,
          sketch: Sketch.serialize(sketch),
          protected_hashes: []
        },
        [:deterministic]
      )

    File.write!(Path.join(state_dir, "test-node.state"), payload)

    pid = start_supervised!({Admission, opts})
    state = :sys.get_state(pid)

    assert Sketch.estimate(state.local_cms, "hot-key") >= 1
    # Doorkeeper is intentionally not persisted; it boots empty.
    refute Talan.BloomFilter.member?(state.doorkeeper, "hot-key")
  end

  test "boot merges peer state files into boot_cms", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    state_dir = Keyword.fetch!(opts, :state_dir)
    File.mkdir_p!(state_dir)

    peer_sketch =
      Sketch.new(depth: 4, width: 256)
      |> Sketch.increment("global-hot")
      |> Sketch.increment("global-hot")
      |> Sketch.increment("global-hot")

    peer_payload =
      :erlang.term_to_binary(
        %{
          format_version: 1,
          node_id: "peer-1",
          written_at: System.system_time(:millisecond),
          aging_epoch: 0,
          increments_since_reset: 3,
          sketch: Sketch.serialize(peer_sketch),
          protected_hashes: []
        },
        [:deterministic]
      )

    File.write!(Path.join(state_dir, "peer-1.state"), peer_payload)

    pid = start_supervised!({Admission, opts})
    state = :sys.get_state(pid)

    assert Sketch.estimate(state.boot_cms, "global-hot") >= 1
  end

  test "boot tolerates a corrupt own state file and cold-boots", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    state_dir = Keyword.fetch!(opts, :state_dir)
    File.mkdir_p!(state_dir)

    # Garbage that is not a valid term_to_binary payload. decode_state_payload/2
    # uses binary_to_term(_, [:safe]) and must not crash the GenServer; the
    # process boots with an empty CMS instead.
    File.write!(Path.join(state_dir, "test-node.state"), "not a valid erlang term <<>>")

    pid = start_supervised!({Admission, opts})
    state = :sys.get_state(pid)

    assert Sketch.estimate(state.local_cms, "anything") == 0
    assert state.probationary_bytes == 0
  end

  test "window_ratio 0.0 disables the window; admits land in the main gate", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, window_ratio: 0.0)
    pid = start_supervised!({Admission, opts})

    descriptor = %{key_hash: "no-window", size_bytes: 5_000, body_sha256: "s", cost_us: 1_000}
    assert {:admit, []} = Admission.admit(pid, descriptor)

    state = :sys.get_state(pid)
    # window_budget == 0, so the candidate skips the window entirely and is
    # admitted straight into probationary by the main gate.
    assert state.window_bytes == 0
    assert in_queue?(state.probationary, "no-window")
    assert state.probationary_bytes == 5_000
  end

  test "background scan inserts on-disk entries into probationary", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    # Pre-place a real entry on disk via the FileSystem adapter so the
    # meta payload is valid for read_descriptor/1.
    put_disk_entry(tmp_dir, hex_hash("a"), "encoded image body")

    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    Admission.await_scan(pid, 5_000)

    state = :sys.get_state(pid)
    assert state.probationary_bytes > 0
    assert in_queue?(state.probationary, hex_hash("a"))
  end

  test "scan does not overwrite a key already inserted by runtime traffic", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    hash = hex_hash("b")
    # Pre-place an entry on disk with one size.
    put_disk_entry(tmp_dir, hash, "old-on-disk-body")

    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    # Immediately admit a different descriptor for the same key. The admit
    # call is processed before the scan's apply-batch call (both are
    # GenServer.call, serialized by the mailbox), establishing runtime
    # presence ahead of the scan reaching this key.
    runtime_descriptor = %{
      key_hash: hash,
      size_bytes: 4_321,
      body_sha256: "runtime_sha",
      cost_us: 1_000
    }

    {:admit, _} = Admission.admit(pid, runtime_descriptor)

    Admission.await_scan(pid, 5_000)

    state = :sys.get_state(pid)
    # The runtime descriptor survives; the scan did not overwrite it with
    # the on-disk descriptor (which has a different size and body_sha256).
    located = locate_descriptor(state, hash)
    assert located.size_bytes == 4_321
    assert located.body_sha256 == "runtime_sha"
  end

  test "protected entries are restored in LRU-to-MRU order from persisted state", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    older = hex_hash("abcd")
    newer = hex_hash("ef01")

    # Pre-place meta files for both hashes on disk.
    put_disk_entry(tmp_dir, older, "older-body")
    put_disk_entry(tmp_dir, newer, "newer-body")

    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    state_dir = Keyword.fetch!(opts, :state_dir)
    File.mkdir_p!(state_dir)

    sketch = Sketch.new(depth: 4, width: 256)

    # protected_hashes are persisted LRU→MRU.
    payload =
      :erlang.term_to_binary(
        %{
          format_version: 1,
          node_id: "test-node",
          written_at: System.system_time(:millisecond),
          aging_epoch: 0,
          increments_since_reset: 0,
          sketch: Sketch.serialize(sketch),
          protected_hashes: [older, newer]
        },
        [:deterministic]
      )

    File.write!(Path.join(state_dir, "test-node.state"), payload)

    pid = start_supervised!({Admission, opts})
    Admission.await_scan(pid, 5_000)

    state = :sys.get_state(pid)

    # Read ordered_set positions; older must precede newer (LRU at front).
    ordered =
      :ets.tab2list(state.protected)
      |> Enum.sort_by(fn {{pos, _hash}, _descriptor} -> pos end)
      |> Enum.map(fn {{_pos, hash}, _descriptor} -> hash end)

    assert ordered == [older, newer]
  end

  test "boot reconciliation evicts LRU until usage is under cap", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    # Place several entries on disk whose total exceeds a small cap.
    h1 = hex_hash("c1")
    h2 = hex_hash("c2")
    h3 = hex_hash("c3")

    body = String.duplicate("x", 4_000)
    put_disk_entry(tmp_dir, h1, body)
    put_disk_entry(tmp_dir, h2, body)
    put_disk_entry(tmp_dir, h3, body)

    # max_size_bytes small enough that all three (12_000 bytes) overshoot.
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, max_size_bytes: 9_000)
    pid = start_supervised!({Admission, opts})
    Admission.await_scan(pid, 5_000)

    state = :sys.get_state(pid)
    total = state.window_bytes + state.probationary_bytes + state.protected_bytes
    assert total <= 9_000

    # At least one on-disk meta file should have been deleted by reconcile.
    remaining =
      [h1, h2, h3]
      |> Enum.count(fn h ->
        {:ok, paths} = FileSystem.paths_from_hash(h, root: tmp_dir)
        File.exists?(paths.meta_path)
      end)

    assert remaining < 3
  end

  defp hex_hash(seed), do: seed <> String.duplicate("0", 64 - byte_size(seed))

  defp put_disk_entry(root, hash, body) do
    cache_key = %Key{
      hash: hash,
      data: [schema_version: 1]
    }

    metadata =
      struct!(Entry.Metadata,
        content_type: "image/webp",
        headers: [{"vary", "Accept"}],
        created_at: ~U[2026-04-29 10:15:00Z],
        output_format: :webp
      )

    opts = [root: root]
    {:ok, state} = FileSystem.open_sink(cache_key, metadata, opts)
    {:ok, state} = FileSystem.write_chunk(state, body, opts)
    :ok = FileSystem.commit_sink(state, opts)
  end

  # Find the descriptor for a key_hash across all three queues.
  defp locate_descriptor(state, key_hash) do
    [state.window, state.probationary, state.protected]
    |> Enum.find_value(fn table ->
      case :ets.match_object(table, {{:_, key_hash}, :_}) do
        [{_key, descriptor}] -> descriptor
        _ -> nil
      end
    end)
  end

  defp base_opts(overrides) do
    [
      registry: overrides[:registry],
      root: overrides[:tmp_dir],
      node_id: "test-node",
      state_dir: Path.join(overrides[:tmp_dir], ".cache_state"),
      max_size_bytes: overrides[:max_size_bytes] || 1_000_000,
      window_ratio: overrides[:window_ratio] || 0.01,
      sketch_depth: 4,
      sketch_width: overrides[:sketch_width] || 256,
      doorkeeper_cardinality: overrides[:doorkeeper_cardinality] || 1024,
      doorkeeper_fpr: overrides[:doorkeeper_fpr] || 0.01
    ]
  end

  # Test-local introspection helper: reads the GenServer's :protected ETS
  # queue tables by key_hash. Admission's own in_queue?/2 is private.
  defp in_queue?(table, key_hash), do: :ets.match_object(table, {{:_, key_hash}, :_}) != []
end
