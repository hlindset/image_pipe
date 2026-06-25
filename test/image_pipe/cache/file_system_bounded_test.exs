defmodule ImagePipe.Cache.FileSystemBoundedTest do
  # async: true — each test uses a unique cache root, and the bounded
  # supervision tree derives its Registry name from that root (see
  # FileSystem.registry_name/1), so concurrently-booted trees never clash on a
  # process name.
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Sketch
  alias ImagePipe.Cache.Key

  @node_id "bounded-node"

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

  # Mirror admission_test.exs base_opts/1 so Admission boots without Task 25's
  # config-derived defaults. The caller supplies :root and :max_size_bytes.
  defp bounded_opts(root, overrides) do
    Keyword.merge(
      [
        root: root,
        node_id: @node_id,
        state_dir: Path.join(root, ".cache_state"),
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
    [{pid, _}] = Registry.lookup(FileSystem.registry_name(root), {root, @node_id})
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

  test "cross-node warm start merges multiple peer state files into boot_cms",
       %{root: root} do
    opts = bounded_opts(root, max_size_bytes: 1_000_000)
    state_dir = Keyword.fetch!(opts, :state_dir)
    File.mkdir_p!(state_dir)

    # Two peers (distinct node_ids, neither equal to @node_id) each persisted a
    # sketch with a different hot key. On boot the local node has no own state,
    # so boot_cms must reflect BOTH peers' frequencies — not just one.
    File.write!(Path.join(state_dir, "peer-a.state"), peer_state_payload("peer-a", "hot-a", 3))
    File.write!(Path.join(state_dir, "peer-b.state"), peer_state_payload("peer-b", "hot-b", 5))

    start_supervised!(FileSystem.child_spec(opts))
    state = :sys.get_state(admission_pid(root))

    assert Sketch.estimate(state.boot_cms, "hot-a") >= 1
    assert Sketch.estimate(state.boot_cms, "hot-b") >= 1
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

  # Build a persisted Admission state payload for a peer node whose sketch has
  # `key` incremented `count` times. Mirrors the on-disk format Admission
  # writes (format_version 1) so warm-start merge reads it back.
  defp peer_state_payload(node_id, key, count) do
    sketch =
      Enum.reduce(1..count, Sketch.new(depth: 4, width: 256), fn _, acc ->
        Sketch.increment(acc, key)
      end)

    :erlang.term_to_binary(
      %{
        format_version: 1,
        node_id: node_id,
        written_at: System.system_time(:millisecond),
        aging_epoch: 0,
        increments_since_reset: count,
        sketch: Sketch.serialize(sketch),
        protected_hashes: []
      },
      [:deterministic]
    )
  end
end
