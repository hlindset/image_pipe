defmodule ImagePipe.Cache.FileSystemTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.PeriodicSweep
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.Key
  alias ImagePipe.Source.Record

  @max_size_bytes 1_000_000_000

  defp key(hash \\ String.duplicate("a", 64)) do
    %Key{
      hash: hash,
      data: [schema_version: 1]
    }
  end

  defp entry(body \\ "encoded image") do
    %Entry{
      body: body,
      content_type: "image/webp",
      headers: [{"vary", "Accept"}],
      created_at: ~U[2026-04-29 10:15:00Z]
    }
  end

  defp entry_metadata(overrides \\ []) do
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

  defp put_entry(cache_key, %Entry{} = entry, opts) do
    metadata =
      entry_metadata(
        content_type: entry.content_type,
        headers: entry.headers,
        created_at: entry.created_at
      )

    with {:ok, state} <- FileSystem.open_sink(cache_key, metadata, opts),
         {:ok, state} <- FileSystem.write_chunk(state, entry.body, opts) do
      FileSystem.commit_sink(state, opts)
    end
  end

  defp body_sha256(body) do
    :crypto.hash(:sha256, body)
    |> Base.encode16(case: :lower)
  end

  defp body_filename(cache_key, body),
    do: Store.body_filename(cache_key.hash, body_sha256(body), byte_size(body), 0)

  defp metadata(cache_key, body, overrides \\ []) do
    Map.merge(
      %{
        metadata_version: 1,
        content_type: "image/webp",
        headers: [],
        created_at: "2026-04-29T10:15:00Z",
        body_byte_size: byte_size(body),
        body_sha256: body_sha256(body),
        body_filename: body_filename(cache_key, body),
        cost_us: 0,
        debug: nil,
        representation: nil
      },
      Map.new(overrides)
    )
  end

  # Options for a cache on `root`.
  defp opts(root, extra \\ []), do: [root: root, max_size_bytes: @max_size_bytes] ++ extra

  # Starts the cache's processes, so writes are admitted, and returns them
  # once the startup scan has run.
  defp start_cache!(opts) do
    {:ok, opts} = FileSystem.validate_options(opts)

    root = opts |> FileSystem.child_spec() |> start_supervised!()

    {:cache, cache, :supervisor, _modules} =
      List.keyfind(Supervisor.which_children(root), :cache, 0)

    children = Supervisor.which_children(cache)

    for {{Admission, _root}, pid, _type, _modules} <- children, do: Admission.await_scan(pid)
    children
  end

  defp root(context) do
    Path.join(System.tmp_dir!(), "image_pipe_fs_cache_#{context.test}")
  end

  setup context do
    root = root(context)
    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    if Map.get(context, :cache, true), do: start_cache!(opts(root))
    {:ok, root: root}
  end

  test "requires an absolute root" do
    assert FileSystem.get(key(), []) == {:error, {:missing_required_option, :root}}

    assert FileSystem.get(key(), root: "relative/cache") ==
             {:error, {:invalid_root, "relative/cache"}}

    assert FileSystem.validate_options([]) == {:error, {:missing_required_option, :root}}

    assert FileSystem.validate_options(root: "relative/cache") ==
             {:error, {:invalid_root, "relative/cache"}}
  end

  test "rejects unknown filesystem adapter options", %{root: root} do
    assert FileSystem.validate_options(opts(root, path_prefx: "processed")) ==
             {:error, {:unknown_options, [:path_prefx]}}

    assert FileSystem.get(key(), opts(root, path_prefx: "processed")) ==
             {:error, {:unknown_options, [:path_prefx]}}

    assert FileSystem.validate_options(opts(root, fail_on_cache_error: true)) ==
             {:error, {:unknown_options, [:fail_on_cache_error]}}
  end

  test "accepts filesystem root as cache root" do
    assert FileSystem.get(key(), opts("/")) == :miss
  end

  test "rejects cache paths that resolve outside the root through symlinks", %{root: root} do
    outside_root = root <> "_outside"
    File.rm_rf!(outside_root)
    File.mkdir_p!(outside_root)
    on_exit(fn -> File.rm_rf!(outside_root) end)

    File.ln_s!(outside_root, Path.join(root, "aa"))
    hash = "aabb" <> String.duplicate("1", 60)

    # A rejection is never remembered, so a fixed partition is accepted.
    for _attempt <- 1..2 do
      assert FileSystem.get(key(hash), opts(root)) ==
               {:error, {:path_outside_root, Path.join([root, "aa", "bb"])}}
    end

    File.rm!(Path.join(root, "aa"))
    File.mkdir_p!(Path.join([root, "aa", "bb"]))
    assert FileSystem.get(key(hash), opts(root)) == :miss
  end

  test "rejects invalid hashes before path construction", %{root: root} do
    too_short_hash = String.duplicate("a", 63)
    non_hex_hash = String.duplicate("g", 64)
    path_shaped_hash = "abcd/" <> String.duplicate("a", 59)

    assert FileSystem.get(key(too_short_hash), opts(root)) ==
             {:error, {:invalid_hash, too_short_hash}}

    assert FileSystem.get(key(non_hex_hash), opts(root)) ==
             {:error, {:invalid_hash, non_hex_hash}}

    assert FileSystem.get(key(path_shaped_hash), opts(root)) ==
             {:error, {:invalid_hash, path_shaped_hash}}
  end

  test "writes and reads body and metadata under hash-partitioned paths", %{root: root} do
    cache_key = key("abcdef" <> String.duplicate("1", 58))

    assert put_entry(cache_key, entry(), opts(root)) == :ok
    assert {:hit, cached_entry} = FileSystem.get(cache_key, opts(root))

    assert cached_entry.body == "encoded image"
    assert cached_entry.content_type == "image/webp"
    assert cached_entry.headers == [{"vary", "Accept"}]
    assert cached_entry.created_at == ~U[2026-04-29 10:15:00Z]

    assert File.exists?(Path.join([root, "ab", "cd", body_filename(cache_key, "encoded image")]))
    assert File.exists?(Path.join([root, "ab", "cd", cache_key.hash <> ".meta"]))
  end

  test "round-trips a Debug.Info through metadata serialize/deserialize", %{root: root} do
    cache_key = key("abcdef" <> String.duplicate("2", 58))

    info = %ImagePipe.Debug.Info{
      source_format: :jpeg,
      source_width: 4000,
      source_height: 3000,
      output_format: :avif,
      output_quality: 72,
      aq: %{metric: :ssimulacra2, score: 78.4, min: 60, max: 65},
      pipeline: ["scale", "crop"],
      timings: %{decode: 8, transform: 21, encode: 140, total: 181}
    }

    metadata =
      entry_metadata(
        content_type: "image/avif",
        output_format: :avif,
        representation: {:image, :avif},
        debug: info
      )

    assert {:ok, state} = FileSystem.open_sink(cache_key, metadata, opts(root))
    assert {:ok, state} = FileSystem.write_chunk(state, "BODYBYTES", opts(root))
    assert :ok = FileSystem.commit_sink(state, opts(root))

    assert {:hit, %Entry{debug: read_back, representation: {:image, :avif}}} =
             FileSystem.get(cache_key, opts(root))

    assert read_back == info
  end

  test "round-trips a complete-body representation through metadata", %{root: root} do
    cache_key = key("abcdef" <> String.duplicate("3", 58))

    metadata =
      entry_metadata(
        content_type: "application/json",
        output_format: nil,
        representation: {:complete_body, "application/json"}
      )

    assert {:ok, state} = FileSystem.open_sink(cache_key, metadata, opts(root))
    assert {:ok, state} = FileSystem.write_chunk(state, ~s({"ok":true}), opts(root))
    assert :ok = FileSystem.commit_sink(state, opts(root))

    assert {:hit, %Entry{representation: {:complete_body, "application/json"}}} =
             FileSystem.get(cache_key, opts(root))
  end

  test "sink writes chunks to temp files and makes the entry visible only at commit", %{
    root: root
  } do
    cache_key = key("abcdef" <> String.duplicate("1", 58))

    assert {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), opts(root))
    assert {:ok, state} = FileSystem.write_chunk(state, "encoded ", opts(root))
    assert {:ok, state} = FileSystem.write_chunk(state, "image", opts(root))

    assert FileSystem.get(cache_key, opts(root)) == :miss
    assert {:ok, paths} = FileSystem.paths(cache_key, opts(root))
    assert Enum.any?(File.ls!(paths.dir), &String.ends_with?(&1, ".tmp"))

    assert :ok = FileSystem.commit_sink(state, opts(root))
    assert {:hit, cached_entry} = FileSystem.get(cache_key, opts(root))
    assert cached_entry.body == "encoded image"
    assert cached_entry.content_type == "image/webp"
    assert cached_entry.headers == [{"vary", "Accept"}]
    assert cached_entry.created_at == ~U[2026-04-29 10:15:00Z]
    refute Enum.any?(File.ls!(paths.dir), &String.ends_with?(&1, ".tmp"))
  end

  test "sink write errors return the unchanged state", %{root: root} do
    cache_key = key("abcdef" <> String.duplicate("2", 58))
    assert {:ok, paths} = FileSystem.paths(cache_key, opts(root))
    File.mkdir_p!(paths.dir)

    read_only_path = Path.join(paths.dir, "read-only.tmp")
    File.write!(read_only_path, "")
    {:ok, body_io} = File.open(read_only_path, [:read, :binary])

    state = %{
      paths: paths,
      temp_body_path: read_only_path,
      temp_meta_path: nil,
      body_io: body_io,
      size: 0,
      hash_context: :crypto.hash_init(:sha256),
      metadata: entry_metadata()
    }

    try do
      assert {:error, :ebadf, returned_state} =
               FileSystem.write_chunk(state, "not written", opts(root))

      assert returned_state.size == state.size
      assert returned_state.hash_context == state.hash_context
    after
      File.close(body_io)
    end
  end

  test "sink abort removes temp files and leaves no visible entry", %{root: root} do
    cache_key = key("b" <> String.duplicate("1", 63))

    assert {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), opts(root))
    assert {:ok, state} = FileSystem.write_chunk(state, "partial", opts(root))
    assert {:ok, paths} = FileSystem.paths(cache_key, opts(root))
    assert Enum.any?(File.ls!(paths.dir), &String.ends_with?(&1, ".tmp"))

    assert :ok = FileSystem.abort_sink(state, opts(root))
    assert FileSystem.get(cache_key, opts(root)) == :miss
    refute Enum.any?(File.ls!(paths.dir), &String.ends_with?(&1, ".tmp"))
  end

  test "sink abort treats temp cleanup errors as best effort", %{root: root} do
    cache_key = key("bcbcbc" <> String.duplicate("1", 58))
    assert {:ok, paths} = FileSystem.paths(cache_key, opts(root))
    File.mkdir_p!(paths.dir)
    temp_obstruction = Path.join(paths.dir, ".#{cache_key.hash}.forced.tmp")
    File.mkdir_p!(temp_obstruction)

    assert {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), opts(root))

    assert :ok = FileSystem.abort_sink(%{state | temp_body_path: temp_obstruction}, opts(root))
    assert FileSystem.get(cache_key, opts(root)) == :miss
  end

  test "sink commit cleans up when body rename fails", %{root: root} do
    cache_key = key("cecece" <> String.duplicate("1", 58))
    assert {:ok, paths} = FileSystem.paths(cache_key, opts(root))
    File.mkdir_p!(paths.dir)

    body_path = Path.join(paths.dir, body_filename(cache_key, "body"))
    File.mkdir_p!(body_path)

    assert {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), opts(root))
    assert {:ok, state} = FileSystem.write_chunk(state, "body", opts(root))

    assert {:error, _reason} = FileSystem.commit_sink(state, opts(root))
    assert File.dir?(body_path)
    refute File.exists?(paths.meta_path)
    refute Enum.any?(File.ls!(paths.dir), &String.ends_with?(&1, ".tmp"))
  end

  test "concurrent sink commits for the same key leave a readable entry", %{root: root} do
    cache_key = key("dddddd" <> String.duplicate("1", 58))

    results =
      ["body-one", "body-two"]
      |> Task.async_stream(
        fn body ->
          {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), opts(root))
          {:ok, state} = FileSystem.write_chunk(state, body, opts(root))
          FileSystem.commit_sink(state, opts(root))
        end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == [:ok, :ok]
    assert {:hit, cached_entry} = FileSystem.get(cache_key, opts(root))
    assert cached_entry.body in ["body-one", "body-two"]
  end

  test "missing metadata or body is a miss", %{root: root} do
    cache_key = key("123456" <> String.duplicate("a", 58))
    assert FileSystem.get(cache_key, opts(root)) == :miss

    dir = Path.join([root, "12", "34"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, body_filename(cache_key, "body")), "body")

    assert FileSystem.get(cache_key, opts(root)) == :miss

    meta_only_key = key("223456" <> String.duplicate("a", 58))
    meta_only_dir = Path.join([root, "22", "34"])
    File.mkdir_p!(meta_only_dir)

    File.write!(
      Path.join(meta_only_dir, meta_only_key.hash <> ".meta"),
      :erlang.term_to_binary(metadata(meta_only_key, "body"))
    )

    assert FileSystem.get(meta_only_key, opts(root)) == :miss
  end

  test "invalid metadata is returned as an error", %{root: root} do
    cache_key = key("654321" <> String.duplicate("b", 58))
    dir = Path.join([root, "65", "43"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, body_filename(cache_key, "body")), "body")

    File.write!(
      Path.join(dir, cache_key.hash <> ".meta"),
      :erlang.term_to_binary(%{metadata_version: 999})
    )

    assert FileSystem.get(cache_key, opts(root)) ==
             {:error, {:invalid_metadata, :version_mismatch}}
  end

  test "body byte-size mismatch is returned as invalid metadata", %{root: root} do
    cache_key = key("bbbbbb" <> String.duplicate("c", 58))
    assert put_entry(cache_key, entry("12345"), opts(root)) == :ok

    dir = Path.join([root, "bb", "bb"])
    File.write!(Path.join(dir, body_filename(cache_key, "12345")), "123")

    assert FileSystem.get(cache_key, opts(root)) ==
             {:error, {:invalid_metadata, :body_byte_size_mismatch}}
  end

  test "invalid body digest metadata is returned as invalid metadata", %{root: root} do
    cache_key = key("bcbcbc" <> String.duplicate("c", 58))
    dir = Path.join([root, "bc", "bc"])
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, cache_key.hash <> ".meta"),
      :erlang.term_to_binary(
        metadata(cache_key, "body",
          body_sha256: "not-a-sha256",
          body_filename: "#{cache_key.hash}.not-a-sha256.4.0.body"
        )
      )
    )

    assert FileSystem.get(cache_key, opts(root)) ==
             {:error, {:invalid_metadata, :invalid_body_filename}}
  end

  test "invalid metadata content type is returned as invalid metadata", %{root: root} do
    cache_key = key("bebebe" <> String.duplicate("c", 58))
    dir = Path.join([root, "be", "be"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, body_filename(cache_key, "body")), "body")

    File.write!(
      Path.join(dir, cache_key.hash <> ".meta"),
      :erlang.term_to_binary(
        metadata(cache_key, "body", content_type: "application/octet-stream")
      )
    )

    assert {:error, {:invalid_metadata, {:invalid_content_type, _reason}}} =
             FileSystem.get(cache_key, opts(root))
  end

  test "serialized representation must agree with its content type", %{root: root} do
    for {suffix, representation, content_type} <- [
          {"1", {:complete_body, "text/plain"}, "application/json"},
          {"2", {:image, :jpeg}, "image/webp"},
          {"3", {:image, :unknown}, "image/webp"},
          {"4", :invalid, "image/webp"}
        ] do
      cache_key = key("c0ffee" <> String.duplicate(suffix, 58))
      dir = Path.join([root, "c0", "ff"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, body_filename(cache_key, "body")), "body")

      File.write!(
        Path.join(dir, cache_key.hash <> ".meta"),
        :erlang.term_to_binary(
          metadata(cache_key, "body", representation: representation, content_type: content_type)
        )
      )

      assert {:error, {:invalid_metadata, {:invalid_representation, ^representation}}} =
               FileSystem.get(cache_key, opts(root))
    end
  end

  test "malformed metadata headers are returned as invalid metadata", %{root: root} do
    cache_key = key("bfbfbf" <> String.duplicate("c", 58))
    dir = Path.join([root, "bf", "bf"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, body_filename(cache_key, "body")), "body")

    File.write!(
      Path.join(dir, cache_key.hash <> ".meta"),
      :erlang.term_to_binary(metadata(cache_key, "body", headers: [{"vary", :not_binary}]))
    )

    assert FileSystem.get(cache_key, opts(root)) ==
             {:error, {:invalid_metadata, :invalid_headers}}
  end

  test "replacing an entry with a new body removes the old body", %{root: root} do
    cache_key = key("ababab" <> String.duplicate("1", 58))

    assert put_entry(cache_key, entry("body-one"), opts(root)) == :ok
    assert put_entry(cache_key, entry("body-two"), opts(root)) == :ok
    assert put_entry(cache_key, entry("body-two"), opts(root)) == :ok

    assert {:ok, paths} = FileSystem.paths(cache_key, opts(root))

    assert File.ls!(paths.dir) |> Enum.filter(&String.ends_with?(&1, ".body")) ==
             [body_filename(cache_key, "body-two")]

    assert {:hit, cached_entry} = FileSystem.get(cache_key, opts(root))
    assert cached_entry.body == "body-two"
  end

  test "put succeeds when the content-addressed body already exists", %{root: root} do
    cache_key = key("adadad" <> String.duplicate("1", 58))
    assert {:ok, paths} = FileSystem.paths(cache_key, opts(root))
    File.mkdir_p!(paths.dir)
    File.write!(Path.join(paths.dir, body_filename(cache_key, "body")), "body")

    assert put_entry(cache_key, entry("body"), opts(root)) == :ok
    assert {:hit, cached_entry} = FileSystem.get(cache_key, opts(root))
    assert cached_entry.body == "body"
  end

  test "reusing an existing body moves its mtime", %{root: root} do
    cache_key = key("aeaeae" <> String.duplicate("1", 58))
    assert {:ok, paths} = FileSystem.paths(cache_key, opts(root))
    File.mkdir_p!(paths.dir)
    body = Path.join(paths.dir, body_filename(cache_key, "body"))
    File.write!(body, "body")
    old = System.os_time(:second) - 7_200
    File.touch!(body, old)

    assert put_entry(cache_key, entry("body"), opts(root)) == :ok
    assert File.stat!(body, time: :posix).mtime > old
  end

  test "unexpected body read error is returned", %{root: root} do
    cache_key = key("fafafa" <> String.duplicate("2", 58))
    assert put_entry(cache_key, entry("body"), opts(root)) == :ok

    body_path = Path.join([root, "fa", "fa", body_filename(cache_key, "body")])
    File.rm!(body_path)
    File.mkdir_p!(body_path)

    assert FileSystem.get(cache_key, opts(root)) == {:error, {:body_read, :eisdir}}
  end

  test "cleans temp files when metadata write fails", %{root: root} do
    cache_key = key("cccccc" <> String.duplicate("d", 58))
    dir = Path.join([root, "cc", "cc"])
    File.mkdir_p!(dir)
    File.mkdir_p!(Path.join(dir, cache_key.hash <> ".meta"))

    assert {:error, _reason} = put_entry(cache_key, entry(), opts(root))
    refute File.ls!(dir) |> Enum.any?(&String.ends_with?(&1, ".tmp"))
  end

  test "does not replace an existing body when metadata destination is obstructed", %{root: root} do
    cache_key = key("cdcdcd" <> String.duplicate("d", 58))
    dir = Path.join([root, "cd", "cd"])
    File.mkdir_p!(dir)

    body_path = Path.join(dir, body_filename(cache_key, "old body"))
    meta_path = Path.join(dir, cache_key.hash <> ".meta")
    File.write!(body_path, "old body")
    File.mkdir_p!(meta_path)

    assert {:error, _reason} = put_entry(cache_key, entry("new body"), opts(root))
    assert File.read!(body_path) == "old body"
  end

  test "keeps a content-addressed body orphan when metadata commit fails", %{root: root} do
    cache_key = key("cecece" <> String.duplicate("d", 58))
    assert {:ok, paths} = FileSystem.paths(cache_key, opts(root))
    File.mkdir_p!(paths.dir)
    File.mkdir_p!(paths.meta_path)

    new_body_path = Path.join(paths.dir, body_filename(cache_key, "new body"))

    assert {:error, _reason} = put_entry(cache_key, entry("new body"), opts(root))
    assert File.exists?(new_body_path)
    refute File.ls!(paths.dir) |> Enum.any?(&String.ends_with?(&1, ".tmp"))
  end

  test "an entry stores no source record, and one an earlier version stored is ignored", %{
    root: root
  } do
    cache_key = key()
    opts = opts(root)
    {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), opts)
    {:ok, state} = FileSystem.write_chunk(state, "record", opts)
    :ok = FileSystem.commit_sink(state, opts)

    {:ok, paths} = FileSystem.paths(cache_key, opts)
    meta = paths.meta_path |> File.read!() |> :erlang.binary_to_term()
    refute Map.has_key?(meta, :source_record)

    # A record whose origin lacks a field, as an earlier version could leave.
    record = %Record{
      byte_identity: {:strong, "digest"},
      origin: %{status: 200, headers: %{}},
      received_at: 1
    }

    File.write!(paths.meta_path, :erlang.term_to_binary(Map.put(meta, :source_record, record)))

    assert {:hit, %{body: "record"}} = FileSystem.get(cache_key, opts)
  end

  describe "cost_us metadata" do
    test "is persisted in the meta file and returned on hit", %{root: root} do
      cache_key = key()
      opts = opts(root)
      metadata = entry_metadata(cost_us: 42_000)

      {:ok, state} = FileSystem.open_sink(cache_key, metadata, opts)
      {:ok, state} = FileSystem.write_chunk(state, "encoded image", opts)
      :ok = FileSystem.commit_sink(state, opts)

      assert {:hit, hit_entry} = FileSystem.get(cache_key, opts)
      # Verify cost_us lands in the on-disk meta payload by re-reading the file directly.
      meta_path = Path.join([root, "aa", "aa", String.duplicate("a", 64) <> ".meta"])
      meta = meta_path |> File.read!() |> :erlang.binary_to_term([:safe])
      assert meta.cost_us == 42_000
      assert hit_entry.body == "encoded image"
    end
  end

  describe "paths_from_hash/2" do
    test "builds partitioned paths for a 64-char hash", %{root: root} do
      hash = String.duplicate("a", 64)
      opts = [root: root]

      assert {:ok, paths} = FileSystem.paths_from_hash(hash, opts)
      assert paths.dir == Path.join([root, "aa", "aa"])
      assert paths.meta_path == Path.join([root, "aa", "aa", hash <> ".meta"])
      assert paths.hash == hash
      assert paths.root == root
    end

    test "validates hash format" do
      assert {:error, {:invalid_hash, _}} =
               FileSystem.paths_from_hash("not-a-hash", root: "/tmp")
    end

    test "two different hashes land in different partition dirs", %{root: root} do
      hash_a = "aabb" <> String.duplicate("1", 60)
      hash_b = "ccdd" <> String.duplicate("1", 60)

      assert {:ok, paths_a} = FileSystem.paths_from_hash(hash_a, opts(root))
      assert {:ok, paths_b} = FileSystem.paths_from_hash(hash_b, opts(root))

      assert paths_a.dir == Path.join([root, "aa", "bb"])
      assert paths_b.dir == Path.join([root, "cc", "dd"])
      assert paths_a.dir != paths_b.dir
    end
  end

  # A temp file two hours old, as a request killed mid-write leaves.
  defp leftover(root, digit) do
    dir = Path.join([root, "aa", "aa"])
    File.mkdir_p!(dir)
    path = Path.join(dir, ".#{String.duplicate(digit, 64)}.Ab_c-dE.tmp")
    File.write!(path, "bytes")
    File.touch!(path, System.os_time(:second) - 7_200)
    path
  end

  describe "child_spec/1" do
    @describetag cache: false

    test "an instance sweeps a pool while it runs, after its startup scan", %{
      root: root
    } do
      pid = start_sweep(root: root, max_size_bytes: 10_000_000)
      path = leftover(root, "a")
      _ = :sys.get_state(pid)
      assert File.exists?(path)

      send(pid, :sweep)
      _ = :sys.get_state(pid)
      refute File.exists?(path)
    end
  end

  # Starts the cache's processes and returns its periodic sweep once its
  # first message, and the startup scan, have been handled.
  defp start_sweep(opts) do
    children = start_cache!(opts)
    [pid] = for {_id, pid, _type, [PeriodicSweep]} <- children, do: pid
    _ = :sys.get_state(pid)
    pid
  end

  describe "config validation" do
    test "rejects max_size_bytes: 0" do
      assert {:error, _} = FileSystem.validate_options(root: "/tmp", max_size_bytes: 0)
    end

    test "rejects negative max_size_bytes" do
      assert {:error, _} = FileSystem.validate_options(root: "/tmp", max_size_bytes: -1)
    end

    test "requires max_size_bytes" do
      assert FileSystem.validate_options(root: "/tmp") ==
               {:error, {:missing_required_option, :max_size_bytes}}
    end

    test "accepts a complete config" do
      assert {:ok, _opts} =
               FileSystem.validate_options(
                 root: "/tmp",
                 max_size_bytes: 100_000_000
               )
    end
  end

  test "concurrent puts for the same key leave a readable entry", %{root: root} do
    cache_key = key("dddddd" <> String.duplicate("e", 58))

    results =
      ["body-one", "body-two"]
      |> Task.async_stream(
        fn body -> put_entry(cache_key, entry(body), opts(root)) end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == [:ok, :ok]
    assert {:hit, cached_entry} = FileSystem.get(cache_key, opts(root))
    assert cached_entry.body in ["body-one", "body-two"]
  end
end
