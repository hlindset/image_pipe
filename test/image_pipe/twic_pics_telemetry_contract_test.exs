defmodule ImagePipe.TwicPicsTelemetryContractTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Dialect.TwicPics
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.OriginImage

  defmodule ParkingSource do
    @moduledoc false
    @behaviour ImagePipe.Source

    @impl true
    def validate_options(opts), do: {:ok, Keyword.put_new(opts, :telemetry_kind, :parking_test)}

    @impl true
    def resolve(source, _opts, _runtime_opts) do
      path = source.segments

      {:ok,
       %Resolved{
         adapter: :path,
         source_kind: :path,
         identity: [kind: :path, adapter: :path, root: "twicpics-telemetry-parking", path: path],
         internal_cache: :enabled,
         http_cache: :enabled,
         cache_semantics: %CacheSemantics{
           byte_identity:
             {:strong, [kind: :path, root: "twicpics-telemetry-parking", path: path]},
           stable?: true
         },
         fetch: [path: path]
       }}
    end

    @impl true
    def fetch(_resolved, opts, _runtime_opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)

      stream =
        Stream.resource(
          fn ->
            send(test_pid, {:fetch_parked, self()})

            receive do
              :proceed -> :ok
            end
          end,
          fn _state -> {:halt, :ok} end,
          fn _state -> :ok end
        )

      {:ok, %Response{stream: stream}}
    end
  end

  defmodule RaisingAfterFirstChunkImage do
    @moduledoc false

    def stream!(_image, [{:suffix, ".jpg"} | _options]) do
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

  @stages [
    [:request],
    [:parse],
    [:send],
    [:deliver],
    [:render],
    [:cache, :lookup],
    [:cache, :write],
    [:source, :resolve],
    [:source, :fetch],
    [:source, :fetch_decode],
    [:transform, :execute],
    [:transform, :operation],
    [:transform, :input_color_management],
    [:transform, :materialize],
    [:output, :negotiate],
    [:encode]
  ]

  @test_seams [:image_module, :chain]
  @image_path "/images/cat.jpg?twic=v1/resize=64/output=jpeg"

  @doc false
  def handle_event(name, _measurements, metadata, {test_pid, prefix}) do
    send(test_pid, {:telemetry_event, prefix, name, metadata})
  end

  test "cache miss has equivalent semantic stage order and result metadata" do
    {framework_conn, framework} = run(:framework, :cache_miss)
    {dialect_conn, dialect} = run(:dialect, :cache_miss)

    assert framework_conn.status == 200
    assert dialect_conn.status == 200
    assert outer_request?(framework)
    assert outer_request?(dialect)

    assert framework == dialect
  end

  test "cache hit has equivalent cache-only generation stage semantics" do
    {framework_conn, framework} = run(:framework, :cache_hit)
    {dialect_conn, dialect} = run(:dialect, :cache_hit)

    assert framework_conn.status == 200
    assert dialect_conn.status == 200
    assert stage?(framework, [:cache, :lookup])
    refute stage?(framework, [:source, :fetch])
    refute stage?(framework, [:transform, :execute])
    assert framework == dialect
  end

  test "conditional 304 has equivalent pre-fetch stage semantics" do
    {framework_conn, framework} = run(:framework, :not_modified)
    {dialect_conn, dialect} = run(:dialect, :not_modified)

    assert framework_conn.status == 304
    assert dialect_conn.status == 304
    refute stage?(framework, [:cache, :lookup])
    refute stage?(framework, [:source, :fetch])
    assert stop_result(framework, [:request]) == :not_modified
    assert framework == dialect
  end

  test "parse error has equivalent stage semantics and error attribution" do
    {framework_conn, framework} = run(:framework, :parse_error)
    {dialect_conn, dialect} = run(:dialect, :parse_error)

    assert framework_conn.status == 400
    assert dialect_conn.status == 400
    assert stop_result(framework, [:parse]) == :error
    assert stop_error(framework, [:parse]) == :parser_error
    refute stage?(framework, [:source, :resolve])
    assert framework == dialect
  end

  test "streamed failure after prepare has equivalent delivery error attribution" do
    {framework_conn, framework} = run(:framework, :streamed_error)
    {dialect_conn, dialect} = run(:dialect, :streamed_error)

    assert framework_conn.status == 200
    assert dialect_conn.status == 200
    assert stop_result(framework, [:deliver]) == :processing_error
    assert stop_error(framework, [:deliver]) == :encode
    assert stop_result(framework, [:encode]) == :ok

    assert stop_metadata(framework, [:request]) ==
             %{result: :processing_error, status: 200}

    assert stop_metadata(dialect, [:request]) ==
             %{result: :processing_error, status: 200}

    assert framework == dialect
  end

  test "owner cancellation has equivalent incomplete stage semantics" do
    {:killed, framework} = run(:framework, :owner_cancellation)
    {:killed, dialect} = run(:dialect, :owner_cancellation)

    assert event?(framework, [:request], :start)
    refute event?(framework, [:request], :stop)
    refute event?(framework, [:deliver], :stop)
    assert framework == dialect
  end

  test "semantic normalization collapses only immediately repeated callbacks" do
    duplicate = %{stage: [:output, :negotiate], phase: :start, metadata: %{}}
    boundary = %{stage: [:transform, :materialize], phase: :start, metadata: %{}}

    assert collapse_adjacent_topology_duplicates([duplicate, duplicate, boundary]) ==
             [duplicate, boundary]
  end

  test "semantic normalization preserves separated repetitions and operation order" do
    operation = %{
      stage: [:transform, :operation],
      phase: :start,
      metadata: %{operation: :resize, index: 1}
    }

    materialize = %{stage: [:transform, :materialize], phase: :start, metadata: %{}}
    trace = [operation, materialize, operation]

    assert collapse_adjacent_topology_duplicates(trace) == trace
    refute collapse_adjacent_topology_duplicates([operation, operation, materialize]) == trace
  end

  test "semantic trace retains operation names and indices" do
    prefix = [:semantic_trace_fixture]

    events = [
      {prefix ++ [:transform, :operation, :start], %{operation: :resize, index: 0}},
      {prefix ++ [:transform, :operation, :stop], %{operation: :resize, index: 0, result: :ok}},
      {prefix ++ [:transform, :operation, :start], %{operation: :resize, index: 1}},
      {prefix ++ [:transform, :operation, :stop], %{operation: :resize, index: 1, result: :ok}}
    ]

    assert Enum.map(semantic_trace(events, prefix), & &1.metadata) == [
             %{operation: :resize, index: 0},
             %{operation: :resize, index: 0, result: :ok},
             %{operation: :resize, index: 1},
             %{operation: :resize, index: 1, result: :ok}
           ]
  end

  test "parser-error normalization accepts only the two known wrapper tags" do
    for {stage, result, error} <- [
          {[:parse], :error, :error},
          {[:parse], :error, :unsupported_transform},
          {[:request], :parser_error, :error},
          {[:request], :parser_error, :unsupported_transform}
        ] do
      event = %{stage: stage, phase: :stop, metadata: %{result: result, error: error}}

      assert normalize_parser_error(event).metadata.error == :parser_error
    end
  end

  test "a wrong dialect parser error remains visible to the semantic comparison" do
    framework = %{
      stage: [:parse],
      phase: :stop,
      metadata: %{result: :error, error: :error}
    }

    wrong_dialect = %{
      stage: [:parse],
      phase: :stop,
      metadata: %{result: :error, error: :decode}
    }

    assert normalize_parser_error(framework).metadata.error == :parser_error
    assert normalize_parser_error(wrong_dialect).metadata.error == :decode
    refute normalize_parser_error(framework) == normalize_parser_error(wrong_dialect)
  end

  defp run(arm, :cache_miss) do
    observe(arm, :cache_miss, fn prefix ->
      call(arm, @image_path, opts(prefix, cache: {CacheProbe, []}))
    end)
  end

  defp run(arm, :cache_hit) do
    table = :ets.new(:twicpics_telemetry_contract_hit, [:set, :public])
    cache = {CacheProbe, store: table}
    warm_opts = base_opts(cache: cache)
    assert call(arm, @image_path, warm_opts).status == 200

    observe(arm, :cache_hit, fn prefix ->
      call(arm, @image_path, opts(prefix, cache: cache))
    end)
  end

  defp run(arm, :not_modified) do
    warm = call(arm, @image_path, base_opts(cache: {CacheProbe, []}))
    assert warm.status == 200
    assert [etag] = get_resp_header(warm, "etag")

    observe(arm, :not_modified, fn prefix ->
      call(arm, @image_path, opts(prefix, cache: {CacheProbe, []}), [
        {"if-none-match", etag}
      ])
    end)
  end

  defp run(arm, :parse_error) do
    observe(arm, :parse_error, fn prefix ->
      call(
        arm,
        "/images/cat.jpg?twic=v1/unknown=1",
        opts(prefix, cache: {CacheProbe, []})
      )
    end)
  end

  defp run(arm, :streamed_error) do
    test_pid = self()

    observe(arm, :streamed_error, fn prefix ->
      ExUnit.CaptureLog.capture_log(fn ->
        conn =
          call(
            arm,
            @image_path,
            opts(prefix, cache: {CacheProbe, []}, image_module: RaisingAfterFirstChunkImage)
          )

        send(test_pid, {:streamed_error_conn, conn})
      end)

      assert_receive {:streamed_error_conn, conn}
      conn
    end)
  end

  defp run(arm, :owner_cancellation) do
    test_pid = self()

    observe(arm, :owner_cancellation, fn prefix ->
      owner =
        spawn(fn ->
          call(
            arm,
            @image_path,
            parser: ImagePipe.Parser.TwicPics,
            sources: [path: {ParkingSource, test_pid: test_pid}],
            telemetry_prefix: prefix,
            cache: {CacheProbe, []}
          )
        end)

      owner_ref = Process.monitor(owner)
      assert_receive {:fetch_parked, producer}
      producer_ref = Process.monitor(producer)

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
      send(producer, :proceed)
      assert_receive {:DOWN, ^producer_ref, :process, ^producer, _reason}, 2_000
      :killed
    end)
  end

  defp observe(arm, scenario, fun) do
    prefix = [
      :"twicpics_telemetry_#{arm}_#{scenario}_#{System.unique_integer([:positive])}"
    ]

    events =
      Enum.flat_map(@stages, fn stage ->
        [
          prefix ++ stage ++ [:start],
          prefix ++ stage ++ [:stop],
          prefix ++ stage ++ [:exception]
        ]
      end)

    handler_id = {__MODULE__, arm, scenario, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_event/4,
        {self(), prefix}
      )

    try do
      result = fun.(prefix)
      {result, prefix |> captured() |> semantic_trace(prefix)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp captured(prefix, acc \\ []) do
    receive do
      {:telemetry_event, ^prefix, name, metadata} ->
        captured(prefix, [{name, metadata} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp semantic_trace(events, prefix) do
    Enum.map(events, fn {name, metadata} ->
      suffix = Enum.drop(name, length(prefix))
      {stage, [phase]} = Enum.split(suffix, -1)

      normalize_parser_error(%{
        stage: stage,
        phase: phase,
        metadata: Map.take(metadata, [:result, :error, :status, :operation, :index])
      })
    end)
    |> collapse_adjacent_topology_duplicates()
  end

  defp collapse_adjacent_topology_duplicates(events) do
    events
    |> Enum.reduce([], fn
      event, [previous | _rest] = acc when event == previous -> acc
      event, acc -> [event | acc]
    end)
    |> Enum.reverse()
  end

  defp normalize_parser_error(
         %{stage: [:parse], metadata: %{result: :error, error: error}} = event
       )
       when error in [:error, :unsupported_transform],
       do: put_in(event, [:metadata, :error], :parser_error)

  defp normalize_parser_error(
         %{stage: [:request], metadata: %{result: :parser_error, error: error}} = event
       )
       when error in [:error, :unsupported_transform],
       do: put_in(event, [:metadata, :error], :parser_error)

  defp normalize_parser_error(event), do: event

  defp opts(prefix, extra), do: base_opts(Keyword.put(extra, :telemetry_prefix, prefix))

  defp base_opts(extra) do
    Keyword.merge(
      [
        parser: ImagePipe.Parser.TwicPics,
        http_cache: [mode: :enabled],
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://twicpics-telemetry.test",
             byte_identity: :strong,
             req_options: [plug: OriginImage]}
        ]
      ],
      extra
    )
  end

  defp call(arm, path, opts, headers \\ []) do
    conn =
      Enum.reduce(headers, conn(:get, path), fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)

    call_arm(arm, conn, opts)
  end

  defp call_arm(:framework, conn, opts) do
    {seams, known} = Keyword.split(opts, @test_seams)
    ImagePipe.Plug.call(conn, Keyword.merge(ImagePipe.Plug.init(known), seams))
  end

  defp call_arm(:dialect, conn, opts) do
    {seams, known} = Keyword.split(opts, @test_seams)

    known =
      known
      |> Keyword.delete(:parser)
      |> Keyword.delete(:http_cache)

    TwicPics.call(conn, Keyword.merge(TwicPics.init(known), seams))
  end

  defp stage?(trace, stage), do: Enum.any?(trace, &(&1.stage == stage))

  defp event?(trace, stage, phase),
    do: Enum.any?(trace, &(&1.stage == stage and &1.phase == phase))

  defp outer_request?(trace) do
    match?(%{stage: [:request], phase: :start}, List.first(trace)) and
      match?(%{stage: [:request], phase: :stop}, List.last(trace))
  end

  defp stop_result(trace, stage), do: stop_metadata(trace, stage)[:result]
  defp stop_error(trace, stage), do: stop_metadata(trace, stage)[:error]

  defp stop_metadata(trace, stage) do
    trace
    |> Enum.find(&(&1.stage == stage and &1.phase == :stop))
    |> Map.fetch!(:metadata)
  end
end
