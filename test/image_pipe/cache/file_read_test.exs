defmodule ImagePipe.Cache.FileReadTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry.Metadata
  alias ImagePipe.Cache.FileSystem
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

  defp put(root, body) do
    key = %Key{hash: String.duplicate("a", 64), data: []}

    metadata = %Metadata{
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now(),
      output_format: :jpeg
    }

    {:ok, sink} = FileSystem.open_sink(key, metadata, root: root)
    {:ok, sink} = FileSystem.write_chunk(sink, body, root: root)
    :ok = FileSystem.commit_sink(sink, root: root)
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
