defmodule ImagePipe.Cache.FileReadTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry.Metadata
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.Key

  setup do
    root = Path.join(System.tmp_dir!(), "image-pipe-read-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "a pinned cache hit survives eviction and delivers bounded chunks", %{root: root} do
    body = :binary.copy("image", 40_000)
    key = put(root, body)
    assert {:hit, entry} = Cache.lookup_entry(key, cache: {FileSystem, root: root})
    assert %Cache.File{} = entry.body
    File.rm_rf!(Path.join(root, "aa"))
    chunks = Enum.to_list(Cache.File.stream(entry.body))
    assert Enum.all?(chunks, &(byte_size(&1) <= 65_536))
    assert IO.iodata_to_binary(chunks) == body
    Cache.Entry.close(entry)
  end

  test "same-size corruption is rejected before delivery", %{root: root} do
    key = put(root, "image")
    [body] = Path.wildcard(Path.join(root, "**/*.body"))
    File.write!(body, "wrong")

    assert {:miss, ^key, {:cache_read, _}} =
             Cache.lookup_entry(key, cache: {FileSystem, root: root})
  end

  test "input invalidation releases bounded cache accounting", %{root: root} do
    opts = [root: root, node_id: "test", max_size_bytes: 100, window_ratio: 1.0]
    start_supervised!(FileSystem.child_spec(opts))
    [{admission, _}] = Registry.lookup(FileSystem.registry_name(root), {root, "test"})
    assert :ok = Admission.await_scan(admission)
    key = put(root, "image", opts)
    assert :sys.get_state(admission).window_bytes == 5

    assert :ok = Cache.Input.discard(key, input_cache: {FileSystem, opts})
    assert FileSystem.get(key, opts) == :miss
    state = :sys.get_state(admission)
    assert state.window_bytes + state.probationary_bytes + state.protected_bytes == 0
  end

  test "invalidation releases accounting even when the body is already missing", %{root: root} do
    opts = [root: root, node_id: "test", max_size_bytes: 100, window_ratio: 1.0]
    start_supervised!(FileSystem.child_spec(opts))
    [{admission, _}] = Registry.lookup(FileSystem.registry_name(root), {root, "test"})
    assert :ok = Admission.await_scan(admission)
    key = put(root, "image", opts)
    [body] = Path.wildcard(Path.join(root, "**/*.body"))
    File.rm!(body)

    assert {:error, :enoent} = Cache.Input.discard(key, input_cache: {FileSystem, opts})
    assert :sys.get_state(admission).window_bytes == 0
    assert FileSystem.get(key, opts) == :miss
  end

  test "failed metadata invalidation retains the body and accounting", %{root: root} do
    opts = [root: root, node_id: "test", max_size_bytes: 100, window_ratio: 1.0]
    start_supervised!(FileSystem.child_spec(opts))
    [{admission, _}] = Registry.lookup(FileSystem.registry_name(root), {root, "test"})
    assert :ok = Admission.await_scan(admission)
    key = put(root, "image", opts)
    {:ok, paths} = FileSystem.paths(key, opts)
    File.rm!(paths.meta_path)
    File.mkdir!(paths.meta_path)

    assert {:error, _} = Cache.Input.discard(key, input_cache: {FileSystem, opts})
    assert :sys.get_state(admission).window_bytes == 5
    assert [body] = Path.wildcard(Path.join(root, "**/*.body"))
    assert File.read!(body) == "image"
  end

  defp put(root, body, opts \\ nil) do
    opts = opts || [root: root]
    key = %Key{hash: String.duplicate("a", 64), data: []}

    metadata = %Metadata{
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now(),
      output_format: :jpeg
    }

    {:ok, sink} = FileSystem.open_sink(key, metadata, opts)
    {:ok, sink} = FileSystem.write_chunk(sink, body, opts)
    :ok = FileSystem.commit_sink(sink, opts)
    key
  end

  test "invalidation rejects serialized filenames outside the entry", %{root: root} do
    key = put(root, "image")
    {:ok, paths} = FileSystem.paths(key, root: root)
    outside = Path.join(root, "unrelated")
    File.write!(outside, "keep")
    metadata = paths.meta_path |> File.read!() |> :erlang.binary_to_term()

    File.write!(
      paths.meta_path,
      :erlang.term_to_binary(%{metadata | body_filename: "../../unrelated"})
    )

    assert {:error, _} = Cache.Input.discard(key, input_cache: {FileSystem, root: root})
    assert File.read!(outside) == "keep"
  end
end
