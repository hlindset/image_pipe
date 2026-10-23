defmodule ImagePipeServer.ApplicationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ImagePipeServer.Application, as: App
  alias ImagePipeServer.Config
  alias ImagePipeServer.Health

  @moduletag :tmp_dir

  describe "the running application" do
    # The test run boots the application from test/support/server.toml.
    setup do
      {:ok, {_ip, port}} = ThousandIsland.listener_info(App.listener())
      %{base: "http://127.0.0.1:#{port}"}
    end

    test "answers the health checks over HTTP", %{base: base} do
      for path <- ["/health/live", "/health/ready"] do
        assert {:ok, %{status: 200, body: "ok"}} = Req.get(base <> path, retry: false)
      end
    end

    test "warms up every output format without a failure" do
      log =
        capture_log(fn -> assert ImagePipeServer.Warmup.run(ImagePipeServer.ImagePipe) == :ok end)

      refute log =~ "warmup"
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

    test "turns off libvips' operation cache" do
      assert Vix.Vips.cache_get_max() == 0
    end

    test "attaches the default Logger from [telemetry]" do
      assert Enum.any?(
               :telemetry.list_handlers([:image_pipe]),
               &(&1.id == "image-pipe-default-logger")
             )
    end
  end

  describe "booting with invalid configuration" do
    test "prints the error alone and exits with status 1", %{tmp_dir: dir} do
      path = Path.join(dir, "config.toml")
      File.write!(path, "[sources.photos]\nadapter = \"file\"\nroot = \"#{dir}\"\n")

      {output, status} =
        System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", ""],
          env: [{"MIX_ENV", "test"}, {"IPS_CONFIG", path}, {"ERL_CRASH_DUMP", ""}],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ ~r/^invalid configuration: sources.photos.match: required$/m
      refute output =~ "**"
      refute output =~ "exited"
    end
  end

  describe "booting on a port in use" do
    for setting <- ["port", "health_port"] do
      test "names server.#{setting} and exits with status 1", %{tmp_dir: dir} do
        {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
        {:ok, taken} = :inet.port(socket)
        ports = %{"port" => 0, "health_port" => 0} |> Map.put(unquote(setting), taken)

        path = Path.join(dir, "config.toml")

        File.write!(path, """
        [server]
        port = #{ports["port"]}
        health_port = #{ports["health_port"]}
        bind = "127.0.0.1"

        [url]
        allow_unsigned = true

        [sources.static]
        adapter = "file"
        match = "path"
        root = "test/support/images"
        root_id = "static"
        """)

        {output, status} =
          System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", ""],
            env: [{"MIX_ENV", "test"}, {"IPS_CONFIG", path}, {"ERL_CRASH_DUMP", ""}],
            stderr_to_stdout: true
          )

        assert status == 1

        assert output =~
                 ~r/^cannot start: can't listen on server.#{unquote(setting)} #{taken} at 127.0.0.1: address already in use$/m

        refute output =~ "**"
        refute output =~ "exited"
      end
    end
  end

  describe "tracer_options/1" do
    test "ignores an inbound traceparent by default" do
      assert App.tracer_options(Config.build!(url: [allow_unsigned: true])) == [
               extract_inbound: false
             ]
    end

    test "continues an inbound traceparent with trust_traceparent" do
      config =
        Config.build!(
          Config.options!(%{
            "url" => %{"allow_unsigned" => true},
            "telemetry" => %{"trust_traceparent" => true}
          })
        )

      assert App.tracer_options(config)[:extract_inbound] == true
    end
  end

  describe "router_options/2" do
    test "has the router log its own answers when log_requests is on" do
      on = Config.build!(url: [allow_unsigned: true])

      off =
        Config.build!(
          Config.options!(%{
            "url" => %{"allow_unsigned" => true},
            "telemetry" => %{"log_requests" => false}
          })
        )

      assert App.router_options(on, Health.new())[:log_requests] == true
      assert App.router_options(off, Health.new())[:log_requests] == false
    end
  end

  describe "children/1" do
    test "starts the pool and the ImagePipe instance before the listener", %{
      tmp_dir: dir
    } do
      config =
        Config.build!(
          url: [allow_unsigned: true],
          pool: [max_concurrency: 2],
          cache: [
            cache: [root: Path.join(dir, "out"), max_size_bytes: 1_000_000]
          ]
        )

      assert [pool, instance, warmup, http, serving] = App.children(config, Health.new())
      assert {ImagePipe.ProcessingPool, pool_opts} = pool
      assert pool_opts[:max_concurrency] == 2
      assert {ImagePipe, instance_opts} = instance
      assert instance_opts[:config] == config.image_pipe
      assert instance_opts[:detector_warmup] == :all
      assert {ImagePipeServer.Warmup, _instance} = warmup
      assert %{id: :http, start: {Bandit, :start_link, _opts}} = http
      assert %{id: :serving} = serving
    end

    test "gives each warmed S3 credential provider its own child id" do
      config =
        Config.build!(
          Config.options!(%{
            "url" => %{"allow_unsigned" => true},
            "sources" => %{
              "media" => %{
                "adapter" => "s3",
                "match" => %{"scheme" => "s3"},
                "region" => "us-east-1",
                "endpoint" => "https://s3.example.com",
                "credentials" => %{"provider" => "instance_role"},
                "buckets" => %{
                  "photos" => %{},
                  "avatars" => %{
                    "credentials" => %{"provider" => "instance_role", "ttl_seconds" => 300}
                  }
                }
              }
            }
          })
        )

      ids =
        for child <- App.children(config, Health.new()),
            do: Supervisor.child_spec(child, []).id

      assert length(Enum.uniq(ids)) == length(ids)
      assert length(config.credential_warmups) == 2
    end

    test "starts the processing pool, the ImagePipe instance and the listener by default" do
      assert [
               {ImagePipe.ProcessingPool, _pool},
               {ImagePipe, _instance},
               {ImagePipeServer.Warmup, _warmup},
               %{id: :http, start: {Bandit, :start_link, _http}},
               %{id: :serving}
             ] = App.children(Config.build!(url: [allow_unsigned: true]), Health.new())
    end

    test "turns readiness on after the listener starts" do
      drain = Health.new()

      %{start: {module, function, args}} =
        List.last(App.children(Config.build!(url: [allow_unsigned: true]), drain))

      assert apply(module, function, args) == :ignore
      assert Health.serving?(drain)
    end
  end

  describe "[url] settings" do
    test "sign the instance's URLs with url.keys" do
      key = String.duplicate("ab", 32)

      config =
        Config.build!(
          Config.options!(%{
            "url" => %{"keys" => [key]},
            "sources" => %{
              "static" => %{
                "adapter" => "file",
                "match" => "path",
                "root" => "test/support/images",
                "root_id" => "static"
              }
            }
          })
        )

      instance = :"signed_instance_#{System.unique_integer([:positive])}"
      start_supervised!({ImagePipe, name: instance, config: config.image_pipe})
      image_pipe = ImagePipe.Plug.init([instance: instance] ++ config.http)
      path = "/w=4/format=png/src/pic.png"
      sign = &ImagePipe.URL.sign_path(path, ImagePipe.URL.config(keys: [&1]))
      call = &ImagePipe.Plug.call(Plug.Test.conn(:get, &1), image_pipe).status

      assert call.(sign.(key)) == 200
      assert call.(sign.(String.duplicate("cd", 32))) == 403
      assert call.(path) == 403
    end
  end

  describe "log_formatter/2" do
    test "writes text without color escapes unless colors are on" do
      event = %{level: :warning, msg: {:string, "slow"}, meta: %{time: :logger.timestamp()}}

      for {colors, escapes?} <- [{false, false}, {true, true}] do
        {formatter, config} = App.log_formatter(:text, colors)
        line = event |> formatter.format(config) |> IO.iodata_to_binary()

        assert line =~ "[warning] slow"
        assert String.contains?(line, "\e[") == escapes?
      end
    end

    test "writes one JSON object per line with the request ID and summary fields" do
      for format <- [:json, :gcp, :datadog, :elastic] do
        {formatter, config} = App.log_formatter(format, false)

        event = %{
          level: :info,
          msg: {:string, "GET /w=40/src/a.jpg 200 3ms"},
          meta: %{
            time: :logger.timestamp(),
            request_id: "req-1",
            image_pipe: %{status: 200, input_size: {40, 27}},
            plug: {:secret, :options}
          }
        }

        line = event |> formatter.format(config) |> IO.iodata_to_binary()

        assert %{} = JSON.decode!(line), inspect(format)
        assert [_one_line] = String.split(String.trim(line), "\n"), inspect(format)
        assert line =~ ~s("request_id":"req-1"), inspect(format)
        assert line =~ ~s("image_pipe":{), inspect(format)
        assert line =~ ~s("input_size":[40,27]), inspect(format)
        refute line =~ "secret", inspect(format)
      end
    end
  end

  describe "http_child/2" do
    test "caps connections on one acceptor and sets the read timeout" do
      config =
        Config.build!(
          url: [allow_unsigned: true],
          server: [max_connections: 2048, read_timeout: 5_000]
        )

      {Bandit, opts} = App.http_child(config, {ImagePipeServer.Router, []})
      island = opts[:thousand_island_options]

      assert island[:num_acceptors] == 1
      assert island[:num_connections] == 2048
      assert island[:read_timeout] == 5_000
      assert opts[:http_options][:compress] == false
    end

    test "serves a new connection while another is held below max_connections" do
      config =
        Config.build!(
          url: [allow_unsigned: true],
          server: [port: 0, bind: "127.0.0.1", max_connections: 2]
        )

      {Bandit, opts} = App.http_child(config, {Health, drain: Health.new()})
      name = :"listener_#{System.unique_integer([:positive])}"

      # A closed connection's handler can still hold its slot when the next
      # request arrives; the acceptor then waits for one. The default 1s wait
      # outlasts the receive timeout, while 5 retries of 50ms still fail
      # within it when the cap never frees a slot.
      opts =
        opts
        |> put_in([:thousand_island_options, :supervisor_options], name: name)
        |> put_in([:thousand_island_options, :max_connections_retry_wait], 50)

      start_supervised!(Supervisor.child_spec({Bandit, opts}, id: :capped_listener))
      {:ok, {_ip, port}} = ThousandIsland.listener_info(name)

      {:ok, _held} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      for _ <- 1..4 do
        assert {:ok, %{status: 200}} =
                 Req.get("http://127.0.0.1:#{port}/health/live",
                   retry: false,
                   receive_timeout: 500,
                   headers: [connection: "close"]
                 )
      end
    end
  end

  describe "HTTP versions" do
    test "serves HTTP/1.1 and refuses HTTP/2 prior knowledge" do
      config = Config.build!(url: [allow_unsigned: true], server: [port: 0, bind: "127.0.0.1"])
      {Bandit, opts} = App.http_child(config, {Health, drain: Health.new()})
      name = :"listener_#{System.unique_integer([:positive])}"
      opts = put_in(opts, [:thousand_island_options, :supervisor_options], name: name)
      start_supervised!(Supervisor.child_spec({Bandit, opts}, id: :versions_listener))
      {:ok, {_ip, port}} = ThousandIsland.listener_info(name)

      assert {:ok, %{status: 200}} =
               Req.get("http://127.0.0.1:#{port}/health/live", retry: false)

      result =
        with {:ok, conn} <- Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http2]),
             {:ok, conn, ref} <- Mint.HTTP.request(conn, "GET", "/health/live", [], nil) do
          receive_status(conn, ref)
        end

      refute match?({:ok, 200}, result)
    end
  end

  defp receive_status(conn, ref) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            case Enum.find(responses, &match?({:status, ^ref, _}, &1)) do
              {:status, ^ref, status} -> {:ok, status}
              nil -> receive_status(conn, ref)
            end

          {:error, _conn, reason, _responses} ->
            {:error, reason}

          :unknown ->
            receive_status(conn, ref)
        end
    after
      2_000 -> {:error, :timeout}
    end
  end

  describe "health listener" do
    defp start_named(child, id) do
      {Bandit, opts} = child
      name = :"#{id}_#{System.unique_integer([:positive])}"
      opts = put_in(opts, [:thousand_island_options, :supervisor_options], name: name)
      start_supervised!(Supervisor.child_spec({Bandit, opts}, id: id))
      {:ok, {_ip, port}} = ThousandIsland.listener_info(name)
      port
    end

    test "listens on health_bind" do
      config =
        Config.build!(
          url: [allow_unsigned: true],
          server: [port: 0, bind: "0.0.0.0", health_bind: "127.0.0.1", health_port: 0]
        )

      health = start_named(App.health_child(config, Health.new()), :bound_health_listener)

      assert {:ok, %{status: 200}} =
               Req.get("http://127.0.0.1:#{health}/health/live", retry: false)

      {Bandit, opts} = App.health_child(config, Health.new())
      assert opts[:ip] == {127, 0, 0, 1}
    end

    test "starts only with health_port" do
      refute App.health_child(Config.build!(url: [allow_unsigned: true]), Health.new())
    end

    test "answers liveness while the main listener is at its connection cap" do
      config =
        Config.build!(
          url: [allow_unsigned: true],
          server: [port: 0, bind: "127.0.0.1", max_connections: 1, health_port: 0]
        )

      drain = Health.new()
      main = start_named(App.http_child(config, {Health, drain: drain}), :main_listener)
      health = start_named(App.health_child(config, drain), :health_listener)

      {:ok, _held} = :gen_tcp.connect(~c"127.0.0.1", main, [:binary, active: false])

      assert {:ok, %{status: 200}} =
               Req.get("http://127.0.0.1:#{health}/health/live",
                 retry: false,
                 receive_timeout: 500
               )

      assert {:ok, %{status: 404}} =
               Req.get("http://127.0.0.1:#{health}/w=2/src/pic.png", retry: false)
    end
  end

  describe "draining" do
    test "marks the server draining, then waits shutdown_delay" do
      drain = Health.new()
      started = System.monotonic_time(:millisecond)

      assert App.prep_stop({drain, 50}) == {drain, 50}
      assert Health.draining?(drain)
      assert System.monotonic_time(:millisecond) - started >= 50
    end
  end

  describe "read timeout" do
    @tag :capture_log
    test "closes connections that stay silent" do
      config =
        Config.build!(
          url: [allow_unsigned: true],
          server: [port: 0, bind: "127.0.0.1", read_timeout: 100]
        )

      {Bandit, opts} =
        App.http_child(config, {ImagePipeServer.Router, App.router_options(config, Health.new())})

      name = :"listener_#{System.unique_integer([:positive])}"
      opts = put_in(opts, [:thousand_island_options, :supervisor_options], name: name)
      start_supervised!(Supervisor.child_spec({Bandit, opts}, id: :idle_listener))
      {:ok, {_ip, port}} = ThousandIsland.listener_info(name)

      # A connection that sends nothing is closed without a response.
      {:ok, silent} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      assert {:error, :closed} = :gen_tcp.recv(silent, 0, 2_000)

      # One that stops partway through a request gets a 408 first.
      {:ok, partial} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      :ok = :gen_tcp.send(partial, "GET /health/live HTTP/1.1\r\n")
      assert {:ok, "HTTP/1." <> response} = :gen_tcp.recv(partial, 0, 2_000)
      assert response =~ "408"
      assert {:error, :closed} = :gen_tcp.recv(partial, 0, 2_000)
    end
  end

  describe "malformed requests" do
    test "answer 400 without logging the request's headers" do
      config =
        Config.build!(
          url: [allow_unsigned: true],
          server: [port: 0, bind: "127.0.0.1", health_port: 0]
        )

      drain = Health.new()

      listeners = [
        App.http_child(config, {ImagePipeServer.Router, App.router_options(config, drain)}),
        App.health_child(config, drain)
      ]

      for {{Bandit, opts}, index} <- Enum.with_index(listeners) do
        name = :"listener_#{System.unique_integer([:positive])}"
        opts = put_in(opts, [:thousand_island_options, :supervisor_options], name: name)
        start_supervised!(Supervisor.child_spec({Bandit, opts}, id: {:malformed, index}))
        {:ok, {_ip, port}} = ThousandIsland.listener_info(name)

        log =
          capture_log(fn ->
            {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
            :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nAuthorization Bearer s3cr3t\r\n\r\n")
            assert {:ok, "HTTP/1.0 400" <> _rest} = :gen_tcp.recv(socket, 0, 2_000)
            assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
          end)

        refute log =~ "s3cr3t"
      end
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
        Config.build!(
          url: [allow_unsigned: true],
          server: [port: 0, bind: "127.0.0.1", shutdown_timeout: shutdown_timeout]
        )

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
