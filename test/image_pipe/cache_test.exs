defmodule ImagePipe.CacheTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source

  defmodule HitAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, opts), do: {:hit, Keyword.fetch!(opts, :entry)}
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule MissAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule CaptureAdapter do
    @behaviour ImagePipe.Cache

    def get(%Key{} = key, opts) do
      send(self(), {:cache_get, key, opts})
      :miss
    end

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

  defp plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: %Source.Path{segments: ["images", "cat.jpg"]},
          pipelines: [%Pipeline{operations: []}],
          output: %Output{mode: {:explicit, :webp}}
        ],
        overrides
      )
    )
  end

  defp automatic_plan do
    plan(output: %Output{mode: :automatic})
  end

  defp source_identity do
    [kind: :path, adapter: :path, root: "default", path: ["images", "cat.jpg"]]
  end

  defp cache_key do
    %Key{
      hash: String.duplicate("a", 64),
      data: [schema_version: 2]
    }
  end

  defp entry(body \\ "body") do
    %Entry{
      body: body,
      content_type: "image/webp",
      headers: [],
      created_at: ~U[2026-04-29 10:15:00Z]
    }
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

  test "returns disabled when no cache is configured" do
    assert Cache.lookup(
             conn(:get, "/_/plain/images/cat.jpg"),
             plan(),
             source_identity(),
             []
           ) ==
             :disabled
  end

  test "ImagePipe init rejects invalid cache config early" do
    assert_raise ArgumentError, ~r/invalid cache config/, fn ->
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path: {ImagePipe.Source.File, root: "priv/static", root_id: "static"}
        ],
        cache: {__MODULE__.DoesNotExist, []}
      )
    end

    assert_raise ArgumentError, ~r/invalid cache config/, fn ->
      ImagePipe.Plug.init(cache: {MissingSinkCallbacksAdapter, []})
    end

    assert_raise ArgumentError, ~r/invalid cache config/, fn ->
      ImagePipe.Plug.init(cache: {MissAdapter, key_headers: [:accept_language]})
    end

    assert_raise ArgumentError, ~r/key_headers.*cannot include.*accept/, fn ->
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        cache: {MissAdapter, key_headers: ["Accept"]}
      )
    end

    assert_raise ArgumentError, ~r/invalid cache config/, fn ->
      ImagePipe.Plug.init(cache: {MissAdapter, max_body_bytes: "10MB"})
    end
  end

  test "ImagePipe init rejects missing required options early" do
    assert_raise ArgumentError, ~r/required :parser option not found/, fn ->
      ImagePipe.Plug.init([])
    end
  end

  test "ImagePipe init rejects invalid filesystem cache options early" do
    assert_raise ArgumentError, ~r/invalid cache config/, fn ->
      ImagePipe.Plug.init(cache: {ImagePipe.Cache.FileSystem, root: "relative/cache"})
    end

    assert_raise ArgumentError, ~r/invalid cache config/, fn ->
      ImagePipe.Plug.init(
        cache: {ImagePipe.Cache.FileSystem, root: System.tmp_dir!(), path_prefix: "../outside"}
      )
    end

    assert_raise ArgumentError, ~r/invalid cache config/, fn ->
      ImagePipe.Plug.init(
        cache:
          {ImagePipe.Cache.FileSystem, root: System.tmp_dir!(), path_prefix: "processed//images"}
      )
    end
  end

  test "ImagePipe init preserves normalized filesystem cache options" do
    root = Path.join(System.tmp_dir!(), "image_pipe_cache_init")

    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path: {ImagePipe.Source.File, root: "priv/static", root_id: "static"}
        ],
        cache: {ImagePipe.Cache.FileSystem, root: root <> "/../image_pipe_cache_init"}
      )

    assert {ImagePipe.Cache.FileSystem, cache_opts} = Keyword.fetch!(opts, :cache)
    assert cache_opts[:root] == Path.expand(root)
    assert cache_opts[:path_prefix] == ""
  end

  test "returns hits with the generated key" do
    configured_entry = entry()

    assert {:hit, %Key{} = key, ^configured_entry} =
             Cache.lookup(
               conn(:get, "/_/f:webp/plain/images/cat.jpg"),
               plan(),
               source_identity(),
               cache: {HitAdapter, entry: configured_entry}
             )

    assert key.data[:source_identity] == source_identity()
  end

  test "invalid hit content types are cache read errors" do
    invalid_entry = %Entry{
      body: "body",
      content_type: "image/gif",
      headers: [],
      created_at: ~U[2026-04-29 10:15:00Z]
    }

    log =
      capture_log(fn ->
        assert {:miss, %Key{},
                {:cache_read, {:invalid_entry, {:unsupported_output_format, "image/gif"}}}} =
                 Cache.lookup(
                   conn(:get, "/_/f:webp/plain/images/cat.jpg"),
                   plan(),
                   source_identity(),
                   cache: {HitAdapter, entry: invalid_entry}
                 )
      end)

    assert log =~ "cache read error"
    assert log =~ "unsupported_output_format"
  end

  test "returns miss with the generated key" do
    assert {:miss, %Key{} = key} =
             Cache.lookup(
               conn(:get, "/_/f:webp/plain/images/cat.jpg"),
               plan(),
               source_identity(),
               cache: {MissAdapter, []}
             )

    assert key.hash =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "automatic lookup key uses modern candidates without reaching adapter opts" do
    assert {:miss, %Key{} = key} =
             Cache.lookup(
               :get
               |> conn("/_/plain/images/cat.jpg")
               |> Plug.Conn.put_req_header("accept", "image/avif,image/webp"),
               automatic_plan(),
               source_identity(),
               auto_avif: false,
               cache: {CaptureAdapter, key_headers: ["accept-language"]}
             )

    assert key.data[:output] == [
             mode: :automatic,
             modern_candidates: [:webp],
             auto: [jpeg_xl: true, avif: false, webp: true],
             quality: :default,
             format_qualities: %{},
             quality_search: :none,
             max_bytes: nil,
             strip_metadata: true,
             color_profile: :strip,
             keep_copyright: true,
             hdr: :tone_map,
             flatten_background: [
               space: :srgb,
               red: 255,
               green: 255,
               blue: 255,
               alpha: [unit: :ratio, numerator: 1, denominator: 1]
             ],
             jxl_effort: nil
           ]

    assert_received {:cache_get, ^key, adapter_opts}
    refute Keyword.has_key?(adapter_opts, :selected_output_format)
    refute Keyword.has_key?(adapter_opts, :selected_output_reason)
    refute Keyword.has_key?(adapter_opts, :auto_avif)
    assert Keyword.fetch!(adapter_opts, :key_headers) == ["accept-language"]
  end

  test "adapter-private options named like automatic output flags do not affect key data" do
    assert {:miss, %Key{} = key} =
             Cache.lookup(
               :get
               |> conn("/_/plain/images/cat.jpg")
               |> Plug.Conn.put_req_header("accept", "image/avif,image/webp"),
               automatic_plan(),
               source_identity(),
               cache: {CaptureAdapter, auto_avif: false, auto_webp: false}
             )

    assert key.data[:output][:auto] == [jpeg_xl: true, avif: true, webp: true]

    assert_received {:cache_get, ^key, adapter_opts}
    assert Keyword.fetch!(adapter_opts, :auto_avif) == false
    assert Keyword.fetch!(adapter_opts, :auto_webp) == false
  end

  test "read errors fail open by default and are logged" do
    log =
      capture_log(fn ->
        assert {:miss, %Key{}, {:cache_read, :read_failed}} =
                 Cache.lookup(
                   conn(:get, "/_/f:webp/plain/images/cat.jpg"),
                   plan(),
                   source_identity(),
                   cache: {ErrorAdapter, []}
                 )
      end)

    assert log =~ "cache read error"
    assert log =~ ":read_failed"
  end

  test "lookup returns miss when adapter.get raises" do
    log =
      capture_log(fn ->
        assert {:miss, %Key{}, {:cache_read, %RuntimeError{message: "adapter get crashed"}}} =
                 Cache.lookup(
                   conn(:get, "/_/f:webp/plain/images/cat.jpg"),
                   plan(),
                   source_identity(),
                   cache: {RaisingGetAdapter, []}
                 )
      end)

    assert log =~ "cache read error"
  end

  test "unexpected adapter get result is handled as a cache read error" do
    log =
      capture_log(fn ->
        assert {:miss, %Key{}, {:cache_read, {:invalid_adapter_result, :surprise}}} =
                 Cache.lookup(
                   conn(:get, "/_/f:webp/plain/images/cat.jpg"),
                   plan(),
                   source_identity(),
                   cache: {UnexpectedResultAdapter, []}
                 )
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
      key_headers: ["accept-language"],
      test_pid: self(),
      drop_me: true
    ]

    opts = Cache.validate_config!(cache: {NormalizingAdapter, cache_opts})

    assert {:miss, %Key{}} =
             Cache.lookup(
               conn(:get, "/_/f:webp/plain/images/cat.jpg"),
               plan(),
               source_identity(),
               opts
             )

    assert_received {:normalized_cache_get, runtime_opts}
    assert Keyword.fetch!(runtime_opts, :key_headers) == ["accept-language"]
    assert Keyword.fetch!(runtime_opts, :test_pid) == self()
    assert Keyword.fetch!(runtime_opts, :normalized?)
    refute Keyword.has_key?(runtime_opts, :drop_me)

    assert Cache.open_sink(cache_key(), resolved_output(), opts)

    assert_received {:normalized_open_sink, sink_opts}
    assert Keyword.fetch!(sink_opts, :key_headers) == ["accept-language"]
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
