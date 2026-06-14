defmodule ImagePipe.PlugTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  doctest ImagePipe.Plug

  @slow_origin_ci_load_timeout 10_000

  alias ImagePipe.Parser.Imgproxy.Presets
  alias ImagePipe.Parser.Imgproxy.Signature
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.PlugTest.ConsumeLargeSourceImage
  alias ImagePipe.PlugTest.ConsumeSourceThenDecodeErrorImage
  alias ImagePipe.PlugTest.LargeBodyOrigin
  alias ImagePipe.SourceTest.RootHTTPAdapter

  defmodule CacheProbe do
    @behaviour ImagePipe.Cache

    alias ImagePipe.Cache.Entry
    alias ImagePipe.Cache.Key

    def get(%Key{} = key, opts) do
      opts
      |> Keyword.get(:message_target, self())
      |> send({:cache_get, key})

      case Keyword.fetch(opts, :get_result_fun) do
        {:ok, get_result_fun} -> get_result_fun.(key)
        :error -> Keyword.get(opts, :get_result, :miss)
      end
    end

    def open_sink(%Key{} = key, metadata, opts) do
      {:ok, %{key: key, metadata: metadata, chunks: [], opts: opts}}
    end

    def write_chunk(state, chunk, _opts) do
      {:ok, %{state | chunks: [chunk | state.chunks]}}
    end

    def commit_sink(state, _opts) do
      entry = %Entry{
        body: state.chunks |> Enum.reverse() |> IO.iodata_to_binary(),
        content_type: state.metadata.content_type,
        headers: state.metadata.headers,
        created_at: state.metadata.created_at
      }

      opts = state.opts

      opts
      |> Keyword.get(:message_target, self())
      |> send({:cache_put, state.key, entry})

      Keyword.get(opts, :put_result, :ok)
    end

    def abort_sink(_state, _opts), do: :ok
  end

  defmodule OriginShouldNotBeCalled do
    def call(conn, _opts) do
      send(self(), :origin_was_called)
      Plug.Conn.send_resp(conn, 200, "unexpected")
    end
  end

  defmodule OriginImage do
    def call(conn, _) do
      body = File.read!("priv/static/images/beach.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule CountingOriginImage do
    def init(opts), do: opts

    def call(conn, opts) do
      test_pid = Keyword.get(opts, :test_pid) || conn.owner || self()
      Kernel.send(test_pid, :origin_was_called)

      body = File.read!("priv/static/images/beach.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule StreamingOnlyImage do
    def stream!(_image, suffix: ".jpg") do
      send(message_target(), :stream_encoder_called)
      ["streamed jpeg"]
    end

    def write!(_image, :memory, suffix: ".jpg") do
      send(message_target(), :memory_encoder_called)
      raise "cache-enabled memory encoder should not be called"
    end

    defp message_target do
      case Process.get(:"$callers") do
        [pid | _rest] when is_pid(pid) -> pid
        _callers -> self()
      end
    end
  end

  defmodule BoundedCacheStreamingImage do
    def stream!(_image, suffix: ".jpg") do
      send(message_target(), :stream_encoder_called)
      ["streamed jpeg over cache limit"]
    end

    def write(_image, :memory, suffix: ".jpg") do
      send(message_target(), :memory_encoder_called)
      raise "cache skip path should not encode the full body in memory"
    end

    defp message_target do
      case Process.get(:"$callers") do
        [pid | _rest] when is_pid(pid) -> pid
        _callers -> self()
      end
    end
  end

  defmodule MultiChunkStreamingImage do
    def stream!(_image, suffix: ".jpg") do
      send(message_target(), :stream_encoder_called)
      ["first chunk", "second chunk"]
    end

    defp message_target do
      case Process.get(:"$callers") do
        [pid | _rest] when is_pid(pid) -> pid
        _callers -> self()
      end
    end
  end

  defmodule EmptyStreamingImage do
    def stream!(_image, suffix: ".jpg") do
      send(message_target(), :stream_encoder_called)
      []
    end

    defp message_target do
      case Process.get(:"$callers") do
        [pid | _rest] when is_pid(pid) -> pid
        _callers -> self()
      end
    end
  end

  defmodule FailingStreamBeforeHeaderImage do
    def stream!(_image, suffix: ".jpg") do
      send(message_target(), :stream_encoder_called)
      raise "forced stream encode failure"
    end

    defp message_target do
      case Process.get(:"$callers") do
        [pid | _rest] when is_pid(pid) -> pid
        _callers -> self()
      end
    end
  end

  defmodule ClosedChunkAdapter do
    def send_chunked(%{owner: owner} = payload, _status, _headers) do
      send(owner, :closed_adapter_send_chunked)
      {:ok, "", payload}
    end

    def chunk(_payload, _body), do: {:error, :closed}
  end

  defmodule InvalidOriginImage do
    def call(conn, _) do
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, "not actually a png")
    end
  end

  defmodule CorruptTailOriginImage do
    def call(conn, _) do
      body = File.read!("priv/static/images/beach.jpg")
      prefix_size = max(byte_size(body) - 64, 1)
      body = binary_part(body, 0, prefix_size) <> :binary.copy(<<0>>, 64)

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  # Serves only the JPEG header (5000 bytes) — enough for the decoder to open a
  # sequential image but not enough to satisfy copy_memory when a materializing op
  # (e.g. vertical flip) tries to pull all pixels from the stream.
  defmodule TruncatedHeaderOnlyOriginImage do
    def call(conn, _) do
      body = File.read!("priv/static/images/beach.jpg")
      truncated = binary_part(body, 0, 5000)

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, truncated)
    end
  end

  defmodule ChunkedOriginImage do
    def call(conn, _) do
      body = File.read!("priv/static/images/beach.jpg")

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("image/jpeg")
        |> Plug.Conn.send_chunked(200)

      midpoint = div(byte_size(body), 2)
      {:ok, conn} = Plug.Conn.chunk(conn, binary_part(body, 0, midpoint))
      {:ok, conn} = Plug.Conn.chunk(conn, binary_part(body, midpoint, byte_size(body) - midpoint))
      conn
    end
  end

  defmodule RecordingImageOpen do
    def open(stream, opts) do
      send(message_target(), {:image_open_options, opts})
      Image.open(stream, opts)
    end

    defp message_target do
      case Process.get(:"$callers") do
        [pid | _rest] when is_pid(pid) -> pid
        _callers -> self()
      end
    end
  end

  defmodule FailingMaterializer do
    def materialize(_state, _opts), do: {:error, :forced_materialization_failure}
  end

  def sample_plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: %SourcePath{segments: ["images", "beach.jpg"]},
          pipelines: [%Pipeline{operations: []}],
          output: %Output{mode: :automatic}
        ],
        overrides
      )
    )
  end

  defp source_opts(plug, root_url, adapter_opts \\ []) do
    [
      sources: [
        path:
          {RootHTTPAdapter,
           Keyword.merge([root_url: root_url, req_options: [plug: plug]], adapter_opts)}
      ]
    ]
  end

  defp default_source_opts(root_url) do
    source_opts(OriginImage, root_url)
  end

  defp init_image_pipe(opts) do
    opts
    |> translate_origin_test_opts()
    |> ImagePipe.Plug.init()
  end

  defp call_image_pipe(conn, opts) do
    ImagePipe.Plug.call(conn, init_or_pass_opts(opts))
  end

  defp init_or_pass_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :sources) do
      sources when is_map(sources) -> opts
      _sources -> init_image_pipe(opts)
    end
  end

  defp translate_origin_test_opts(opts) do
    {root_url, opts} = Keyword.pop(opts, :root_url)
    {origin_req_options, opts} = Keyword.pop(opts, :origin_req_options, [])
    {origin_receive_timeout, opts} = Keyword.pop(opts, :origin_receive_timeout)

    opts =
      if origin_receive_timeout,
        do: Keyword.put(opts, :receive_timeout, origin_receive_timeout),
        else: opts

    case root_url do
      nil ->
        opts

      root_url ->
        Keyword.put_new(opts, :sources,
          path: {RootHTTPAdapter, root_url: root_url, req_options: origin_req_options}
        )
    end
  end

  def sample_explicit_plan(format, operations \\ []) do
    sample_plan(
      pipelines: [%Pipeline{operations: operations}],
      output: %Output{mode: {:explicit, format}}
    )
  end

  defmodule UnsupportedSourceKindParser do
    @behaviour ImagePipe.Parser

    @impl ImagePipe.Parser
    def parse(_conn, _opts) do
      {:ok, ImagePipe.PlugTest.sample_plan(source: :signed)}
    end

    @impl ImagePipe.Parser
    def handle_error(conn, {:error, reason}) do
      Plug.Conn.send_resp(conn, 400, inspect(reason))
    end
  end

  defmodule UnprojectableOperationParser do
    @behaviour ImagePipe.Parser

    @impl ImagePipe.Parser
    def parse(_conn, _opts) do
      {:ok,
       ImagePipe.PlugTest.sample_explicit_plan(:jpeg, [
         struct(ImagePipe.PlugTest.UnprojectableOperationTransform)
       ])}
    end

    @impl ImagePipe.Parser
    def handle_error(conn, _error), do: conn
  end

  defmodule UnprojectableOperationTransform do
    defstruct []

    def name(%__MODULE__{}), do: :unprojectable

    def metadata(%__MODULE__{}), do: %{access: :random}

    def execute(%__MODULE__{}, %ImagePipe.Transform.State{} = state), do: {:ok, state}
  end

  defmodule EmptyPipelineParser do
    @behaviour ImagePipe.Parser

    @impl ImagePipe.Parser
    def parse(_conn, _opts) do
      {:ok,
       ImagePipe.PlugTest.sample_plan(
         pipelines: [],
         output: %ImagePipe.Plan.Output{mode: {:explicit, :jpeg}}
       )}
    end

    @impl ImagePipe.Parser
    def handle_error(conn, _error), do: conn
  end

  defmodule UnsupportedSemanticPipelineParser do
    @behaviour ImagePipe.Parser

    @impl ImagePipe.Parser
    def parse(_conn, _opts) do
      {:ok,
       ImagePipe.PlugTest.sample_explicit_plan(:jpeg, [
         resize_fit_operation(),
         :not_a_plan_operation
       ])}
    end

    @impl ImagePipe.Parser
    def handle_error(conn, _error), do: conn

    defp resize_fit_operation do
      {:ok, operation} = Operation.resize(:fit, {:px, 100}, {:px, 100}, enlargement: :deny)
      operation
    end
  end

  defmodule RaisingAfterFirstChunkImage do
    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {["first chunk"], :raise}
          :raise -> raise "boom after first chunk"
        end,
        fn _ -> :ok end
      )
    end
  end

  defp start_cache_probe do
    test_pid = self()

    start_supervised!(%{
      id: {:cache_probe, make_ref()},
      start: {Task, :start_link, [fn -> cache_probe_loop(test_pid, []) end]}
    })
  end

  defp cache_probe_loop(test_pid, messages) do
    receive do
      {:cache_get, _key} = message ->
        cache_probe_loop(test_pid, [message | messages])

      {:cache_put, _key, _entry} = message ->
        cache_probe_loop(test_pid, [message | messages])

      :origin_was_called = message ->
        cache_probe_loop(test_pid, [message | messages])

      {:flush, ref} ->
        messages
        |> Enum.reverse()
        |> Enum.each(&send(test_pid, &1))

        send(test_pid, {:cache_probe_flushed, ref})
        cache_probe_loop(test_pid, [])
    end
  end

  defp flush_cache_probe(cache_probe) do
    ref = make_ref()
    send(cache_probe, {:flush, ref})
    assert_receive {:cache_probe_flushed, ^ref}
  end

  defp assert_cache_get_output(expected_output) do
    assert_cache_get_output(expected_output, 20, [])
  end

  defp assert_cache_get_output(expected_output, 0, seen_outputs) do
    flunk(
      "expected cache lookup for #{inspect(expected_output)}, saw #{inspect(Enum.reverse(seen_outputs))}"
    )
  end

  defp assert_cache_get_output(expected_output, remaining, seen_outputs) do
    receive do
      {:cache_get, %ImagePipe.Cache.Key{} = key} ->
        output = key.data[:output]

        if output == expected_output do
          assert true
        else
          assert_cache_get_output(expected_output, remaining - 1, [output | seen_outputs])
        end
    after
      0 ->
        flunk(
          "expected cache lookup for #{inspect(expected_output)}, saw #{inspect(Enum.reverse(seen_outputs))}"
        )
    end
  end

  defp start_slow_partial_origin(test_pid, ref, content_type \\ "image/jpeg") do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)

        case :gen_tcp.recv(socket, 0) do
          {:ok, _request} ->
            send_slow_partial_origin_response(test_pid, ref, content_type, socket, listen_socket)

          {:error, reason} ->
            send(test_pid, {ref, :request_closed_before_first_chunk, self(), reason})
            :gen_tcp.close(socket)
            :gen_tcp.close(listen_socket)
        end
      end)

    {"http://127.0.0.1:#{port}", server}
  end

  defp send_slow_partial_origin_response(test_pid, ref, content_type, socket, listen_socket) do
    body = File.read!("priv/static/images/beach.jpg")
    first_chunk = binary_part(body, 0, 128)

    response = [
      "HTTP/1.1 200 OK\r\n",
      "content-type: #{content_type}\r\n",
      "transfer-encoding: chunked\r\n",
      "\r\n",
      chunked_body_chunk(first_chunk)
    ]

    case :gen_tcp.send(socket, response) do
      :ok ->
        send(test_pid, {ref, :first_chunk_sent, self()})
        await_slow_partial_origin_close(ref, socket, listen_socket)

      {:error, reason} ->
        send(test_pid, {ref, :first_chunk_send_failed, self(), reason})
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
    end
  end

  defp call_after_slow_origin_first_chunk(conn, opts, ref, server) do
    task = Task.async(fn -> call_image_pipe(conn, opts) end)

    # This real-socket handshake has two sequential waits: first for the fake
    # origin's first chunk (the client must be scheduled to connect + send the
    # request), then for the request's own `origin_receive_timeout` (~1s) to
    # surface. Neither leg is the behavior under test — both are dominated by
    # BEAM scheduling latency, which has a heavy tail on a loaded/throttled CI
    # runner even though the work itself is trivial. So both share one generous
    # CI-load budget; capping the first leg lower than the second is what made
    # this test flaky.
    assert_receive {^ref, :first_chunk_sent, ^server}, @slow_origin_ci_load_timeout
    Task.await(task, @slow_origin_ci_load_timeout)
  end

  defp chunked_body_chunk(body) do
    [Integer.to_string(byte_size(body), 16), "\r\n", body, "\r\n"]
  end

  defp await_slow_partial_origin_close(ref, socket, listen_socket) do
    :inet.setopts(socket, active: :once)

    receive do
      {^ref, :close} ->
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)

      {:tcp_closed, ^socket} ->
        :gen_tcp.close(listen_socket)

      {:tcp_error, ^socket, _reason} ->
        :gen_tcp.close(listen_socket)
    after
      5_000 ->
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
    end
  end

  test "init normalizes parser option" do
    opts =
      init_image_pipe(
        [parser: ImagePipe.Parser.Imgproxy] ++ default_source_opts("https://example.test")
      )

    assert Keyword.fetch!(opts, :parser) == ImagePipe.Parser.Imgproxy
  end

  test "init requires parser option even if unrelated param_parser option is present" do
    assert_raise ArgumentError, ~r/required :parser option not found/, fn ->
      init_image_pipe(
        [param_parser: ImagePipe.Parser.Imgproxy] ++ default_source_opts("https://example.test")
      )
    end
  end

  test "init rejects missing parser option through required option validation" do
    assert_raise ArgumentError, ~r/required :parser option not found/, fn ->
      init_image_pipe(default_source_opts("https://example.test"))
    end
  end

  test "init validates parser option shape without loading the parser module" do
    opts =
      init_image_pipe(
        [parser: ImagePipe.PlugTest.MissingParser] ++
          default_source_opts("https://example.test")
      )

    assert Keyword.fetch!(opts, :parser) == ImagePipe.PlugTest.MissingParser
  end

  test "init normalizes imgproxy signature options through the imgproxy parser" do
    opts =
      init_image_pipe(
        [
          parser: ImagePipe.Parser.Imgproxy,
          imgproxy: [
            signature: [
              keys: ["746573742d6b6579"],
              salts: ["746573742d73616c74"],
              signature_size: 8,
              trusted_signatures: ["local-dev!"]
            ]
          ]
        ] ++ default_source_opts("https://example.test")
      )

    imgproxy = Keyword.fetch!(opts, :imgproxy)

    assert %Signature{
             mode: :enabled,
             key_salt_pairs: [{"test-key", "test-salt"}],
             signature_size: 8,
             trusted_signatures: trusted_signatures
           } = Keyword.fetch!(imgproxy, :signature)

    assert MapSet.equal?(trusted_signatures, MapSet.new(["local-dev!"]))
  end

  test "init normalizes imgproxy presets through the imgproxy parser" do
    opts =
      init_image_pipe(
        [
          parser: ImagePipe.Parser.Imgproxy,
          imgproxy: [
            presets: %{
              "default" => "rt:fill/el:1",
              "thumb" => "rs:fit:120:120",
              "nested" => "pr:thumb/q:82",
              "responsive" => "w:900/-/w:450",
              "future" => "watermark:0.5"
            }
          ]
        ] ++ default_source_opts("https://example.test")
      )

    imgproxy = Keyword.fetch!(opts, :imgproxy)

    assert %Signature{mode: :disabled} = Keyword.fetch!(imgproxy, :signature)
    assert %Presets{} = presets = Keyword.fetch!(imgproxy, :presets)

    assert {:ok, [["rt:fill", "el:1"]]} =
             Presets.fetch(presets, "default")

    assert {:ok, [["rs:fit:120:120"]]} =
             Presets.fetch(presets, "thumb")

    assert {:ok, [["w:900"], ["w:450"]]} =
             Presets.fetch(presets, "responsive")

    assert {:ok, [["watermark:0.5"]]} =
             Presets.fetch(presets, "future")
  end

  test "init rejects malformed imgproxy presets before requests" do
    invalid_configs = [
      [presets: []],
      [presets: %{"" => "w:100"}],
      [presets: %{:thumb => "w:100"}],
      [presets: %{"thumb" => ""}],
      [presets: %{"thumb" => 100}],
      [presets: %{"thumb" => "pr"}],
      [presets: %{"thumb" => "pr:"}],
      [presets: %{"thumb" => "pr: "}],
      [presets: %{"thumb" => "pr: other"}],
      [presets: %{"thumb" => "pr:other "}],
      [presets: %{"thumb" => "w:100//h:100"}],
      [presets: %Presets{definitions: %{"thumb" => [["w:100"]]}}]
    ]

    for imgproxy <- invalid_configs do
      assert_raise ArgumentError, ~r/invalid imgproxy config/, fn ->
        init_image_pipe(
          [parser: ImagePipe.Parser.Imgproxy, imgproxy: imgproxy] ++
            default_source_opts("https://example.test")
        )
      end
    end
  end

  test "init keeps rejecting unknown top-level imgproxy options after presets are added" do
    assert_raise ArgumentError, ~r/unknown options.*:trusted_signatures/, fn ->
      init_image_pipe(
        [
          parser: ImagePipe.Parser.Imgproxy,
          imgproxy: [presets: %{}, trusted_signatures: ["local-dev!"]]
        ] ++ default_source_opts("https://example.test")
      )
    end
  end

  test "init rejects malformed imgproxy signature options before requests" do
    assert_raise ArgumentError, ~r/keys and salts must be non-empty hex-encoded strings/, fn ->
      init_image_pipe(
        [
          parser: ImagePipe.Parser.Imgproxy,
          imgproxy: [
            signature: [
              keys: ["not-hex"],
              salts: ["73616c74"]
            ]
          ]
        ] ++ default_source_opts("https://example.test")
      )
    end
  end

  test "init rejects unknown top-level imgproxy options before requests" do
    assert_raise ArgumentError, ~r/unknown options.*:trusted_signatures/, fn ->
      init_image_pipe(
        [
          parser: ImagePipe.Parser.Imgproxy,
          imgproxy: [trusted_signatures: ["local-dev!"]]
        ] ++ default_source_opts("https://example.test")
      )
    end
  end

  test "init rejects explicit nil signature config before requests" do
    assert_raise ArgumentError, ~r/invalid value for :signature option/, fn ->
      init_image_pipe(
        [parser: ImagePipe.Parser.Imgproxy, imgproxy: [signature: nil]] ++
          default_source_opts("https://example.test")
      )
    end
  end

  test "plug delegates response delivery to response sender" do
    plug_ast =
      __DIR__
      |> Path.join("../../lib/image_pipe/plug.ex")
      |> Path.expand()
      |> File.read!()
      |> Code.string_to_quoted!()

    assert remote_call?(plug_ast, [:Sender], :send_result, 3)
    assert remote_call?(plug_ast, [:Sender], :send_source_error, 2)

    refute remote_call?(plug_ast, [:Plug, :Conn], :send_resp)
    refute remote_call?(plug_ast, [:Plug, :Conn], :send_chunked)
    refute import_module?(plug_ast, [:Plug, :Conn])
    refute unqualified_call?(plug_ast, :chunk)
    refute unqualified_call?(plug_ast, :put_resp_header)
    refute unqualified_call?(plug_ast, :put_resp_content_type)
  end

  defp remote_call?(ast, module_parts, function, arity \\ :any) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, parts}, called_function]}, _, args} = node, found? ->
          arity_matches? = arity == :any or length(args) == arity

          {node,
           found? or (parts == module_parts and called_function == function and arity_matches?)}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp import_module?(ast, module_parts) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:import, _, [{:__aliases__, _, parts} | _]} = node, found? ->
          {node, found? or parts == module_parts}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp unqualified_call?(ast, function) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {called_function, _, args} = node, found?
        when is_atom(called_function) and is_list(args) ->
          {node, found? or called_function == function}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  test "no cache configured preserves the streaming response path" do
    conn = conn(:get, "/_/f:jpeg/plain/images/beach.jpg")
    test_pid = self()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        image_module: StreamingOnlyImage,
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [
          plug: fn conn -> CountingOriginImage.call(conn, test_pid: test_pid) end
        ]
      )

    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body == "streamed jpeg"
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert_received {:plug_conn, :sent}
    assert_received :stream_encoder_called
    refute_received :memory_encoder_called
  end

  test "no-cache image request still sends an image" do
    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> call_image_pipe(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {ImagePipe.Source.File, root: "priv/static", root_id: "static"}]
      )

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "image/jpeg")
    assert byte_size(conn.resp_body) > 0
  end

  test "a non-GET/HEAD method returns 405 with an Allow header before any processing" do
    test_pid = self()

    conn =
      :post
      |> conn("/_/plain/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [
          plug: fn conn ->
            send(test_pid, :origin_fetched)
            Plug.Conn.send_resp(conn, 200, "x")
          end
        ]
      )

    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["GET, HEAD"]
    # The 405 short-circuits before source resolution/fetch — the origin is never hit.
    refute_received :origin_fetched
  end

  test "streaming sends headers once and resumes for subsequent chunks" do
    conn = conn(:get, "/_/f:jpeg/plain/images/beach.jpg")
    test_pid = self()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        image_module: MultiChunkStreamingImage,
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [
          plug: fn conn -> CountingOriginImage.call(conn, test_pid: test_pid) end
        ]
      )

    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body == "first chunksecond chunk"
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert_received {:plug_conn, :sent}
    refute_received {:plug_conn, :sent}
    assert_received :stream_encoder_called
  end

  test "closed chunk delivery returns the started chunked response" do
    conn =
      :get
      |> conn("/_/f:jpeg/plain/images/beach.jpg")
      |> Map.put(:adapter, {ClosedChunkAdapter, %{owner: self()}})

    test_pid = self()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        image_module: StreamingOnlyImage,
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [
          plug: fn conn -> CountingOriginImage.call(conn, test_pid: test_pid) end
        ]
      )

    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body == ""
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert_received :closed_adapter_send_chunked
    assert_received :stream_encoder_called
  end

  test "automatic source-format output does not require encoder overrides before streaming" do
    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg")

    test_pid = self()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        image_module: StreamingOnlyImage,
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [
          plug: fn conn -> CountingOriginImage.call(conn, test_pid: test_pid) end
        ]
      )

    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body == "streamed jpeg"
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert_received :stream_encoder_called
  end

  test "does not touch cache when parser validation fails" do
    conn = conn(:get, "/_/w:-1/plain/images/beach.jpg")
    cache_probe = start_cache_probe()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 400
    refute_received {:cache_get, _key}
    refute_received :origin_was_called
  end

  test "does not touch cache when planner validation fails" do
    conn = conn(:get, "/_/f:best/plain/images/beach.jpg")
    cache_probe = start_cache_probe()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 400
    refute_received {:cache_get, _key}
    refute_received :origin_was_called
  end

  test "semantic pipeline validation fails before source identity, cache, or origin access" do
    conn = conn(:get, "/image")
    cache_probe = start_cache_probe()

    conn =
      call_image_pipe(conn,
        parser: UnsupportedSemanticPipelineParser,
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 422
    assert conn.resp_body == "invalid image transform"
    refute_received {:cache_get, _key}
    refute_received :origin_was_called
  end

  test "serves cache hits without fetching origin" do
    cache_probe = start_cache_probe()

    cached_entry = %ImagePipe.Cache.Entry{
      body: "cached image",
      content_type: "image/webp",
      headers: [{"Vary", "Accept"}, {"connection", "close"}],
      created_at: DateTime.utc_now()
    }

    conn = conn(:get, "/_/f:webp/plain/images/beach.jpg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        cache: {CacheProbe, message_target: cache_probe, get_result: {:hit, cached_entry}},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "cached image"
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert get_resp_header(conn, "vary") == ["Accept"]
    assert get_resp_header(conn, "connection") == []
    assert_received {:cache_get, key}

    assert key.data[:source_identity] == [
             kind: :path,
             adapter: :test_http_root,
             root: "http://origin.test",
             path: ["images", "beach.jpg"]
           ]

    refute_received :origin_was_called
  end

  test "cache misses process source response, write entry, and send encoded body" do
    conn = conn(:get, "/_/f:jpeg/plain/images/beach.jpg")
    test_pid = self()
    cache_probe = start_cache_probe()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [
          plug: fn conn -> CountingOriginImage.call(conn, test_pid: test_pid) end
        ]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert byte_size(conn.resp_body) > 0
    assert_received {:cache_get, key}
    assert_received {:cache_put, ^key, entry}
    assert_received {:plug_conn, :sent}
    assert entry.content_type == "image/jpeg"
    assert entry.headers == []
    assert entry.body == conn.resp_body
  end

  test "cache misses for auto output store vary header and selected content type" do
    test_pid = self()
    cache_probe = start_cache_probe()

    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [
          plug: fn conn -> CountingOriginImage.call(conn, test_pid: test_pid) end
        ]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "vary") == ["Accept"]
    assert_received {:cache_put, _key, entry}
    assert entry.content_type == "image/jpeg"
    assert entry.headers == [{"vary", "Accept"}]
  end

  test "imgproxy cachebuster changes cache key but not transform operations" do
    cached_entry = %ImagePipe.Cache.Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    cache_probe = start_cache_probe()

    first_conn =
      conn(:get, "/_/cb:a/w:100/f:jpeg/plain/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        cache: {CacheProbe, message_target: cache_probe, get_result: {:hit, cached_entry}},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert first_conn.status == 200
    assert_received {:cache_get, key_a}
    refute_received :origin_was_called

    cache_probe = start_cache_probe()

    second_conn =
      conn(:get, "/_/cb:b/w:100/f:jpeg/plain/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        cache: {CacheProbe, message_target: cache_probe, get_result: {:hit, cached_entry}},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert second_conn.status == 200
    assert_received {:cache_get, key_b}
    refute_received :origin_was_called

    assert key_a.data[:pipelines] == key_b.data[:pipelines]
    assert key_a.data[:cache] == [cachebuster: "a"]
    assert key_b.data[:cache] == [cachebuster: "b"]
    refute key_a.hash == key_b.hash
  end

  test "imgproxy automatic cache key normalizes equivalent raw Accept headers at cache boundary" do
    cached_entry = %ImagePipe.Cache.Entry{
      body: "cached avif",
      content_type: "image/avif",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    cache_probe = start_cache_probe()

    first_conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.1")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        cache: {CacheProbe, message_target: cache_probe, get_result: {:hit, cached_entry}},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert first_conn.status == 200
    assert_received {:cache_get, key_a}
    refute_received :origin_was_called

    cache_probe = start_cache_probe()

    second_conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/avif,image/webp")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        cache: {CacheProbe, message_target: cache_probe, get_result: {:hit, cached_entry}},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert second_conn.status == 200
    assert_received {:cache_get, key_b}
    refute_received :origin_was_called

    assert key_a.data[:output] == [
             mode: :automatic,
             modern_candidates: [:avif, :webp],
             auto: [avif: true, webp: true],
             quality: :default,
             format_qualities: %{},
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
             ]
           ]

    refute inspect(key_a.data) =~ "image/webp"
    refute inspect(key_a.data) =~ "image/avif"
    assert key_a.data == key_b.data
    assert key_a.hash == key_b.hash
  end

  test "imgproxy filename and disposition are excluded from cache key data at cache boundary" do
    cached_entry = %ImagePipe.Cache.Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    cache_probe = start_cache_probe()

    first_conn =
      conn(:get, "/_/w:100/f:jpeg/fn:one/att:true/plain/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        cache: {CacheProbe, message_target: cache_probe, get_result: {:hit, cached_entry}},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert first_conn.status == 200

    assert get_resp_header(first_conn, "content-disposition") == [
             ~s(attachment; filename="one.jpg")
           ]

    assert_received {:cache_get, key_a}
    refute_received :origin_was_called

    cache_probe = start_cache_probe()

    second_conn =
      conn(:get, "/_/w:100/f:jpeg/fn:two/att:false/plain/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        cache: {CacheProbe, message_target: cache_probe, get_result: {:hit, cached_entry}},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert second_conn.status == 200

    assert get_resp_header(second_conn, "content-disposition") == [
             ~s(inline; filename="two.jpg")
           ]

    assert_received {:cache_get, key_b}
    refute_received :origin_was_called

    refute Keyword.has_key?(key_a.data, :response)
    assert key_a.data == key_b.data
    assert key_a.hash == key_b.hash
  end

  test "cache-miss stream encode failures are not cached and preserve automatic Vary" do
    cache_probe = start_cache_probe()

    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        image_module: FailingStreamBeforeHeaderImage,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache: {CacheProbe, message_target: cache_probe}
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 500
    assert conn.resp_body == "error encoding image"
    assert get_resp_header(conn, "vary") == ["Accept"]
    assert_received :stream_encoder_called
    refute_received {:cache_put, _key, _entry}
  end

  test "does not fetch origin when parser validation fails" do
    conn = conn(:get, "/_/w:-1/plain/images/beach.jpg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    assert conn.status == 400
    refute_received :origin_was_called
  end

  test "does not fetch origin when planner validation fails" do
    conn = conn(:get, "/_/f:best/plain/images/beach.jpg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    assert conn.status == 400
    refute_received :origin_was_called
  end

  test "empty pipeline plan returns a controlled response before source fetch" do
    conn = conn(:get, "/_/f:jpeg/plain/images/beach.jpg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: EmptyPipelineParser,
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image transform"
    refute_received :origin_was_called
  end

  test "returns a controlled response for unsupported source plans before source fetch" do
    conn = conn(:get, "/_/signed/images/beach.jpg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: UnsupportedSourceKindParser,
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image transform"
    refute_received :origin_was_called
  end

  test "auto output negotiates content type from Accept and sets Vary" do
    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "auto output uses source format for missing empty and wildcard-only Accept" do
    cases = [
      conn(:get, "/_/plain/images/beach.jpg"),
      conn(:get, "/_/plain/images/beach.jpg") |> put_req_header("accept", ""),
      conn(:get, "/_/plain/images/beach.jpg") |> put_req_header("accept", "*/*"),
      conn(:get, "/_/plain/images/beach.jpg") |> put_req_header("accept", "*/*;q=1"),
      conn(:get, "/_/plain/images/beach.jpg")
      |> put_req_header("accept", "application/json,*/*;q=1")
    ]

    for conn <- cases do
      conn =
        call_image_pipe(conn,
          root_url: "http://origin.test",
          parser: ImagePipe.Parser.Imgproxy,
          origin_req_options: [plug: OriginImage]
        )

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn, "vary") == ["Accept"]
    end
  end

  test "automatic fallback selects accepted source format" do
    {:ok, image} = Image.new(20, 20, color: :white)
    body = Image.write!(image, :memory, suffix: ".png")

    origin = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end

    conn =
      :get
      |> conn("/_/plain/images/cat.png")
      |> put_req_header("accept", "image/png")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: origin]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "processes an imgproxy fill URL with explicit output extension" do
    conn = conn(:get, "/_/rs:fill:100:100/g:ce/plain/images/beach.jpg@jpeg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "vary") == []
  end

  test "plain source @extension selects explicit output format after options" do
    conn =
      call_image_pipe(
        conn(:get, "/_/f:webp/plain/images/beach.jpg@png"),
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "vary") == []
  end

  test "automatic output uses server preference over relative q-values" do
    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.1")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/avif"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "exact Accept exclusion overrides wildcard allowance" do
    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/avif;q=0,image/*;q=1")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "automatic AVIF cache hits do not fetch origin" do
    cache_probe = start_cache_probe()

    cached_entry = %ImagePipe.Cache.Entry{
      body: "cached avif",
      content_type: "image/avif",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/avif,image/webp")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        cache: {CacheProbe, message_target: cache_probe, get_result: {:hit, cached_entry}},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "cached avif"

    assert_cache_get_output(
      mode: :automatic,
      modern_candidates: [:avif, :webp],
      auto: [avif: true, webp: true],
      quality: :default,
      format_qualities: %{},
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
      ]
    )

    refute_received :origin_was_called
  end

  test "automatic JPEG source-format cache hits do not fetch origin" do
    cache_probe = start_cache_probe()

    cached_entry = %ImagePipe.Cache.Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg")

    get_result_fun = fn key ->
      case key.data[:output] do
        [
          mode: :automatic,
          modern_candidates: [],
          auto: [avif: true, webp: true],
          quality: :default,
          format_qualities: %{},
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
          ]
        ] ->
          {:hit, cached_entry}

        _other ->
          :miss
      end
    end

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        cache: {CacheProbe, message_target: cache_probe, get_result_fun: get_result_fun},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "cached jpeg"

    assert_cache_get_output(
      mode: :automatic,
      modern_candidates: [],
      auto: [avif: true, webp: true],
      quality: :default,
      format_qualities: %{},
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
      ]
    )

    refute_received :origin_was_called
  end

  test "deferred source-format cache hits can serve disabled modern formats without origin" do
    cache_probe = start_cache_probe()

    cached_entry = %ImagePipe.Cache.Entry{
      body: "cached source avif",
      content_type: "image/avif",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/avif")

    get_result_fun = fn key ->
      case key.data[:output] do
        [
          mode: :automatic,
          modern_candidates: [],
          auto: [avif: false, webp: false],
          quality: :default,
          format_qualities: %{},
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
          ]
        ] ->
          {:hit, cached_entry}

        _other ->
          :miss
      end
    end

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        auto_avif: false,
        auto_webp: false,
        cache: {CacheProbe, message_target: cache_probe, get_result_fun: get_result_fun},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "cached source avif"

    assert_cache_get_output(
      mode: :automatic,
      modern_candidates: [],
      auto: [avif: false, webp: false],
      quality: :default,
      format_qualities: %{},
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
      ]
    )

    refute_received :origin_was_called
  end

  test "automatic cache key is available before source fetch when modern formats are disabled" do
    cache_probe = start_cache_probe()

    cached_entry = %ImagePipe.Cache.Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/*")

    get_result_fun = fn key ->
      case key.data[:output] do
        [
          mode: :automatic,
          modern_candidates: [],
          auto: [avif: false, webp: false],
          quality: :default,
          format_qualities: %{},
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
          ]
        ] ->
          {:hit, cached_entry}

        _other ->
          :miss
      end
    end

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        auto_avif: false,
        auto_webp: false,
        cache: {CacheProbe, message_target: cache_probe, get_result_fun: get_result_fun},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "cached jpeg"

    assert_cache_get_output(
      mode: :automatic,
      modern_candidates: [],
      auto: [avif: false, webp: false],
      quality: :default,
      format_qualities: %{},
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
      ]
    )

    refute_received :origin_was_called
  end

  test "disabled automatic modern formats still set Vary for negotiated source output" do
    conn = conn(:get, "/_/plain/images/beach.jpg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        auto_avif: false,
        auto_webp: false,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "disabled automatic modern formats use source output despite baseline Accept exclusions" do
    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg;q=0")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        auto_avif: false,
        auto_webp: false,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "source-format automatic negotiation ignores baseline Accept and uses decoded source format" do
    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/png")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        auto_avif: false,
        auto_webp: false,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
  end

  test "source-format automatic negotiation cancels streaming source when decode fails" do
    ref = make_ref()
    {root_url, server} = start_slow_partial_origin(self(), ref, "image/gif")
    server_ref = Process.monitor(server)
    on_exit(fn -> send(server, {ref, :close}) end)

    conn =
      :get
      |> conn("/_/plain/images/slow.jpg")
      |> put_req_header("accept", "image/png")
      |> call_image_pipe(
        root_url: root_url,
        parser: ImagePipe.Parser.Imgproxy,
        auto_avif: false,
        auto_webp: false
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"
    assert_receive {^ref, :first_chunk_sent, ^server}
    assert_receive {:DOWN, ^server_ref, :process, ^server, _reason}, 1_000
  end

  test "does not touch cache or origin when planner rejects unsupported semantics" do
    conn = conn(:get, "/_/f:best/plain/images/beach.jpg")
    cache_probe = start_cache_probe()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 400
    refute_received {:cache_get, _key}
    refute_received :origin_was_called
  end

  test "does not touch cache or origin when imgproxy preset is unknown" do
    conn = conn(:get, "/_/pr:missing/plain/images/beach.jpg")
    cache_probe = start_cache_probe()

    opts =
      init_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        imgproxy: [presets: %{"thumb" => "w:100"}],
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    conn = call_image_pipe(conn, opts)

    flush_cache_probe(cache_probe)
    assert conn.status == 400
    assert conn.resp_body =~ "unknown_preset"
    refute_received {:cache_get, _key}
    refute_received :origin_was_called
  end

  test "does not touch cache or origin when a used imgproxy preset contains unsupported options" do
    conn = conn(:get, "/_/pr:future/plain/images/beach.jpg")
    cache_probe = start_cache_probe()

    opts =
      init_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        imgproxy: [presets: %{"future" => "watermark:0.5"}],
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    conn = call_image_pipe(conn, opts)

    flush_cache_probe(cache_probe)
    assert conn.status == 400
    assert conn.resp_body =~ "unknown_option"
    refute_received {:cache_get, _key}
    refute_received :origin_was_called
  end

  test "does not touch cache or origin when a used imgproxy preset reaches planner rejection" do
    conn = conn(:get, "/_/pr:best/plain/images/beach.jpg")
    cache_probe = start_cache_probe()

    opts =
      init_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        imgproxy: [presets: %{"best" => "f:best"}],
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    conn = call_image_pipe(conn, opts)

    flush_cache_probe(cache_probe)
    assert conn.status == 400
    assert conn.resp_body =~ "unsupported_output_format"
    refute_received {:cache_get, _key}
    refute_received :origin_was_called
  end

  test "explicit output format does not set Vary on uncached streaming responses" do
    conn =
      call_image_pipe(
        conn(:get, "/_/f:webp/plain/images/beach.jpg"),
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert get_resp_header(conn, "vary") == []
  end

  test "auto output uses source format when Accept excludes baseline formats" do
    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/*;q=0")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "safe one-pass resize opens origin with sequential access" do
    conn =
      conn(:get, "/_/rt:force/w:100/format:jpeg/plain/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        image_open_module: RecordingImageOpen,
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    # Two-step open: header open first (random), then decode open (sequential).
    assert_received {:image_open_options, header_opts}
    assert Keyword.get(header_opts, :access) == :random
    assert_received {:image_open_options, decode_opts}
    assert Keyword.get(decode_opts, :access) == :sequential
    assert Keyword.get(decode_opts, :fail_on) == :error
  end

  test "cover opens origin with sequential access" do
    conn =
      conn(:get, "/_/rs:fill:100:100/f:jpeg/plain/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        image_open_module: RecordingImageOpen,
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    # Two-step open: header open first (random), then decode open (sequential).
    assert_received {:image_open_options, header_opts}
    assert Keyword.get(header_opts, :access) == :random
    assert_received {:image_open_options, decode_opts}
    assert Keyword.get(decode_opts, :access) == :sequential
    assert Keyword.get(decode_opts, :fail_on) == :error
  end

  test "sequential materialization failure without origin error returns decode error" do
    conn =
      conn(:get, "/_/rt:force/w:100/plain/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        image_open_module: RecordingImageOpen,
        parser: ImagePipe.Parser.Imgproxy,
        image_materializer: FailingMaterializer,
        origin_req_options: [plug: OriginImage]
      )

    # Two-step open: header open first (random), then decode open (sequential).
    assert_received {:image_open_options, header_opts}
    assert Keyword.get(header_opts, :access) == :random
    assert_received {:image_open_options, decode_opts}
    assert Keyword.get(decode_opts, :access) == :sequential
    assert Keyword.get(decode_opts, :fail_on) == :error
    assert conn.status == 415
    assert conn.state == :sent
    assert conn.resp_body == "source response is not a supported image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "deferred automatic sequential materialization failure returns decode error" do
    conn =
      :get
      |> conn("/_/rt:force/w:100/plain/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        image_open_module: RecordingImageOpen,
        parser: ImagePipe.Parser.Imgproxy,
        image_materializer: FailingMaterializer,
        origin_req_options: [plug: OriginImage]
      )

    # Two-step open: header open first (random), then decode open (sequential).
    assert_received {:image_open_options, header_opts}
    assert Keyword.get(header_opts, :access) == :random
    assert_received {:image_open_options, decode_opts}
    assert Keyword.get(decode_opts, :access) == :sequential
    assert Keyword.get(decode_opts, :fail_on) == :error
    assert conn.status == 415
    assert conn.state == :sent
    assert conn.resp_body == "source response is not a supported image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "processes an imgproxy path URL with dimensions and explicit output format" do
    conn = conn(:get, "/_/w:100/h:100/f:jpeg/plain/images/beach.jpg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
  end

  test "returns text 500 when encoding fails before sending chunked headers" do
    conn = conn(:get, "/_/plain/images/beach.jpg")

    log =
      capture_log(fn ->
        conn =
          call_image_pipe(conn,
            root_url: "http://origin.test",
            parser: ImagePipe.Parser.Imgproxy,
            image_module: FailingStreamBeforeHeaderImage,
            origin_req_options: [plug: OriginImage]
          )

        assert conn.status == 500
        assert conn.resp_body == "error encoding image"
        assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
      end)

    assert log =~ "encode_error:"
    assert log =~ "forced stream encode failure"
    assert_received :stream_encoder_called
  end

  test "returns text 500 when encoder produces an empty stream" do
    conn = conn(:get, "/_/plain/images/beach.jpg")

    log =
      capture_log(fn ->
        conn =
          call_image_pipe(conn,
            root_url: "http://origin.test",
            image_module: EmptyStreamingImage,
            parser: ImagePipe.Parser.Imgproxy,
            origin_req_options: [plug: OriginImage]
          )

        assert conn.status == 500
        assert conn.state == :sent
        assert conn.resp_body == "error encoding image"
        assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
      end)

    assert log =~ "encode_error: empty_stream"
    assert_received :stream_encoder_called
  end

  test "does not send text 500 when encoding fails after chunked response starts" do
    conn = conn(:get, "/_/plain/images/beach.jpg")

    log =
      capture_log(fn ->
        conn =
          call_image_pipe(conn,
            root_url: "http://origin.test",
            image_module: RaisingAfterFirstChunkImage,
            parser: ImagePipe.Parser.Imgproxy,
            origin_req_options: [plug: OriginImage]
          )

        assert conn.status == 200
        assert conn.state == :chunked
        assert conn.resp_body == "first chunk"
        assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      end)

    assert log =~ "prepared_stream_error:"
    assert log =~ "boom after first chunk"
  end

  test "rejects decoded images above the configured pixel limit" do
    {:ok, image} = Image.new(20, 20, color: :white)
    body = Image.write!(image, :memory, suffix: ".png")

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end

    conn =
      conn(:get, "/_/w:10/plain/images/large.png")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        max_input_pixels: 399,
        origin_req_options: [plug: plug]
      )

    assert conn.status == 413
    assert conn.resp_body == "source image is too large"
  end

  test "allows static result dimensions within configured limits" do
    conn =
      conn(:get, "/_/el:1/w:64/f:jpeg/plain/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        max_result_width: 64,
        max_result_height: 8_192,
        max_result_pixels: 40_000_000,
        image_module: StreamingOnlyImage,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert conn.resp_body == "streamed jpeg"
    assert_received :stream_encoder_called
  end

  test "default source body limit applies through the request flow" do
    conn =
      conn(:get, "/_/plain/images/large-body.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        image_open_module: ConsumeSourceThenDecodeErrorImage,
        origin_req_options: [plug: LargeBodyOrigin]
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"
  end

  test "explicit source body limit overrides the default through the request flow" do
    conn =
      conn(:get, "/_/plain/images/large-body.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        max_body_bytes: 10_000_001,
        image_open_module: ConsumeSourceThenDecodeErrorImage,
        origin_req_options: [plug: LargeBodyOrigin]
      )

    assert conn.status == 415
    assert conn.resp_body == "source response is not a supported image"
  end

  test "cache hit reuses successful response across source body limits" do
    permissive =
      conn(:get, "/_/plain/images/large-body.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        max_body_bytes: 10_000_001,
        image_open_module: ConsumeLargeSourceImage,
        cache: {CacheProbe, message_target: self()},
        origin_req_options: [plug: LargeBodyOrigin]
      )

    assert permissive.status == 200
    assert_received {:cache_put, permissive_key, permissive_entry}
    assert_received {:cache_get, ^permissive_key}

    get_result_fun = fn key ->
      if key.hash == permissive_key.hash do
        {:hit, permissive_entry}
      else
        :miss
      end
    end

    cached =
      conn(:get, "/_/plain/images/large-body.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        image_open_module: ConsumeLargeSourceImage,
        cache: {CacheProbe, message_target: self(), get_result_fun: get_result_fun},
        origin_req_options: [plug: LargeBodyOrigin]
      )

    assert cached.status == 200
    assert cached.resp_body == permissive.resp_body
    assert_received {:cache_get, cached_key}
    assert cached_key.hash == permissive_key.hash
  end

  test "body limit failures surface as source errors during decode" do
    conn =
      conn(:get, "/_/plain/images/large-body.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        max_body_bytes: 5,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"
  end

  test "body limit failures after partial valid image bytes surface as source errors" do
    body = File.read!("priv/static/images/beach.jpg")

    conn =
      conn(:get, "/_/plain/images/large-body.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        max_body_bytes: byte_size(body) - 1,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"
  end

  test "source timeout while decoding partial valid image bytes surfaces as a source error" do
    ref = make_ref()
    {root_url, server} = start_slow_partial_origin(self(), ref)
    monitor_ref = Process.monitor(server)

    conn =
      call_after_slow_origin_first_chunk(
        conn(:get, "/_/plain/images/slow.jpg"),
        [
          root_url: root_url,
          parser: ImagePipe.Parser.Imgproxy,
          origin_receive_timeout: 1_000
        ],
        ref,
        server
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"

    send(server, {ref, :close})
    assert_receive {:DOWN, ^monitor_ref, :process, ^server, _reason}
  end

  test "sequential body limit after initial valid bytes surfaces as a source error" do
    body = File.read!("priv/static/images/beach.jpg")

    conn =
      conn(:get, "/_/rt:force/w:100/plain/images/large-body.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        max_body_bytes: byte_size(body) - 1,
        origin_req_options: [plug: ChunkedOriginImage]
      )

    assert conn.status == 422
    assert conn.state == :sent
    assert conn.resp_body == "invalid image source"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "sequential timeout after initial valid bytes surfaces as a source error" do
    ref = make_ref()
    {root_url, server} = start_slow_partial_origin(self(), ref)
    monitor_ref = Process.monitor(server)

    conn =
      call_after_slow_origin_first_chunk(
        conn(:get, "/_/rt:force/w:100/plain/images/slow.jpg"),
        [
          root_url: root_url,
          parser: ImagePipe.Parser.Imgproxy,
          origin_receive_timeout: 1_000
        ],
        ref,
        server
      )

    assert conn.status == 422
    assert conn.state == :sent
    assert conn.resp_body == "invalid image source"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

    send(server, {ref, :close})
    assert_receive {:DOWN, ^monitor_ref, :process, ^server, _reason}
  end

  test "sequential corrupt image tail without origin error remains a decode error" do
    conn =
      conn(:get, "/_/rt:force/w:100/plain/images/corrupt-tail.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: CorruptTailOriginImage]
      )

    assert conn.status == 415
    assert conn.state == :sent
    assert conn.resp_body == "source response is not a supported image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "per-op materialization failure on a corrupt source returns 415, not 422" do
    # A truncated source that opens as a sequential JPEG (header intact) but fails
    # when a materializing op (vertical flip) calls copy_memory mid-chain must be
    # classified as a decode error (415), not a transform error (422).
    conn =
      conn(:get, "/_/fl:0:1/plain/images/truncated.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: TruncatedHeaderOnlyOriginImage]
      )

    assert conn.status == 415
    assert conn.state == :sent
    assert conn.resp_body == "source response is not a supported image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "invalid streamed image bytes are decode errors" do
    conn =
      conn(:get, "/_/plain/images/broken.png")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: InvalidOriginImage]
      )

    assert conn.status == 415
    assert conn.resp_body == "source response is not a supported image"
  end

  test "cache read errors fail open by default and continue to origin" do
    cache_probe = start_cache_probe()

    conn =
      conn(:get, "/_/f:jpeg/plain/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache: {CacheProbe, message_target: cache_probe, get_result: {:error, :read_failed}}
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert_received :origin_was_called
    assert_received {:cache_put, _key, _entry}
  end

  test "cache write errors fail open by default and still return response" do
    cache_probe = start_cache_probe()

    conn =
      conn(:get, "/_/f:jpeg/plain/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache: {CacheProbe, message_target: cache_probe, put_result: {:error, :write_failed}}
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert byte_size(conn.resp_body) > 0
    assert_received :origin_was_called
    assert_received {:cache_put, _key, _entry}
  end

  test "automatic cache write errors fail open and preserve negotiated Vary" do
    cache_probe = start_cache_probe()

    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache: {CacheProbe, message_target: cache_probe, put_result: {:error, :write_failed}}
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert byte_size(conn.resp_body) > 0
    assert get_resp_header(conn, "vary") == ["Accept"]
    assert_received :origin_was_called
    assert_received {:cache_put, _key, _entry}
  end

  test "cache writes over max_body_bytes are skipped and still return response" do
    cache_probe = start_cache_probe()

    conn =
      conn(:get, "/_/f:jpeg/plain/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache: {CacheProbe, message_target: cache_probe, max_body_bytes: 1}
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert byte_size(conn.resp_body) > 1
    refute_received {:cache_put, _key, _entry}
  end

  test "cache writes over max_body_bytes skip full memory encoding" do
    cache_probe = start_cache_probe()

    conn =
      conn(:get, "/_/f:jpeg/plain/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        image_module: BoundedCacheStreamingImage,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache: {CacheProbe, message_target: cache_probe, max_body_bytes: 1}
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "streamed jpeg over cache limit"
    assert_received :stream_encoder_called
    refute_received :memory_encoder_called
    refute_received {:cache_put, _key, _entry}
  end

  test "unsuccessful processed responses are not cached" do
    cache_probe = start_cache_probe()

    conn =
      conn(:get, "/_/f:jpeg/plain/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: InvalidOriginImage],
        cache: {CacheProbe, message_target: cache_probe}
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 415
    assert conn.resp_body == "source response is not a supported image"
    refute_received {:cache_put, _key, _entry}
  end

  test "filesystem cache persists processed responses across requests" do
    cache_root =
      Path.join(
        System.tmp_dir!(),
        "image_pipe_integration_cache_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(cache_root)
    File.mkdir_p!(cache_root)

    try do
      cache_probe = start_cache_probe()

      opts = [
        root_url: "http://origin.test",
        parser: ImagePipe.Parser.Imgproxy,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache:
          {ImagePipe.Cache.FileSystem,
           root: cache_root,
           path_prefix: "processed",
           max_body_bytes: 10_000_000,
           key_headers: [],
           key_cookies: []}
      ]

      first_conn =
        conn(:get, "/_/f:jpeg/plain/images/beach.jpg")
        |> call_image_pipe(opts)

      flush_cache_probe(cache_probe)
      assert first_conn.status == 200
      assert_received :origin_was_called

      second_conn =
        conn(:get, "/_/f:jpeg/plain/images/beach.jpg")
        |> call_image_pipe(opts)

      flush_cache_probe(cache_probe)
      assert second_conn.status == 200
      assert second_conn.resp_body == first_conn.resp_body
      refute_received :origin_was_called
    after
      File.rm_rf!(cache_root)
    end
  end
end
