defmodule ImagePipe.Cache.FileReadTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry.Metadata
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.Key
  alias ImagePipe.Test.Caches

  @max_size_bytes 1_000_000_000

  setup do
    root = Path.join(System.tmp_dir!(), "image-pipe-read-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "a pinned cache hit survives eviction and delivers bounded chunks", %{root: root} do
    body = :binary.copy("image", 40_000)
    key = put(root, body)

    assert {:hit, entry} =
             Cache.lookup_entry(key, cache: [root: root, max_size_bytes: @max_size_bytes])

    assert %Cache.File{} = entry.body
    File.rm_rf!(Path.join(root, "aa"))
    chunks = Enum.to_list(Cache.File.stream(entry.body))
    assert Enum.all?(chunks, &(byte_size(&1) <= 65_536))
    assert IO.iodata_to_binary(chunks) == body
    Cache.Entry.close(entry)
  end

  test "a truncated body is rejected before delivery", %{root: root} do
    key = put(root, "image")
    [body] = Path.wildcard(Path.join(root, "**/*.body"))
    File.write!(body, "imag")

    assert {:miss, ^key, {:cache_read, _}} =
             Cache.lookup_entry(key, cache: [root: root, max_size_bytes: @max_size_bytes])
  end

  for corruption <- [:overwrite, :bit_flip] do
    test "checksum verification detects equal-length #{corruption}", %{root: root} do
      original = :binary.copy("image", 40_000)
      key = put(root, original)
      [path] = Path.wildcard(Path.join(root, "**/*.body"))

      changed =
        case unquote(corruption) do
          :overwrite ->
            <<prefix::binary-size(65_536), _range::binary-size(1_024), tail::binary>> = original
            IO.iodata_to_binary([prefix, :binary.copy("x", 1_024), tail])

          :bit_flip ->
            <<prefix::binary-size(65_536), byte, tail::binary>> = original
            <<prefix::binary, Bitwise.bxor(byte, 1), tail::binary>>
        end

      File.write!(path, changed)
      assert File.stat!(path).size == byte_size(original)

      assert {:error, {:invalid_metadata, :body_digest_mismatch}} =
               Cache.Input.verify(key, input_cache: [root: root, max_size_bytes: @max_size_bytes])
    end
  end

  test "input invalidation releases cache accounting", %{root: root} do
    opts = [root: root, max_size_bytes: 100]
    start_supervised!(FileSystem.child_spec(opts))
    [{admission, _}] = Registry.lookup(FileSystem.registry_name(root), root)
    assert :ok = Admission.await_scan(admission)
    key = put(root, "image", opts)
    assert :sys.get_state(admission).stored_bytes == 5

    assert :ok = Cache.Input.discard(key, input_cache: opts)
    assert FileSystem.get(key, opts) == :miss
    assert :sys.get_state(admission).stored_bytes == 0
  end

  test "invalidation releases accounting even when the body is already missing", %{root: root} do
    opts = [root: root, max_size_bytes: 100]
    start_supervised!(FileSystem.child_spec(opts))
    [{admission, _}] = Registry.lookup(FileSystem.registry_name(root), root)
    assert :ok = Admission.await_scan(admission)
    key = put(root, "image", opts)
    [body] = Path.wildcard(Path.join(root, "**/*.body"))
    File.rm!(body)

    assert {:error, :enoent} = Cache.Input.discard(key, input_cache: opts)
    assert :sys.get_state(admission).stored_bytes == 0
    assert FileSystem.get(key, opts) == :miss
  end

  test "failed metadata invalidation retains the body and accounting", %{root: root} do
    opts = [root: root, max_size_bytes: 100]
    start_supervised!(FileSystem.child_spec(opts))
    [{admission, _}] = Registry.lookup(FileSystem.registry_name(root), root)
    assert :ok = Admission.await_scan(admission)
    key = put(root, "image", opts)
    {:ok, paths} = FileSystem.paths(key, opts)
    File.rm!(paths.meta_path)
    File.mkdir!(paths.meta_path)

    assert {:error, _} = Cache.Input.discard(key, input_cache: opts)
    assert :sys.get_state(admission).stored_bytes == 5
    assert [body] = Path.wildcard(Path.join(root, "**/*.body"))
    assert File.read!(body) == "image"
  end

  defp put(root, body, opts \\ nil) do
    opts = opts || [root: root, max_size_bytes: @max_size_bytes]
    key = %Key{hash: String.duplicate("a", 64), data: []}

    metadata = %Metadata{
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now(),
      output_format: :jpeg
    }

    Caches.write!(opts, key, metadata, body)
    key
  end

  test "invalidation rejects serialized filenames outside the entry", %{root: root} do
    key = put(root, "image")
    {:ok, paths} = FileSystem.paths(key, root: root, max_size_bytes: @max_size_bytes)
    outside = Path.join(root, "unrelated")
    File.write!(outside, "keep")
    metadata = paths.meta_path |> File.read!() |> :erlang.binary_to_term()

    File.write!(
      paths.meta_path,
      :erlang.term_to_binary(%{metadata | body_filename: "../../unrelated"})
    )

    assert {:error, _} =
             Cache.Input.discard(key, input_cache: [root: root, max_size_bytes: @max_size_bytes])

    assert File.read!(outside) == "keep"
  end
end
