defmodule ImagePipe.Cache.FileSystemBoundedTest do
  # async: true — each test uses a unique cache root, and the bounded
  # supervision tree derives its Registry name from that root (see
  # FileSystem.registry_name/1), so concurrently-booted trees never clash on a
  # process name.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Key

  defp key(hash \\ String.duplicate("a", 64)) do
    %Key{
      hash: hash,
      data: [schema_version: 1]
    }
  end

  defp entry(body) do
    %Entry{
      body: body,
      content_type: "image/webp",
      headers: [{"vary", "Accept"}],
      created_at: ~U[2026-04-29 10:15:00Z]
    }
  end

  defp entry_metadata(overrides) do
    struct!(
      ImagePipe.Cache.Entry.Metadata,
      Keyword.merge(
        [
          content_type: "image/webp",
          headers: [{"vary", "Accept"}],
          created_at: ~U[2026-04-29 10:15:00Z],
          output_format: :webp
        ],
        overrides
      )
    )
  end

  # Small sketches, like admission_test.exs base_opts/1. The caller supplies
  # :root and :max_size_bytes.
  defp bounded_opts(root, overrides) do
    Keyword.merge(
      [
        root: root,
        max_size_bytes: overrides[:max_size_bytes] || 1_000_000,
        window_ratio: 0.01,
        sketch_depth: 4,
        sketch_width: 256,
        doorkeeper_cardinality: 1024,
        doorkeeper_fpr: 0.01
      ],
      Keyword.drop(overrides, [:max_size_bytes])
    )
  end

  defp put_entry(cache_key, %Entry{} = e, opts) do
    metadata =
      entry_metadata(
        content_type: e.content_type,
        headers: e.headers,
        created_at: e.created_at
      )

    with {:ok, state} <- FileSystem.open_sink(cache_key, metadata, opts),
         {:ok, state} <- FileSystem.write_chunk(state, e.body, opts) do
      FileSystem.commit_sink(state, opts)
    end
  end

  defp admission_pid(root) do
    [{pid, _}] = Registry.lookup(FileSystem.registry_name(root), root)
    pid
  end

  defp body_path(root, cache_key, body) do
    sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    Path.join([root, "aa", "aa", "#{cache_key.hash}.#{sha}.body"])
  end

  defp meta_path(root, cache_key) do
    Path.join([root, "aa", "aa", "#{cache_key.hash}.meta"])
  end

  # A distinct 64-char lowercase-hex key hash per index, partitioned across
  # different AB/CD directories (unlike the fixed "aa/aa" helpers above).
  defp distinct_key(index) do
    hash = :crypto.hash(:sha256, "entry-#{index}") |> Base.encode16(case: :lower)
    key(hash)
  end

  # Recursively sum the byte sizes of every *.body file under root. This is
  # the on-disk realization of Admission's tracked body bytes; the soft-cap
  # invariant says it must stay at or under max_size_bytes.
  defp total_body_bytes(root) do
    walk_files(root)
    |> Enum.filter(&String.ends_with?(&1, ".body"))
    |> Enum.reduce(0, fn path, acc -> acc + File.stat!(path).size end)
  end

  defp body_file_count(root) do
    walk_files(root)
    |> Enum.count(&String.ends_with?(&1, ".body"))
  end

  defp walk_files(path) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.flat_map(entries, &walk_entry(path, &1))

      {:error, _} ->
        []
    end
  end

  defp walk_entry(path, entry) do
    child = Path.join(path, entry)
    if File.dir?(child), do: walk_files(child), else: [child]
  end

  setup context do
    root =
      Path.join(System.tmp_dir!(), "image_pipe_fs_bounded_#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Map.put(context, :root, root)
  end

  test "admitted entry is written and tracked by Admission", %{root: root} do
    opts = bounded_opts(root, max_size_bytes: 1_000_000)
    start_supervised!(FileSystem.child_spec(opts))

    cache_key = key()
    assert :ok = put_entry(cache_key, entry("encoded image"), opts)

    # Files landed on disk.
    assert File.exists?(meta_path(root, cache_key))
    assert File.exists?(body_path(root, cache_key, "encoded image"))

    # Admission tracked the candidate (probationary or window bytes > 0).
    state = :sys.get_state(admission_pid(root))
    assert state.window_bytes + state.probationary_bytes + state.protected_bytes > 0

    assert {:hit, hit} = FileSystem.get(cache_key, opts)
    assert hit.body == "encoded image"
  end

  test "window overflow keeps newer entries and promotes an accessed main entry", %{root: root} do
    opts = bounded_opts(root, max_size_bytes: 100, window_ratio: 0.1)
    start_supervised!(FileSystem.child_spec(opts))
    pid = admission_pid(root)
    FileSystem.Admission.await_scan(pid)

    for index <- 1..3 do
      assert :ok = put_entry(distinct_key(index), entry("image"), opts)
    end

    state = :sys.get_state(pid)
    assert state.window_bytes == 10
    assert state.probationary_bytes == 5
    assert {:hit, _} = FileSystem.get(distinct_key(1), opts)
    state = :sys.get_state(pid)
    assert state.protected_bytes == 5
    assert state.probationary_bytes == 0
  end

  test "an entry larger than the window budget is admitted to main when it has room", %{
    root: root
  } do
    opts = bounded_opts(root, max_size_bytes: 100, window_ratio: 0.1)
    start_supervised!(FileSystem.child_spec(opts))
    pid = admission_pid(root)
    FileSystem.Admission.await_scan(pid)
    small = distinct_key(1)
    oversized = distinct_key(2)
    body = String.duplicate("o", 20)

    assert :ok = put_entry(small, entry("image"), opts)
    assert :ok = put_entry(oversized, entry(body), opts)

    state = :sys.get_state(pid)
    assert state.window_bytes == 5
    assert state.probationary_bytes == 20
    assert {:hit, %{body: ^body}} = FileSystem.get(oversized, opts)
  end

  test "rejected (over-cap) entry deletes the written body and meta", %{root: root} do
    # max_size_bytes smaller than the entry forces {:reject, :over_cap}.
    opts = bounded_opts(root, max_size_bytes: 4)
    start_supervised!(FileSystem.child_spec(opts))

    cache_key = key()
    # commit_sink signals admission rejection so the Sink can record the
    # request-path outcome; the bytes are still cleaned up below.
    assert {:ok, :rejected} = put_entry(cache_key, entry("this body is way over the cap"), opts)

    # Both body and meta were cleaned up; nothing untracked remains.
    refute File.exists?(meta_path(root, cache_key))
    refute File.exists?(body_path(root, cache_key, "this body is way over the cap"))

    # No accounting for the rejected entry.
    state = :sys.get_state(admission_pid(root))
    assert state.window_bytes + state.probationary_bytes + state.protected_bytes == 0

    assert FileSystem.get(cache_key, opts) == :miss
  end

  test "get/2 casts a hit descriptor to Admission, synthesizing tracking", %{root: root} do
    bounded = bounded_opts(root, max_size_bytes: 1_000_000)
    start_supervised!(FileSystem.child_spec(bounded))

    cache_key = key()

    # Place the entry on disk WITHOUT going through bounded admit, so Admission
    # is not yet tracking it (mirrors a cold-boot hit before the scan reaches
    # the key). Unbounded opts skip the admit path entirely.
    unbounded = [root: root]
    assert :ok = put_entry(cache_key, entry("encoded image"), unbounded)

    pid = admission_pid(root)
    assert :sys.get_state(pid).probationary_bytes == 0

    # A bounded get hits and casts the descriptor to Admission.
    assert {:hit, hit} = FileSystem.get(cache_key, bounded)
    assert hit.body == "encoded image"

    # Flush the async hit cast, then assert the synthesized probationary entry.
    _ = :sys.get_state(pid)
    assert :sys.get_state(pid).probationary_bytes == byte_size("encoded image")
  end

  test "bounded mode with no Admission process fails closed (skips write)", %{root: root} do
    # Bounded opts but no supervision tree started: lookup_admission/1 returns
    # :unavailable, so commit_sink must NOT leave an untracked entry on disk.
    opts = bounded_opts(root, max_size_bytes: 1_000_000)

    cache_key = key()
    assert :ok = put_entry(cache_key, entry("encoded image"), opts)

    refute File.exists?(meta_path(root, cache_key))
    refute File.exists?(body_path(root, cache_key, "encoded image"))
    assert FileSystem.get(cache_key, opts) == :miss
  end

  test "cycling ~1.5x cap worth of entries keeps on-disk bytes within the cap",
       %{root: root} do
    # 100 KB cap, 10 KB bodies: 15 distinct entries = 1.5x cap. With a tiny
    # window the main gate must reject or evict enough that on-disk body bytes
    # never exceed the cap.
    cap = 100_000
    body_size = 10_000
    count = 15

    opts = bounded_opts(root, max_size_bytes: cap, window_ratio: 0.01)
    start_supervised!(FileSystem.child_spec(opts))

    body = String.duplicate("x", body_size)

    for i <- 1..count do
      cache_key = distinct_key(i)
      # Each commit is either admitted (:ok) or declined ({:ok, :rejected})
      # once the cache fills; both clean up to a consistent on-disk state.
      assert put_entry(cache_key, entry(body), opts) in [:ok, {:ok, :rejected}]
      # commit_bounded admits synchronously, so disk is consistent here.
      assert total_body_bytes(root) <= cap
    end

    # Final state: the cache filled and shed load — fewer than all 15 bodies
    # remain, and total usage is within the cap.
    assert body_file_count(root) < count
    assert total_body_bytes(root) <= cap

    # Admission's accounting agrees with the on-disk realization.
    state = :sys.get_state(admission_pid(root))
    tracked = state.window_bytes + state.probationary_bytes + state.protected_bytes
    assert tracked <= cap
    assert tracked == total_body_bytes(root)
  end

  test "growing a cached body keeps disk usage within the cap", %{root: root} do
    opts = bounded_opts(root, max_size_bytes: 100, window_ratio: 1.0)
    start_supervised!(FileSystem.child_spec(opts))

    original = String.duplicate("a", 40)
    replacement = String.duplicate("c", 80)
    cache_key = key()

    assert :ok = put_entry(cache_key, entry(original), opts)
    assert :ok = put_entry(distinct_key(2), entry(String.duplicate("b", 40)), opts)
    assert :ok = put_entry(cache_key, entry(replacement), opts)

    assert total_body_bytes(root) <= 100
    assert tracked_bytes(admission_pid(root)) == total_body_bytes(root)
    refute File.exists?(body_path(root, cache_key, original))
    assert {:hit, %{body: ^replacement}} = FileSystem.get(cache_key, opts)
  end

  test "main admission evicts only enough bytes to cover the free-space deficit", %{root: root} do
    opts = bounded_opts(root, max_size_bytes: 100, window_ratio: 0.0)
    start_supervised!(FileSystem.child_spec(opts))

    assert :ok = put_entry(distinct_key(1), entry(String.duplicate("a", 40)), opts)
    assert :ok = put_entry(distinct_key(2), entry(String.duplicate("b", 40)), opts)
    candidate = distinct_key(3)
    body = String.duplicate("c", 50)

    assert {:ok, :rejected} = put_entry(candidate, entry(body), opts)
    assert :ok = put_entry(candidate, entry(body), opts)
    assert total_body_bytes(root) == 90
    assert tracked_bytes(admission_pid(root)) == 90
    assert {:hit, %{body: ^body}} = FileSystem.get(candidate, opts)
  end

  test "main admission evicts the least recently used entry", %{root: root} do
    opts = bounded_opts(root, max_size_bytes: 100, window_ratio: 0.0)
    start_supervised!(FileSystem.child_spec(opts))
    older = distinct_key(1)
    newer = distinct_key(2)
    candidate = distinct_key(3)

    assert :ok = put_entry(older, entry(String.duplicate("a", 40)), opts)
    assert :ok = put_entry(newer, entry(String.duplicate("b", 40)), opts)
    assert {:ok, :rejected} = put_entry(candidate, entry(String.duplicate("c", 30)), opts)
    assert :ok = put_entry(candidate, entry(String.duplicate("c", 30)), opts)

    assert FileSystem.get(older, opts) == :miss
    assert {:hit, _} = FileSystem.get(newer, opts)
  end

  test "a popular entry needing more victims than the limit displaces unrequested entries", %{
    root: root
  } do
    opts = bounded_opts(root, max_size_bytes: 10_000, window_ratio: 0.0)
    start_supervised!(FileSystem.child_spec(opts))
    pid = admission_pid(root)
    FileSystem.Admission.await_scan(pid)

    # 200 never-requested 50-byte entries fill the cache, so admitting a
    # 5,000-byte entry takes 100 victims, past the default limit of 64.
    for index <- 1..200 do
      assert :ok = put_entry(distinct_key(index), entry(String.duplicate("s", 50)), opts)
    end

    candidate = distinct_key(0)
    body = String.duplicate("l", 5_000)
    results = for _request <- 1..3, do: put_entry(candidate, entry(body), opts)

    assert :ok in results

    # The write evicts 64 entries and leaves the remaining overshoot to the
    # reconciliation batch it queues ahead of this call.
    assert tracked_bytes(pid) <= 10_000
    assert total_body_bytes(root) == tracked_bytes(pid)
    assert {:hit, %{body: ^body}} = FileSystem.get(candidate, opts)
  end

  test "a write whose victims reach protected entries still respects the victim limit", %{
    root: root
  } do
    opts =
      bounded_opts(root, max_size_bytes: 1_000, window_ratio: 0.0, eviction_victim_limit: 4)

    start_supervised!(FileSystem.child_spec(opts))
    pid = admission_pid(root)
    FileSystem.Admission.await_scan(pid)

    # Ten 100-byte entries fill the cache. Reading one promotes it to protected.
    for index <- 1..10 do
      assert :ok = put_entry(distinct_key(index), entry(String.duplicate("s", 100)), opts)
    end

    assert {:hit, _} = FileSystem.get(distinct_key(1), opts)
    _ = :sys.get_state(pid)

    # Admitting 1,000 bytes takes all nine probationary entries plus the
    # protected one, past the limit of 4.
    candidate = distinct_key(0)
    body = String.duplicate("l", 1_000)

    for _request <- 1..3 do
      assert {:ok, :rejected} = put_entry(candidate, entry(body), opts)
    end

    assert tracked_bytes(pid) == 1_000
    assert {:hit, _} = FileSystem.get(distinct_key(1), opts)
  end

  test "protected eviction follows LRU order", %{root: root} do
    opts = bounded_opts(root, max_size_bytes: 100, window_ratio: 0.0)
    start_supervised!(FileSystem.child_spec(opts), id: :cache)
    older = distinct_key(1)
    newer = distinct_key(2)

    for cache_key <- [older, newer] do
      assert :ok = put_entry(cache_key, entry("small"), opts)
      assert {:hit, _} = FileSystem.get(cache_key, opts)
    end

    assert :ok = put_entry(distinct_key(3), entry(String.duplicate("c", 90)), opts)
    candidate = distinct_key(4)
    body = String.duplicate("d", 95)
    assert {:ok, :rejected} = put_entry(candidate, entry(body), opts)
    assert :ok = put_entry(candidate, entry(body), opts)

    assert FileSystem.get(older, opts) == :miss
    assert {:hit, _} = FileSystem.get(newer, opts)
    assert total_body_bytes(root) == 100
  end

  property "replacement sequences preserve the disk budget and accounting", %{root: root} do
    check all(
            ratio <- member_of([0.0, 0.25, 1.0]),
            writes <-
              list_of(tuple({integer(1..3), integer(1..100)}), min_length: 5, max_length: 20),
            max_runs: 30
          ) do
      cache_root = Path.join(root, Integer.to_string(System.unique_integer([:positive])))
      opts = bounded_opts(cache_root, max_size_bytes: 100, window_ratio: ratio)
      start_supervised!(FileSystem.child_spec(opts), id: cache_root)

      for {index, size} <- writes do
        cache_key = distinct_key(index)
        body = String.duplicate(Integer.to_string(index), size)
        result = put_entry(cache_key, entry(body), opts)
        assert result in [:ok, {:ok, :rejected}]
        assert total_body_bytes(cache_root) <= 100
        assert tracked_bytes(admission_pid(cache_root)) == total_body_bytes(cache_root)
        assert tracked_hashes(admission_pid(cache_root)) == meta_hashes(cache_root)

        case {result, FileSystem.get(cache_key, opts)} do
          {:ok, {:hit, hit}} -> assert hit.body == body
          {{:ok, :rejected}, :miss} -> :ok
        end
      end

      stop_supervised!(cache_root)
    end
  end

  test "rejected growth removes superseded files and accounting", %{root: root} do
    opts = bounded_opts(root, max_size_bytes: 100, window_ratio: 0.5)
    start_supervised!(FileSystem.child_spec(opts))
    cache_key = key()
    original = String.duplicate("a", 20)
    replacement = String.duplicate("b", 80)

    assert :ok = put_entry(cache_key, entry(original), opts)
    assert {:ok, :rejected} = put_entry(cache_key, entry(replacement), opts)
    assert FileSystem.get(cache_key, opts) == :miss
    assert total_body_bytes(root) == 0
    assert tracked_bytes(admission_pid(root)) == 0
    refute File.exists?(meta_path(root, cache_key))
  end

  test "re-committing the same key with a new body deletes the old body", %{root: root} do
    opts = bounded_opts(root, max_size_bytes: 1_000_000)
    start_supervised!(FileSystem.child_spec(opts))

    cache_key = key()
    assert :ok = put_entry(cache_key, entry("first body"), opts)
    assert File.exists?(body_path(root, cache_key, "first body"))

    # Same key, new content → new body_sha256. same_key_replace emits a
    # body-only victim for the superseded body; the meta is rewritten in place.
    assert :ok = put_entry(cache_key, entry("second body"), opts)

    refute File.exists?(body_path(root, cache_key, "first body"))
    assert File.exists?(body_path(root, cache_key, "second body"))
    assert File.exists?(meta_path(root, cache_key))

    assert {:hit, hit} = FileSystem.get(cache_key, opts)
    assert hit.body == "second body"

    # Accounting tracks only the current body, not both.
    state = :sys.get_state(admission_pid(root))
    tracked = state.window_bytes + state.probationary_bytes + state.protected_bytes
    assert tracked == byte_size("second body")
  end

  test "two bounded caches with distinct roots coexist in one VM", %{root: root} do
    other_root = root <> "_second"
    File.mkdir_p!(other_root)
    on_exit(fn -> File.rm_rf!(other_root) end)

    opts_a = bounded_opts(root, max_size_bytes: 1_000_000)
    opts_b = bounded_opts(other_root, max_size_bytes: 1_000_000)

    # Both supervision trees boot without clashing on a Registry process name:
    # each derives its Registry from its own root.
    start_supervised!(FileSystem.child_spec(opts_a), id: :cache_a)
    start_supervised!(FileSystem.child_spec(opts_b), id: :cache_b)

    refute FileSystem.registry_name(root) == FileSystem.registry_name(other_root)

    cache_key = key()
    assert :ok = put_entry(cache_key, entry("body a"), opts_a)
    assert :ok = put_entry(cache_key, entry("body b"), opts_b)

    # Each cache tracks and serves its own body independently.
    assert {:hit, %{body: "body a"}} = FileSystem.get(cache_key, opts_a)
    assert {:hit, %{body: "body b"}} = FileSystem.get(cache_key, opts_b)

    assert tracked_bytes(admission_pid(root)) == byte_size("body a")
    assert tracked_bytes(admission_pid(other_root)) == byte_size("body b")
  end

  defp tracked_bytes(pid) do
    state = :sys.get_state(pid)
    state.window_bytes + state.probationary_bytes + state.protected_bytes
  end

  defp tracked_hashes(pid) do
    state = :sys.get_state(pid)

    for table <- [state.window, state.probationary, state.protected],
        {{_position, hash}, _descriptor} <- :ets.tab2list(table),
        into: MapSet.new(),
        do: hash
  end

  defp meta_hashes(root) do
    for path <- walk_files(root), String.ends_with?(path, ".meta"), into: MapSet.new() do
      Path.basename(path, ".meta")
    end
  end
end
