defmodule ImagePipe.Cache.LookupEntryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Key

  setup do
    root = Path.join(System.tmp_dir!(), "lookup-entry-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    opts = Cache.validate_config!(cache: [root: root])
    %{opts: opts}
  end

  defp key do
    %Key{hash: String.duplicate("a", 64), data: [schema_version: 2]}
  end

  defp store(opts, body) do
    key()
    |> Cache.open_sink({:complete_body, "text/plain"}, opts)
    |> Cache.write_chunk(body, opts)
    |> Cache.commit_sink(opts)
  end

  defp rewrite_metadata(opts, fun) do
    {:ok, %{meta_path: meta_path}} = FileSystem.paths(key(), Keyword.fetch!(opts, :cache))

    metadata = meta_path |> File.read!() |> :erlang.binary_to_term()
    File.write!(meta_path, :erlang.term_to_binary(fun.(metadata)))
  end

  test "returns :disabled when no cache is configured" do
    assert Cache.lookup_entry(key(), []) == :disabled
  end

  test "returns a miss with the given key", %{opts: opts} do
    assert Cache.lookup_entry(key(), opts) == {:miss, key()}
  end

  test "returns a stored entry as a hit", %{opts: opts} do
    store(opts, "body")

    assert {:hit, %Entry{content_type: "text/plain"} = entry} = Cache.lookup_entry(key(), opts)
    Entry.close(entry)
  end

  test "an invalid stored entry is a fail-open cache read error", %{opts: opts} do
    store(opts, "body")
    rewrite_metadata(opts, &%{&1 | content_type: "image/gif", representation: nil})

    log =
      capture_log(fn ->
        assert {:miss, returned_key, {:cache_read, {:invalid_metadata, _reason}}} =
                 Cache.lookup_entry(key(), opts)

        assert returned_key == key()
      end)

    assert log =~ "cache read error"
  end

  test "read errors fail open and are logged", %{opts: opts} do
    store(opts, "body")
    {:ok, %{meta_path: meta_path}} = FileSystem.paths(key(), Keyword.fetch!(opts, :cache))
    File.write!(meta_path, "not metadata")

    log =
      capture_log(fn ->
        assert {:miss, returned_key, {:cache_read, _reason}} = Cache.lookup_entry(key(), opts)
        assert returned_key == key()
      end)

    assert log =~ "cache read error"
  end

  describe "telemetry" do
    setup do
      prefix = [:lookup_entry_test]
      events = [prefix ++ [:cache, :lookup, :start], prefix ++ [:cache, :lookup, :stop]]

      handler_id = {__MODULE__, self(), make_ref()}
      :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{prefix: prefix}
    end

    test "emits a [:cache, :lookup] span for a miss", %{prefix: prefix, opts: opts} do
      Cache.lookup_entry(key(), Keyword.put(opts, :telemetry_prefix, prefix))

      assert_receive {:telemetry, :start, _measurements, %{}}
      assert_receive {:telemetry, :stop, _measurements, %{result: :ok, cache: :miss}}
    end

    test "emits a [:cache, :lookup] span with :disabled when no cache is configured", %{
      prefix: prefix
    } do
      Cache.lookup_entry(key(), telemetry_prefix: prefix)

      assert_receive {:telemetry, :start, _measurements, %{cache: :disabled}}
      assert_receive {:telemetry, :stop, _measurements, %{result: :ok, cache: :disabled}}
    end
  end

  def handle_event(event, measurements, metadata, test_pid) do
    phase = List.last(event)
    send(test_pid, {:telemetry, phase, measurements, metadata})
  end
end
