defmodule ImagePipe.Cache.FileSystem.AdmissionTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Sketch
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.Key
  alias ImagePipe.Test.Caches

  setup do
    # Start the per-test Registry and a private tmp cache root. A single setup
    # callback supplies both keys so every test gets a consistent context;
    # there is no second tag-gated setup to race with.
    tmp_dir = Path.join(System.tmp_dir!(), "admission_test_#{System.unique_integer([:positive])}")
    registry_name = FileSystem.registry_name(tmp_dir)
    start_supervised!({Registry, keys: :unique, name: registry_name})
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{registry: registry_name, tmp_dir: tmp_dir}
  end

  test "start_link registers the process under its root", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    pid = start_supervised!({Admission, base_opts(registry: registry, tmp_dir: tmp_dir)})
    assert is_pid(pid)

    assert [{^pid, _}] = Registry.lookup(registry, tmp_dir)
  end

  test "hit/2 marks the key in doorkeeper on first sighting, increments CMS on second",
       %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, sketch_width: 64)
    pid = start_supervised!({Admission, opts})

    descriptor = persisted_descriptor(tmp_dir, "key-1")

    Admission.hit(pid, descriptor)
    state = :sys.get_state(pid)
    assert Talan.BloomFilter.member?(state.doorkeeper, descriptor.key_hash)
    assert Sketch.estimate(state.sketch, descriptor.key_hash) == 0

    Admission.hit(pid, descriptor)
    state = :sys.get_state(pid)
    assert Sketch.estimate(state.sketch, descriptor.key_hash) >= 1
  end

  test "miss/2 is a sighting, and the commit that follows it isn't another",
       %{registry: registry, tmp_dir: tmp_dir} do
    pid = start_supervised!({Admission, base_opts(registry: registry, tmp_dir: tmp_dir)})
    Admission.await_scan(pid)
    pool = [root: tmp_dir, max_size_bytes: 1_000_000]

    Admission.miss(pid, hash("new"))
    assert :ok = put_with_cost(pool, "new", 1_000)
    state = :sys.get_state(pid)
    assert Talan.BloomFilter.member?(state.doorkeeper, hash("new"))
    assert Sketch.estimate(state.sketch, hash("new")) == 0

    Admission.miss(pid, hash("new"))
    assert Sketch.estimate(:sys.get_state(pid).sketch, hash("new")) == 1
  end

  test "hit/2 on an untracked persisted key restores its accounting",
       %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})
    Admission.await_scan(pid)
    hash = hex_hash("c")
    put_disk_entry(tmp_dir, hash, "persisted body")
    {:ok, paths} = FileSystem.paths_from_hash(hash, root: tmp_dir)
    {:ok, descriptor, _} = FileSystem.read_descriptor(paths.meta_path)
    Admission.hit(pid, descriptor)

    assert entry_row(pid, hash) ==
             {hash, byte_size("persisted body"), 0, descriptor.body_filename}

    assert stored_bytes(pid) == byte_size("persisted body")
  end

  test "hit/2 on an untracked key deleted since it was read is dropped",
       %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})
    Admission.await_scan(pid)
    hash = hex_hash("f")
    put_disk_entry(tmp_dir, hash, "persisted body")
    {:ok, paths} = FileSystem.paths_from_hash(hash, root: tmp_dir)
    {:ok, descriptor, _} = FileSystem.read_descriptor(paths.meta_path)
    :ok = Store.delete(%Key{hash: hash, data: []}, root: tmp_dir)
    Admission.hit(pid, descriptor)

    assert entry_row(pid, hash) == nil
    assert stored_bytes(pid) == 0
  end

  test "aging triggers when local CMS sample threshold is hit", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, sketch_width: 4)
    pid = start_supervised!({Admission, opts})

    # Threshold = 4 * 10 = 40 sightings
    # First sighting goes to doorkeeper; subsequent 39+ go to CMS.
    descriptor = persisted_descriptor(tmp_dir, "k")
    Enum.each(1..50, fn _ -> Admission.hit(pid, descriptor) end)

    # 49 counted sightings against a threshold of 40: one aging pass reset the
    # count.
    state = :sys.get_state(pid)
    assert state.sketch.increments_since_reset < 40
  end

  test "boot sweeps leftovers after the scan", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)

    dir = Path.join([tmp_dir, "aa", "aa"])
    File.mkdir_p!(dir)
    leftover = Path.join(dir, ".#{String.duplicate("a", 64)}.Ab_c-dE.tmp")
    File.write!(leftover, "bytes")
    File.touch!(leftover, System.os_time(:second) - 7_200)

    pid = start_supervised!({Admission, opts})
    :ok = Admission.await_scan(pid)

    refute File.exists?(leftover)
  end

  test "an entry the startup sweep removes is no longer counted", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    hash = hex_hash("e1")
    put_disk_entry(tmp_dir, hash, String.duplicate("x", 4_000))
    {:ok, paths} = FileSystem.paths_from_hash(hash, root: tmp_dir)
    File.write!(paths.meta_path, "not a term")

    for path <- Path.wildcard(Path.join(paths.dir, "*")),
        do: File.touch!(path, System.os_time(:second) - 7_200)

    pid = start_supervised!({Admission, base_opts(registry: registry, tmp_dir: tmp_dir)})
    :ok = Admission.await_scan(pid)

    assert entry_row(pid, hash) == nil
    assert stored_bytes(pid) == 0
  end

  test "the scan ignores a body name with a signed size", %{registry: registry, tmp_dir: tmp_dir} do
    hash = hex_hash("e2")
    put_disk_entry(tmp_dir, hash, "body")
    {:ok, paths} = FileSystem.paths_from_hash(hash, root: tmp_dir)
    [body] = Path.wildcard(Path.join(paths.dir, "*.body"))

    File.rename!(
      body,
      Path.join(paths.dir, "#{hash}.#{String.duplicate("a", 64)}.-9000000.0.body")
    )

    pid = start_supervised!({Admission, base_opts(registry: registry, tmp_dir: tmp_dir)})
    :ok = Admission.await_scan(pid)

    assert stored_bytes(pid) == 0
  end

  test "a write into a cache over its cap evicts only its own bytes", ctx do
    pid = start_cache(ctx, 10_000)
    pool = [root: ctx.tmp_dir, max_size_bytes: 10_000]
    for i <- 1..10, do: :ok = put_with_cost(pool, "resident-#{i}", 1_000)

    # As after the cap was lowered, before the startup batches catch up. The
    # new entry costs far more, so it wins the admission gate.
    :sys.replace_state(pid, &%{&1 | max_size_bytes: 5_000})

    assert :ok = put_with_cost(pool, "new", 1_000_000)
    assert stored_bytes(pid) == 10_000
  end

  describe "admission gate" do
    setup %{registry: registry, tmp_dir: tmp_dir} do
      opts = base_opts(registry: registry, tmp_dir: tmp_dir, max_size_bytes: 10_000)
      pid = start_supervised!({Admission, opts})
      Admission.await_scan(pid)
      pool = [root: tmp_dir, max_size_bytes: 10_000]
      for i <- 1..10, do: :ok = put_with_cost(pool, "resident-#{i}", 1_000)
      %{pid: pid, pool: pool}
    end

    test "admits a once-seen entry that is costlier per byte than its victim", ctx do
      assert :ok = put_with_cost(ctx.pool, "costly", 100_000)
      assert tracked?(ctx.pid, "costly")
      assert stored_bytes(ctx.pid) == 10_000
    end

    test "rejects a once-seen entry that is cheaper per byte than its victim", ctx do
      assert {:ok, :rejected} = put_with_cost(ctx.pool, "cheap", 10)
      refute tracked?(ctx.pid, "cheap")
      assert stored_bytes(ctx.pid) == 10_000
    end

    test "may admit a losing entry once it has been requested six times", ctx do
      # Make the random admission draw always succeed.
      :sys.replace_state(ctx.pid, &%{&1 | random_admission_one_in: 1})

      for _ <- 1..5 do
        Admission.miss(ctx.pid, hash("cheap"))
        assert {:ok, :rejected} = put_with_cost(ctx.pool, "cheap", 10)
      end

      refute tracked?(ctx.pid, "cheap")

      Admission.miss(ctx.pid, hash("cheap"))
      assert :ok = put_with_cost(ctx.pool, "cheap", 10)
      assert tracked?(ctx.pid, "cheap")
    end
  end

  describe "sampled eviction" do
    test "evicts the lowest-scoring entry", ctx do
      pid = start_cache(ctx, 3_000)
      pool = [root: ctx.tmp_dir, max_size_bytes: 3_000]

      # Scores (frequency × cost / size): a 4 × 1_000, b 1 × 2_000, c 1 × 3_000.
      :ok = put_entry(pool, "a", 1_000, 1_000)
      :ok = put_entry(pool, "b", 1_000, 2_000)
      :ok = put_entry(pool, "c", 1_000, 3_000)
      for _ <- 1..3, do: {:hit, _} = FileSystem.get(key("a"), pool)

      assert :ok = put_entry(pool, "candidate", 1_000, 100_000)

      refute tracked?(pid, "b")
      assert FileSystem.get(key("b"), pool) == :miss
      assert Enum.all?(["a", "c", "candidate"], &tracked?(pid, &1))
      assert stored_bytes(pid) == 3_000
    end

    test "takes the lowest-scoring entries until the write fits", ctx do
      pid = start_cache(ctx, 4_000)
      pool = [root: ctx.tmp_dir, max_size_bytes: 4_000]

      for cost <- [3_000, 1_000, 4_000, 2_000],
          do: :ok = put_entry(pool, "cost-#{cost}", 1_000, cost)

      assert :ok = put_entry(pool, "candidate", 2_500, 1_000_000)

      for cost <- [1_000, 2_000, 3_000] do
        refute tracked?(pid, "cost-#{cost}")
        assert FileSystem.get(key("cost-#{cost}"), pool) == :miss
      end

      assert tracked?(pid, "cost-4000")
      assert tracked?(pid, "candidate")
      assert stored_bytes(pid) == 3_500
    end

    test "a rejected replacement leaves the entry it would replace", ctx do
      pid = start_cache(ctx, 2_000)
      pool = [root: ctx.tmp_dir, max_size_bytes: 2_000]
      old_body = body("a", 1_000)

      :ok = put_entry(pool, "a", 1_000, 1_000_000)
      :ok = put_entry(pool, "b", 1_000, 1_000_000)
      old_row = entry_row(pid, hash("a"))

      assert {:ok, :rejected} = put_entry(pool, "a", 1_500, 1)

      assert {:hit, %{body: ^old_body}} = FileSystem.get(key("a"), pool)
      assert entry_row(pid, hash("a")) == old_row
      assert tracked?(pid, "b")
      assert stored_bytes(pid) == 2_000
    end
  end

  test "background scan builds entries from body filenames", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    hash = hex_hash("a")
    put_disk_entry(tmp_dir, hash, "encoded image body", 1_234)
    {:ok, paths} = FileSystem.paths_from_hash(hash, root: tmp_dir)
    {:ok, descriptor, _mtime} = FileSystem.read_descriptor(paths.meta_path)

    pid = start_supervised!({Admission, base_opts(registry: registry, tmp_dir: tmp_dir)})
    Admission.await_scan(pid, 5_000)

    size = byte_size("encoded image body")
    assert entry_row(pid, hash) == {hash, size, 1_234, descriptor.body_filename}
    assert stored_bytes(pid) == size
  end

  test "background scan reads no metadata for a key with one body", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    hash = hex_hash("a")
    put_disk_entry(tmp_dir, hash, "encoded image body", 1_234)
    {:ok, paths} = FileSystem.paths_from_hash(hash, root: tmp_dir)
    {:ok, descriptor, _mtime} = FileSystem.read_descriptor(paths.meta_path)
    File.write!(paths.meta_path, "not metadata")

    pid = start_supervised!({Admission, base_opts(registry: registry, tmp_dir: tmp_dir)})
    Admission.await_scan(pid, 5_000)

    size = byte_size("encoded image body")
    assert entry_row(pid, hash) == {hash, size, 1_234, descriptor.body_filename}
    assert stored_bytes(pid) == size
  end

  test "scan does not overwrite a key already inserted by runtime traffic", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    hash = hex_hash("b")
    # Pre-place an entry on disk with one size.
    put_disk_entry(tmp_dir, hash, "old-on-disk-body")
    {:ok, paths} = FileSystem.paths_from_hash(hash, root: tmp_dir)
    {:ok, snapshot, _mtime} = FileSystem.read_descriptor(paths.meta_path)
    :ok = Store.delete(%Key{hash: hash, data: []}, root: tmp_dir)

    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    Admission.await_scan(pid, 5_000)
    put_disk_entry(tmp_dir, hash, String.duplicate("x", 4_321))
    {:ok, runtime_descriptor, _} = FileSystem.read_descriptor(paths.meta_path)
    Admission.hit(pid, runtime_descriptor)
    assert :ok = GenServer.call(pid, {:apply_scan_batch, [snapshot]})

    # The runtime entry survives; the scan did not overwrite it with the
    # snapshot, which has a different size and body.
    assert {^hash, 4_321, _cost, body_filename} = entry_row(pid, hash)
    assert body_filename == runtime_descriptor.body_filename
    assert stored_bytes(pid) == 4_321
  end

  # Puts Admission back in the state it keeps while a startup scan runs, so the
  # test can change entries and then apply the snapshot the scan would hold.
  defp during_scan(_ctx, opts, fun) do
    pid = start_supervised!({Admission, opts})
    Admission.await_scan(pid)

    :sys.replace_state(pid, fn state ->
      %{state | scan_changes: :ets.new(:scan_changes, [:set, :private])}
    end)

    fun.(pid)
    pid
  end

  defp snapshot(root, hash) do
    {:ok, paths} = FileSystem.paths_from_hash(hash, root: root)
    {:ok, descriptor, _mtime} = FileSystem.read_descriptor(paths.meta_path)
    {paths, descriptor}
  end

  defp apply_snapshot(pid, entry), do: GenServer.call(pid, {:apply_scan_batch, [entry]})

  test "a scan snapshot of an entry deleted mid-scan is skipped", ctx do
    hash = hex_hash("d")
    opts = base_opts(registry: ctx.registry, tmp_dir: ctx.tmp_dir)

    pid =
      during_scan(ctx, opts, fn pid ->
        put_disk_entry(ctx.tmp_dir, hash, "old body")
        {paths, entry} = snapshot(ctx.tmp_dir, hash)
        assert Admission.delete(pid, paths) == :ok

        assert :ok = apply_snapshot(pid, entry)
        assert stored_bytes(pid) == 0
      end)

    assert stored_bytes(pid) == 0

    assert FileSystem.get(%Key{hash: hash, data: []},
             root: ctx.tmp_dir,
             max_size_bytes: 1_000_000
           ) == :miss
  end

  test "a scan snapshot of an entry evicted mid-scan is skipped", ctx do
    hash = hex_hash("e")
    opts = base_opts(registry: ctx.registry, tmp_dir: ctx.tmp_dir, max_size_bytes: 50)

    during_scan(ctx, opts, fn pid ->
      put_disk_entry(ctx.tmp_dir, hash, String.duplicate("x", 100))
      {_paths, entry} = snapshot(ctx.tmp_dir, hash)

      # A hit tracks the entry before the scan reaches it, and the over-cap
      # entry is then evicted.
      Admission.hit(pid, entry)
      assert stored_bytes(pid) == 100
      assert :ok = GenServer.call(pid, :reconcile_to_cap)
      assert stored_bytes(pid) == 0

      assert :ok = apply_snapshot(pid, entry)
      assert stored_bytes(pid) == 0
    end)
  end

  test "a write rejected mid-scan leaves its key's entry on disk counted", ctx do
    hash = hex_hash("d2")
    opts = base_opts(registry: ctx.registry, tmp_dir: ctx.tmp_dir, max_size_bytes: 1_000)

    pid =
      during_scan(ctx, opts, fn pid ->
        put_disk_entry(ctx.tmp_dir, hash, String.duplicate("x", 500))
        {paths, entry} = snapshot(ctx.tmp_dir, hash)
        pool = [root: ctx.tmp_dir, max_size_bytes: 1_000]

        assert {:ok, :rejected} =
                 put_bytes(pool, %Key{hash: hash, data: []}, String.duplicate("y", 2_000))

        assert :ok = apply_snapshot(pid, entry)
        assert File.exists?(paths.meta_path)
      end)

    assert entry_row(pid, hash) != nil
    assert stored_bytes(pid) == 500
  end

  test "a write replacing an entry the scan hasn't reached deletes the old body", ctx do
    hash = hex_hash("d3")
    opts = base_opts(registry: ctx.registry, tmp_dir: ctx.tmp_dir)

    pid =
      during_scan(ctx, opts, fn pid ->
        put_disk_entry(ctx.tmp_dir, hash, "old body")
        {paths, entry} = snapshot(ctx.tmp_dir, hash)
        pool = [root: ctx.tmp_dir, max_size_bytes: 1_000_000]

        assert :ok = put_bytes(pool, %Key{hash: hash, data: []}, "new body")
        assert :ok = apply_snapshot(pid, entry)

        assert [_one] = Path.wildcard(Path.join(paths.dir, "*.body"))
      end)

    assert stored_bytes(pid) == byte_size("new body")
  end

  test "a stale sweep report doesn't forget an entry committed since", ctx do
    pid = start_cache(ctx, 1_000_000)
    pool = [root: ctx.tmp_dir, max_size_bytes: 1_000_000]
    :ok = put_entry(pool, "a", 700, 1_000)

    # The sweep removed an older, undecodable metadata file for the key before
    # this commit and reports it only now.
    GenServer.cast(pid, {:swept, [{hash("a"), :meta}]})

    assert tracked?(pid, "a")
    assert stored_bytes(pid) == 700
  end

  test "a hit that counts an untracked entry over the cap evicts back under it", ctx do
    pid = start_cache(ctx, 1_000)
    pool = [root: ctx.tmp_dir, max_size_bytes: 1_000]
    for seed <- ["a", "b", "c"], do: :ok = put_entry(pool, seed, 300, 1_000)

    hash = hex_hash("e3")
    put_disk_entry(ctx.tmp_dir, hash, String.duplicate("x", 400))
    {_paths, descriptor} = snapshot(ctx.tmp_dir, hash)
    Admission.hit(pid, descriptor)
    _ = :sys.get_state(pid)

    assert stored_bytes(pid) <= 1_000
  end

  test "a crashed scan still evicts down to the cap", ctx do
    pid = start_cache(ctx, 1_000)
    pool = [root: ctx.tmp_dir, max_size_bytes: 1_000]
    for seed <- ["a", "b", "c"], do: :ok = put_entry(pool, seed, 300, 1_000)
    ref = make_ref()

    # As after the cap was lowered and the scan died before reconciling.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | max_size_bytes: 500,
          scan_task_ref: ref,
          scan_complete?: false,
          scan_changes: :ets.new(:scan_changes, [:set, :private])
      }
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      send(pid, {:DOWN, ref, :process, self(), :boom})
      _ = :sys.get_state(pid)
    end)

    assert stored_bytes(pid) <= 500
  end

  test "boot reconciliation evicts until usage is under cap", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    hashes = for seed <- ["c1", "c2", "c3"], do: hex_hash(seed)
    for hash <- hashes, do: put_disk_entry(tmp_dir, hash, String.duplicate("x", 4_000))

    # All three (12_000 bytes) overshoot the cap; evicting one fits.
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, max_size_bytes: 9_000)
    pid = start_supervised!({Admission, opts})
    Admission.await_scan(pid, 5_000)

    assert stored_bytes(pid) == 8_000

    remaining =
      Enum.filter(hashes, fn hash ->
        {:ok, paths} = FileSystem.paths_from_hash(hash, root: tmp_dir)
        File.exists?(paths.meta_path)
      end)

    assert length(remaining) == 2
    assert Enum.all?(remaining, &(entry_row(pid, &1) != nil))
  end

  test "boot reconciliation evicts the cheapest entry when none has been seen", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
    [cheap, dear_a, dear_b] = for seed <- ["d1", "d2", "d3"], do: hex_hash(seed)
    put_disk_entry(tmp_dir, cheap, String.duplicate("x", 4_000), 1_000)
    put_disk_entry(tmp_dir, dear_a, String.duplicate("x", 4_000), 90_000)
    put_disk_entry(tmp_dir, dear_b, String.duplicate("x", 4_000), 90_000)

    opts = base_opts(registry: registry, tmp_dir: tmp_dir, max_size_bytes: 9_000)
    pid = start_supervised!({Admission, opts})
    Admission.await_scan(pid, 5_000)

    assert entry_row(pid, cheap) == nil
    assert entry_row(pid, dear_a) != nil
    assert entry_row(pid, dear_b) != nil
  end

  defp start_cache(ctx, max_size_bytes) do
    opts = base_opts(registry: ctx.registry, tmp_dir: ctx.tmp_dir, max_size_bytes: max_size_bytes)
    pid = start_supervised!({Admission, opts})
    Admission.await_scan(pid)
    pid
  end

  defp put_with_cost(pool, seed, cost_us), do: put_entry(pool, seed, 1_000, cost_us)

  defp put_entry(pool, seed, size, cost_us),
    do: put_bytes(pool, key(seed), body(seed, size), cost_us)

  defp put_bytes(pool, key, body, cost_us \\ 1_000) do
    metadata =
      struct!(Entry.Metadata,
        content_type: "image/png",
        headers: [],
        output_format: :png,
        created_at: ~U[2026-04-29 10:15:00Z],
        cost_us: cost_us
      )

    with {:ok, sink} <- FileSystem.open_sink(key, metadata, pool),
         {:ok, sink} <- FileSystem.write_chunk(sink, body, pool) do
      FileSystem.commit_sink(sink, pool)
    end
  end

  defp body(seed, size), do: String.pad_leading(seed, size, "x")

  defp key(seed), do: %Key{hash: hash(seed), data: []}

  defp tracked?(pid, seed), do: entry_row(pid, hash(seed)) != nil

  # Admission keeps both hashes raw in its rows. This gives the row back in
  # the hex the rest of the cache uses, with the body filename it stands for.
  defp entry_row(pid, key_hash) do
    case :ets.lookup(:sys.get_state(pid).entries, Base.decode16!(key_hash, case: :lower)) do
      [{_key, size, cost, body_sha256}] ->
        sha = Base.encode16(body_sha256, case: :lower)
        {key_hash, size, cost, FileSystem.Store.body_filename(key_hash, sha, size, cost)}

      [] ->
        nil
    end
  end

  defp stored_bytes(pid), do: :sys.get_state(pid).stored_bytes

  defp hash(seed), do: :crypto.hash(:sha256, seed) |> Base.encode16(case: :lower)

  defp hex_hash(seed), do: seed <> String.duplicate("0", 64 - byte_size(seed))

  defp persisted_descriptor(root, seed) do
    hash = hash(seed)
    put_disk_entry(root, hash, String.duplicate("x", 100))
    {:ok, paths} = FileSystem.paths_from_hash(hash, root: root)
    {:ok, descriptor, _mtime} = FileSystem.read_descriptor(paths.meta_path)
    descriptor
  end

  # Leaves an entry on disk that no Admission tracks, as an earlier run would:
  # it's written through a cache on a staging root and copied into place.
  defp put_disk_entry(root, hash, body, cost_us \\ 0) do
    cache_key = %Key{
      hash: hash,
      data: [schema_version: 1]
    }

    metadata =
      struct!(Entry.Metadata,
        content_type: "image/webp",
        headers: [{"vary", "Accept"}],
        created_at: ~U[2026-04-29 10:15:00Z],
        output_format: :webp,
        cost_us: cost_us
      )

    staging = root <> "_staging"
    paths = Caches.write!([root: staging], cache_key, metadata, body)
    dir = Path.join(root, Path.relative_to(paths.dir, staging))
    File.mkdir_p!(dir)
    File.cp_r!(paths.dir, dir)
    File.rm_rf!(staging)
  end

  # Small sketches, aging every 10 sightings per counter, so tests reach aging
  # and admission decisions quickly.
  defp base_opts(overrides) do
    sketch_width = overrides[:sketch_width] || 256

    Store.admission_options(
      [
        root: overrides[:tmp_dir],
        max_size_bytes: overrides[:max_size_bytes] || 1_000_000,
        sketch_depth: 4,
        sketch_width: sketch_width,
        aging_sample_size: sketch_width * 10,
        doorkeeper_cardinality: overrides[:doorkeeper_cardinality] || 1024,
        doorkeeper_fpr: overrides[:doorkeeper_fpr] || 0.01
      ],
      overrides[:registry]
    )
  end
end
