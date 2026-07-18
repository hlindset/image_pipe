defmodule ImagePipe.Dialect.TwicPics.LifecycleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Dialect.TwicPics
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}
  alias ImgproxyWireConformanceTest.CountingOriginImage
  alias ImgproxyWireConformanceTest.OriginImage
  alias ImgproxyWireConformanceTest.OriginShouldNotFetch

  defmodule Origin503 do
    @moduledoc false

    def init(opts), do: opts

    def call(conn, opts) do
      send(Keyword.fetch!(opts, :test_pid), :origin_fetch)
      Plug.Conn.send_resp(conn, 503, "origin 503")
    end
  end

  defmodule CorruptOrigin do
    @moduledoc false

    def init(opts), do: opts

    def call(conn, opts) do
      send(Keyword.fetch!(opts, :test_pid), :origin_fetch)

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, "not an image \xFF\xFE")
    end
  end

  defmodule ResolveTrackingSource do
    @moduledoc false
    @behaviour ImagePipe.Source

    alias ImagePipe.SourceTest.RootHTTPAdapter

    @impl true
    def validate_options(opts) do
      with {:ok, validated} <- RootHTTPAdapter.validate_options(opts),
           {:ok, test_pid} <- Keyword.fetch(opts, :test_pid) do
        {:ok, Keyword.put(validated, :test_pid, test_pid)}
      end
    end

    @impl true
    def resolve(source, opts, runtime_opts) do
      send(Keyword.fetch!(opts, :test_pid), :source_resolve)
      RootHTTPAdapter.resolve(source, opts, runtime_opts)
    end

    @impl true
    def fetch(resolved, opts, runtime_opts) do
      RootHTTPAdapter.fetch(resolved, opts, runtime_opts)
    end
  end

  defmodule RaisingBeforeFirstChunkImage do
    @moduledoc false

    def stream!(_image, [{:suffix, ".jpg"} | _options]) do
      Stream.resource(
        fn -> :start end,
        fn :start -> raise "boom before first chunk" end,
        fn _state -> :ok end
      )
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

  defmodule TrackingCache do
    @moduledoc false
    @behaviour ImagePipe.Cache

    @impl true
    def get(key, opts) do
      send(target(), {:cache_get, key})

      case Keyword.fetch(opts, :store) do
        {:ok, table} ->
          case :ets.lookup(table, key.hash) do
            [{_hash, entry}] -> {:hit, entry}
            [] -> Keyword.get(opts, :get_result, :miss)
          end

        :error ->
          Keyword.get(opts, :get_result, :miss)
      end
    end

    @impl true
    def open_sink(key, metadata, opts) do
      send(target(), {:cache_open, key, metadata})
      {:ok, %{key: key, metadata: metadata, chunks: [], opts: opts}}
    end

    @impl true
    def write_chunk(state, chunk, opts) do
      send(target(), {:cache_write, chunk})

      case Keyword.get(opts, :fail_write?, false) do
        true -> {:error, :forced_write_failure, state}
        false -> {:ok, %{state | chunks: [chunk | state.chunks]}}
      end
    end

    @impl true
    def commit_sink(state, opts) do
      body = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()
      maybe_store(opts, state.key, state.metadata, body)
      send(target(), :cache_commit)
      :ok
    end

    @impl true
    def abort_sink(_state, _opts) do
      send(target(), :cache_abort)
      :ok
    end

    defp maybe_store(opts, key, metadata, body) do
      case Keyword.fetch(opts, :store) do
        {:ok, table} ->
          entry = %Entry{
            body: body,
            content_type: metadata.content_type,
            headers: metadata.headers,
            created_at: metadata.created_at,
            representation: metadata.representation,
            debug: metadata.debug
          }

          :ets.insert(table, {key.hash, entry})

        :error ->
          :ok
      end
    end

    defp target do
      case Process.get(:"$callers") do
        [pid | _rest] when is_pid(pid) -> pid
        _callers -> self()
      end
    end
  end

  @default_sources [
    path:
      {RootHTTPAdapter,
       root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
  ]

  @test_seams [:image_module, :on_bracket_exit, :chain]

  defp opts(extra \\ []) do
    {seams, validated} = Keyword.split(extra, @test_seams)
    base = TwicPics.init(Keyword.merge([sources: @default_sources], validated))
    Keyword.merge(base, seams)
  end

  defp counting_sources(internal_cache \\ :enabled) do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test",
         byte_identity: :strong,
         internal_cache: internal_cache,
         req_options: [plug: {CountingOriginImage, test_pid: self()}]}
    ]
  end

  defp should_not_fetch_sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test",
         byte_identity: :strong,
         req_options: [plug: OriginShouldNotFetch]}
    ]
  end

  defp resolve_tracking_sources do
    [
      path:
        {ResolveTrackingSource,
         root_url: "http://origin.test",
         byte_identity: :strong,
         test_pid: self(),
         req_options: [plug: {CountingOriginImage, test_pid: self()}]}
    ]
  end

  defp stateful_cache do
    table = :ets.new(:twic_pics_lifecycle_cache, [:set, :public])
    {TrackingCache, store: table}
  end

  defp request(method, path, config, headers \\ []) do
    conn = conn(method, path)

    conn =
      Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)

    TwicPics.call(conn, config)
  end

  defp get(path, config, headers \\ []), do: request(:get, path, config, headers)

  defp decoded_dims(body) do
    {:ok, image} = Image.from_binary(body)
    {Image.width(image), Image.height(image)}
  end

  @doc false
  def handle_telemetry(event, measurements, metadata, owner) do
    send(owner, {:telemetry_event, event, measurements, metadata})
  end

  defp attach_events(prefix, stages) do
    owner = self()
    handler_id = make_ref()

    events =
      for stage <- stages,
          phase <- [:start, :stop, :exception],
          do: prefix ++ stage ++ [phase]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry/4,
        owner
      )

    handler_id
  end

  describe "route and request lifecycle" do
    test "GET executes the ordered TwicPics chain and sends an image" do
      conn = get("/images/beach.jpg?twic=v1/contain=100x80/output=jpeg", opts())

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert {width, height} = decoded_dims(conn.resp_body)
      assert width <= 100
      assert height <= 80
    end

    test "HEAD returns the current image metadata without a response body" do
      conn = request(:head, "/images/beach.jpg?twic=v1/resize=64/output=jpeg", opts())

      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert [_etag] = get_resp_header(conn, "etag")
    end

    test "OPTIONS and unsupported methods terminate before source and cache" do
      config = opts(sources: resolve_tracking_sources(), cache: {TrackingCache, []})

      options = request(:options, "/images/beach.jpg?twic=v1/resize=64", config)
      put = request(:put, "/images/beach.jpg?twic=v1/resize=64", config)

      assert options.status == 204
      assert get_resp_header(options, "allow") == ["GET, HEAD"]
      assert put.status == 405
      assert get_resp_header(put, "allow") == ["GET, HEAD"]
      refute_received :source_resolve
      refute_received :origin_fetch
      refute_received {:cache_get, _key}
    end

    test "parse failures happen before source resolution, cache lookup, and fetch" do
      config = opts(sources: resolve_tracking_sources(), cache: {TrackingCache, []})
      conn = get("/images/beach.jpg?twic=v1/unknown=1", config)

      assert conn.status == 400
      refute_received :source_resolve
      refute_received :origin_fetch
      refute_received {:cache_get, _key}
    end

    test "unsupported explicit output is rejected before cache and fetch" do
      config =
        opts(
          sources: counting_sources(),
          cache: {TrackingCache, []},
          output_capabilities: %{avif: false}
        )

      conn = get("/images/beach.jpg?twic=v1/output=avif", config)

      assert conn.status == 501
      refute_received :origin_fetch
      refute_received {:cache_get, _key}
    end
  end

  describe "CORS" do
    test "200, 304, and parse-error responses carry the configured origin" do
      cors_opts = opts(allow_origin: "https://cdn.test")
      ok = get("/images/beach.jpg?twic=v1/resize=64/output=jpeg", cors_opts)
      [etag] = get_resp_header(ok, "etag")

      not_modified =
        get(
          "/images/beach.jpg?twic=v1/resize=64/output=jpeg",
          opts(allow_origin: "https://cdn.test", sources: should_not_fetch_sources()),
          [{"if-none-match", etag}]
        )

      bad = get("/images/beach.jpg?twic=v1/debug=maybe", cors_opts)

      assert ok.status == 200
      assert not_modified.status == 304
      assert bad.status == 400

      for conn <- [ok, not_modified, bad] do
        assert get_resp_header(conn, "access-control-allow-origin") == ["https://cdn.test"]
      end
    end

    test "OPTIONS and 405 carry the configured CORS headers" do
      config = opts(allow_origin: "https://cdn.test", sources: should_not_fetch_sources())
      options = request(:options, "/images/beach.jpg", config)
      denied = request(:post, "/images/beach.jpg", config)

      assert get_resp_header(options, "access-control-allow-origin") == ["https://cdn.test"]
      assert get_resp_header(options, "access-control-allow-methods") == ["GET, HEAD, OPTIONS"]
      assert get_resp_header(denied, "access-control-allow-origin") == ["https://cdn.test"]
    end
  end

  describe "conditional and cache ordering" do
    test "a matching concrete ETag returns 304 before cache lookup and fetch" do
      plain = get("/images/beach.jpg?twic=v1/resize=64/output=jpeg", opts())
      [etag] = get_resp_header(plain, "etag")

      config = opts(sources: should_not_fetch_sources(), cache: {TrackingCache, []})

      conn =
        get(
          "/images/beach.jpg?twic=v1/resize=64/output=jpeg",
          config,
          [{"if-none-match", etag}]
        )

      assert conn.status == 304
      assert conn.resp_body == ""
      refute_received {:cache_get, _key}
    end

    test "If-None-Match wildcard is 200 on a miss and 304 only on a hit" do
      config = opts(sources: counting_sources(), cache: stateful_cache())
      path = "/images/beach.jpg?twic=v1/resize=64/output=jpeg"

      cold = get(path, config, [{"if-none-match", "*"}])
      assert cold.status == 200
      assert_received :origin_fetch

      warm = get(path, config, [{"if-none-match", "*"}])
      assert warm.status == 304
      refute_received :origin_fetch
    end

    test "a miss writes once and a subsequent hit does not fetch or rewrite" do
      config = opts(sources: counting_sources(), cache: stateful_cache())
      path = "/images/beach.jpg?twic=v1/contain=80x80/output=jpeg"

      miss = get(path, config)
      assert miss.status == 200
      assert_received :origin_fetch
      assert_received :cache_commit

      hit = get(path, config)
      assert hit.status == 200
      refute_received :origin_fetch
      refute_received :cache_commit
      assert hit.resp_body == miss.resp_body
      assert get_resp_header(hit, "etag") == get_resp_header(miss, "etag")
      assert get_resp_header(hit, "vary") == get_resp_header(miss, "vary")
    end

    test "a source with internal cache disabled performs no cache read or write" do
      config =
        opts(
          sources: counting_sources(:disabled),
          cache: {TrackingCache, []}
        )

      conn = get("/images/beach.jpg?twic=v1/resize=64/output=jpeg", config)

      assert conn.status == 200
      assert_received :origin_fetch
      refute_received {:cache_get, _key}
      refute_received {:cache_open, _key, _metadata}
      refute_received :cache_commit
    end

    test "a cache read failure fails open and commits the generated response" do
      read_failure =
        opts(
          sources: counting_sources(),
          cache: {TrackingCache, get_result: {:error, :forced_read_failure}}
        )

      read_conn = get("/images/beach.jpg?twic=v1/resize=63/output=jpeg", read_failure)
      assert read_conn.status == 200
      assert_received :origin_fetch
      assert_received :cache_commit
    end

    test "a cache write failure fails open and aborts instead of committing" do
      write_failure =
        opts(
          sources: counting_sources(),
          cache: {TrackingCache, fail_write?: true}
        )

      write_conn = get("/images/beach.jpg?twic=v1/resize=62/output=jpeg", write_failure)
      assert write_conn.status == 200
      assert_received :origin_fetch
      assert_received :cache_abort
      refute_received :cache_commit
    end
  end

  describe "generation failures and limits" do
    test "source, decode, and input-limit failures preserve the core status taxonomy" do
      source_config =
        opts(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               byte_identity: :strong,
               req_options: [plug: {Origin503, test_pid: self()}]}
          ]
        )

      corrupt_config =
        opts(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               byte_identity: :strong,
               req_options: [plug: {CorruptOrigin, test_pid: self()}]}
          ]
        )

      source_error = get("/images/beach.jpg?twic=v1/output=jpeg", source_config)
      decode_error = get("/images/beach.jpg?twic=v1/output=jpeg", corrupt_config)

      input_error =
        get(
          "/images/beach.jpg?twic=v1/output=jpeg",
          opts(max_input_pixels: 1, sources: counting_sources())
        )

      assert source_error.status == 502
      assert decode_error.status == 415
      assert input_error.status == 413
    end

    test "an automatic-output generation failure preserves Vary: Accept" do
      config =
        opts(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               byte_identity: :strong,
               req_options: [plug: {CorruptOrigin, test_pid: self()}]}
          ]
        )

      conn =
        get(
          "/images/beach.jpg?twic=v1/resize=64",
          config,
          [{"accept", "image/webp,image/*"}]
        )

      assert conn.status == 415
      assert conn.resp_body == "source response is not a supported image"
      assert get_resp_header(conn, "vary") == ["Accept"]
      assert_received :origin_fetch
    end

    test "result dimensions clamp to the tighter host cap" do
      conn =
        get(
          "/images/beach.jpg?twic=v1/resize=500/output=jpeg",
          opts(max_result_width: 31, max_result_height: 29, max_result_pixels: 899)
        )

      assert conn.status == 200
      {width, height} = decoded_dims(conn.resp_body)
      assert width <= 31
      assert height <= 29
      assert width * height <= 899
    end

    test "a first-pull encoder failure is a pre-header 500 and never opens a cache sink" do
      config =
        opts(
          cache: {TrackingCache, []},
          image_module: RaisingBeforeFirstChunkImage
        )

      conn = get("/images/beach.jpg?twic=v1/resize=64/output=jpeg", config)

      assert conn.status == 500
      assert conn.state == :sent
      assert conn.resp_body == "error encoding image"
      refute_received {:cache_open, _key, _metadata}
      refute_received :cache_commit
    end

    test "a later stream failure keeps the committed 200 and aborts the cache sink" do
      config =
        opts(
          cache: {TrackingCache, []},
          image_module: RaisingAfterFirstChunkImage
        )

      log =
        capture_log(fn ->
          conn = get("/images/beach.jpg?twic=v1/resize=64/output=jpeg", config)
          assert conn.status == 200
          assert conn.state == :chunked
          assert conn.resp_body == "first chunk"
        end)

      assert log =~ "boom after first chunk"
      assert_received {:cache_open, _key, _metadata}
      assert_received :cache_abort
      refute_received :cache_commit
    end
  end

  describe "telemetry" do
    test "request, parse, transform, encode, and send use the shared span names" do
      prefix = [:image_pipe_task_10, :lifecycle]

      stages = [
        [:request],
        [:parse],
        [:transform, :execute],
        [:encode],
        [:send]
      ]

      handler_id = attach_events(prefix, stages)
      on_exit(fn -> :telemetry.detach(handler_id) end)

      conn =
        get(
          "/images/beach.jpg?twic=v1/resize=64/output=jpeg",
          opts(telemetry_prefix: prefix)
        )

      assert conn.status == 200

      for stage <- stages do
        start_event = prefix ++ stage ++ [:start]
        stop_event = prefix ++ stage ++ [:stop]

        assert_receive {:telemetry_event, ^start_event, measurements, metadata}
        assert is_integer(measurements.system_time)
        assert is_integer(measurements.monotonic_time)
        assert is_map(metadata)

        assert_receive {:telemetry_event, ^stop_event, stop_measurements, stop_metadata}

        assert is_integer(stop_measurements.duration)
        assert stop_metadata.result == :ok
      end
    end

    test "a first-pull encoder failure closes the encode span as a processing error" do
      prefix = [:image_pipe_task_10, :encode_failure]
      handler_id = attach_events(prefix, [[:encode]])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      conn =
        get(
          "/images/beach.jpg?twic=v1/resize=64/output=jpeg",
          opts(
            telemetry_prefix: prefix,
            image_module: RaisingBeforeFirstChunkImage
          )
        )

      assert conn.status == 500

      stop_event = prefix ++ [:encode, :stop]

      assert_receive {:telemetry_event, ^stop_event, measurements,
                      %{result: :processing_error, error: :encode}}

      assert is_integer(measurements.duration)
    end

    test "the existing default Logger and OTel Capture consume the shared stages" do
      prefix = [:image_pipe_task_10, :surfaces]
      TestExporter.set_receiver(self())

      :ok = TestExporter.attach(self(), prefix: prefix)
      :ok = Telemetry.attach_default_logger(prefix: prefix)

      on_exit(fn ->
        Telemetry.detach_default_logger()
        Telemetry.detach_tracer()
        TestExporter.clear_receiver()
      end)

      log =
        capture_log(fn ->
          conn =
            get(
              "/images/beach.jpg?twic=v1/resize=64/output=jpeg",
              opts(telemetry_prefix: prefix)
            )

          assert conn.status == 200
        end)

      assert log =~ "image_pipe request: ok"
      assert log =~ "image_pipe parse: ok"
      assert log =~ "image_pipe transform execute: ok"
      assert log =~ "image_pipe encode: ok"
      assert log =~ "image_pipe send: ok"

      for name <- [
            "image_pipe.parse",
            "image_pipe.transform.execute",
            "image_pipe.encode",
            "image_pipe.send",
            "image_pipe.request"
          ] do
        assert_receive {:span, %Span{name: ^name}}
      end
    end
  end
end
