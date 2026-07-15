defmodule ImagePipe.Cache.LookupEntryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key

  defmodule HitAdapter do
    def get(%Key{}, opts), do: {:hit, Keyword.fetch!(opts, :entry)}
  end

  defmodule MissAdapter do
    def get(%Key{}, _opts), do: :miss
  end

  defmodule ErrorAdapter do
    def get(%Key{}, _opts), do: {:error, :read_failed}
  end

  defp key do
    %Key{hash: String.duplicate("a", 64), data: [schema_version: 2]}
  end

  defp entry(body \\ "body") do
    %Entry{
      body: body,
      content_type: "image/webp",
      headers: [],
      created_at: ~U[2026-04-29 10:15:00Z]
    }
  end

  test "returns :disabled when no cache is configured" do
    assert Cache.lookup_entry(key(), []) == :disabled
  end

  test "returns a miss with the given key" do
    assert Cache.lookup_entry(key(), cache: {MissAdapter, []}) == {:miss, key()}
  end

  test "returns a hit entry via the adapter, without re-wrapping the key" do
    configured_entry = entry()

    assert Cache.lookup_entry(key(), cache: {HitAdapter, entry: configured_entry}) ==
             {:hit, configured_entry}
  end

  test "an invalid hit entry is a fail-open cache read error" do
    invalid_entry = %Entry{
      body: "body",
      content_type: "image/gif",
      headers: [],
      created_at: ~U[2026-04-29 10:15:00Z]
    }

    log =
      capture_log(fn ->
        assert {:miss, returned_key, {:cache_read, {:invalid_entry, _reason}}} =
                 Cache.lookup_entry(key(), cache: {HitAdapter, entry: invalid_entry})

        assert returned_key == key()
      end)

    assert log =~ "cache read error"
  end

  test "read errors fail open and are logged" do
    log =
      capture_log(fn ->
        assert {:miss, returned_key, {:cache_read, :read_failed}} =
                 Cache.lookup_entry(key(), cache: {ErrorAdapter, []})

        assert returned_key == key()
      end)

    assert log =~ "cache read error"
    assert log =~ ":read_failed"
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

    test "emits a [:cache, :lookup] span for a miss", %{prefix: prefix} do
      Cache.lookup_entry(key(), cache: {MissAdapter, []}, telemetry_prefix: prefix)

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
