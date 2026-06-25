defmodule ImagePipe.Cache.FileSystemTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Key

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

  defp body_filename(cache_key, body), do: "#{cache_key.hash}.#{body_sha256(body)}.body"

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
        debug: nil
      },
      Map.new(overrides)
    )
  end

  defp root(context) do
    Path.join(System.tmp_dir!(), "image_pipe_fs_cache_#{context.test}")
  end

  setup context do
    root = root(context)
    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
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

  test "rejects traversal-shaped path prefixes", %{root: root} do
    assert FileSystem.get(key(), root: root, path_prefix: "../outside") ==
             {:error, {:invalid_path_prefix, "../outside"}}

    assert FileSystem.get(key(), root: root, path_prefix: "/absolute") ==
             {:error, {:invalid_path_prefix, "/absolute"}}

    assert FileSystem.get(key(), root: root, path_prefix: "processed/./images") ==
             {:error, {:invalid_path_prefix, "processed/./images"}}

    assert FileSystem.get(key(), root: root, path_prefix: "processed//images") ==
             {:error, {:invalid_path_prefix, "processed//images"}}

    assert FileSystem.get(key(), root: root, path_prefix: "processed\\..\\outside") ==
             {:error, {:invalid_path_prefix, "processed\\..\\outside"}}

    assert FileSystem.validate_options(root: root, path_prefix: "../outside") ==
             {:error, {:invalid_path_prefix, "../outside"}}
  end

  test "accepts tilde as a normal relative path segment", %{root: root} do
    assert FileSystem.validate_options(root: root, path_prefix: "~cache") ==
             {:ok, [root: root, path_prefix: "~cache"]}
  end

  test "rejects unknown filesystem adapter options", %{root: root} do
    assert FileSystem.validate_options(root: root, path_prefx: "processed") ==
             {:error, {:unknown_options, [:path_prefx]}}

    assert FileSystem.get(key(), root: root, path_prefx: "processed") ==
             {:error, {:unknown_options, [:path_prefx]}}

    assert FileSystem.validate_options(root: root, fail_on_cache_error: true) ==
             {:error, {:unknown_options, [:fail_on_cache_error]}}
  end

  test "accepts filesystem root as cache root" do
    assert FileSystem.get(key(), root: "/") == :miss
  end

  test "rejects cache paths that resolve outside the root through symlinks", %{root: root} do
    outside_root = root <> "_outside"
    File.rm_rf!(outside_root)
    File.mkdir_p!(outside_root)
    on_exit(fn -> File.rm_rf!(outside_root) end)

    File.ln_s!(outside_root, Path.join(root, "aa"))

    assert FileSystem.get(key("aabb" <> String.duplicate("1", 60)), root: root) ==
             {:error, {:path_outside_root, Path.join([root, "aa", "bb"])}}
  end

  test "rejects invalid hashes before path construction", %{root: root} do
    too_short_hash = String.duplicate("a", 63)
    non_hex_hash = String.duplicate("g", 64)
    path_shaped_hash = "abcd/" <> String.duplicate("a", 59)

    assert FileSystem.get(key(too_short_hash), root: root) ==
             {:error, {:invalid_hash, too_short_hash}}

    assert FileSystem.get(key(non_hex_hash), root: root) ==
             {:error, {:invalid_hash, non_hex_hash}}

    assert FileSystem.get(key(path_shaped_hash), root: root) ==
             {:error, {:invalid_hash, path_shaped_hash}}
  end

  test "writes and reads body and metadata under hash-partitioned paths", %{root: root} do
    cache_key = key("abcdef" <> String.duplicate("1", 58))

    assert put_entry(cache_key, entry(), root: root, path_prefix: "processed") == :ok
    assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root, path_prefix: "processed")

    assert cached_entry.body == "encoded image"
    assert cached_entry.content_type == "image/webp"
    assert cached_entry.headers == [{"vary", "Accept"}]
    assert cached_entry.created_at == ~U[2026-04-29 10:15:00Z]

    assert File.exists?(
             Path.join([root, "processed", "ab", "cd", body_filename(cache_key, "encoded image")])
           )

    assert File.exists?(Path.join([root, "processed", "ab", "cd", cache_key.hash <> ".meta"]))
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

    metadata = entry_metadata(content_type: "image/avif", output_format: :avif, debug: info)

    assert {:ok, state} = FileSystem.open_sink(cache_key, metadata, root: root)
    assert {:ok, state} = FileSystem.write_chunk(state, "BODYBYTES", root: root)
    assert :ok = FileSystem.commit_sink(state, root: root)

    assert {:hit, %Entry{debug: read_back}} = FileSystem.get(cache_key, root: root)
    assert read_back == info
  end

  test "sink writes chunks to temp files and makes the entry visible only at commit", %{
    root: root
  } do
    cache_key = key("abcdef" <> String.duplicate("1", 58))

    assert {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), root: root)
    assert {:ok, state} = FileSystem.write_chunk(state, "encoded ", root: root)
    assert {:ok, state} = FileSystem.write_chunk(state, "image", root: root)

    assert FileSystem.get(cache_key, root: root) == :miss
    assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
    assert Enum.any?(File.ls!(paths.dir), &String.ends_with?(&1, ".tmp"))

    assert :ok = FileSystem.commit_sink(state, root: root)
    assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root)
    assert cached_entry.body == "encoded image"
    assert cached_entry.content_type == "image/webp"
    assert cached_entry.headers == [{"vary", "Accept"}]
    assert cached_entry.created_at == ~U[2026-04-29 10:15:00Z]
    refute Enum.any?(File.ls!(paths.dir), &String.ends_with?(&1, ".tmp"))
  end

  test "sink write errors return the unchanged state", %{root: root} do
    cache_key = key("abcdef" <> String.duplicate("2", 58))
    assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
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
               FileSystem.write_chunk(state, "not written", root: root)

      assert returned_state.size == state.size
      assert returned_state.hash_context == state.hash_context
    after
      File.close(body_io)
    end
  end

  test "sink abort removes temp files and leaves no visible entry", %{root: root} do
    cache_key = key("b" <> String.duplicate("1", 63))

    assert {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), root: root)
    assert {:ok, state} = FileSystem.write_chunk(state, "partial", root: root)
    assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
    assert Enum.any?(File.ls!(paths.dir), &String.ends_with?(&1, ".tmp"))

    assert :ok = FileSystem.abort_sink(state, root: root)
    assert FileSystem.get(cache_key, root: root) == :miss
    refute Enum.any?(File.ls!(paths.dir), &String.ends_with?(&1, ".tmp"))
  end

  test "sink abort treats temp cleanup errors as best effort", %{root: root} do
    cache_key = key("bcbcbc" <> String.duplicate("1", 58))
    assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
    File.mkdir_p!(paths.dir)
    temp_obstruction = Path.join(paths.dir, ".#{cache_key.hash}.forced.tmp")
    File.mkdir_p!(temp_obstruction)

    assert {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), root: root)

    assert :ok = FileSystem.abort_sink(%{state | temp_body_path: temp_obstruction}, root: root)
    assert FileSystem.get(cache_key, root: root) == :miss
  end

  test "sink commit cleans up when body rename fails", %{root: root} do
    cache_key = key("cecece" <> String.duplicate("1", 58))
    assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
    File.mkdir_p!(paths.dir)

    body_path = Path.join(paths.dir, body_filename(cache_key, "body"))
    File.mkdir_p!(body_path)

    assert {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), root: root)
    assert {:ok, state} = FileSystem.write_chunk(state, "body", root: root)

    assert {:error, _reason} = FileSystem.commit_sink(state, root: root)
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
          {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), root: root)
          {:ok, state} = FileSystem.write_chunk(state, body, root: root)
          FileSystem.commit_sink(state, root: root)
        end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == [:ok, :ok]
    assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root)
    assert cached_entry.body in ["body-one", "body-two"]
  end

  test "missing metadata or body is a miss", %{root: root} do
    cache_key = key("123456" <> String.duplicate("a", 58))
    assert FileSystem.get(cache_key, root: root) == :miss

    dir = Path.join([root, "12", "34"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, body_filename(cache_key, "body")), "body")

    assert FileSystem.get(cache_key, root: root) == :miss

    meta_only_key = key("223456" <> String.duplicate("a", 58))
    meta_only_dir = Path.join([root, "22", "34"])
    File.mkdir_p!(meta_only_dir)

    File.write!(
      Path.join(meta_only_dir, meta_only_key.hash <> ".meta"),
      :erlang.term_to_binary(metadata(meta_only_key, "body"))
    )

    assert FileSystem.get(meta_only_key, root: root) == :miss
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

    assert FileSystem.get(cache_key, root: root) ==
             {:error, {:invalid_metadata, :version_mismatch}}
  end

  test "body byte-size mismatch is returned as invalid metadata", %{root: root} do
    cache_key = key("bbbbbb" <> String.duplicate("c", 58))
    assert put_entry(cache_key, entry("12345"), root: root) == :ok

    dir = Path.join([root, "bb", "bb"])
    File.write!(Path.join(dir, body_filename(cache_key, "12345")), "123")

    assert FileSystem.get(cache_key, root: root) ==
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
          body_filename: "#{cache_key.hash}.not-a-sha256.body"
        )
      )
    )

    assert FileSystem.get(cache_key, root: root) ==
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
             FileSystem.get(cache_key, root: root)
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

    assert FileSystem.get(cache_key, root: root) ==
             {:error, {:invalid_metadata, :invalid_headers}}
  end

  test "cache hits trust same-size body files without digest recomputation", %{root: root} do
    cache_key = key("eeeeee" <> String.duplicate("1", 58))
    assert put_entry(cache_key, entry("body-one"), root: root) == :ok

    dir = Path.join([root, "ee", "ee"])
    File.write!(Path.join(dir, body_filename(cache_key, "body-one")), "body-two")

    assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root)
    assert cached_entry.body == "body-two"
  end

  test "metadata from an earlier concurrent writer still points at its own body", %{root: root} do
    cache_key = key("ababab" <> String.duplicate("1", 58))

    assert put_entry(cache_key, entry("body-one"), root: root) == :ok
    assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
    metadata_one = File.read!(paths.meta_path)

    assert put_entry(cache_key, entry("body-two"), root: root) == :ok
    File.write!(paths.meta_path, metadata_one)

    assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root)
    assert cached_entry.body == "body-one"
  end

  test "put succeeds when the content-addressed body already exists", %{root: root} do
    cache_key = key("adadad" <> String.duplicate("1", 58))
    assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
    File.mkdir_p!(paths.dir)
    File.write!(Path.join(paths.dir, body_filename(cache_key, "body")), "body")

    assert put_entry(cache_key, entry("body"), root: root) == :ok
    assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root)
    assert cached_entry.body == "body"
  end

  test "unexpected body read error is returned", %{root: root} do
    cache_key = key("fafafa" <> String.duplicate("2", 58))
    assert put_entry(cache_key, entry("body"), root: root) == :ok

    body_path = Path.join([root, "fa", "fa", body_filename(cache_key, "body")])
    File.rm!(body_path)
    File.mkdir_p!(body_path)

    assert FileSystem.get(cache_key, root: root) == {:error, {:body_read, :eisdir}}
  end

  test "cleans temp files when metadata write fails", %{root: root} do
    cache_key = key("cccccc" <> String.duplicate("d", 58))
    dir = Path.join([root, "cc", "cc"])
    File.mkdir_p!(dir)
    File.mkdir_p!(Path.join(dir, cache_key.hash <> ".meta"))

    assert {:error, _reason} = put_entry(cache_key, entry(), root: root)
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

    assert {:error, _reason} = put_entry(cache_key, entry("new body"), root: root)
    assert File.read!(body_path) == "old body"
  end

  test "keeps a content-addressed body orphan when metadata commit fails", %{root: root} do
    cache_key = key("cecece" <> String.duplicate("d", 58))
    assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
    File.mkdir_p!(paths.dir)
    File.mkdir_p!(paths.meta_path)

    new_body_path = Path.join(paths.dir, body_filename(cache_key, "new body"))

    assert {:error, _reason} = put_entry(cache_key, entry("new body"), root: root)
    assert File.exists?(new_body_path)
    refute File.ls!(paths.dir) |> Enum.any?(&String.ends_with?(&1, ".tmp"))
  end

  describe "cost_us metadata" do
    test "is persisted in the meta file and returned on hit", %{root: root} do
      cache_key = key()
      opts = [root: root]
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
      opts = [root: root, path_prefix: ""]

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

      assert {:ok, paths_a} = FileSystem.paths_from_hash(hash_a, root: root)
      assert {:ok, paths_b} = FileSystem.paths_from_hash(hash_b, root: root)

      assert paths_a.dir == Path.join([root, "aa", "bb"])
      assert paths_b.dir == Path.join([root, "cc", "dd"])
      assert paths_a.dir != paths_b.dir
    end
  end

  describe "child_spec/1" do
    test "returns a supervisor spec when max_size_bytes is set", %{root: root} do
      opts = [root: root, max_size_bytes: 10_000_000, node_id: "n1"]
      assert %{id: _, start: _} = FileSystem.child_spec(opts)
    end

    test "returns :ignore for unbounded mode" do
      assert FileSystem.child_spec(root: "/tmp") == :ignore
    end
  end

  describe "bounded mode config validation" do
    test "rejects max_size_bytes: 0" do
      assert {:error, _} = FileSystem.validate_options(root: "/tmp", max_size_bytes: 0)
    end

    test "rejects negative max_size_bytes" do
      assert {:error, _} = FileSystem.validate_options(root: "/tmp", max_size_bytes: -1)
    end

    test "rejects bounded options without max_size_bytes" do
      assert {:error, _} = FileSystem.validate_options(root: "/tmp", window_ratio: 0.5)
    end

    test "accepts a complete bounded config" do
      assert {:ok, _opts} =
               FileSystem.validate_options(
                 root: "/tmp",
                 max_size_bytes: 100_000_000,
                 node_id: "n1"
               )
    end

    test "derives sketch_width and doorkeeper_cardinality from max_size_bytes" do
      {:ok, opts} =
        FileSystem.validate_options(root: "/tmp", max_size_bytes: 10_000_000_000, node_id: "n1")

      assert opts[:sketch_width] == 400_000
      assert opts[:doorkeeper_cardinality] == 800_000
      assert opts[:doorkeeper_fpr] == 0.01
      assert opts[:eviction_victim_limit] == 64
      assert opts[:aging_sample_size] == 2_000_000
      assert opts[:reconcile_interval] == 60
    end

    test "aging_sample_size does not change when sketch_width is overridden" do
      {:ok, opts} =
        FileSystem.validate_options(
          root: "/tmp",
          max_size_bytes: 10_000_000_000,
          node_id: "n1",
          sketch_width: 16_384
        )

      assert opts[:sketch_width] == 16_384
      assert opts[:aging_sample_size] == 2_000_000
    end

    test "accepts custom :eviction_victim_limit" do
      {:ok, opts} =
        FileSystem.validate_options(
          root: "/tmp",
          max_size_bytes: 100_000_000,
          node_id: "n1",
          eviction_victim_limit: 32
        )

      assert opts[:eviction_victim_limit] == 32
    end

    test "rejects non-positive :eviction_victim_limit" do
      assert {:error, _} =
               FileSystem.validate_options(
                 root: "/tmp",
                 max_size_bytes: 100_000_000,
                 node_id: "n1",
                 eviction_victim_limit: 0
               )
    end

    test "rejects :window_ratio outside [0.0, 1.0]" do
      assert {:error, _} =
               FileSystem.validate_options(
                 root: "/tmp",
                 max_size_bytes: 100_000_000,
                 node_id: "n1",
                 window_ratio: 1.5
               )
    end

    test "accepts :window_ratio of 0.0 (window disabled)" do
      assert {:ok, opts} =
               FileSystem.validate_options(
                 root: "/tmp",
                 max_size_bytes: 100_000_000,
                 node_id: "n1",
                 window_ratio: 0.0
               )

      assert opts[:window_ratio] == 0.0
    end

    test "rejects :doorkeeper_fpr outside (0.0, 1.0)" do
      assert {:error, _} =
               FileSystem.validate_options(
                 root: "/tmp",
                 max_size_bytes: 100_000_000,
                 node_id: "n1",
                 doorkeeper_fpr: 1.0
               )
    end
  end

  test "concurrent puts for the same key leave a readable entry", %{root: root} do
    cache_key = key("dddddd" <> String.duplicate("e", 58))

    results =
      ["body-one", "body-two"]
      |> Task.async_stream(
        fn body -> put_entry(cache_key, entry(body), root: root) end,
        max_concurrency: 2,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == [:ok, :ok]
    assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root)
    assert cached_entry.body in ["body-one", "body-two"]
  end
end
