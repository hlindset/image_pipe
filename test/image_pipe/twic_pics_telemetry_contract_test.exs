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

  test "cache miss preserves semantic stage order and result metadata" do
    {conn, trace} = run(:cache_miss)

    assert conn.status == 200
    assert outer_request?(trace)
    assert_trace(:cache_miss, trace)
  end

  test "cache hit preserves cache-only generation stage semantics" do
    {conn, trace} = run(:cache_hit)

    assert conn.status == 200
    assert stage?(trace, [:cache, :lookup])
    refute stage?(trace, [:source, :fetch])
    refute stage?(trace, [:transform, :execute])
    assert_trace(:cache_hit, trace)
  end

  test "conditional 304 preserves pre-fetch stage semantics" do
    {conn, trace} = run(:not_modified)

    assert conn.status == 304
    refute stage?(trace, [:cache, :lookup])
    refute stage?(trace, [:source, :fetch])
    assert stop_result(trace, [:request]) == :not_modified
    assert_trace(:not_modified, trace)
  end

  test "parse error preserves stage semantics and error attribution" do
    {conn, trace} = run(:parse_error)

    assert conn.status == 400
    assert stop_result(trace, [:parse]) == :error
    assert stop_error(trace, [:parse]) == :parser_error
    refute stage?(trace, [:source, :resolve])
    assert_trace(:parse_error, trace)
  end

  test "streamed failure after prepare preserves delivery error attribution" do
    {conn, trace} = run(:streamed_error)

    assert conn.status == 200
    assert stop_result(trace, [:deliver]) == :processing_error
    assert stop_error(trace, [:deliver]) == :encode
    assert stop_result(trace, [:encode]) == :ok
    assert stop_metadata(trace, [:request]) == %{result: :processing_error, status: 200}
    assert_trace(:streamed_error, trace)
  end

  test "owner cancellation preserves incomplete stage semantics" do
    {:killed, trace} = run(:owner_cancellation)

    assert event?(trace, [:request], :start)
    refute event?(trace, [:request], :stop)
    refute event?(trace, [:deliver], :stop)
    assert_trace(:owner_cancellation, trace)
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

  defp run(:cache_miss) do
    observe(:cache_miss, fn prefix ->
      call(@image_path, opts(prefix, cache: {CacheProbe, []}))
    end)
  end

  defp run(:cache_hit) do
    table = :ets.new(:twicpics_telemetry_contract_hit, [:set, :public])
    cache = {CacheProbe, store: table}
    warm_opts = base_opts(cache: cache)
    assert call(@image_path, warm_opts).status == 200

    observe(:cache_hit, fn prefix ->
      call(@image_path, opts(prefix, cache: cache))
    end)
  end

  defp run(:not_modified) do
    warm = call(@image_path, base_opts(cache: {CacheProbe, []}))
    assert warm.status == 200
    assert [etag] = get_resp_header(warm, "etag")

    observe(:not_modified, fn prefix ->
      call(@image_path, opts(prefix, cache: {CacheProbe, []}), [
        {"if-none-match", etag}
      ])
    end)
  end

  defp run(:parse_error) do
    observe(:parse_error, fn prefix ->
      call(
        "/images/cat.jpg?twic=v1/unknown=1",
        opts(prefix, cache: {CacheProbe, []})
      )
    end)
  end

  defp run(:streamed_error) do
    test_pid = self()

    observe(:streamed_error, fn prefix ->
      ExUnit.CaptureLog.capture_log(fn ->
        conn =
          call(
            @image_path,
            opts(prefix, cache: {CacheProbe, []}, image_module: RaisingAfterFirstChunkImage)
          )

        send(test_pid, {:streamed_error_conn, conn})
      end)

      assert_receive {:streamed_error_conn, conn}
      conn
    end)
  end

  defp run(:owner_cancellation) do
    test_pid = self()

    observe(:owner_cancellation, fn prefix ->
      owner =
        start_supervised!(
          {Task,
           fn ->
             call(
               @image_path,
               sources: [path: {ParkingSource, test_pid: test_pid}],
               telemetry_prefix: prefix,
               cache: {CacheProbe, []}
             )
           end}
        )

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

  defp observe(scenario, fun) do
    prefix = [
      :"twicpics_telemetry_dialect_#{scenario}_#{System.unique_integer([:positive])}"
    ]

    events =
      Enum.flat_map(@stages, fn stage ->
        [
          prefix ++ stage ++ [:start],
          prefix ++ stage ++ [:stop],
          prefix ++ stage ++ [:exception]
        ]
      end)

    handler_id = {__MODULE__, scenario, make_ref()}

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

  defp assert_trace(scenario, trace) do
    assert Enum.map(trace, &{&1.stage, &1.phase, &1.metadata}) == expected_trace(scenario)
  end

  defp expected_trace(:cache_miss) do
    [
      {[:request], :start, %{}},
      {[:parse], :start, %{}},
      {[:parse], :stop, %{result: :ok}},
      {[:source, :resolve], :start, %{}},
      {[:source, :resolve], :stop, %{result: :ok}},
      {[:cache, :lookup], :start, %{}},
      {[:cache, :lookup], :stop, %{result: :ok}},
      {[:source, :fetch_decode], :start, %{}},
      {[:source, :fetch], :start, %{}},
      {[:source, :fetch], :stop, %{result: :ok}},
      {[:source, :fetch_decode], :stop, %{result: :ok}},
      {[:transform, :execute], :start, %{}},
      {[:transform, :input_color_management], :start, %{}},
      {[:transform, :input_color_management], :stop, %{result: :ok}},
      {[:transform, :operation], :start, %{index: 0, operation: :resize}},
      {[:transform, :operation], :stop, %{index: 0, operation: :resize, result: :ok}},
      {[:transform, :execute], :stop, %{result: :ok}},
      {[:output, :negotiate], :start, %{}},
      {[:output, :negotiate], :stop, %{result: :ok}},
      {[:transform, :materialize], :start, %{}},
      {[:transform, :materialize], :stop, %{result: :ok}},
      {[:encode], :start, %{}},
      {[:encode], :stop, %{result: :ok}},
      {[:send], :start, %{result: :ok}},
      {[:deliver], :start, %{}},
      {[:cache, :write], :start, %{}},
      {[:cache, :write], :stop, %{result: :ok}},
      {[:deliver], :stop, %{result: :ok, status: 200}},
      {[:send], :stop, %{result: :ok, status: 200}},
      {[:request], :stop, %{result: :ok, status: 200}}
    ]
  end

  defp expected_trace(:cache_hit) do
    [
      {[:request], :start, %{}},
      {[:parse], :start, %{}},
      {[:parse], :stop, %{result: :ok}},
      {[:source, :resolve], :start, %{}},
      {[:source, :resolve], :stop, %{result: :ok}},
      {[:cache, :lookup], :start, %{}},
      {[:cache, :lookup], :stop, %{result: :ok}},
      {[:send], :start, %{result: :ok}},
      {[:send], :stop, %{result: :ok, status: 200}},
      {[:request], :stop, %{result: :ok, status: 200}}
    ]
  end

  defp expected_trace(:not_modified) do
    [
      {[:request], :start, %{}},
      {[:parse], :start, %{}},
      {[:parse], :stop, %{result: :ok}},
      {[:source, :resolve], :start, %{}},
      {[:source, :resolve], :stop, %{result: :ok}},
      {[:send], :start, %{result: :not_modified}},
      {[:send], :stop, %{result: :not_modified, status: 304}},
      {[:request], :stop, %{result: :not_modified, status: 304}}
    ]
  end

  defp expected_trace(:parse_error) do
    [
      {[:request], :start, %{}},
      {[:parse], :start, %{}},
      {[:parse], :stop, %{error: :parser_error, result: :error}},
      {[:send], :start, %{result: :parser_error}},
      {[:send], :stop, %{result: :parser_error, status: 400}},
      {[:request], :stop, %{error: :parser_error, result: :parser_error, status: 400}}
    ]
  end

  defp expected_trace(:streamed_error) do
    [
      {[:request], :start, %{}},
      {[:parse], :start, %{}},
      {[:parse], :stop, %{result: :ok}},
      {[:source, :resolve], :start, %{}},
      {[:source, :resolve], :stop, %{result: :ok}},
      {[:cache, :lookup], :start, %{}},
      {[:cache, :lookup], :stop, %{result: :ok}},
      {[:source, :fetch_decode], :start, %{}},
      {[:source, :fetch], :start, %{}},
      {[:source, :fetch], :stop, %{result: :ok}},
      {[:source, :fetch_decode], :stop, %{result: :ok}},
      {[:transform, :execute], :start, %{}},
      {[:transform, :input_color_management], :start, %{}},
      {[:transform, :input_color_management], :stop, %{result: :ok}},
      {[:transform, :operation], :start, %{index: 0, operation: :resize}},
      {[:transform, :operation], :stop, %{index: 0, operation: :resize, result: :ok}},
      {[:transform, :execute], :stop, %{result: :ok}},
      {[:output, :negotiate], :start, %{}},
      {[:output, :negotiate], :stop, %{result: :ok}},
      {[:transform, :materialize], :start, %{}},
      {[:transform, :materialize], :stop, %{result: :ok}},
      {[:encode], :start, %{}},
      {[:encode], :stop, %{result: :ok}},
      {[:send], :start, %{result: :ok}},
      {[:deliver], :start, %{}},
      {[:deliver], :stop, %{error: :encode, result: :processing_error, status: 200}},
      {[:send], :stop, %{result: :processing_error, status: 200}},
      {[:request], :stop, %{result: :processing_error, status: 200}}
    ]
  end

  defp expected_trace(:owner_cancellation) do
    [
      {[:request], :start, %{}},
      {[:parse], :start, %{}},
      {[:parse], :stop, %{result: :ok}},
      {[:source, :resolve], :start, %{}},
      {[:source, :resolve], :stop, %{result: :ok}},
      {[:cache, :lookup], :start, %{}},
      {[:cache, :lookup], :stop, %{result: :ok}},
      {[:source, :fetch_decode], :start, %{}},
      {[:source, :fetch], :start, %{}},
      {[:source, :fetch], :stop, %{result: :ok}},
      {[:source, :fetch_decode], :stop, %{error: :decode, result: :processing_error}}
    ]
  end

  defp opts(prefix, extra), do: base_opts(Keyword.put(extra, :telemetry_prefix, prefix))

  defp base_opts(extra) do
    Keyword.merge(
      [
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

  defp call(path, opts, headers \\ []) do
    conn =
      Enum.reduce(headers, conn(:get, path), fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)

    {seams, known} = Keyword.split(opts, @test_seams)
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
