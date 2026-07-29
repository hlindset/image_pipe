defmodule ImagePipe.CacheTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key
  alias ImagePipe.Output.Resolved

  defmodule MissAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule NormalizingAdapter do
    @behaviour ImagePipe.Cache

    def validate_options(opts) do
      {:ok,
       opts
       |> Keyword.drop([:drop_me])
       |> Keyword.put(:normalized?, true)}
    end

    def get(%Key{}, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:normalized_cache_get, opts})
      :miss
    end

    def open_sink(%Key{}, %Entry.Metadata{}, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:normalized_open_sink, opts})
      {:ok, %{}}
    end

    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule ErrorAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: {:error, :read_failed}
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:error, :open_failed}
    def write_chunk(state, _chunk, _opts), do: {:error, :write_failed, state}
    def commit_sink(_state, _opts), do: {:error, :commit_failed}
    def abort_sink(_state, _opts), do: {:error, :abort_failed}
  end

  defmodule UnexpectedResultAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: :surprise
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: :surprise
    def abort_sink(_state, _opts), do: :surprise
  end

  defmodule MissingSinkCallbacksAdapter do
    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
  end

  defmodule SinkMissAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: :miss

    def open_sink(%Key{} = key, %Entry.Metadata{} = metadata, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:open_sink, key, metadata, opts})
      {:ok, %{chunks: [], opts: opts}}
    end

    def write_chunk(state, chunk, _opts) when is_binary(chunk) do
      send(Keyword.fetch!(state.opts, :test_pid), {:write_chunk, chunk})
      {:ok, %{state | chunks: [chunk | state.chunks]}}
    end

    def commit_sink(state, _opts) do
      send(Keyword.fetch!(state.opts, :test_pid), {:commit_sink, state.chunks})
      :ok
    end

    def abort_sink(state, _opts) do
      send(Keyword.fetch!(state.opts, :test_pid), {:abort_sink, state.chunks})
      :ok
    end
  end

  defmodule SinkWriteErrorAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{aborted?: false}}
    def write_chunk(state, _chunk, _opts), do: {:error, :write_failed, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule SinkCommitErrorAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: {:error, :commit_failed}
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule SinkAbortErrorAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: {:error, :abort_failed}
  end

  defmodule SinkAdmissionRejectedAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: {:ok, :rejected}
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule RaisingGetAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: raise("adapter get crashed")
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule RaisingCommitAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: raise("adapter commit crashed")
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule LegacyPutOnlyAdapter do
    def get(%Key{}, _opts), do: :miss
    def put(%Key{}, %Entry{}, _opts), do: :ok
  end

  defp cache_key do
    %Key{
      hash: String.duplicate("a", 64),
      data: [schema_version: 2]
    }
  end

  # A minimal declarative mount; every init case below differs only in `cache:`.
  defp mount(extra) do
    [
      dialect: ImagePipe.Dialect.IIIF,
      resolver: {ImagePipe.Dialect.IIIF.Resolver.Static, map: %{}},
      sources: [path: {ImagePipe.Source.File, root: "priv/static", root_id: "static"}]
    ] ++ extra
  end

  defp resolved_output do
    %Resolved{
      format: :webp,
      quality: nil,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  test "ImagePipe init rejects invalid cache config early" do
    for cache <- [
          {__MODULE__.DoesNotExist, []},
          {MissingSinkCallbacksAdapter, []},
          {MissAdapter, [max_body_bytes: "10MB"]}
        ] do
      assert_raise ArgumentError, ~r/invalid cache config/, fn ->
        ImagePipe.Plug.init(mount(cache: cache))
      end
    end
  end

  test "ImagePipe init rejects header/cookie cache partitioning options" do
    for key <- [:key_headers, :key_cookies] do
      assert_raise ArgumentError, ~r/#{key} was removed.*storage_inputs:/s, fn ->
        ImagePipe.Plug.init(mount(cache: {MissAdapter, [{key, ["accept-language"]}]}))
      end
    end
  end

  test "ImagePipe init rejects a mount missing a required dialect option early" do
    assert_raise ArgumentError, ~r/required :resolver option not found/, fn ->
      ImagePipe.Plug.init(dialect: ImagePipe.Dialect.IIIF)
    end
  end

  test "ImagePipe init rejects invalid filesystem cache options early" do
    for cache <- [
          {ImagePipe.Cache.FileSystem, [root: "relative/cache"]},
          {ImagePipe.Cache.FileSystem, [root: System.tmp_dir!(), path_prefix: "../outside"]},
          {ImagePipe.Cache.FileSystem,
           [root: System.tmp_dir!(), path_prefix: "processed//images"]}
        ] do
      assert_raise ArgumentError, ~r/invalid cache config/, fn ->
        ImagePipe.Plug.init(mount(cache: cache))
      end
    end
  end

  test "ImagePipe init preserves normalized filesystem cache options" do
    root = Path.join(System.tmp_dir!(), "image_pipe_cache_init")

    opts =
      ImagePipe.Plug.init(
        mount(cache: {ImagePipe.Cache.FileSystem, root: root <> "/../image_pipe_cache_init"})
      )

    assert {ImagePipe.Cache.FileSystem, cache_opts} = Keyword.fetch!(opts, :cache)
    assert cache_opts[:root] == Path.expand(root)
    assert cache_opts[:path_prefix] == ""
  end

  test "lookup returns miss when adapter.get raises" do
    log =
      capture_log(fn ->
        assert {:miss, %Key{}, {:cache_read, %RuntimeError{message: "adapter get crashed"}}} =
                 Cache.lookup_entry(cache_key(), cache: {RaisingGetAdapter, []})
      end)

    assert log =~ "cache read error"
  end

  test "unexpected adapter get result is handled as a cache read error" do
    log =
      capture_log(fn ->
        assert {:miss, %Key{}, {:cache_read, {:invalid_adapter_result, :surprise}}} =
                 Cache.lookup_entry(cache_key(), cache: {UnexpectedResultAdapter, []})
      end)

    assert log =~ "cache read error"
    assert log =~ ":surprise"
  end

  test "open_sink threads cost_us from opts into adapter metadata" do
    Cache.open_sink(
      cache_key(),
      resolved_output(),
      cache: {SinkMissAdapter, test_pid: self()},
      cost_us: 42_000
    )

    assert_received {:open_sink, %Key{}, %Entry.Metadata{cost_us: 42_000}, _adapter_opts}
  end

  test "open_sink builds body-free metadata from resolved output" do
    resolved_output = %Resolved{
      format: :webp,
      quality: nil,
      response_headers: [{"Vary", "Accept"}, {"x-private", "drop"}],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }

    sink =
      Cache.open_sink(cache_key(), resolved_output, cache: {SinkMissAdapter, test_pid: self()})

    assert_received {:open_sink, %Key{}, %Entry.Metadata{} = metadata, adapter_opts}
    assert metadata.content_type == "image/webp"
    assert metadata.headers == [{"vary", "Accept"}]
    assert %DateTime{} = metadata.created_at
    assert metadata.output_format == :webp
    assert Keyword.fetch!(adapter_opts, :test_pid) == self()
    assert sink
  end

  test "write_chunk and commit_sink dispatch through the adapter sink state" do
    sink =
      cache_key()
      |> Cache.open_sink(resolved_output(), cache: {SinkMissAdapter, test_pid: self()})
      |> Cache.write_chunk("abc", cache: {SinkMissAdapter, test_pid: self()})
      |> Cache.write_chunk("def", cache: {SinkMissAdapter, test_pid: self()})

    assert :ok = Cache.commit_sink(sink, cache: {SinkMissAdapter, test_pid: self()})
    assert_received {:write_chunk, "abc"}
    assert_received {:write_chunk, "def"}
    assert_received {:commit_sink, ["def", "abc"]}
  end

  test "abort_sink dispatches cleanup and returns ok" do
    sink =
      Cache.open_sink(cache_key(), resolved_output(), cache: {SinkMissAdapter, test_pid: self()})

    assert :ok = Cache.abort_sink(sink, :cancelled, cache: {SinkMissAdapter, test_pid: self()})
    assert_received {:abort_sink, []}
  end

  test "open_sink fails open and logs adapter errors" do
    attach_telemetry([[:image_pipe, :cache, :stage]])

    log =
      capture_log(fn ->
        assert Cache.open_sink(cache_key(), resolved_output(), cache: {ErrorAdapter, []}) == nil
      end)

    assert log =~ "cache sink open error"
    assert log =~ ":open_failed"

    assert_receive {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                    %{cache: :stage_error, error: :open_failed, output_format: :webp}}
  end

  test "write_chunk drops the sink when max_body_bytes would be crossed" do
    attach_telemetry([[:image_pipe, :cache, :stage]])

    sink =
      Cache.open_sink(cache_key(), resolved_output(),
        cache: {SinkMissAdapter, test_pid: self(), max_body_bytes: 3}
      )

    assert Cache.write_chunk(sink, "abcd",
             cache: {SinkMissAdapter, test_pid: self(), max_body_bytes: 3}
           ) == nil

    assert_received {:abort_sink, []}

    assert_receive {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                    %{cache: :stage_skipped, reason: :too_large, output_format: :webp}}
  end

  test "write_chunk adapter errors abort and fail open" do
    attach_telemetry([[:image_pipe, :cache, :stage]])

    sink = Cache.open_sink(cache_key(), resolved_output(), cache: {SinkWriteErrorAdapter, []})

    assert Cache.write_chunk(sink, "abc", cache: {SinkWriteErrorAdapter, []}) == nil

    assert_receive {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                    %{cache: :stage_error, error: :write_failed, output_format: :webp}}
  end

  test "commit_sink adapter errors fail open through cache write telemetry" do
    attach_telemetry([[:image_pipe, :cache, :write, :stop]])

    sink =
      cache_key()
      |> Cache.open_sink(resolved_output(), cache: {SinkCommitErrorAdapter, []})
      |> Cache.write_chunk("abc", cache: {SinkCommitErrorAdapter, []})

    assert :ok = Cache.commit_sink(sink, cache: {SinkCommitErrorAdapter, []})

    assert_receive {:telemetry_event, [:image_pipe, :cache, :write, :stop], _measurements,
                    %{result: :cache_error, cache: :write_error, error: :commit_failed}}
  end

  test "commit_sink returns :ok and logs when adapter.commit_sink raises" do
    attach_telemetry([[:image_pipe, :cache, :write, :stop]])

    sink =
      cache_key()
      |> Cache.open_sink(resolved_output(), cache: {RaisingCommitAdapter, []})
      |> Cache.write_chunk("abc", cache: {RaisingCommitAdapter, []})

    log =
      capture_log(fn ->
        assert :ok = Cache.commit_sink(sink, cache: {RaisingCommitAdapter, []})
      end)

    assert log =~ "cache sink commit error"

    assert_receive {:telemetry_event, [:image_pipe, :cache, :write, :stop], _measurements,
                    %{result: :cache_error, cache: :write_error}}
  end

  test "commit_sink reports admission rejection on the cache write span" do
    attach_telemetry([[:image_pipe, :cache, :write, :stop]])

    sink =
      cache_key()
      |> Cache.open_sink(resolved_output(), cache: {SinkAdmissionRejectedAdapter, []})
      |> Cache.write_chunk("abc", cache: {SinkAdmissionRejectedAdapter, []})

    # Rejection is a successful, non-error outcome: the request path fails open
    # (nothing stored) and Cache.commit_sink still returns :ok.
    assert :ok = Cache.commit_sink(sink, cache: {SinkAdmissionRejectedAdapter, []})

    assert_receive {:telemetry_event, [:image_pipe, :cache, :write, :stop], _measurements,
                    %{result: :ok, cache: :admission_rejected, output_format: :webp}}
  end

  test "abort_sink adapter errors fail open through cleanup telemetry" do
    attach_telemetry([[:image_pipe, :cache, :stage]])

    sink =
      cache_key()
      |> Cache.open_sink(resolved_output(), cache: {SinkAbortErrorAdapter, []})
      |> Cache.write_chunk("abc", cache: {SinkAbortErrorAdapter, []})

    assert :ok = Cache.abort_sink(sink, :cancelled, cache: {SinkAbortErrorAdapter, []})

    assert_receive {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                    %{cache: :stage_cleanup_error, error: :abort_failed, output_format: :webp}}
  end

  test "adapter runtime opts use validated adapter options without raw adapter config leftovers" do
    cache_opts = [
      max_body_bytes: 10_000,
      test_pid: self(),
      drop_me: true
    ]

    opts = Cache.validate_config!(cache: {NormalizingAdapter, cache_opts})

    assert {:miss, %Key{}} = Cache.lookup_entry(cache_key(), opts)

    assert_received {:normalized_cache_get, runtime_opts}
    assert Keyword.fetch!(runtime_opts, :max_body_bytes) == 10_000
    assert Keyword.fetch!(runtime_opts, :test_pid) == self()
    assert Keyword.fetch!(runtime_opts, :normalized?)
    refute Keyword.has_key?(runtime_opts, :drop_me)

    assert Cache.open_sink(cache_key(), resolved_output(), opts)

    assert_received {:normalized_open_sink, sink_opts}
    assert Keyword.fetch!(sink_opts, :max_body_bytes) == 10_000
    assert Keyword.fetch!(sink_opts, :test_pid) == self()
    assert Keyword.fetch!(sink_opts, :normalized?)
    refute Keyword.has_key?(sink_opts, :drop_me)
  end

  test "unexpected adapter commit result is handled as a cache write error" do
    log =
      capture_log(fn ->
        sink =
          cache_key()
          |> Cache.open_sink(resolved_output(), cache: {UnexpectedResultAdapter, []})
          |> Cache.write_chunk("abc", cache: {UnexpectedResultAdapter, []})

        assert :ok = Cache.commit_sink(sink, cache: {UnexpectedResultAdapter, []})
      end)

    assert log =~ "cache sink commit error"
    assert log =~ ":surprise"
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp attach_telemetry(events) do
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
