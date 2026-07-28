defmodule ImagePipe.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias ImagePipe.Dialect.IIIF
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source
  alias ImagePipe.Source.Response, as: SourceResponse
  alias Vix.Vips.Image, as: VipsImage

  # `:telemetry` handlers are global and fire for every emission of an event
  # name VM-wide. Every event this suite asserts or refutes is therefore scoped
  # to a prefix only this module mounts.
  @prefix [:image_pipe_telemetry_suite]
  @custom_prefix [:image_pipe_telemetry_suite_custom]

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

  # The plan-shaped doubles below need no options of their own: they read only
  # the shared runtime keys (`sources`, `cache`, safety limits) and the
  # declarative base's own keys, so config validation delegates to both.
  defmodule PlanFixtureConfig do
    alias ImagePipe.Dialect.Declarative
    alias ImagePipe.Dialect.SharedConfig

    def validate!(opts) do
      {shared, rest} = Keyword.split(opts, SharedConfig.keys())
      {base, unknown} = Keyword.split(rest, Declarative.config_keys())

      if unknown != [] do
        raise "unknown mount option(s): #{inspect(Keyword.keys(unknown))}"
      end

      Keyword.merge(SharedConfig.validate_runtime!(shared), Declarative.validate_config!(base))
    end
  end

  defmodule EmptyPipelineDialect do
    use ImagePipe.Dialect.Declarative

    @impl ImagePipe.Dialect
    def validate_config!(opts), do: PlanFixtureConfig.validate!(opts)

    @impl ImagePipe.Dialect.Declarative
    def parse_plan(_conn, _config), do: {:ok, ImagePipe.TelemetryTest.plan(pipelines: [])}

    @impl ImagePipe.Dialect
    def render_error(conn, reason, config),
      do: IIIF.render_error(conn, reason, config)
  end

  defmodule RaisingDialect do
    use ImagePipe.Dialect.Declarative

    @impl ImagePipe.Dialect
    def validate_config!(opts), do: PlanFixtureConfig.validate!(opts)

    @impl ImagePipe.Dialect.Declarative
    def parse_plan(_conn, _config), do: raise("forced parse failure")

    @impl ImagePipe.Dialect
    def render_error(conn, reason, config),
      do: IIIF.render_error(conn, reason, config)
  end

  # Automatic output negotiation is a shape the IIIF grammar cannot spell (its
  # path always names a format), so — like the empty-pipeline case above — the
  # tests that exercise it drive a plan with `output: :automatic` through a
  # test-local declarative dialect.
  defmodule AutomaticBeachDialect do
    use ImagePipe.Dialect.Declarative

    @impl ImagePipe.Dialect
    def validate_config!(opts), do: PlanFixtureConfig.validate!(opts)

    @impl ImagePipe.Dialect.Declarative
    def parse_plan(_conn, _config) do
      {:ok,
       ImagePipe.TelemetryTest.plan(
         pipelines: [%ImagePipe.Plan.Pipeline{operations: []}],
         output: %ImagePipe.Plan.Output{mode: :automatic}
       )}
    end

    @impl ImagePipe.Dialect
    def render_error(conn, reason, config),
      do: IIIF.render_error(conn, reason, config)
  end

  defmodule AutomaticTiffDialect do
    use ImagePipe.Dialect.Declarative

    @impl ImagePipe.Dialect
    def validate_config!(opts), do: PlanFixtureConfig.validate!(opts)

    @impl ImagePipe.Dialect.Declarative
    def parse_plan(_conn, _config) do
      {:ok,
       ImagePipe.TelemetryTest.plan(
         source: %ImagePipe.Plan.Source.Path{segments: ["images", "source.tiff"]},
         pipelines: [%ImagePipe.Plan.Pipeline{operations: []}],
         output: %ImagePipe.Plan.Output{mode: :automatic}
       )}
    end

    @impl ImagePipe.Dialect
    def render_error(conn, reason, config),
      do: IIIF.render_error(conn, reason, config)
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

  # A plain miss-then-accept-writes cache, just enough to make
  # `[:cache, :write]` fire.
  defmodule WritableCache do
    @behaviour ImagePipe.Cache

    def get(_key, _opts), do: :miss
    def open_sink(_key, _metadata, _opts), do: {:ok, []}
    def write_chunk(chunks, chunk, _opts), do: {:ok, [chunk | chunks]}
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
      |> conn("/beach/full/max/0/default.jpg")
      |> ImagePipe.Plug.call(base_opts())

    assert conn.status == 200
    events = telemetry_events()

    assert_event(events, @prefix ++ [:request, :start], fn measurements, metadata ->
      assert is_integer(measurements.system_time)
      assert span_metadata(metadata) == %{}
    end)

    assert_event(events, @prefix ++ [:request, :stop], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert span_metadata(metadata) == %{result: :ok, status: 200}
    end)

    assert_event(events, @prefix ++ [:parse, :start], fn _measurements, metadata ->
      assert span_metadata(metadata) == %{}
    end)

    assert_event(events, @prefix ++ [:output, :negotiate, :stop], fn measurements, metadata ->
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
      assert_event(events, @prefix ++ stage ++ [:start], fn measurements, _metadata ->
        assert is_integer(measurements.system_time)
      end)

      assert_event(events, @prefix ++ stage ++ [:stop], fn measurements, metadata ->
        assert is_integer(measurements.duration)
        assert metadata.result == :ok
      end)
    end

    refute Enum.any?(events, fn {_event, _measurements, metadata} ->
             Map.has_key?(metadata, :request_path) or Map.has_key?(metadata, :path)
           end)
  end

  # A positive gate on the span SET, not just on individual spans: a runner
  # change that silently stops emitting one of these fails here.
  test "an image request emits the complete stage-span set" do
    conn =
      :get
      |> conn("/beach/full/100,/0/default.jpg")
      |> ImagePipe.Plug.call(base_opts(cache: {WritableCache, []}))

    assert conn.status == 200

    assert_spans(telemetry_events(), [
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
    ])
  end

  test "an info.json request emits the complete stage-span set, with render a sibling of fetch_decode" do
    conn =
      :get
      |> conn("/beach/info.json")
      |> ImagePipe.Plug.call(base_opts())

    assert conn.status == 200
    events = telemetry_events()

    assert_spans(events, [
      [:request],
      [:parse],
      [:source, :resolve],
      [:source, :fetch],
      [:source, :fetch_decode],
      [:render],
      [:send]
    ])

    # The render terminal runs after the decode bracket closes, so its span is a
    # SIBLING of [:source, :fetch_decode] rather than its parent: fetch_decode
    # has already stopped by the time [:render] starts.
    names = event_names(events)

    assert index_of(names, @prefix ++ [:source, :fetch_decode, :stop]) <
             index_of(names, @prefix ++ [:render, :start])

    # No image terminal ran, and info.json takes neither the cache-lookup nor
    # the output-negotiation branch of the image path.
    refute_event(events, @prefix ++ [:encode, :start])
    refute_event(events, @prefix ++ [:deliver, :start])
    refute_event(events, @prefix ++ [:cache, :lookup, :start])
    refute_event(events, @prefix ++ [:output, :negotiate, :start])
  end

  test "a decode failure on info.json emits no render span" do
    conn =
      :get
      |> conn("/beach/info.json")
      |> ImagePipe.Plug.call(base_opts(sources: [path: {InvalidSourceAdapter, []}]))

    assert conn.status == 415
    events = telemetry_events()

    assert_event(events, @prefix ++ [:source, :fetch_decode, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
    end)

    refute_event(events, @prefix ++ [:render, :start])
    refute_event(events, @prefix ++ [:render, :stop])
  end

  test "source resolve and fetch spans use safe low-cardinality metadata" do
    conn =
      :get
      |> conn("/beach/full/max/0/default.jpg")
      |> ImagePipe.Plug.call(base_opts())

    assert conn.status == 200
    events = telemetry_events()

    for stage <- [[:source, :resolve], [:source, :fetch]] do
      assert_event(events, @prefix ++ stage ++ [:start], fn measurements, metadata ->
        assert is_integer(measurements.system_time)
        assert metadata.source_kind in [:path, :url, :object, :reference]
        assert metadata.source_adapter_kind in [:file, :http, :s3, :custom]
        refute Map.has_key?(metadata, :source_adapter)
        refute inspect(metadata) =~ "images/beach.jpg"
        refute inspect(metadata) =~ "origin.test"
      end)

      assert_event(events, @prefix ++ stage ++ [:stop], fn measurements, metadata ->
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

    # The runner projects the mount config down to the adapter's runtime opts;
    # the telemetry prefix rides that projection.
    runtime_opts = ImagePipe.Source.runtime_opts(opts)

    assert ImagePipe.Source.resolve(%Source.Path{segments: ["blocked.jpg"]}, opts, runtime_opts) ==
             {:error, {:source, :denied_path}}

    events = telemetry_events()

    assert_event(events, @prefix ++ [:source, :resolve, :stop], fn measurements, metadata ->
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
      |> conn("/beach/full/max/0/default.jpg")
      |> ImagePipe.Plug.call(base_opts(telemetry_prefix: @custom_prefix))

    assert conn.status == 200
    events = telemetry_events()

    assert_event(events, @custom_prefix ++ [:request, :start], fn measurements, _metadata ->
      assert is_integer(measurements.system_time)
    end)

    assert_event(events, @custom_prefix ++ [:request, :stop], fn _measurements, metadata ->
      assert metadata.result == :ok
      assert metadata.status == 200
    end)

    assert_event(events, @custom_prefix ++ [:parse, :start], fn measurements, _metadata ->
      assert is_integer(measurements.system_time)
    end)

    assert_event(events, @custom_prefix ++ [:parse, :stop], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert metadata.result == :ok
    end)

    refute_event(events, @prefix ++ [:request, :start])
    refute_event(events, @prefix ++ [:request, :stop])
    refute_event(events, @prefix ++ [:parse, :start])
    refute_event(events, @prefix ++ [:parse, :stop])
  end

  test "deliver stop metadata reports processing error after chunked stream failure" do
    {conn, log} =
      with_log(fn ->
        :get
        |> conn("/beach/full/max/0/default.jpg")
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
    assert_event(events, @prefix ++ [:encode, :stop], fn _measurements, metadata ->
      assert metadata.result == :ok
      assert metadata.output_format == :jpeg
    end)

    assert_event(events, @prefix ++ [:deliver, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
      assert metadata.status == 200
      assert metadata.output_format == :jpeg
    end)

    assert_event(events, @prefix ++ [:send, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
      assert metadata.status == 200
    end)

    assert_event(events, @prefix ++ [:request, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
      assert metadata.status == 200
    end)
  end

  test "request and send stop metadata report processing error when streaming encode fails before response" do
    {conn, log} =
      with_log(fn ->
        :get
        |> conn("/beach/full/max/0/default.jpg")
        |> ImagePipe.Plug.call(base_opts(image_module: RaisingBeforeFirstChunkImage))
      end)

    assert conn.status == 500
    assert conn.resp_body == "error encoding image"
    assert log =~ "boom before first chunk"

    events = telemetry_events()

    # The encoder fails forcing the first chunk in the producer, so the [:encode]
    # span carries the processing error.
    assert_event(events, @prefix ++ [:encode, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
      assert metadata.output_format == :jpeg
    end)

    # No prepared stream is ever sent (the request goes through the processing-error
    # path), so the [:deliver] span never fires.
    refute_event(events, @prefix ++ [:deliver, :stop])

    assert_event(events, @prefix ++ [:send, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
      assert metadata.status == 500
    end)

    assert_event(events, @prefix ++ [:request, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
      assert metadata.status == 500
    end)
  end

  test "automatic source format fallback does not emit failed output negotiation telemetry" do
    conn =
      :get
      |> conn("/automatic")
      |> ImagePipe.Plug.call(fixture_opts(AutomaticBeachDialect))

    assert conn.status == 200
    events = telemetry_events()

    output_stop_events =
      Enum.filter(events, fn {event, _measurements, _metadata} ->
        event == @prefix ++ [:output, :negotiate, :stop]
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
      |> conn("/automatic")
      |> ImagePipe.Plug.call(
        fixture_opts(AutomaticTiffDialect,
          sources: [path: {SourceBytes, body: tiff_body(:white)}]
        )
      )

    assert conn.status == 200
    events = telemetry_events()

    output_stop_events =
      Enum.filter(events, fn {event, _measurements, _metadata} ->
        event == @prefix ++ [:output, :negotiate, :stop]
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
      |> conn("/beach/full/max/0/default.jpg")
      |> ImagePipe.Plug.call(base_opts(cache: {FailOpenCacheReadFailure, []}))

    assert conn.status == 200
    events = telemetry_events()

    assert_event(events, @prefix ++ [:cache, :lookup, :stop], fn _measurements, metadata ->
      assert metadata.result == :cache_error
      assert metadata.cache == :read_error
      assert metadata.error == :read_failed
    end)

    assert_event(events, @prefix ++ [:request, :stop], fn _measurements, metadata ->
      assert metadata.result == :ok
      assert metadata.status == 200
    end)
  end

  test "invalid cache entries are reported on cache lookup telemetry" do
    conn =
      :get
      |> conn("/beach/full/max/0/default.jpg")
      |> ImagePipe.Plug.call(base_opts(cache: {InvalidCacheHit, []}))

    assert conn.status == 200
    events = telemetry_events()

    assert_event(events, @prefix ++ [:cache, :lookup, :stop], fn _measurements, metadata ->
      assert metadata.result == :cache_error
      assert metadata.cache == :read_error
      assert metadata.error == :invalid_entry
    end)

    assert_event(events, @prefix ++ [:request, :stop], fn _measurements, metadata ->
      assert metadata.result == :ok
      assert metadata.status == 200
    end)
  end

  test "fail-open cache staging write errors are reported on cache stage telemetry" do
    conn =
      :get
      |> conn("/beach/full/max/0/default.jpg")
      |> ImagePipe.Plug.call(base_opts(cache: {FailOpenCacheWriteFailure, []}))

    assert conn.status == 200
    events = telemetry_events()

    assert_event(events, @prefix ++ [:cache, :stage], fn _measurements, metadata ->
      assert metadata.result == :cache_error
      assert metadata.cache == :stage_error
      assert metadata.error == :write_failed
    end)

    assert_event(events, @prefix ++ [:request, :stop], fn _measurements, metadata ->
      assert metadata.result == :ok
      assert metadata.status == 200
    end)
  end

  test "emits request stop metadata for failures that return responses" do
    cases = [
      parse: {
        conn(:get, "/beach/full/max/370/default.jpg"),
        base_opts(),
        :parser_error,
        400
      },
      plan: {
        conn(:get, "/any"),
        fixture_opts(EmptyPipelineDialect),
        :plan_error,
        422
      },
      source: {
        conn(:get, "/beach/full/max/0/default.jpg"),
        base_opts(sources: []),
        :source_error,
        500
      },
      processing: {
        conn(:get, "/beach/full/max/0/default.jpg"),
        base_opts(sources: [path: {InvalidSourceAdapter, []}]),
        :processing_error,
        415
      }
    ]

    for {name, {conn, opts, result, status}} <- cases do
      sent = ImagePipe.Plug.call(conn, opts)
      assert sent.status == status

      events = telemetry_events()

      assert_event(events, @prefix ++ [:request, :stop], fn _measurements, metadata ->
        assert metadata.result == result
        assert metadata.status == status
        # Every error branch (parse included) tags the top-level span.
        assert is_atom(metadata.error)
      end)

      refute_event(events, @prefix ++ [:request, :exception],
        message: "expected #{name} returned response not to emit request exception"
      )
    end
  end

  test "parse error stop metadata names the rejected reason" do
    conn =
      :get
      |> conn("/beach/full/max/370/default.jpg")
      |> ImagePipe.Plug.call(base_opts())

    assert conn.status == 400
    events = telemetry_events()

    assert_event(events, @prefix ++ [:parse, :stop], fn _measurements, metadata ->
      assert metadata.result == :error
      assert metadata.error == :invalid_rotation
    end)
  end

  test "source and plan-validation request errors carry the outer reason tag" do
    source =
      :get
      |> conn("/beach/full/max/0/default.jpg")
      |> ImagePipe.Plug.call(base_opts(sources: []))

    assert source.status == 500

    assert_event(telemetry_events(), @prefix ++ [:request, :stop], fn _measurements, metadata ->
      assert metadata.error == :source
    end)

    plan =
      :get
      |> conn("/any")
      |> ImagePipe.Plug.call(fixture_opts(EmptyPipelineDialect))

    assert plan.status == 422

    assert_event(telemetry_events(), @prefix ++ [:request, :stop], fn _measurements, metadata ->
      assert metadata.error == :plan_validation
    end)
  end

  test "emits exception events only for real raised exceptions" do
    assert_raise RuntimeError, "forced parse failure", fn ->
      ImagePipe.Plug.call(conn(:get, "/any"), fixture_opts(RaisingDialect))
    end

    events = telemetry_events()

    assert_event(events, @prefix ++ [:parse, :exception], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert metadata.kind == :error
      assert %RuntimeError{message: "forced parse failure"} = metadata.reason
      assert is_list(metadata.stacktrace)
    end)

    assert_event(events, @prefix ++ [:request, :exception], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert metadata.kind == :error
      assert %RuntimeError{message: "forced parse failure"} = metadata.reason
      assert is_list(metadata.stacktrace)
    end)
  end

  test "fetch_decode stop metadata includes load_option, achieved_shrink, and dims for shrunk JPEG" do
    {:ok, full_image} = Image.open("priv/static/images/beach.jpg")
    orig_w = Image.width(full_image)
    orig_h = Image.height(full_image)
    target_w = div(orig_w, 9)

    conn =
      :get
      |> conn("/beach/full/#{target_w},/0/default.jpg")
      |> ImagePipe.Plug.call(base_opts())

    assert conn.status == 200

    assert_event(
      telemetry_events(),
      @prefix ++ [:source, :fetch_decode, :stop],
      fn _measurements, stop_meta ->
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
    )
  end

  test "transform execute span carries operation count and names" do
    conn =
      :get
      |> conn("/beach/full/100,/0/default.jpg")
      |> ImagePipe.Plug.call(base_opts())

    assert conn.status == 200
    events = telemetry_events()

    assert_event(events, @prefix ++ [:transform, :execute, :start], fn _measurements, metadata ->
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
      |> conn("/srctiff/full/max/0/default.jpg")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 422
    events = telemetry_events()

    assert_event(events, @prefix ++ [:source, :fetch_decode, :stop], fn _measurements, metadata ->
      assert metadata.result == :source_error
      assert metadata.error == :body_too_large
    end)
  end

  test "fetch_decode stop metadata reports processing_error for input-pixel limit" do
    opts = base_opts(max_input_pixels: 1)

    conn =
      :get
      |> conn("/beach/full/max/0/default.jpg")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 413
    events = telemetry_events()

    assert_event(events, @prefix ++ [:source, :fetch_decode, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
      assert metadata.error == :input_limit
    end)
  end

  test "input_color_management span fires with working_space and imported? for a standard sRGB image" do
    conn =
      :get
      |> conn("/beach/full/max/0/default.jpg")
      |> ImagePipe.Plug.call(base_opts())

    assert conn.status == 200
    events = telemetry_events()

    assert_event(
      events,
      @prefix ++ [:transform, :input_color_management, :start],
      fn measurements, _metadata -> assert is_integer(measurements.system_time) end
    )

    assert_event(
      events,
      @prefix ++ [:transform, :input_color_management, :stop],
      fn measurements, metadata ->
        assert is_integer(measurements.duration)
        assert metadata.result == :ok
        assert is_atom(metadata.working_space)
        assert is_boolean(metadata.imported?)
        # beach.jpg has the canonical sRGB IEC61966 profile, which is not re-imported
        assert metadata.imported? == false
      end
    )
  end

  test "validates telemetry prefix option at init" do
    assert ImagePipe.Plug.init(opts(telemetry_prefix: @custom_prefix))[:telemetry_prefix] ==
             @custom_prefix

    for prefix <- ["image_pipe", [:image_pipe, "request"], [], [:image_pipe, 1]] do
      assert_raise ArgumentError,
                   ~r/invalid ImagePipe shared runtime options: invalid value for :telemetry_prefix option/,
                   fn -> ImagePipe.Plug.init(opts(telemetry_prefix: prefix)) end
    end
  end

  describe "request_result/1" do
    # The shared classifier the dialect Plugs stamp on their [:request] span's
    # :result. It must exactly mirror the runner's own error classification so
    # both arms speak the same vocabulary.
    test "maps :ok and :not_modified straight through" do
      assert ImagePipe.Telemetry.request_result(:ok) == :ok
      assert ImagePipe.Telemetry.request_result(:not_modified) == :not_modified
    end

    test "maps a source error" do
      assert ImagePipe.Telemetry.request_result({:error, {:source, :connect_error}}) ==
               :source_error
    end

    test "maps a cache-write error" do
      assert ImagePipe.Telemetry.request_result({:error, {:cache_write, :boom}}) == :cache_error
    end

    test "maps output/pipeline plan validation errors, bare and wrapped" do
      assert ImagePipe.Telemetry.request_result({:error, :invalid_output_plan}) == :plan_error
      assert ImagePipe.Telemetry.request_result({:error, :invalid_pipeline_plan}) == :plan_error

      assert ImagePipe.Telemetry.request_result({:error, {:invalid_output_plan, :reason}}) ==
               :plan_error

      assert ImagePipe.Telemetry.request_result({:error, {:invalid_pipeline_plan, :reason}}) ==
               :plan_error

      assert ImagePipe.Telemetry.request_result({:error, :empty_pipeline_plan}) == :plan_error
    end

    test "everything else falls back to processing_error" do
      assert ImagePipe.Telemetry.request_result({:error, {:transform, :boom}}) ==
               :processing_error

      assert ImagePipe.Telemetry.request_result({:error, {:decode, :boom}}) == :processing_error
      assert ImagePipe.Telemetry.request_result({:error, :some_other_reason}) == :processing_error
    end
  end

  # `image_module` is a test-injection seam the dialect config rejects as an
  # unknown option; it is spliced onto the validated config after init/1.
  @post_init_keys [:image_module]

  defp base_opts(overrides \\ []) do
    init_opts(overrides)
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp opts(overrides) do
    Keyword.merge(
      [
        dialect: ImagePipe.Dialect.IIIF,
        telemetry_prefix: @prefix,
        resolver:
          {ImagePipe.Dialect.IIIF.Resolver.Static,
           map: %{
             "beach" => %Source.Path{segments: ["images", "beach.jpg"]},
             "srctiff" => %Source.Path{segments: ["images", "source.tiff"]}
           }},
        sources: [
          path: {ImagePipe.Source.File, root: "priv/static", root_id: "static", stable: :trusted}
        ]
      ],
      overrides
    )
  end

  defp init_opts(overrides) do
    {post_init, known} = overrides |> opts() |> Keyword.split(@post_init_keys)
    Keyword.merge(ImagePipe.Plug.init(known), post_init)
  end

  # A mount for one of the plan-shaped declarative doubles: no resolver (they
  # ignore the conn), same source and prefix as the IIIF mounts.
  defp fixture_opts(dialect, overrides \\ []) do
    ImagePipe.Plug.init(
      Keyword.merge(
        [
          dialect: dialect,
          telemetry_prefix: @prefix,
          sources: [
            path:
              {ImagePipe.Source.File, root: "priv/static", root_id: "static", stable: :trusted}
          ]
        ],
        overrides
      )
    )
  end

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
    span_events(@prefix) ++ [@prefix ++ [:cache, :stage]]
  end

  defp custom_events do
    span_events(@custom_prefix) ++ [@custom_prefix ++ [:cache, :stage]]
  end

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
      [:transform, :input_color_management],
      [:render],
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

  # Every named stage must have emitted BOTH a :start and a :stop.
  defp assert_spans(events, stages) do
    names = event_names(events)

    for stage <- stages, suffix <- [:start, :stop] do
      event = @prefix ++ stage ++ [suffix]

      assert event in names,
             "expected telemetry event #{inspect(event)}, got #{inspect(names)}"
    end
  end

  defp refute_event(events, event, opts \\ []) do
    message = Keyword.get(opts, :message, "unexpected telemetry event #{inspect(event)}")

    refute Enum.any?(events, fn {candidate, _measurements, _metadata} -> candidate == event end),
           message
  end

  defp event_names(events),
    do: Enum.map(events, fn {event, _measurements, _metadata} -> event end)

  defp index_of(names, event) do
    index = Enum.find_index(names, &(&1 == event))
    assert index, "expected telemetry event #{inspect(event)}, got #{inspect(names)}"
    index
  end

  # Span metadata always carries `:telemetry_span_context`; drop it so a test
  # can pin the rest of the map exactly.
  defp span_metadata(metadata), do: Map.delete(metadata, :telemetry_span_context)
end
