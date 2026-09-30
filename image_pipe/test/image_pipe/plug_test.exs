defmodule ImagePipe.PlugTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  doctest ImagePipe.Plug

  @slow_origin_ci_load_timeout 10_000

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
    def stream!(_image, [{:suffix, ".jpg"} | _]) do
      send(message_target(), :stream_encoder_called)
      ["streamed jpeg"]
    end

    def write!(_image, :memory, [{:suffix, ".jpg"} | _]) do
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
    def stream!(_image, [{:suffix, ".jpg"} | _]) do
      send(message_target(), :stream_encoder_called)
      ["streamed jpeg over cache limit"]
    end

    def write(_image, :memory, [{:suffix, ".jpg"} | _]) do
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
    def stream!(_image, [{:suffix, ".jpg"} | _]) do
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
    def stream!(_image, [{:suffix, ".jpg"} | _]) do
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
    def stream!(_image, [{:suffix, ".jpg"} | _]) do
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

  # Keys the API mount's `validate_config!/1` does not accept, spliced onto the
  # validated config AFTER `ImagePipe.Plug.init/1`:
  #
  #   * `image_module`/`image_open_module`/`image_materializer` are test-injection
  #     seams, deliberately absent from every mount option surface;
  #   * `receive_timeout` is a per-request source runtime option that adapters
  #     honor (`ImagePipe.Source.runtime_opts/1`) but no mount surface exposes.
  @post_init_config_keys [
    :image_module,
    :image_open_module,
    :image_materializer,
    :receive_timeout
  ]

  defp init_image_pipe(opts) do
    {post_init, mount_opts} =
      opts
      |> translate_origin_test_opts()
      |> Keyword.split(@post_init_config_keys)

    Keyword.merge(ImagePipe.Plug.init(mount_opts), post_init)
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

  defmodule RaisingAfterFirstChunkImage do
    def stream!(_image, [{:suffix, ".jpg"} | _]) do
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

  # An encode failure raised before the first chunk renders through the API
  # error renderer, so its cause is observable on the `[:encode]` span's stop
  # metadata rather than in the log. `:telemetry` handlers are global, so each
  # attachment gets its own private prefix and is detached with the test.
  defp attach_encode_stop_handler do
    prefix = [:"plug_test_encode_#{System.unique_integer([:positive])}"]
    handler_id = "plug-test-encode-#{inspect(prefix)}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      prefix ++ [:encode, :stop],
      fn _event, _measurements, metadata, pid -> send(pid, {:encode_stop, metadata}) end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    prefix
  end

  # The output facet of a looked-up key: which format the pre-fetch identity
  # named (`:selection`) and the canonical API output policy it was built
  # from (`:output_policy`). Both live under the key's `:representation` facet.
  defp representation_output(%ImagePipe.Cache.Key{} = key) do
    key.data[:representation]
    |> Keyword.take([:selection, :output_policy])
    |> Map.new()
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
        output = representation_output(key)

        if output == Map.new(expected_output) do
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

  # The API automatic-output policy facet every automatic cache-key assertion
  # in this file shares. `selection` (the negotiated head, or
  # `:source_negotiated` when the choice is deferred to the decoded source
  # format) is asserted alongside it.
  defp automatic_output_policy_data do
    [
      quality: :default,
      default_quality: {:quality, 80},
      format_qualities: %{webp: {:quality, 79}, avif: {:quality, 63}},
      quality_search: :none,
      quality_search_max_iterations: nil,
      quality_search_offsets: %{
        default: 2.4,
        overrides: %{{:avif, :graphic} => 6.0}
      },
      max_bytes: nil,
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip,
      hdr: :tone_map,
      flatten_background: [
        space: :srgb,
        red: 255,
        green: 255,
        blue: 255,
        alpha: [unit: :ratio, numerator: 1, denominator: 1]
      ],
      encoder_options: %{}
    ]
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

  # A stalled partial origin (one chunk of a chunked response, then the socket is
  # held open) surfaces as a source error, but WHICH source error is timing-
  # dependent under load: the per-message receive timeout (504 "source timeout")
  # or the incomplete-chunked-body path (422 "incomplete source response") can win
  # the race. Both are correct source-error classifications of the same stall; the
  # contract under test is "surfaces as a source error" (never a 500 crash or 200).
  # Tightening this back to a single deterministic status is tracked in #429
  # (classify transport errors by reason in ReqStream).
  defp assert_stalled_source_error(conn) do
    assert conn.status in [422, 504]
    assert conn.resp_body in ["incomplete source response", "source timeout"]
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

  test "no cache configured preserves the streaming response path" do
    conn = conn(:get, "/format=jpeg/src/images/beach.jpg")
    test_pid = self()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        image_module: StreamingOnlyImage,
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
      |> conn("/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
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
      |> conn("/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
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
    conn = conn(:get, "/format=jpeg/src/images/beach.jpg")
    test_pid = self()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        image_module: MultiChunkStreamingImage,
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
      |> conn("/format=jpeg/src/images/beach.jpg")
      |> Map.put(:adapter, {ClosedChunkAdapter, %{owner: self()}})

    test_pid = self()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        image_module: StreamingOnlyImage,
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
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg")

    test_pid = self()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        image_module: StreamingOnlyImage,
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

  test "does not touch cache when parse validation fails" do
    conn = conn(:get, "/w=bad/format=jpeg/src/images/beach.jpg")
    cache_probe = start_cache_probe()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 400
    refute_received {:cache_get, _key}
    refute_received :origin_was_called
  end

  test "does not touch cache when output format validation fails" do
    conn = conn(:get, "/format=invalid/src/images/beach.jpg")
    cache_probe = start_cache_probe()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 400
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

    conn = conn(:get, "/src/images/beach.jpg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
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
    conn = conn(:get, "/format=jpeg/src/images/beach.jpg")
    test_pid = self()
    cache_probe = start_cache_probe()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
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
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
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

  test "automatic cache key normalizes equivalent raw Accept headers at cache boundary" do
    cached_entry = %ImagePipe.Cache.Entry{
      body: "cached avif",
      content_type: "image/avif",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    cache_probe = start_cache_probe()

    first_conn =
      :get
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.1")
      |> call_image_pipe(
        root_url: "http://origin.test",
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
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/avif,image/webp")
      |> call_image_pipe(
        root_url: "http://origin.test",
        cache: {CacheProbe, message_target: cache_probe, get_result: {:hit, cached_entry}},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert second_conn.status == 200
    assert_received {:cache_get, key_b}
    refute_received :origin_was_called

    assert representation_output(key_a) == %{
             selection: {:image, :avif},
             output_policy: automatic_output_policy_data()
           }

    refute inspect(key_a.data) =~ "image/webp"
    refute inspect(key_a.data) =~ "image/avif"
    assert key_a.data == key_b.data
    assert key_a.hash == key_b.hash
  end

  test "cache-miss stream encode failures are not cached and preserve automatic Vary" do
    cache_probe = start_cache_probe()

    conn =
      :get
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg")
      |> call_image_pipe(
        root_url: "http://origin.test",
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

  test "does not fetch origin when parse validation fails" do
    conn = conn(:get, "/w=bad/format=jpeg/src/images/beach.jpg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    assert conn.status == 400
    refute_received :origin_was_called
  end

  test "does not fetch origin when output format validation fails" do
    conn = conn(:get, "/format=invalid/src/images/beach.jpg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    assert conn.status == 400
    refute_received :origin_was_called
  end

  test "auto output negotiates content type from Accept and sets Vary" do
    conn =
      :get
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "auto output uses source format for missing empty and wildcard-only Accept" do
    cases = [
      conn(:get, "/src/images/beach.jpg"),
      conn(:get, "/src/images/beach.jpg") |> put_req_header("accept", ""),
      conn(:get, "/src/images/beach.jpg") |> put_req_header("accept", "*/*"),
      conn(:get, "/src/images/beach.jpg") |> put_req_header("accept", "*/*;q=1"),
      conn(:get, "/src/images/beach.jpg")
      |> put_req_header("accept", "application/json,*/*;q=1")
    ]

    for conn <- cases do
      conn =
        call_image_pipe(conn,
          root_url: "http://origin.test",
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
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/png")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        origin_req_options: [plug: origin]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "processes a region request with an explicit output format" do
    conn = conn(:get, "/region=0,0,100,100/format=jpeg/src/images/beach.jpg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "vary") == []
  end

  test "explicit output format selects the output content type" do
    conn =
      call_image_pipe(
        conn(:get, "/format=png/src/images/beach.jpg"),
        root_url: "http://origin.test",
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "vary") == []
  end

  test "automatic output uses server preference over relative q-values" do
    conn =
      :get
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.1")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/avif"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "image/* wildcard does not rescue a format excluded by an exact q=0" do
    conn =
      :get
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/avif;q=0,image/*;q=1")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    # avif is excluded by its exact q=0, and image/* is not a modern-format signal,
    # so negotiation falls back to the source format.
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
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
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/avif,image/webp")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        cache: {CacheProbe, message_target: cache_probe, get_result: {:hit, cached_entry}},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "cached avif"

    assert_cache_get_output(
      selection: {:image, :avif},
      output_policy: automatic_output_policy_data()
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
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg")

    expected_output = %{
      selection: {:image, :source_negotiated},
      output_policy: automatic_output_policy_data()
    }

    get_result_fun = fn key ->
      if representation_output(key) == expected_output, do: {:hit, cached_entry}, else: :miss
    end

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        cache: {CacheProbe, message_target: cache_probe, get_result_fun: get_result_fun},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "cached jpeg"

    assert_cache_get_output(
      selection: {:image, :source_negotiated},
      output_policy: automatic_output_policy_data()
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
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/avif")

    expected_output = %{
      selection: {:image, :source_negotiated},
      output_policy: automatic_output_policy_data()
    }

    get_result_fun = fn key ->
      if representation_output(key) == expected_output, do: {:hit, cached_entry}, else: :miss
    end

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        auto_avif: false,
        auto_webp: false,
        cache: {CacheProbe, message_target: cache_probe, get_result_fun: get_result_fun},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "cached source avif"

    assert_cache_get_output(
      selection: {:image, :source_negotiated},
      output_policy: automatic_output_policy_data()
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
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/*")

    expected_output = %{
      selection: {:image, :source_negotiated},
      output_policy: automatic_output_policy_data()
    }

    get_result_fun = fn key ->
      if representation_output(key) == expected_output, do: {:hit, cached_entry}, else: :miss
    end

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        auto_avif: false,
        auto_webp: false,
        cache: {CacheProbe, message_target: cache_probe, get_result_fun: get_result_fun},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "cached jpeg"

    assert_cache_get_output(
      selection: {:image, :source_negotiated},
      output_policy: automatic_output_policy_data()
    )

    refute_received :origin_was_called
  end

  test "disabled automatic modern formats still set Vary for negotiated source output" do
    conn = conn(:get, "/src/images/beach.jpg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
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
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg;q=0")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
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
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/png")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
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
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/png")
      |> call_image_pipe(
        root_url: root_url,
        auto_avif: false,
        auto_webp: false
      )

    assert_stalled_source_error(conn)
    assert_receive {^ref, :first_chunk_sent, ^server}
    assert_receive {:DOWN, ^server_ref, :process, ^server, _reason}, 1_000
  end

  test "does not touch cache or origin when output format validation fails" do
    conn = conn(:get, "/format=invalid/src/images/beach.jpg")
    cache_probe = start_cache_probe()

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 400
    refute_received {:cache_get, _key}
    refute_received :origin_was_called
  end

  test "explicit output format does not set Vary on uncached streaming responses" do
    conn =
      call_image_pipe(
        conn(:get, "/format=webp/src/images/beach.jpg"),
        root_url: "http://origin.test",
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert get_resp_header(conn, "vary") == []
  end

  test "auto output uses source format when Accept excludes baseline formats" do
    conn =
      :get
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/*;q=0")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "safe one-pass resize opens origin with sequential access" do
    conn =
      conn(:get, "/w=100/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        image_open_module: RecordingImageOpen,
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

  test "region crop opens origin with sequential access" do
    conn =
      conn(:get, "/region=0,0,100,100/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        image_open_module: RecordingImageOpen,
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
      conn(:get, "/w=100/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        image_open_module: RecordingImageOpen,
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
      |> conn("/w=100/src/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        image_open_module: RecordingImageOpen,
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

  test "processes a path URL with dimensions and explicit output format" do
    conn = conn(:get, "/w=100/h=100/format=jpeg/src/images/beach.jpg")

    conn =
      call_image_pipe(conn,
        root_url: "http://origin.test",
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
  end

  test "returns text 500 when encoding fails before sending chunked headers" do
    prefix = attach_encode_stop_handler()

    {conn, log} =
      with_log(fn ->
        call_image_pipe(conn(:get, "/format=jpeg/src/images/beach.jpg"),
          root_url: "http://origin.test",
          telemetry_prefix: prefix,
          image_module: FailingStreamBeforeHeaderImage,
          origin_req_options: [plug: OriginImage]
        )
      end)

    assert conn.status == 500
    assert conn.resp_body == "error encoding image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert_received {:encode_stop, %{result: :processing_error, error: :encode}}
    assert_received :stream_encoder_called

    assert log =~ "encode_error: ** (RuntimeError) forced stream encode failure"

    assert log =~
             ~r{plug_test\.exs:\d+: ImagePipe\.PlugTest\.FailingStreamBeforeHeaderImage\.stream!/2}
  end

  test "returns text 500 when encoder produces an empty stream" do
    prefix = attach_encode_stop_handler()

    {conn, log} =
      with_log(fn ->
        call_image_pipe(conn(:get, "/format=jpeg/src/images/beach.jpg"),
          root_url: "http://origin.test",
          telemetry_prefix: prefix,
          image_module: EmptyStreamingImage,
          origin_req_options: [plug: OriginImage]
        )
      end)

    assert conn.status == 500
    assert conn.state == :sent
    assert conn.resp_body == "error encoding image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert_received {:encode_stop, %{result: :processing_error, error: :empty_stream}}
    assert_received :stream_encoder_called

    assert log =~ "encode_error: empty_stream"
  end

  test "does not send text 500 when encoding fails after chunked response starts" do
    conn = conn(:get, "/format=jpeg/src/images/beach.jpg")

    log =
      capture_log(fn ->
        conn =
          call_image_pipe(conn,
            root_url: "http://origin.test",
            image_module: RaisingAfterFirstChunkImage,
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
      conn(:get, "/w=10/format=png/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        max_input_pixels: 399,
        origin_req_options: [plug: plug]
      )

    assert conn.status == 413
    assert conn.resp_body == "source image is too large"
  end

  test "default source body limit applies through the request flow" do
    conn =
      conn(:get, "/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        image_open_module: ConsumeSourceThenDecodeErrorImage,
        origin_req_options: [plug: LargeBodyOrigin]
      )

    assert conn.status == 422
    assert conn.resp_body == "source response exceeds the size limit"
  end

  test "explicit source body limit overrides the default through the request flow" do
    conn =
      conn(:get, "/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        max_body_bytes: 10_000_001,
        image_open_module: ConsumeSourceThenDecodeErrorImage,
        origin_req_options: [plug: LargeBodyOrigin]
      )

    assert conn.status == 415
    assert conn.resp_body == "source response is not a supported image"
  end

  test "cache hit reuses successful response across source body limits" do
    permissive =
      conn(:get, "/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
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
      conn(:get, "/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
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
      conn(:get, "/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        max_body_bytes: 5,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 422
    assert conn.resp_body == "source response exceeds the size limit"
  end

  test "body limit failures after partial valid image bytes surface as source errors" do
    body = File.read!("priv/static/images/beach.jpg")

    conn =
      conn(:get, "/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        max_body_bytes: byte_size(body) - 1,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 422
    assert conn.resp_body == "source response exceeds the size limit"
  end

  test "source timeout while decoding partial valid image bytes surfaces as a source error" do
    ref = make_ref()
    {root_url, server} = start_slow_partial_origin(self(), ref)
    monitor_ref = Process.monitor(server)

    conn =
      call_after_slow_origin_first_chunk(
        conn(:get, "/format=jpeg/src/images/beach.jpg"),
        [
          root_url: root_url,
          origin_receive_timeout: 1_000
        ],
        ref,
        server
      )

    assert_stalled_source_error(conn)

    send(server, {ref, :close})
    assert_receive {:DOWN, ^monitor_ref, :process, ^server, _reason}
  end

  test "sequential body limit after initial valid bytes surfaces as a source error" do
    body = File.read!("priv/static/images/beach.jpg")

    conn =
      conn(:get, "/w=100/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        max_body_bytes: byte_size(body) - 1,
        origin_req_options: [plug: ChunkedOriginImage]
      )

    assert conn.status == 422
    assert conn.state == :sent
    assert conn.resp_body == "source response exceeds the size limit"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "sequential timeout after initial valid bytes surfaces as a source error" do
    ref = make_ref()
    {root_url, server} = start_slow_partial_origin(self(), ref)
    monitor_ref = Process.monitor(server)

    conn =
      call_after_slow_origin_first_chunk(
        conn(:get, "/w=100/format=jpeg/src/images/beach.jpg"),
        [
          root_url: root_url,
          origin_receive_timeout: 1_000
        ],
        ref,
        server
      )

    assert_stalled_source_error(conn)
    assert conn.state == :sent
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

    send(server, {ref, :close})
    assert_receive {:DOWN, ^monitor_ref, :process, ^server, _reason}
  end

  test "sequential corrupt image tail without origin error remains a decode error" do
    conn =
      conn(:get, "/w=100/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        origin_req_options: [plug: CorruptTailOriginImage]
      )

    assert conn.status == 415
    assert conn.state == :sent
    assert conn.resp_body == "source response is not a supported image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "per-op materialization failure on a corrupt source returns 415, not 422" do
    # A truncated source that opens as a sequential JPEG (header intact) but fails
    # when the quarter-turn orientation flush calls copy_memory must be classified
    # as a decode error (415), not a transform error (422).
    conn =
      conn(:get, "/rotate=90/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        origin_req_options: [plug: TruncatedHeaderOnlyOriginImage]
      )

    assert conn.status == 415
    assert conn.state == :sent
    assert conn.resp_body == "source response is not a supported image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "invalid streamed image bytes are decode errors" do
    conn =
      conn(:get, "/format=png/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
        origin_req_options: [plug: InvalidOriginImage]
      )

    assert conn.status == 415
    assert conn.resp_body == "source response is not a supported image"
  end

  test "cache read errors fail open by default and continue to origin" do
    cache_probe = start_cache_probe()

    conn =
      conn(:get, "/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
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
      conn(:get, "/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
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
      |> conn("/src/images/beach.jpg")
      |> put_req_header("accept", "image/jpeg")
      |> call_image_pipe(
        root_url: "http://origin.test",
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
      conn(:get, "/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
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
      conn(:get, "/format=jpeg/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
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
      conn(:get, "/format=png/src/images/beach.jpg")
      |> call_image_pipe(
        root_url: "http://origin.test",
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
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache:
          {ImagePipe.Cache.FileSystem,
           root: cache_root, path_prefix: "processed", max_body_bytes: 10_000_000}
      ]

      first_conn =
        conn(:get, "/format=jpeg/src/images/beach.jpg")
        |> call_image_pipe(opts)

      flush_cache_probe(cache_probe)
      assert first_conn.status == 200
      assert_received :origin_was_called

      second_conn =
        conn(:get, "/format=jpeg/src/images/beach.jpg")
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
