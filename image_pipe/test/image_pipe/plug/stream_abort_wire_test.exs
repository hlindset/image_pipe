defmodule ImagePipe.Plug.StreamAbortWireTest do
  @moduledoc """
  A response that fails after its `200` headers went out must not end like a
  complete one, or a client or CDN can't tell the image is truncated.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.CacheObserver
  alias ImagePipe.Test.PlugFixture.OriginImage

  @path "/w=64/format=jpeg/src/images/cat.jpg"
  # A response large enough to take several writes to deliver.
  @large_path "/w=800/format=png/src/images/cat.jpg"

  @sources [
    path: [
      adapter: RootHTTPAdapter,
      match: :path,
      options: [root_url: "http://origin.test", req_options: [plug: OriginImage]]
    ]
  ]

  # Bandit initializes its plug itself, so this hands it an already
  # initialized `ImagePipe.Plug` config.
  defmodule Mounted do
    @moduledoc false
    def init(config), do: config
    def call(conn, config), do: ImagePipe.Plug.call(conn, config)
  end

  # A Plug adapter whose client is gone once the headers are out.
  defmodule ClosedClientAdapter do
    @moduledoc false
    def send_chunked(state, _status, _headers), do: {:ok, nil, state}
    def chunk(_state, _body), do: {:error, :closed}

    def send_file(_state, _status, _headers, _path, _offset, _length),
      do: raise(Bandit.TransportError, message: "closed", error: :closed)

    def get_peer_data(_state), do: %{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil}
    def get_http_protocol(_state), do: :"HTTP/1.1"
  end

  describe "over a real HTTP/1.1 connection" do
    test "a complete stream ends with the terminating chunk" do
      socket = serve(config([]))

      response = read_until(socket, &String.ends_with?(&1, "\r\n0\r\n\r\n"))

      assert response =~ "HTTP/1.1 200"
      assert response =~ "transfer-encoding: chunked"
    end

    test "a stream that fails mid-body closes the connection without the terminating chunk" do
      socket = serve(config(image_module: ImagePipe.RunTest.LateFailureEncoder))

      {response, log} =
        with_log(fn -> read_until(socket, fn _response -> false end) end)

      assert response =~ "HTTP/1.1 200"
      assert response =~ "encoded prefix"
      refute String.ends_with?(response, "\r\n0\r\n\r\n")
      assert log =~ "late encoder failure"
    end
  end

  describe "over a real HTTP/2 connection" do
    test "a stream that fails mid-body is reset" do
      bandit = start_bandit(config(image_module: ImagePipe.RunTest.LateFailureEncoder))
      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
      {:ok, http2} = Mint.HTTP2.connect(:http, "127.0.0.1", port)
      {:ok, http2, ref} = Mint.HTTP2.request(http2, "GET", @path, [], nil)

      {responses, log} = with_log(fn -> receive_stream(http2, ref, []) end)

      assert {:status, ref, 200} in responses

      assert {:error, ^ref, %Mint.HTTPError{reason: {:server_closed_request, :internal_error}}} =
               List.last(responses)

      assert log =~ "late encoder failure"
    end
  end

  test "a cache hit whose body is evicted before delivery is still served" do
    {config, hash, body} = warm(@path)
    remove_body_on_hit(config, hash)

    socket = serve(config)
    response = read_until(socket, &String.ends_with?(&1, "\r\n0\r\n\r\n"))

    assert response =~ "HTTP/1.1 200"
    assert response =~ "transfer-encoding: chunked"
    assert String.contains?(response, body)
    assert body_files(config, hash) == []
  end

  describe "a cache hit over a real connection" do
    setup do
      {config, _hash, body} = warm(@large_path)
      %{config: config, body: body}
    end

    test "delivers the whole body over HTTP/1.1", %{config: config, body: body} do
      socket = serve(config, @large_path)
      response = read_until(socket, &String.ends_with?(&1, body))

      assert response =~ "HTTP/1.1 200"
      assert response =~ "content-length: #{byte_size(body)}\r\n"
      assert String.ends_with?(response, "\r\n\r\n" <> body)
    end

    test "answers HEAD with the body's length and no body", %{config: config, body: body} do
      bandit = start_bandit(config)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      :ok =
        :gen_tcp.send(
          socket,
          "HEAD #{@large_path} HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n"
        )

      response = read_until(socket, fn _acc -> false end)

      assert response =~ "HTTP/1.1 200"
      assert response =~ "content-length: #{byte_size(body)}\r\n"
      assert String.ends_with?(response, "\r\n\r\n")
    end

    test "delivers the whole body over HTTP/2", %{config: config, body: body} do
      bandit = start_bandit(config)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
      {:ok, http2} = Mint.HTTP2.connect(:http, "127.0.0.1", port)
      {:ok, http2, ref} = Mint.HTTP2.request(http2, "GET", @large_path, [], nil)

      responses = receive_stream(http2, ref, [])

      assert {:status, ref, 200} in responses
      assert {:done, ref} in responses
      data = for {:data, ^ref, bytes} <- responses, into: "", do: bytes
      assert data == body
    end
  end

  test "a client that disconnects during a cache hit doesn't abort the response" do
    {config, _hash, _body} = warm(@path)
    conn = :get |> conn(@path) |> Map.put(:adapter, {ClosedClientAdapter, nil})

    assert %Plug.Conn{state: :file} = ImagePipe.Plug.call(conn, config)
  end

  # Stores the response for `path` in a fresh cache and returns a config
  # that serves it as a hit.
  defp warm(path) do
    config = ImagePipe.Plug.init(CacheObserver.observe(sources: @sources))
    assert %Plug.Conn{status: 200} = ImagePipe.Plug.call(conn(:get, path), config)
    assert_receive {:cache_put, hash, body}
    {config, hash, body}
  end

  # Removes the entry's body file once a lookup has opened it, as if it was
  # evicted before delivery.
  defp remove_body_on_hit(config, hash) do
    id = {__MODULE__, make_ref()}
    event = Keyword.fetch!(config, :telemetry_prefix) ++ [:cache, :lookup, :stop]

    :ok =
      :telemetry.attach(
        id,
        event,
        fn _event, _measurements, %{cache: :hit}, _config ->
          for file <- body_files(config, hash), do: File.rm!(file)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp body_files(config, hash) do
    {:ok, %{dir: dir}} = FileSystem.paths_from_hash(hash, Keyword.fetch!(config, :cache))
    Path.wildcard(Path.join(dir, hash <> ".*.body"))
  end

  defp config(extra) do
    {seams, known} = Keyword.split(extra, [:image_module])
    Keyword.merge(ImagePipe.Plug.init([sources: @sources] ++ known), seams)
  end

  defp start_bandit(config) do
    start_supervised!(
      {Bandit, plug: {Mounted, config}, port: 0, ip: :loopback, startup_log: false}
    )
  end

  defp serve(config, path \\ @path) do
    bandit = start_bandit(config)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET #{path} HTTP/1.1\r\nhost: localhost\r\n\r\n")
    socket
  end

  # Collects the request's responses until it finishes or fails.
  defp receive_stream(http2, ref, acc) do
    receive do
      message ->
        case Mint.HTTP2.stream(http2, message) do
          {:ok, http2, responses} ->
            acc = acc ++ responses

            if Enum.any?(responses, &finished?(&1, ref)),
              do: acc,
              else: receive_stream(http2, ref, acc)

          :unknown ->
            receive_stream(http2, ref, acc)
        end
    after
      5_000 -> acc
    end
  end

  defp finished?({:done, ref}, ref), do: true
  defp finished?({:error, ref, _reason}, ref), do: true
  defp finished?(_response, _ref), do: false

  # Reads until `done?` holds or the server closes the connection.
  defp read_until(socket, done?, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data
        if done?.(acc), do: acc, else: read_until(socket, done?, acc)

      {:error, :closed} ->
        acc
    end
  end
end
