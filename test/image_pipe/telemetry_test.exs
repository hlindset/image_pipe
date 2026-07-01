defmodule ImagePipe.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source
  alias ImagePipe.Source.Response, as: SourceResponse
  alias Vix.Vips.Image, as: VipsImage

  defmodule InvalidSourceAdapter do
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts) do
      {:ok,
       %ImagePipe.Source.Resolved{
         adapter: :path,
         source_kind: :path,
         identity: [kind: :path, root: "invalid", path: ["images", "beach.jpg"]],
         internal_cache: :enabled,
         http_cache: :inherit,
         cache_semantics: %ImagePipe.Source.CacheSemantics{byte_identity: :none, stable?: false},
         fetch: :invalid
       }}
    end

    @impl ImagePipe.Source
    def fetch(_resolved, _opts, _runtime_opts) do
      {:ok, %ImagePipe.Source.Response{stream: ["not actually a png"]}}
    end
  end

  defmodule UnsupportedSourceParser do
    @behaviour ImagePipe.Parser

    @impl ImagePipe.Parser
    def parse(_conn, _opts), do: {:ok, ImagePipe.TelemetryTest.plan(source: :signed)}

    @impl ImagePipe.Parser
    def handle_error(conn, _error), do: conn
  end

  defmodule EmptyPipelineParser do
    @behaviour ImagePipe.Parser

    @impl ImagePipe.Parser
    def parse(_conn, _opts), do: {:ok, ImagePipe.TelemetryTest.plan(pipelines: [])}

    @impl ImagePipe.Parser
    def handle_error(conn, _error), do: conn
  end

  defmodule RaisingParser do
    @behaviour ImagePipe.Parser

    @impl ImagePipe.Parser
    def parse(_conn, _opts), do: raise("forced parser failure")

    @impl ImagePipe.Parser
    def handle_error(conn, _error), do: conn
  end

  defmodule CacheReadFailure do
    @behaviour ImagePipe.Cache

    def get(_key, _opts), do: {:error, :read_failed}
    def open_sink(_key, _metadata, _opts), do: raise("cache read failure test should not write")
    def write_chunk(_state, _chunk, _opts), do: raise("cache read failure test should not write")
    def commit_sink(_state, _opts), do: raise("cache read failure test should not write")
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule FailOpenCacheReadFailure do
    @behaviour ImagePipe.Cache

    def get(_key, _opts), do: {:error, :read_failed}
    def open_sink(_key, _metadata, _opts), do: {:ok, []}
    def write_chunk(chunks, chunk, _opts), do: {:ok, [chunk | chunks]}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule InvalidCacheHit do
    @behaviour ImagePipe.Cache

    def get(_key, _opts) do
      {:hit,
       %ImagePipe.Cache.Entry{
         body: "cached gif",
         content_type: "image/gif",
         headers: [],
         created_at: DateTime.utc_now()
       }}
    end

    def open_sink(_key, _metadata, _opts), do: {:ok, []}
    def write_chunk(chunks, chunk, _opts), do: {:ok, [chunk | chunks]}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule FailOpenCacheWriteFailure do
    @behaviour ImagePipe.Cache

    def get(_key, _opts), do: :miss
    def open_sink(_key, _metadata, _opts), do: {:ok, []}
    def write_chunk(state, _chunk, _opts), do: {:error, :write_failed, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule SourceBytes do
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, opts, _runtime_opts) do
      {:ok,
       %ImagePipe.Source.Resolved{
         adapter: :path,
         source_kind: :path,
         identity: [kind: :path, root: "test", path: ["images", "source.tiff"]],
         internal_cache: :enabled,
         http_cache: :inherit,
         cache_semantics: %ImagePipe.Source.CacheSemantics{byte_identity: :none, stable?: false},
         fetch: Keyword.fetch!(opts, :body)
       }}
    end

    @impl ImagePipe.Source
    def fetch(resolved, _opts, _runtime_opts) do
      {:ok, %SourceResponse{stream: [resolved.fetch]}}
    end
  end

  defmodule DeniedSourceAdapter do
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts), do: {:error, {:source, :denied_path}}

    @impl ImagePipe.Source
    def fetch(_resolved, _opts, _runtime_opts), do: raise("resolve should fail before fetch")
  end

  defmodule RaisingAfterFirstChunkImage do
    def stream!(_image, [{:suffix, ".jpg"} | _]) do
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {["first chunk"], :raise}
          :raise -> raise "boom after first chunk"
        end,
        fn _state -> :ok end
      )
    end
  end

  defmodule RaisingBeforeFirstChunkImage do
    def stream!(_image, [{:suffix, ".jpg"} | _]) do
      Stream.resource(
        fn -> :raise end,
        fn :raise -> raise "boom before first chunk" end,
        fn _state -> :ok end
      )
    end
  end

  setup do
    attach_telemetry(default_events() ++ custom_events())
  end

  test "emits request and representative stage spans for successful requests" do
    conn =
      :get
      |> conn("/_/f:jpeg/plain/images/beach.jpg")
      |> ImagePipe.Plug.call(base_opts())

    assert conn.status == 200
    events = telemetry_events()

    assert_event(events, [:image_pipe, :request, :start], fn measurements, metadata ->
      assert is_integer(measurements.system_time)
      assert metadata.parser == ImagePipe.Parser.Imgproxy
      assert metadata.request_method == "GET"
    end)

    assert_event(events, [:image_pipe, :request, :stop], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert metadata.result == :ok
      assert metadata.status == 200
      assert metadata.parser == ImagePipe.Parser.Imgproxy
      assert metadata.request_method == "GET"
    end)

    assert_event(events, [:image_pipe, :output, :negotiate, :stop], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert metadata.result == :ok
      assert metadata.output_mode == :explicit
      assert metadata.output_format == :jpeg
    end)

    for stage <- [
          [:parse],
          [:source, :resolve],
          [:cache, :lookup],
          [:source, :fetch],
          [:transform, :execute],
          [:encode],
          [:send],
          [:deliver]
        ] do
      assert_event(events, [:image_pipe | stage] ++ [:start], fn measurements, _metadata ->
        assert is_integer(measurements.system_time)
      end)

      assert_event(events, [:image_pipe | stage] ++ [:stop], fn measurements, metadata ->
        assert is_integer(measurements.duration)
        assert metadata.result == :ok
      end)
    end

    refute Enum.any?(events, fn {_event, _measurements, metadata} ->
             Map.has_key?(metadata, :request_path) or Map.has_key?(metadata, :path)
           end)
  end

  test "source resolve and fetch spans use safe low-cardinality metadata" do
    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> ImagePipe.Plug.call(base_opts())

    assert conn.status == 200
    events = telemetry_events()

    for stage <- [[:source, :resolve], [:source, :fetch]] do
      assert_event(events, [:image_pipe | stage] ++ [:start], fn measurements, metadata ->
        assert is_integer(measurements.system_time)
        assert metadata.source_kind in [:path, :url, :object, :reference]
        assert metadata.source_adapter_kind in [:file, :http, :s3, :custom]
        refute Map.has_key?(metadata, :source_adapter)
        refute inspect(metadata) =~ "images/beach.jpg"
        refute inspect(metadata) =~ "origin.test"
      end)

      assert_event(events, [:image_pipe | stage] ++ [:stop], fn measurements, metadata ->
        assert is_integer(measurements.duration)
        assert metadata.result == :ok
        assert metadata.source_kind in [:path, :url, :object, :reference]
        assert metadata.source_adapter_kind in [:file, :http, :s3, :custom]
        refute Map.has_key?(metadata, :source_adapter)
        refute inspect(metadata) =~ "images/beach.jpg"
        refute inspect(metadata) =~ "origin.test"
      end)
    end
  end

  test "source resolve stop metadata reports source error reason" do
    opts = init_opts(sources: [path: {DeniedSourceAdapter, []}])

    assert ImagePipe.Source.resolve(%Source.Path{segments: ["blocked.jpg"]}, opts, []) ==
             {:error, {:source, :denied_path}}

    events = telemetry_events()

    assert_event(events, [:image_pipe, :source, :resolve, :stop], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert metadata.result == :source_error
      assert metadata.error == :denied_path
      assert metadata.source_kind == :path
      assert metadata.source_adapter_kind == :custom
    end)
  end

  test "uses configurable telemetry prefix" do
    conn =
      :get
      |> conn("/_/f:jpeg/plain/images/beach.jpg")
      |> ImagePipe.Plug.call(Keyword.put(base_opts(), :telemetry_prefix, [:custom, :image]))

    assert conn.status == 200
    events = telemetry_events()

    assert_event(events, [:custom, :image, :request, :start], fn _measurements, metadata ->
      assert metadata.parser == ImagePipe.Parser.Imgproxy
    end)

    assert_event(events, [:custom, :image, :request, :stop], fn _measurements, metadata ->
      assert metadata.result == :ok
      assert metadata.status == 200
    end)

    assert_event(events, [:custom, :image, :parse, :start], fn measurements, _metadata ->
      assert is_integer(measurements.system_time)
    end)

    assert_event(events, [:custom, :image, :parse, :stop], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert metadata.result == :ok
    end)

    refute_event(events, [:image_pipe, :request, :start])
    refute_event(events, [:image_pipe, :request, :stop])
    refute_event(events, [:image_pipe, :parse, :start])
    refute_event(events, [:image_pipe, :parse, :stop])
  end

  test "deliver stop metadata reports processing error after chunked stream failure" do
    {conn, log} =
      with_log(fn ->
        :get
        |> conn("/_/f:jpeg/plain/images/beach.jpg")
        |> ImagePipe.Plug.call(base_opts(image_module: RaisingAfterFirstChunkImage))
      end)

    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body == "first chunk"
    assert log =~ "boom after first chunk"

    events = telemetry_events()

    # The first chunk was produced successfully, so the producer's forced-encode span
    # succeeds; the failure surfaces later, while the sender streams the remaining
    # chunks over the connection (the [:deliver] span).
    assert_event(events, [:image_pipe, :encode, :stop], fn _measurements, metadata ->
      assert metadata.result == :ok
      assert metadata.output_format == :jpeg
    end)

    assert_event(events, [:image_pipe, :deliver, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
      assert metadata.status == 200
      assert metadata.output_format == :jpeg
    end)

    assert_event(events, [:image_pipe, :send, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
      assert metadata.status == 200
    end)

    assert_event(events, [:image_pipe, :request, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
      assert metadata.status == 200
    end)
  end

  test "request and send stop metadata report processing error when streaming encode fails before response" do
    {conn, log} =
      with_log(fn ->
        :get
        |> conn("/_/f:jpeg/plain/images/beach.jpg")
        |> ImagePipe.Plug.call(base_opts(image_module: RaisingBeforeFirstChunkImage))
      end)

    assert conn.status == 500
    assert conn.resp_body == "error encoding image"
    assert log =~ "boom before first chunk"

    events = telemetry_events()

    # The encoder fails forcing the first chunk in the producer, so the [:encode]
    # span carries the processing error.
    assert_event(events, [:image_pipe, :encode, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
      assert metadata.output_format == :jpeg
    end)

    # No prepared stream is ever sent (the request goes through the processing-error
    # path, not send_prepared_stream/5), so the [:deliver] span never fires.
    refute_event(events, [:image_pipe, :deliver, :stop])

    assert_event(events, [:image_pipe, :send, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
      assert metadata.status == 500
    end)

    assert_event(events, [:image_pipe, :request, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
      assert metadata.status == 500
    end)
  end

  test "automatic source format fallback does not emit failed output negotiation telemetry" do
    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> ImagePipe.Plug.call(base_opts())

    assert conn.status == 200
    events = telemetry_events()

    output_stop_events =
      Enum.filter(events, fn {event, _measurements, _metadata} ->
        event == [:image_pipe, :output, :negotiate, :stop]
      end)

    assert output_stop_events != []

    refute Enum.any?(output_stop_events, fn {_event, _measurements, metadata} ->
             metadata.result != :ok
           end)

    for {_event, _measurements, metadata} <- output_stop_events do
      assert metadata.output_mode == :automatic
      assert metadata.output_format in [:jpeg, :pending_final_image_alpha]
    end
  end

  test "source-only automatic fallback does not emit failed output negotiation telemetry" do
    require_tiff_support!()

    conn =
      :get
      |> conn("/_/plain/images/source.tiff")
      |> ImagePipe.Plug.call(base_opts(sources: [path: {SourceBytes, body: tiff_body(:white)}]))

    assert conn.status == 200
    events = telemetry_events()

    output_stop_events =
      Enum.filter(events, fn {event, _measurements, _metadata} ->
        event == [:image_pipe, :output, :negotiate, :stop]
      end)

    assert output_stop_events != []

    refute Enum.any?(output_stop_events, fn {_event, _measurements, metadata} ->
             metadata.result != :ok
           end)

    for {_event, _measurements, metadata} <- output_stop_events do
      assert metadata.output_mode == :automatic
      assert metadata.output_format in [:jpeg, :pending_final_image_alpha]
    end
  end

  test "fail-open cache read errors are reported on cache lookup telemetry" do
    conn =
      :get
      |> conn("/_/f:jpeg/plain/images/beach.jpg")
      |> ImagePipe.Plug.call(base_opts(cache: {FailOpenCacheReadFailure, []}))

    assert conn.status == 200
    events = telemetry_events()

    assert_event(events, [:image_pipe, :cache, :lookup, :stop], fn _measurements, metadata ->
      assert metadata.result == :cache_error
      assert metadata.cache == :read_error
      assert metadata.error == :read_failed
    end)

    assert_event(events, [:image_pipe, :request, :stop], fn _measurements, metadata ->
      assert metadata.result == :ok
      assert metadata.status == 200
    end)
  end

  test "invalid cache entries are reported on cache lookup telemetry" do
    conn =
      :get
      |> conn("/_/f:jpeg/plain/images/beach.jpg")
      |> ImagePipe.Plug.call(base_opts(cache: {InvalidCacheHit, []}))

    assert conn.status == 200
    events = telemetry_events()

    assert_event(events, [:image_pipe, :cache, :lookup, :stop], fn _measurements, metadata ->
      assert metadata.result == :cache_error
      assert metadata.cache == :read_error
      assert metadata.error == :invalid_entry
    end)

    assert_event(events, [:image_pipe, :request, :stop], fn _measurements, metadata ->
      assert metadata.result == :ok
      assert metadata.status == 200
    end)
  end

  test "fail-open cache staging write errors are reported on cache stage telemetry" do
    conn =
      :get
      |> conn("/_/f:jpeg/plain/images/beach.jpg")
      |> ImagePipe.Plug.call(base_opts(cache: {FailOpenCacheWriteFailure, []}))

    assert conn.status == 200
    events = telemetry_events()

    assert_event(events, [:image_pipe, :cache, :stage], fn _measurements, metadata ->
      assert metadata.result == :cache_error
      assert metadata.cache == :stage_error
      assert metadata.error == :write_failed
    end)

    assert_event(events, [:image_pipe, :request, :stop], fn _measurements, metadata ->
      assert metadata.result == :ok
      assert metadata.status == 200
    end)
  end

  test "emits request stop metadata for failures that return responses" do
    cases = [
      parser: {
        conn(:get, "/_/w:300"),
        base_opts(),
        :parser_error,
        400
      },
      plan: {
        conn(:get, "/any"),
        init_opts(parser: EmptyPipelineParser),
        :plan_error,
        422
      },
      source: {
        conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
        init_opts(sources: []),
        :source_error,
        500
      },
      processing: {
        conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
        init_opts(sources: [path: {InvalidSourceAdapter, []}]),
        :processing_error,
        415
      }
    ]

    for {name, {conn, opts, result, status}} <- cases do
      sent = ImagePipe.Plug.call(conn, opts)
      assert sent.status == status

      events = telemetry_events()

      assert_event(events, [:image_pipe, :request, :stop], fn _measurements, metadata ->
        assert metadata.result == result
        assert metadata.status == status
        # Every error branch (parser included) tags the top-level span.
        assert is_atom(metadata.error)
      end)

      refute_event(events, [:image_pipe, :request, :exception],
        message: "expected #{name} returned response not to emit request exception"
      )
    end
  end

  test "emits exception events only for real raised exceptions" do
    assert_raise RuntimeError, "forced parser failure", fn ->
      ImagePipe.Plug.call(conn(:get, "/any"), init_opts(parser: RaisingParser))
    end

    events = telemetry_events()

    assert_event(events, [:image_pipe, :parse, :exception], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert metadata.kind == :error
      assert %RuntimeError{message: "forced parser failure"} = metadata.reason
      assert is_list(metadata.stacktrace)
    end)

    assert_event(events, [:image_pipe, :request, :exception], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert metadata.kind == :error
      assert %RuntimeError{message: "forced parser failure"} = metadata.reason
      assert is_list(metadata.stacktrace)
    end)
  end

  test "fetch_decode stop metadata includes load_option, achieved_shrink, and dims for shrunk JPEG" do
    alias ImagePipe.Plan
    alias ImagePipe.Plan.Operation
    alias ImagePipe.Plan.Output
    alias ImagePipe.Plan.Pipeline
    alias ImagePipe.Request.Processor
    alias ImagePipe.Source.CacheSemantics
    alias ImagePipe.Source.Resolved

    {:ok, full_image} = Image.open("priv/static/images/beach.jpg")
    orig_w = Image.width(full_image)
    orig_h = Image.height(full_image)
    target_w = div(orig_w, 9)

    {:ok, operation} =
      Operation.resize(:fit, {:px, target_w}, :auto, enlargement: :deny)

    fetch_decode_plan = %Plan{
      source: %ImagePipe.Plan.Source.Path{segments: ["images", "beach.jpg"]},
      pipelines: [%Pipeline{operations: [operation]}],
      output: %Output{mode: {:explicit, :jpeg}}
    }

    resolved_source = %Resolved{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "priv/static", path: ["images", "beach.jpg"]],
      internal_cache: :enabled,
      http_cache: :inherit,
      cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false},
      fetch: :fixture
    }

    processor_opts = [
      sources: %{path: {ImagePipe.SourceTest.ValidAdapter, root: "priv/static"}},
      max_body_bytes: 10_000_000,
      max_input_pixels: 40_000_000,
      max_result_width: 8_192,
      max_result_height: 8_192,
      max_result_pixels: 40_000_000
    ]

    test_pid = self()
    handler_id = {__MODULE__, :fetch_decode_shrink_test, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:image_pipe, :source, :fetch_decode, :stop],
        &__MODULE__.handle_telemetry_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _decoded} =
             Processor.fetch_decode_validate_source_with_source_format(
               fetch_decode_plan,
               resolved_source,
               processor_opts
             )

    assert_received {:telemetry_event, [:image_pipe, :source, :fetch_decode, :stop],
                     _measurements, stop_meta}

    assert stop_meta.result == :ok

    assert {:shrink, shrink_n} = stop_meta.load_option
    assert shrink_n >= 4

    assert %{w: shrink_w, h: shrink_h} = stop_meta.achieved_shrink
    assert shrink_w >= 4.0
    assert shrink_h >= 4.0

    assert {^orig_w, ^orig_h} = stop_meta.original_dims

    assert {loaded_w, _loaded_h} = stop_meta.loaded_dims
    assert loaded_w <= div(orig_w, 4)
  end

  test "transform execute span carries operation count and names" do
    conn =
      :get
      |> conn("/_/rs:fit:100:0/f:jpeg/plain/images/beach.jpg")
      |> ImagePipe.Plug.call(base_opts())

    assert conn.status == 200
    events = telemetry_events()

    assert_event(events, [:image_pipe, :transform, :execute, :start], fn _measurements,
                                                                         metadata ->
      assert is_list(metadata.operations)
      assert :resize in metadata.operations
      assert metadata.operation_count == 1
    end)
  end

  test "fetch_decode stop metadata reports source_error for body-size limit" do
    big_body = :binary.copy(<<0>>, 50_000)

    opts =
      base_opts(
        sources: [path: {SourceBytes, body: big_body}],
        max_body_bytes: 1_000
      )

    # SourceBytes returns `big_body` regardless of this path; the path only has to parse.
    conn =
      :get
      |> conn("/_/plain/images/source.tiff")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 422
    events = telemetry_events()

    assert_event(events, [:image_pipe, :source, :fetch_decode, :stop], fn _measurements,
                                                                          metadata ->
      assert metadata.result == :source_error
      assert metadata.error == :body_too_large
    end)
  end

  test "fetch_decode stop metadata reports processing_error for input-pixel limit" do
    opts = base_opts(max_input_pixels: 1)

    conn =
      :get
      |> conn("/_/f:jpeg/plain/images/beach.jpg")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 413
    events = telemetry_events()

    assert_event(events, [:image_pipe, :source, :fetch_decode, :stop], fn _measurements,
                                                                          metadata ->
      assert metadata.result == :processing_error
      assert metadata.error == :input_limit
    end)
  end

  test "input_color_management span fires with working_space and imported? for a standard sRGB image" do
    test_pid = self()
    handler_id = {__MODULE__, :input_color_management_test, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:image_pipe, :transform, :input_color_management, :start],
          [:image_pipe, :transform, :input_color_management, :stop]
        ],
        &__MODULE__.handle_telemetry_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    conn =
      :get
      |> conn("/_/f:jpeg/plain/images/beach.jpg")
      |> ImagePipe.Plug.call(base_opts())

    assert conn.status == 200

    assert_received {:telemetry_event, [:image_pipe, :transform, :input_color_management, :start],
                     start_measurements, _start_meta}

    assert is_integer(start_measurements.system_time)

    assert_received {:telemetry_event, [:image_pipe, :transform, :input_color_management, :stop],
                     stop_measurements, stop_meta}

    assert is_integer(stop_measurements.duration)
    assert stop_meta.result == :ok
    assert is_atom(stop_meta.working_space)
    assert is_boolean(stop_meta.imported?)
    # beach.jpg has the canonical sRGB IEC61966 profile, which is not re-imported
    assert stop_meta.imported? == false
  end

  test "validates telemetry prefix option at init" do
    assert ImagePipe.Plug.init(opts(telemetry_prefix: [:custom, :image]))[:telemetry_prefix] ==
             [:custom, :image]

    for prefix <- ["image_pipe", [:image_pipe, "request"], [], [:image_pipe, 1]] do
      assert_raise ArgumentError,
                   ~r/invalid ImagePipe options: invalid value for :telemetry_prefix option/,
                   fn -> ImagePipe.Plug.init(opts(telemetry_prefix: prefix)) end
    end
  end

  defp base_opts(overrides \\ []) do
    init_opts(overrides)
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp opts(overrides) do
    Keyword.merge(
      [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path: {ImagePipe.Source.File, root: "priv/static", root_id: "static", stable: :trusted}
        ]
      ],
      overrides
    )
  end

  defp init_opts(overrides), do: overrides |> opts() |> ImagePipe.Plug.init()

  def plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: %Source.Path{segments: ["images", "beach.jpg"]},
          pipelines: [%Pipeline{operations: [resize_fit_operation()]}],
          output: %Output{mode: {:explicit, :jpeg}}
        ],
        overrides
      )
    )
  end

  defp resize_fit_operation do
    assert {:ok, operation} = Operation.resize(:fit, {:px, 100}, {:px, 100}, enlargement: :deny)
    operation
  end

  defp require_tiff_support! do
    with {:ok, loader_suffixes} <- VipsImage.supported_loader_suffixes(),
         true <- ".tiff" in loader_suffixes,
         {:ok, saver_suffixes} <- VipsImage.supported_saver_suffixes(),
         true <- ".tiff" in saver_suffixes do
      :ok
    else
      _error -> raise ExUnit.AssertionError, message: "TIFF load/save support unavailable"
    end
  end

  defp tiff_body(color) do
    Image.new!(20, 20, color: color)
    |> Image.write!(:memory, suffix: ".tiff")
  end

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp default_events do
    span_events(:image_pipe) ++ [[:image_pipe, :cache, :stage]]
  end

  defp custom_events do
    span_events([:custom, :image]) ++ [[:custom, :image, :cache, :stage]]
  end

  defp span_events(prefix) when is_atom(prefix), do: span_events([prefix])

  defp span_events(prefix) when is_list(prefix) do
    for stage <- stages(),
        suffix <- [:start, :stop, :exception],
        do: prefix ++ stage ++ [suffix]
  end

  defp stages do
    [
      [:request],
      [:parse],
      [:source, :resolve],
      [:cache, :lookup],
      [:output, :negotiate],
      [:source, :fetch],
      [:source, :fetch_decode],
      [:transform, :execute],
      [:encode],
      [:cache, :write],
      [:send],
      [:deliver]
    ]
  end

  defp telemetry_events(events \\ []) do
    receive do
      {:telemetry_event, event, measurements, metadata} ->
        telemetry_events([{event, measurements, metadata} | events])
    after
      0 ->
        Enum.reverse(events)
    end
  end

  defp assert_event(events, event, assertion) when is_function(assertion, 2) do
    case Enum.find(events, fn {candidate, _measurements, _metadata} -> candidate == event end) do
      {^event, measurements, metadata} ->
        assertion.(measurements, metadata)

      nil ->
        flunk("expected telemetry event #{inspect(event)}, got #{inspect(event_names(events))}")
    end
  end

  defp refute_event(events, event, opts \\ []) do
    message = Keyword.get(opts, :message, "unexpected telemetry event #{inspect(event)}")

    refute Enum.any?(events, fn {candidate, _measurements, _metadata} -> candidate == event end),
           message
  end

  defp event_names(events),
    do: Enum.map(events, fn {event, _measurements, _metadata} -> event end)
end
