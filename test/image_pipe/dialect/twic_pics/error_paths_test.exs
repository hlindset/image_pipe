defmodule ImagePipe.Dialect.TwicPics.ErrorPathsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.Key
  alias ImagePipe.Delivery
  alias ImagePipe.Delivery.Coordinator
  alias ImagePipe.Dialect.TwicPics
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Delivery.SessionProbe
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Operation.Resize, as: ExecutableResize
  alias ImgproxyWireConformanceTest.OriginImage

  defmodule Origin503 do
    @moduledoc false

    def init(opts), do: opts

    def call(conn, opts) do
      opts |> Keyword.fetch!(:test_pid) |> send(:origin_fetch)
      Plug.Conn.send_resp(conn, 503, "origin 503")
    end
  end

  defmodule CorruptImageOrigin do
    @moduledoc false

    def init(opts), do: opts

    def call(conn, opts) do
      opts |> Keyword.fetch!(:test_pid) |> send(:origin_fetch)

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, "not a valid image \xFF\xFE\x00")
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

  defmodule ObservingCache do
    @moduledoc false
    @behaviour ImagePipe.Cache

    @impl true
    def get(_key, opts) do
      send(Keyword.fetch!(opts, :test_pid), :cache_get)
      :miss
    end

    @impl true
    def open_sink(key, metadata, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:cache_open_sink, key, metadata})
      {:ok, %{chunks: [], test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    @impl true
    def write_chunk(state, chunk, _opts) do
      send(state.test_pid, {:cache_write_chunk, chunk})
      {:ok, %{state | chunks: [chunk | state.chunks]}}
    end

    @impl true
    def commit_sink(state, _opts) do
      send(state.test_pid, :cache_commit_sink)
      :ok
    end

    @impl true
    def abort_sink(state, _opts) do
      send(state.test_pid, :cache_abort_sink)
      :ok
    end
  end

  defmodule RaisingGetCache do
    @moduledoc false
    @behaviour ImagePipe.Cache

    @impl true
    def get(_key, _opts), do: raise("cache get boom")

    @impl true
    def open_sink(_key, _metadata, opts) do
      send(Keyword.fetch!(opts, :test_pid), :cache_open_sink)
      {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    @impl true
    def write_chunk(state, _chunk, _opts), do: {:ok, state}

    @impl true
    def commit_sink(state, _opts) do
      send(state.test_pid, :cache_commit_sink)
      :ok
    end

    @impl true
    def abort_sink(state, _opts) do
      send(state.test_pid, :cache_abort_sink)
      :ok
    end
  end

  defmodule FailingWriteCache do
    @moduledoc false
    @behaviour ImagePipe.Cache

    @impl true
    def get(_key, _opts), do: :miss

    @impl true
    def open_sink(_key, _metadata, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :cache_open_sink)
      {:ok, %{test_pid: test_pid}}
    end

    @impl true
    def write_chunk(state, _chunk, _opts) do
      send(state.test_pid, :cache_write_chunk_failed)
      {:error, :forced_write_failure, state}
    end

    @impl true
    def commit_sink(state, _opts) do
      send(state.test_pid, :cache_commit_sink)
      :ok
    end

    @impl true
    def abort_sink(state, _opts) do
      send(state.test_pid, :cache_abort_sink)
      :ok
    end
  end

  @default_sources [
    path:
      {RootHTTPAdapter,
       root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
  ]
  @test_seams [:image_module, :on_bracket_exit, :chain]

  @doc false
  def handle_request_stop(_name, _measurements, metadata, target) do
    send(target, {:request_stop, metadata})
  end

  defp opts(extra) do
    {seams, validated} = Keyword.split(extra, @test_seams)

    [sources: @default_sources]
    |> Keyword.merge(validated)
    |> TwicPics.init()
    |> Keyword.merge(seams)
  end

  defp get(path, config), do: TwicPics.call(conn(:get, path), config)

  defp decoded_dims(body) do
    {:ok, image} = Image.from_binary(body)
    {Image.width(image), Image.height(image)}
  end

  defp fake_resolved_output do
    %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  defp fake_cache_key, do: %Key{hash: "test-key", data: []}

  defp bracketed_build_fun(chunks, test_pid) do
    fn pump ->
      try do
        pump.(Stream.map(chunks, & &1), "image/jpeg", fake_resolved_output(), nil)
      after
        send(test_pid, :bracket_cleanup)
      end
    end
  end

  describe "row 1: origin 5xx" do
    test "maps 503 to 502 without opening a cache sink or cleanup bracket" do
      test_pid = self()
      prefix = [:"twic_pics_error_paths_#{System.unique_integer([:positive])}"]
      handler_id = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          prefix ++ [:request, :stop],
          &__MODULE__.handle_request_stop/4,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      config =
        opts(
          telemetry_prefix: prefix,
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               byte_identity: :strong,
               req_options: [plug: {Origin503, test_pid: test_pid}]}
          ],
          cache: {ObservingCache, test_pid: test_pid},
          on_bracket_exit: fn -> send(test_pid, :bracket_cleanup) end
        )

      conn = get("/images/cat.jpg?twic=v1/resize=64/output=jpeg", config)

      assert_received :origin_fetch
      assert conn.status == 502
      assert conn.resp_body == "upstream responded 503"
      assert_received {:request_stop, %{result: :source_error, error: :source, status: 502}}
      refute_received {:cache_open_sink, _key, _metadata}
      refute_received :bracket_cleanup
    end
  end

  describe "row 2: owner disconnect during fetch" do
    test "unblocks prepare with owner_down and runs cleanup exactly once" do
      test_pid = self()

      build_fun = fn pump ->
        send(test_pid, {:fetch_started, self()})

        receive do
          :proceed -> :ok
        end

        try do
          pump.(Stream.map(["a", "b"], & &1), "image/jpeg", fake_resolved_output(), nil)
        after
          send(test_pid, :bracket_cleanup)
        end
      end

      owner = spawn(fn -> receive do: (:stop -> :ok) end)

      config = [cache: {ObservingCache, test_pid: test_pid}]
      {:ok, coordinator} = Coordinator.start(build_fun, owner, fake_cache_key(), nil, config)
      coordinator_ref = Process.monitor(coordinator)

      prepare_task = Task.async(fn -> Coordinator.prepare(coordinator) end)
      assert_receive {:fetch_started, producer_pid}

      Process.exit(owner, :kill)
      assert {:error, {:session, {:owner_down, :killed}}} = Task.await(prepare_task)

      send(producer_pid, :proceed)

      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup
      refute_received {:cache_open_sink, _key, _metadata}
      assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason}
    end
  end

  describe "row 3: decode rejection" do
    test "returns 415 without opening a cache sink or cleanup bracket" do
      test_pid = self()

      config =
        opts(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               byte_identity: :strong,
               req_options: [plug: {CorruptImageOrigin, test_pid: test_pid}]}
          ],
          cache: {ObservingCache, test_pid: test_pid},
          on_bracket_exit: fn -> send(test_pid, :bracket_cleanup) end
        )

      conn = get("/images/cat.jpg?twic=v1/resize=64/output=jpeg", config)

      assert_received :origin_fetch
      assert conn.status == 415
      refute_received {:cache_open_sink, _key, _metadata}
      refute_received :bracket_cleanup
    end
  end

  describe "row 4: transform failure after partial work" do
    test "returns 422 after resize, opens no sink, and cleans up exactly once" do
      test_pid = self()

      chain = fn state, operations, chain_opts ->
        call_count = Process.get({__MODULE__, :chain_call_count}, 0) + 1
        Process.put({__MODULE__, :chain_call_count}, call_count)
        send(test_pid, {:chain_call, Enum.map(operations, & &1.__struct__)})

        case call_count do
          1 -> Chain.execute(state, operations, chain_opts)
          _later -> {:error, :forced_second_resize_failure}
        end
      end

      config =
        opts(
          cache: {ObservingCache, test_pid: test_pid},
          chain: chain,
          on_bracket_exit: fn -> send(test_pid, :bracket_cleanup) end
        )

      conn =
        get("/images/cat.jpg?twic=v1/resize=128/resize=50p/output=jpeg", config)

      assert conn.status == 422
      chain_calls = drain_chain_calls()
      assert length(chain_calls) >= 2
      assert Enum.all?(chain_calls, &(ExecutableResize in &1))
      refute_received {:cache_open_sink, _key, _metadata}
      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup
    end
  end

  describe "row 5: encoder failure after the first chunk" do
    test "keeps the committed 200, aborts the sink, and cleans up exactly once" do
      test_pid = self()

      config =
        opts(
          cache: {ObservingCache, test_pid: test_pid},
          image_module: RaisingAfterFirstChunkImage,
          on_bracket_exit: fn -> send(test_pid, :bracket_cleanup) end
        )

      log =
        capture_log(fn ->
          conn = get("/images/cat.jpg?twic=v1/resize=64/output=jpeg", config)
          assert conn.status == 200
          assert conn.state == :chunked
          assert conn.resp_body == "first chunk"
          assert get_resp_header(conn, "content-type") == ["image/jpeg"]
        end)

      assert log =~ "boom after first chunk"
      assert_received {:cache_open_sink, _key, _metadata}
      assert_received {:cache_write_chunk, "first chunk"}
      assert_received :cache_abort_sink
      refute_received :cache_commit_sink
      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup
    end
  end

  describe "row 6: cache lookup raises" do
    test "fails open, commits generated bytes, and cleans up exactly once" do
      test_pid = self()

      config =
        opts(
          cache: {RaisingGetCache, test_pid: test_pid},
          on_bracket_exit: fn -> send(test_pid, :bracket_cleanup) end
        )

      log =
        capture_log(fn ->
          conn = get("/images/cat.jpg?twic=v1/resize=64/output=jpeg", config)
          assert conn.status == 200
          assert {64, _height} = decoded_dims(conn.resp_body)
        end)

      assert log =~ "cache read error"
      assert_received :cache_open_sink
      assert_received :cache_commit_sink
      refute_received :cache_abort_sink
      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup
    end
  end

  describe "row 7: cache write fails" do
    test "fails open, aborts without commit, and cleans up exactly once" do
      test_pid = self()

      config =
        opts(
          cache: {FailingWriteCache, test_pid: test_pid},
          on_bracket_exit: fn -> send(test_pid, :bracket_cleanup) end
        )

      conn = get("/images/cat.jpg?twic=v1/resize=64/output=jpeg", config)

      assert conn.status == 200
      assert {64, _height} = decoded_dims(conn.resp_body)
      assert_received :cache_open_sink
      assert_received :cache_write_chunk_failed
      assert_received :cache_abort_sink
      refute_received :cache_commit_sink
      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup
    end
  end

  describe "row 8: producer cancellation" do
    test "aborts without commit, cleans up once, and tears down the session" do
      test_pid = self()
      build_fun = bracketed_build_fun(["a", "b", "c"], test_pid)
      config = [cache: {ObservingCache, test_pid: test_pid}]

      assert {:ok, prepared} =
               Delivery.stream(self(), build_fun, fake_cache_key(), %PlanResponse{}, config)

      assert prepared.first_chunk == "a"
      assert_received {:cache_open_sink, _key, _metadata}
      assert_received {:cache_write_chunk, "a"}
      assert :ok = prepared.cancel.()
      assert_received :cache_abort_sink
      refute_received :cache_commit_sink
      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup

      for coordinator <- SessionProbe.coordinators() do
        ref = Process.monitor(coordinator)
        assert_receive {:DOWN, ^ref, :process, ^coordinator, _reason}, 2_000
      end

      assert SessionProbe.coordinators() == []
    end
  end

  describe "row 9: response already sent" do
    test "post-completion next and cancel return noproc without double cleanup" do
      test_pid = self()
      build_fun = bracketed_build_fun(["a", "b"], test_pid)

      {:ok, coordinator} = Coordinator.start(build_fun, self(), fake_cache_key(), nil, [])
      coordinator_ref = Process.monitor(coordinator)

      assert {:ok, %{first_chunk: "a"}} = Coordinator.prepare(coordinator)
      assert {:chunk, "b"} = Coordinator.next(coordinator)
      assert :done = Coordinator.next(coordinator)
      assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :normal}
      assert_receive :bracket_cleanup
      refute_received :bracket_cleanup

      assert Coordinator.next(coordinator) == {:error, {:session, :noproc}}
      assert Coordinator.cancel(coordinator) == {:error, {:session, :noproc}}
    end
  end

  defp drain_chain_calls(acc \\ []) do
    receive do
      {:chain_call, structs} -> drain_chain_calls([structs | acc])
    after
      0 -> acc
    end
  end
end
