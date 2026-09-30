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

    test "attaches the default Logger from [telemetry]" do
      assert Enum.any?(
               :telemetry.list_handlers([:image_pipe]),
               &(&1.id == "image-pipe-default-logger")
             )
    end
  end

  describe "children/1" do
    test "starts the pool, bounded caches, and warm-ups before the listener", %{tmp_dir: dir} do
      config =
        Config.build!(
          pool: [max_concurrency: 2],
          cache: [
            cache:
              {ImagePipe.Cache.FileSystem,
               [root: Path.join(dir, "out"), max_size_bytes: 1_000_000, node_id: "test"]},
            input_cache: {ImagePipe.Cache.FileSystem, [root: Path.join(dir, "in")]}
          ],
          processing: [detector: ImagePipeServer.Test.AvailableDetector]
        )

      assert [pool, cache, detector, http] = App.children(config)
      assert {ImagePipe.ProcessingPool, pool_opts} = pool
      assert pool_opts[:max_concurrency] == 2
      assert %{id: {ImagePipe.Cache.FileSystem.Store, _root}} = cache
      assert {ImagePipe.Transform.Detector.Warmup, _opts} = detector
      assert {Bandit, _opts} = http
    end

    test "starts only the listener by default" do
      assert [{Bandit, _opts}] = App.children(Config.build!([]))
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
      assert_receive :request_started
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
