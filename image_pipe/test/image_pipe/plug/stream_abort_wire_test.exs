defmodule ImagePipe.Plug.StreamAbortWireTest do
  @moduledoc """
  A response that fails after its `200` headers went out must not end like a
  complete one, or a client or CDN can't tell the image is truncated.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test

  alias ImagePipe.Cache.Entry
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.OriginImage

  @path "/w=64/format=jpeg/src/images/cat.jpg"

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

  # A cache that always hits. With `unreadable: true` the body's file is
  # removed after it was opened, as if it was evicted before delivery.
  defmodule HitCache do
    @moduledoc false
    @behaviour ImagePipe.Cache

    @impl true
    def get(_key, opts) do
      path = Keyword.fetch!(opts, :path)
      {:ok, file} = ImagePipe.Cache.File.open(path, File.stat!(path).size)
      if Keyword.get(opts, :unreadable, false), do: File.rm!(path)

      {:hit,
       %Entry{
         body: file,
         content_type: "image/jpeg",
         headers: [],
         created_at: DateTime.utc_now(),
         representation: {:image, :jpeg}
       }}
    end

    @impl true
    def open_sink(_key, _metadata, _opts), do: raise("a cache hit should not write")
    @impl true
    def write_chunk(_state, _chunk, _opts), do: raise("a cache hit should not write")
    @impl true
    def commit_sink(_state, _opts), do: raise("a cache hit should not write")
    @impl true
    def abort_sink(_state, _opts), do: :ok
    @impl true
    def validate_options(opts), do: {:ok, opts}
    @impl true
    def child_spec(_opts), do: nil
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
    path = Path.join(System.tmp_dir!(), "stream-abort-#{System.unique_integer([:positive])}")
    File.write!(path, "cached image bytes")
    on_exit(fn -> File.rm(path) end)

    socket = serve(config(cache: {HitCache, path: path, unreadable: true}))
    response = read_until(socket, &String.ends_with?(&1, "0\r\n\r\n"))

    assert response =~ "HTTP/1.1 200"
    assert response =~ "\r\n\r\n12\r\ncached image bytes\r\n0\r\n\r\n"
  end

  describe "a cache hit over a real connection" do
    setup do
      path = Path.join(System.tmp_dir!(), "stream-abort-#{System.unique_integer([:positive])}")
      File.write!(path, :crypto.strong_rand_bytes(200_000))
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "delivers the whole body over HTTP/1.1", %{path: path} do
      body = File.read!(path)
      socket = serve(config(cache: {HitCache, path: path}))
      response = read_until(socket, &String.ends_with?(&1, body))

      assert response =~ "HTTP/1.1 200"
      assert response =~ "content-length: #{byte_size(body)}\r\n"
      assert String.ends_with?(response, "\r\n\r\n" <> body)
    end

    test "delivers the whole body over HTTP/2", %{path: path} do
      bandit = start_bandit(config(cache: {HitCache, path: path}))
      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
      {:ok, http2} = Mint.HTTP2.connect(:http, "127.0.0.1", port)
      {:ok, http2, ref} = Mint.HTTP2.request(http2, "GET", @path, [], nil)

      responses = receive_stream(http2, ref, [])

      assert {:status, ref, 200} in responses
      assert {:done, ref} in responses
      data = for {:data, ^ref, bytes} <- responses, into: "", do: bytes
      assert data == File.read!(path)
    end
  end

  test "a client that disconnects during a cache hit doesn't abort the response" do
    path = Path.join(System.tmp_dir!(), "stream-abort-#{System.unique_integer([:positive])}")
    File.write!(path, "cached image bytes")
    on_exit(fn -> File.rm(path) end)

    config = config(cache: {HitCache, path: path})
    conn = :get |> conn(@path) |> Map.put(:adapter, {ClosedClientAdapter, nil})

    assert %Plug.Conn{state: :file} = ImagePipe.Plug.call(conn, config)
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

  defp serve(config) do
    bandit = start_bandit(config)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET #{@path} HTTP/1.1\r\nhost: localhost\r\n\r\n")
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
