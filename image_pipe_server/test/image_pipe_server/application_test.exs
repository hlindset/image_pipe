defmodule ImagePipeServer.ApplicationTest do
  use ExUnit.Case, async: true

  alias ImagePipeServer.Application, as: App
  alias ImagePipeServer.Config

  @moduletag :tmp_dir

  describe "the running application" do
    # The test run boots the application from test/support/server.toml.
    setup do
      {:ok, {_ip, port}} = ThousandIsland.listener_info(App.listener())
      %{base: "http://127.0.0.1:#{port}"}
    end

    test "answers /health over HTTP", %{base: base} do
      assert {:ok, %{status: 200, body: "ok"}} = Req.get(base <> "/health", retry: false)
    end

    test "serves an image from the configured File mount", %{base: base} do
      assert {:ok, %{status: 200, body: body}} =
               Req.get(base <> "/w=4/format=png/src/pic.png", retry: false, decode_body: false)

      assert {:ok, image} = Image.from_binary(body)
      assert {Image.width(image), Image.height(image)} == {4, 3}
    end

    test "doesn't negotiate content encoding for images", %{base: base} do
      assert {:ok, response} =
               Req.get(base <> "/w=4/format=png/src/pic.png",
                 headers: [{"accept-encoding", "gzip"}],
                 retry: false,
                 decode_body: false,
                 compressed: false
               )

      assert response.status == 200
      assert Req.Response.get_header(response, "content-encoding") == []

      refute "accept-encoding" in (response
                                   |> Req.Response.get_header("vary")
                                   |> Enum.flat_map(&String.split(&1, ", ")))
    end

    test "attaches the default Logger from [telemetry]" do
      assert Enum.any?(
               :telemetry.list_handlers([:image_pipe]),
               &(&1.id == "image-pipe-default-logger")
             )
    end
  end

  describe "tracer_options/1" do
    test "ignores an inbound traceparent by default" do
      options = App.tracer_options(Config.build!([]))
      assert options[:exporter] == ImagePipe.Telemetry.Trace.OpenTelemetryExporter
      assert options[:extract_inbound] == false
    end

    test "continues an inbound traceparent with trust_traceparent" do
      config = Config.build!(Config.options!(%{"telemetry" => %{"trust_traceparent" => true}}))
      assert App.tracer_options(config)[:extract_inbound] == true
    end
  end

  describe "children/1" do
    test "starts the pool and the ImagePipe instance before the listener", %{
      tmp_dir: dir
    } do
      config =
        Config.build!(
          pool: [max_concurrency: 2],
          cache: [
            cache:
              {ImagePipe.Cache.FileSystem,
               [root: Path.join(dir, "out"), max_size_bytes: 1_000_000, node_id: "test"]},
            input_cache: {ImagePipe.Cache.FileSystem, [root: Path.join(dir, "in")]}
          ]
        )

      assert [pool, instance, http] = App.children(config)
      assert {ImagePipe.ProcessingPool, pool_opts} = pool
      assert pool_opts[:max_concurrency] == 2
      assert {ImagePipe, instance_opts} = instance
      assert instance_opts[:config] == config.image_pipe
      assert {Bandit, _opts} = http
    end

    test "starts only the ImagePipe instance and the listener by default" do
      assert [{ImagePipe, _instance}, {Bandit, _http}] = App.children(Config.build!([]))
    end
  end

  describe "http_child/2" do
    test "caps connections across acceptors and sets the read timeout" do
      config = Config.build!(server: [max_connections: 2048, read_timeout: 5_000])
      {Bandit, opts} = App.http_child(config, {ImagePipeServer.Router, []})
      island = opts[:thousand_island_options]

      assert island[:num_acceptors] == 100
      assert island[:num_connections] == 21
      assert island[:read_timeout] == 5_000
      assert opts[:http_options][:compress] == false
    end

    test "uses fewer acceptors than connections for small caps" do
      config = Config.build!(server: [max_connections: 10])
      {Bandit, opts} = App.http_child(config, {ImagePipeServer.Router, []})

      assert opts[:thousand_island_options][:num_acceptors] == 10
      assert opts[:thousand_island_options][:num_connections] == 1
    end
  end

  describe "read timeout" do
    @tag :capture_log
    test "closes connections that stay silent" do
      config = Config.build!(server: [port: 0, bind: "127.0.0.1", read_timeout: 100])

      {Bandit, opts} =
        App.http_child(config, {ImagePipeServer.Router, App.router_options(config)})

      name = :"listener_#{System.unique_integer([:positive])}"
      opts = put_in(opts, [:thousand_island_options, :supervisor_options], name: name)
      start_supervised!(Supervisor.child_spec({Bandit, opts}, id: :idle_listener))
      {:ok, {_ip, port}} = ThousandIsland.listener_info(name)

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      assert {:ok, "HTTP/1.0 408 Request Timeout" <> _rest} = :gen_tcp.recv(socket, 0, 2_000)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
    end
  end

  describe "shutdown" do
    defmodule SlowPlug do
      @behaviour Plug
      def init(opts), do: opts

      def call(conn, test) do
        send(test, :request_started)
        Process.sleep(300)
        Plug.Conn.send_resp(conn, 200, "done")
      end
    end

    defp start_listener(shutdown_timeout) do
      config =
        Config.build!(server: [port: 0, bind: "127.0.0.1", shutdown_timeout: shutdown_timeout])

      {Bandit, opts} = App.http_child(config, {SlowPlug, self()})
      name = :"listener_#{System.unique_integer([:positive])}"
      opts = put_in(opts, [:thousand_island_options, :supervisor_options], name: name)
      pid = start_supervised!(Supervisor.child_spec({Bandit, opts}, id: :listener))
      {:ok, {_ip, port}} = ThousandIsland.listener_info(name)

      request = Task.async(fn -> Req.get("http://127.0.0.1:#{port}/", retry: false) end)
      # The first request through a fresh listener can take longer than the
      # default receive timeout on a loaded CI runner.
      assert_receive :request_started, 2_000
      {pid, request}
    end

    test "lets in-flight requests finish within the grace period" do
      {pid, request} = start_listener(5_000)
      ref = Process.monitor(pid)
      :ok = stop_supervised(:listener)

      assert {:ok, %{status: 200, body: "done"}} = Task.await(request)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    test "cuts off requests that outlast the grace period" do
      {_pid, request} = start_listener(10)
      :ok = stop_supervised(:listener)

      assert {:error, _reason} = Task.await(request)
    end
  end
end
