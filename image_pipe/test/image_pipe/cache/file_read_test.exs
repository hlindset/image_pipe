defmodule ImagePipe.Cache.FileReadTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry.Metadata
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
end
