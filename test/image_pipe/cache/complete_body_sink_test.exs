defmodule ImagePipe.Cache.CompleteBodySinkTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key

  @content_type "text/plain; charset=utf-8"
  @hash "LEHV6nWB2yk8pyo0adR*.7kCMdnj"

  # Records the metadata/entry an adapter observes, without persisting
  # anything — enough to assert the sink builds the right shape.
  defmodule RecordingAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: :miss

    def open_sink(%Key{} = key, %Entry.Metadata{} = metadata, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:open_sink, key, metadata})
      {:ok, %{chunks: [], metadata: metadata, opts: opts}}
    end

    def write_chunk(state, chunk, _opts) when is_binary(chunk) do
      {:ok, %{state | chunks: [chunk | state.chunks]}}
    end

    def commit_sink(state, opts) do
      body = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()

      entry = %Entry{
        body: body,
        content_type: state.metadata.content_type,
        headers: state.metadata.headers,
        created_at: state.metadata.created_at,
        representation: state.metadata.representation
      }

      send(Keyword.fetch!(opts, :test_pid), {:commit_sink, entry})
      :ok
    end

    def abort_sink(_state, _opts), do: :ok
  end

  # A real round-trip store (ETS-backed): commit persists, get looks up —
  # enough to prove a warmed complete-body entry is served on hit through the
  # same `Cache.lookup_entry/2` path an image entry uses.
  defmodule StoreAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{} = key, opts) do
      table = Keyword.fetch!(opts, :table)

      case :ets.lookup(table, key.hash) do
        [{_hash, entry}] -> {:hit, entry}
        [] -> :miss
      end
    end

    def open_sink(%Key{} = key, %Entry.Metadata{} = metadata, _opts) do
      {:ok, %{key: key, metadata: metadata, chunks: []}}
    end

    def write_chunk(state, chunk, _opts) when is_binary(chunk) do
      {:ok, %{state | chunks: [chunk | state.chunks]}}
    end

    def commit_sink(state, opts) do
      table = Keyword.fetch!(opts, :table)
      body = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()

      entry = %Entry{
        body: body,
        content_type: state.metadata.content_type,
        headers: state.metadata.headers,
        created_at: state.metadata.created_at,
        representation: state.metadata.representation
      }

      :ets.insert(table, {state.key.hash, entry})
      :ok
    end

    def abort_sink(_state, _opts), do: :ok
  end

  defmodule FailingOpenAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:error, :open_failed}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defp cache_key, do: %Key{hash: String.duplicate("a", 64), data: [schema_version: 2]}

  test "open_sink builds metadata tagged {:complete_body, content_type}, output_format nil" do
    Cache.open_sink(cache_key(), {:complete_body, @content_type},
      cache: {RecordingAdapter, test_pid: self()}
    )

    assert_received {:open_sink, %Key{}, %Entry.Metadata{} = metadata}
    assert metadata.content_type == @content_type
    assert metadata.representation == {:complete_body, @content_type}
    assert metadata.output_format == nil
    assert metadata.headers == []
  end

  test "entry round-trips through write_chunk/commit_sink with the complete-body content type" do
    sink =
      cache_key()
      |> Cache.open_sink({:complete_body, @content_type},
        cache: {RecordingAdapter, test_pid: self()}
      )
      |> Cache.write_chunk(@hash, cache: {RecordingAdapter, test_pid: self()})

    assert :ok = Cache.commit_sink(sink, cache: {RecordingAdapter, test_pid: self()})

    assert_received {:commit_sink, %Entry{} = entry}
    assert entry.body == @hash
    assert entry.content_type == @content_type
    assert entry.representation == {:complete_body, @content_type}
    assert Entry.validate(entry) == :ok
  end

  test "a warmed complete-body entry is served on hit with the right content type" do
    table = :ets.new(:complete_body_cache_test, [:set, :public])
    cache = {StoreAdapter, table: table}
    key = cache_key()

    key
    |> Cache.open_sink({:complete_body, @content_type}, cache: cache)
    |> Cache.write_chunk(@hash, cache: cache)
    |> Cache.commit_sink(cache: cache)

    assert {:hit, %Entry{} = entry} = Cache.lookup_entry(key, cache: cache)
    assert entry.content_type == @content_type
    assert entry.representation == {:complete_body, @content_type}
    assert entry.body == @hash
  end

  test "fail-open preserved on sink open errors" do
    log =
      capture_log(fn ->
        assert Cache.open_sink(cache_key(), {:complete_body, @content_type},
                 cache: {FailingOpenAdapter, []}
               ) == nil
      end)

    assert log =~ "cache sink open error"
  end

  test "existing image-entry validation is unchanged" do
    valid = %Entry{
      body: "encoded image",
      content_type: "image/webp",
      headers: [{"vary", "Accept"}],
      created_at: ~U[2026-04-29 10:15:00Z]
    }

    assert Entry.validate(valid) == :ok

    invalid = %{valid | content_type: "text/plain"}
    assert {:error, {:unsupported_output_format, "text/plain"}} = Entry.validate(invalid)

    # Explicitly tagging {:image, _} keeps the exact same behavior.
    tagged = %{valid | representation: {:image, :webp}}
    assert Entry.validate(tagged) == :ok

    tagged_invalid = %{invalid | representation: {:image, :webp}}
    assert {:error, {:unsupported_output_format, "text/plain"}} = Entry.validate(tagged_invalid)
  end
end
