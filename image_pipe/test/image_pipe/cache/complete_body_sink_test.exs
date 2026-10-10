defmodule ImagePipe.Cache.CompleteBodySinkTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Key

  @content_type "text/plain; charset=utf-8"
  @hash "LEHV6nWB2yk8pyo0adR*.7kCMdnj"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "complete-body-sink-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.chmod(root, 0o700)
      File.rm_rf(root)
    end)

    %{root: root, opts: Cache.validate_config!(cache: [root: root])}
  end

  defp cache_key, do: %Key{hash: String.duplicate("a", 64), data: [schema_version: 2]}

  test "a warmed complete-body entry is served on hit with the right content type", %{
    opts: opts
  } do
    key = cache_key()

    sink =
      key
      |> Cache.open_sink({:complete_body, @content_type}, [], opts)
      |> Cache.write_chunk(@hash, opts)

    assert :ok = Cache.commit_sink(sink, opts)

    assert {:hit, %Entry{} = entry} = Cache.lookup_entry(key, opts)
    Entry.close(entry)
    assert entry.content_type == @content_type
    assert entry.representation == {:complete_body, @content_type}
    assert entry.headers == []

    assert {:hit, %Entry{body: @hash}} = FileSystem.get(key, Keyword.fetch!(opts, :cache))
  end

  test "fail-open preserved on sink open errors", %{root: root, opts: opts} do
    File.chmod!(root, 0o500)

    log =
      capture_log(fn ->
        assert Cache.open_sink(cache_key(), {:complete_body, @content_type}, [], opts) == nil
      end)

    assert log =~ "cache sink open error"
  end
end
