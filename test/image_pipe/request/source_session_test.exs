defmodule ImagePipe.Request.SourceSessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ImagePipe.Cache.Key
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Request.SourceSession
  alias ImagePipe.Request.SourceSession.Prepared
  alias ImagePipe.Request.SourceSession.Request
  alias ImagePipe.Source.Resolved, as: ResolvedSource
  alias ImagePipe.SourceTest.ValidAdapter

  defmodule MultiChunkImage do
    def stream!(_image, suffix: ".jpg"), do: ["first chunk", "second chunk"]
  end

  defmodule SmallChunkImage do
    def stream!(_image, suffix: ".jpg"), do: ["abc", "def"]
  end

  defmodule CacheSinkProbe do
    @behaviour ImagePipe.Cache

    def get(_key, _opts), do: :miss

    def open_sink(key, metadata, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:cache_open_sink, key, metadata})
      {:ok, %{chunks: [], opts: opts}}
    end

    def write_chunk(state, chunk, _opts) do
      send(Keyword.fetch!(state.opts, :test_pid), {:cache_write_chunk, chunk})
      {:ok, %{state | chunks: [chunk | state.chunks]}}
    end

    def commit_sink(state, _opts) do
      send(
        Keyword.fetch!(state.opts, :test_pid),
        {:cache_commit_sink, Enum.reverse(state.chunks)}
      )

      :ok
    end

    def abort_sink(state, _opts) do
      send(Keyword.fetch!(state.opts, :test_pid), {:cache_abort_sink, Enum.reverse(state.chunks)})
      :ok
    end
  end

  defmodule CacheSinkWriteErrorProbe do
    @behaviour ImagePipe.Cache

    def get(_key, _opts), do: :miss

    def open_sink(_key, _metadata, opts), do: {:ok, %{opts: opts}}

    def write_chunk(state, _chunk, _opts) do
      send(Keyword.fetch!(state.opts, :test_pid), :cache_write_attempted)
      {:error, :write_failed, state}
    end

    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule CleanupStreamImage do
    @event_target ImagePipe.Request.SourceSessionTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {["first chunk"], :second}
          :second -> {["second chunk"], :done}
          :done -> {:halt, :done}
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:stream_finalized, state})
          end
        end
      )
    end
  end

  defmodule BlockingFetchAdapter do
    @behaviour ImagePipe.Source

    alias ImagePipe.Source.Resolved

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts), do: {:error, {:source, :not_used}}

    @impl ImagePipe.Source
    def fetch(%Resolved{fetch: {:block, test_pid}}, _opts, _runtime_opts) do
      send(test_pid, {:fetch_started, self()})

      receive do
        :release_fetch -> {:error, {:source, :released}}
      end
    end
  end

  defmodule EmptyStreamImage do
    def stream!(_image, suffix: ".jpg"), do: []
  end

  defmodule RaisingBeforeFirstChunkImage do
    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :raise end,
        fn :raise -> raise "boom before first chunk" end,
        fn _state -> :ok end
      )
    end
  end

  defmodule RaisingAfterFirstChunkImage do
    @event_target ImagePipe.Request.SourceSessionTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {["first chunk"], :raise}
          :raise -> raise "boom after first chunk"
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:raising_stream_finalized, state})
          end
        end
      )
    end
  end

  defmodule SourceErrorAfterFirstChunkImage do
    @event_target ImagePipe.Request.SourceSessionTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first ->
            {["first chunk"], :raise}

          :raise ->
            raise ImagePipe.Source.StreamError, reason: :stream_exception
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:source_error_stream_finalized, state})
          end
        end
      )
    end
  end

  defmodule OwnerDownBeforeDoneImage do
    @event_target ImagePipe.Request.SourceSessionTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first ->
            {["first chunk"], :finish}

          :finish ->
            if target = Process.whereis(@event_target) do
              send(target, {:before_stream_done, self()})
            end

            receive do
              :continue_stream_done -> {[], :done}
            end

          :done ->
            {:halt, :done}
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:owner_down_stream_finalized, state})
          end
        end
      )
    end
  end

  defmodule OwnerDownBeforeSecondChunkImage do
    @event_target ImagePipe.Request.SourceSessionTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first ->
            {["first chunk"], :second}

          :second ->
            if target = Process.whereis(@event_target) do
              send(target, {:before_second_chunk, self()})
            end

            receive do
              :continue_second_chunk -> {["second chunk"], :done}
            end

          :done ->
            {:halt, :done}
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:owner_down_second_chunk_finalized, state})
          end
        end
      )
    end
  end

  defmodule LinkedExitAfterFirstChunkImage do
    @event_target ImagePipe.Request.SourceSessionTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn ->
          helper =
            spawn_link(fn ->
              receive do
                :boom -> exit(:boom)
              end
            end)

          if target = Process.whereis(@event_target) do
            send(target, {:linked_exit_helper, helper})
          end

          :first
        end,
        fn
          :first -> {["first chunk"], :second}
          :second -> {["second chunk"], :done}
          :done -> {:halt, :done}
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:linked_exit_stream_finalized, state})
          end
        end
      )
    end
  end

  defmodule StreamFetchAdapter do
    @behaviour ImagePipe.Source

    alias ImagePipe.Source.Resolved
    alias ImagePipe.Source.Response

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts), do: {:error, {:source, :not_used}}

    @impl ImagePipe.Source
    def fetch(%Resolved{fetch: {:stream, stream}}, _opts, _runtime_opts) do
      {:ok, %Response{stream: stream}}
    end
  end

  test "request struct carries source session inputs without Plug.Conn" do
    request = request()

    assert %Request{} = request
    assert %Plan{} = request.plan
    assert %ResolvedSource{} = request.resolved_source
    assert %Policy{} = request.output_policy
    assert is_list(request.opts)
    refute Map.has_key?(Map.from_struct(request), :conn)
  end

  test "prepared struct carries the first non-empty encoded chunk" do
    prepared = %Prepared{
      first_chunk: "first chunk",
      content_type: "image/jpeg",
      headers: [],
      resolved_output: resolved_output()
    }

    assert prepared.first_chunk == "first chunk"
    assert prepared.content_type == "image/jpeg"
    assert prepared.headers == []
  end

  test "prepare returns the first encoded chunk before next is called" do
    {:ok, session} = start_session(request())

    assert {:ok, %Prepared{} = prepared} = SourceSession.prepare(session)
    assert prepared.first_chunk == "first chunk"
    assert prepared.content_type == "image/jpeg"
    assert prepared.headers == []
    assert prepared.resolved_output.format == :jpeg
    assert :ok = SourceSession.cancel(session)
  end

  test "next returns one encoded chunk per call and then done" do
    {:ok, session} = start_session(request())

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    assert {:chunk, "second chunk"} = SourceSession.next(session)
    assert :done = SourceSession.next(session)
  end

  test "cache staging commits staged chunks only after next reaches done" do
    attach_telemetry([[:image_pipe, :cache, :write, :stop]])

    key = cache_key()
    {:ok, session} = start_session(cached_request(cache_key: key))

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    assert_received {:cache_write_chunk, "first chunk"}
    refute_received {:cache_commit_sink, _chunks}

    assert {:chunk, "second chunk"} = SourceSession.next(session)
    assert_received {:cache_write_chunk, "second chunk"}
    refute_received {:cache_commit_sink, _chunks}

    assert :done = SourceSession.next(session)

    assert_received {:cache_open_sink, ^key, metadata}
    assert metadata.content_type == "image/jpeg"
    assert metadata.headers == []
    assert %DateTime{} = metadata.created_at
    assert metadata.output_format == :jpeg
    assert_received {:cache_commit_sink, ["first chunk", "second chunk"]}

    assert_receive {:telemetry_event, [:image_pipe, :cache, :write, :stop], _measurements,
                    %{result: :ok, cache: :write, output_format: :jpeg}}
  end

  test "cache staging stops when the cache body limit is crossed" do
    attach_telemetry([[:image_pipe, :cache, :stage]])

    {:ok, session} =
      start_session(
        cached_request(
          opts: opts(image_module: SmallChunkImage),
          cache_opts: [max_body_bytes: 5]
        )
      )

    assert {:ok, %Prepared{first_chunk: "abc"}} = SourceSession.prepare(session)
    assert {:chunk, "def"} = SourceSession.next(session)
    assert :done = SourceSession.next(session)

    refute_received {:cache_commit_sink, _chunks}

    assert_receive {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                    %{
                      result: :ok,
                      cache: :stage_skipped,
                      reason: :too_large,
                      output_format: :jpeg
                    }}
  end

  test "cache staging aborts staged chunks on explicit cancellation" do
    register_stream_events!()
    attach_telemetry([[:image_pipe, :cache, :stage]])

    {:ok, session} =
      start_session(cached_request(opts: opts(image_module: CleanupStreamImage)))

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    assert :ok = SourceSession.cancel(session)

    refute_received {:cache_commit_sink, _chunks}
    assert_received {:cache_abort_sink, ["first chunk"]}
    assert_receive {:stream_finalized, :second}

    assert_receive {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                    %{
                      result: :ok,
                      cache: :stage_abandoned,
                      reason: :cancelled,
                      output_format: :jpeg
                    }}

    refute_received {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                     %{cache: :stage_abandoned}}
  end

  test "cache staging aborts staged chunks on post-first-chunk stream errors" do
    register_stream_events!()
    attach_telemetry([[:image_pipe, :cache, :stage]])

    {:ok, session} =
      start_session(cached_request(opts: opts(image_module: RaisingAfterFirstChunkImage)))

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    assert {:error, {:encode, %RuntimeError{message: "boom after first chunk"}, stacktrace}} =
             SourceSession.next(session)

    assert is_list(stacktrace)
    refute_received {:cache_commit_sink, _chunks}
    assert_received {:cache_abort_sink, ["first chunk"]}
    assert_receive {:raising_stream_finalized, :raise}

    assert_receive {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                    %{
                      result: :ok,
                      cache: :stage_abandoned,
                      reason: :stream_error,
                      output_format: :jpeg
                    }}

    refute_received {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                     %{cache: :stage_abandoned}}
  end

  test "cache staging aborts staged chunks on owner death" do
    register_stream_events!()
    attach_telemetry([[:image_pipe, :cache, :stage]])

    owner =
      start_test_process(fn ->
        receive do
          :stop_owner -> :ok
        end
      end)

    {:ok, session} =
      start_session(
        cached_request(opts: opts(image_module: CleanupStreamImage)),
        owner: owner,
        parent: self()
      )

    session_ref = Process.monitor(session)
    owner_ref = Process.monitor(owner)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    send(owner, :stop_owner)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:DOWN, ^session_ref, :process, ^session, {:shutdown, {:owner_down, :normal}}}
    refute_received {:cache_commit_sink, _chunks}
    assert_received {:cache_abort_sink, ["first chunk"]}

    assert_receive {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                    %{
                      result: :ok,
                      cache: :stage_abandoned,
                      reason: :owner_down,
                      output_format: :jpeg
                    }}

    refute_received {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                     %{cache: :stage_abandoned}}
  end

  test "cache staging checks pending owner death before committing at done" do
    register_stream_events!()
    attach_telemetry([[:image_pipe, :cache, :stage]])

    owner =
      start_test_process(fn ->
        receive do
          :stop_owner -> :ok
        end
      end)

    {:ok, session} =
      start_session(
        cached_request(opts: opts(image_module: OwnerDownBeforeDoneImage)),
        owner: owner,
        parent: self()
      )

    session_ref = Process.monitor(session)
    owner_ref = Process.monitor(owner)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    parent = self()

    caller =
      start_test_process(fn ->
        send(parent, {:next_result, SourceSession.next(session)})
      end)

    caller_ref = Process.monitor(caller)

    assert_receive {:before_stream_done, producer_pid}
    producer_ref = Process.monitor(producer_pid)
    send(owner, :stop_owner)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    assert_receive {:next_result, {:error, {:session, {:shutdown, {:owner_down, :normal}}}}}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert_receive {:DOWN, ^producer_ref, :process, ^producer_pid, :shutdown}
    assert_receive {:DOWN, ^session_ref, :process, ^session, {:shutdown, {:owner_down, :normal}}}
    refute_received {:cache_commit_sink, _chunks}
    assert_received {:cache_abort_sink, ["first chunk"]}

    assert_receive {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                    %{
                      result: :ok,
                      cache: :stage_abandoned,
                      reason: :owner_down,
                      output_format: :jpeg
                    }}
  end

  test "next checks pending owner death before returning later chunks" do
    register_stream_events!()
    attach_telemetry([[:image_pipe, :cache, :stage]])

    owner =
      start_test_process(fn ->
        receive do
          :stop_owner -> :ok
        end
      end)

    {:ok, session} =
      start_session(
        cached_request(opts: opts(image_module: OwnerDownBeforeSecondChunkImage)),
        owner: owner,
        parent: self()
      )

    session_ref = Process.monitor(session)
    owner_ref = Process.monitor(owner)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    parent = self()

    caller =
      start_test_process(fn ->
        send(parent, {:next_result, SourceSession.next(session)})
      end)

    caller_ref = Process.monitor(caller)

    assert_receive {:before_second_chunk, producer_pid}
    producer_ref = Process.monitor(producer_pid)
    send(owner, :stop_owner)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    assert_receive {:next_result, {:error, {:session, {:shutdown, {:owner_down, :normal}}}}}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert_receive {:DOWN, ^producer_ref, :process, ^producer_pid, :shutdown}
    assert_receive {:DOWN, ^session_ref, :process, ^session, {:shutdown, {:owner_down, :normal}}}
    refute_received {:cache_commit_sink, _chunks}
    assert_received {:cache_abort_sink, ["first chunk"]}

    assert_receive {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                    %{
                      result: :ok,
                      cache: :stage_abandoned,
                      reason: :owner_down,
                      output_format: :jpeg
                    }}
  end

  test "cache staging write errors fail open after stream completion" do
    attach_telemetry([[:image_pipe, :cache, :stage]])

    {:ok, session} =
      start_session(cached_request(adapter: CacheSinkWriteErrorProbe))

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    assert {:chunk, "second chunk"} = SourceSession.next(session)
    assert :done = SourceSession.next(session)

    assert_received :cache_write_attempted

    assert_receive {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                    %{
                      result: :cache_error,
                      cache: :stage_error,
                      error: :write_failed,
                      output_format: :jpeg
                    }}
  end

  test "prepare and next exercise the real Image stream path" do
    {:ok, session} = start_session(request(opts: real_image_opts()))

    assert {:ok, %Prepared{first_chunk: first_chunk, content_type: "image/jpeg"}} =
             SourceSession.prepare(session)

    assert is_binary(first_chunk)
    assert byte_size(first_chunk) > 0

    case SourceSession.next(session) do
      {:chunk, chunk} ->
        assert is_binary(chunk)
        assert byte_size(chunk) > 0
        assert :ok = SourceSession.cancel(session)

      :done ->
        :ok
    end
  end

  test "cancel halts the suspended continuation and stops the session normally" do
    register_stream_events!()
    {:ok, session} = start_session(request(opts: opts(image_module: CleanupStreamImage)))
    ref = Process.monitor(session)

    assert {:ok, %Prepared{}} = SourceSession.prepare(session)
    assert :ok = SourceSession.cancel(session)
    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end

  test "next before prepare returns a tagged protocol error" do
    {:ok, session} = start_session(request())

    assert {:error, {:protocol, :not_prepared}} = SourceSession.next(session)
    assert :ok = SourceSession.cancel(session)
  end

  test "call wrappers return tagged errors for missing sessions" do
    dead_pid =
      start_test_process(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(dead_pid)
    send(dead_pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^dead_pid, :normal}

    assert {:error, {:session, :noproc}} = SourceSession.prepare(dead_pid)
  end

  test "call wrappers return tagged timeout errors" do
    {:ok, session} = start_session(blocking_request(), owner: self())
    ref = Process.monitor(session)
    parent = self()

    caller =
      start_test_process(fn ->
        send(parent, {:prepare_result, SourceSession.prepare(session, 100)})
      end)

    caller_ref = Process.monitor(caller)

    assert_receive {:fetch_started, producer_pid}, 1_000
    assert_receive {:prepare_result, {:error, {:session, :timeout}}}, 1_000
    send(producer_pid, :release_fetch)

    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
  end

  test "owner death during in-flight prepare replies and stops producer" do
    owner =
      start_test_process(fn ->
        receive do
          :stop_owner -> :ok
        end
      end)

    {:ok, session} = start_session(blocking_request(), owner: owner, parent: self())
    session_ref = Process.monitor(session)
    owner_ref = Process.monitor(owner)
    parent = self()

    caller =
      start_test_process(fn ->
        send(parent, {:prepare_result, SourceSession.prepare(session, 5_000)})
      end)

    caller_ref = Process.monitor(caller)

    assert_receive {:fetch_started, producer_pid}
    producer_ref = Process.monitor(producer_pid)
    send(owner, :stop_owner)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    assert_receive {:prepare_result, {:error, {:session, {:shutdown, {:owner_down, :normal}}}}}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert_receive {:DOWN, ^producer_ref, :process, ^producer_pid, :shutdown}
    assert_receive {:DOWN, ^session_ref, :process, ^session, {:shutdown, {:owner_down, :normal}}}
  end

  test "cancel during pending next replies to pending caller before stopping" do
    register_stream_events!()

    {:ok, session} =
      start_session(
        cached_request(opts: opts(image_module: OwnerDownBeforeSecondChunkImage)),
        parent: self()
      )

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    parent = self()

    caller =
      start_test_process(fn ->
        send(parent, {:next_result, SourceSession.next(session, 5_000)})
      end)

    caller_ref = Process.monitor(caller)
    session_ref = Process.monitor(session)

    assert_receive {:before_second_chunk, producer_pid}
    producer_ref = Process.monitor(producer_pid)

    assert :ok = SourceSession.cancel(session)
    assert_receive {:next_result, {:error, {:session, :cancelled}}}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert_receive {:DOWN, ^producer_ref, :process, ^producer_pid, :shutdown}
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}
  end

  test "owner death cancels the session once the active callback yields" do
    register_stream_events!()

    owner =
      start_test_process(fn ->
        receive do
          :stop_owner -> :ok
        end
      end)

    {:ok, session} =
      start_session(
        request(opts: opts(image_module: CleanupStreamImage)),
        owner: owner,
        parent: self()
      )

    session_ref = Process.monitor(session)
    owner_ref = Process.monitor(owner)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    send(owner, :stop_owner)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:DOWN, ^session_ref, :process, ^session, {:shutdown, {:owner_down, :normal}}}
  end

  test "source stream failures before the first chunk return source errors" do
    bad_stream = Stream.map([:raise], fn _ -> raise "raw stream failure" end)

    request =
      request(
        resolved_source: %{resolved_source({:stream, bad_stream}) | fetch: {:stream, bad_stream}},
        opts: opts(sources: %{path: {StreamFetchAdapter, []}}, image_module: MultiChunkImage)
      )

    {:ok, session} = start_session(request)
    ref = Process.monitor(session)

    capture_log(fn ->
      assert {:error, {:source, :stream_exception}} = SourceSession.prepare(session)
    end)

    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end

  test "empty encoder streams stay pre-response encode errors" do
    {:ok, session} = start_session(request(opts: opts(image_module: EmptyStreamImage)))
    ref = Process.monitor(session)

    assert {:error, {:encode, :empty_stream}} = SourceSession.prepare(session)

    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end

  test "encoder failures before the first chunk stay pre-response encode errors" do
    {:ok, session} =
      start_session(request(opts: opts(image_module: RaisingBeforeFirstChunkImage)))

    ref = Process.monitor(session)

    assert {:error, {:encode, %RuntimeError{message: "boom before first chunk"}, stacktrace}} =
             SourceSession.prepare(session)

    assert is_list(stacktrace)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end

  test "encoder failures after the first chunk become next errors" do
    register_stream_events!()

    {:ok, session} =
      start_session(request(opts: opts(image_module: RaisingAfterFirstChunkImage)))

    ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    assert {:error, {:encode, %RuntimeError{message: "boom after first chunk"}, stacktrace}} =
             SourceSession.next(session)

    assert is_list(stacktrace)
    assert_receive {:raising_stream_finalized, :raise}
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end

  test "source stream errors during encoder reduction keep source phase" do
    register_stream_events!()

    {:ok, session} =
      start_session(request(opts: opts(image_module: SourceErrorAfterFirstChunkImage)))

    ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    assert {:error, {:source, :stream_exception}} = SourceSession.next(session)
    assert_receive {:source_error_stream_finalized, :raise}
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end

  defp start_session(%Request{} = request, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:owner, self())
      |> Keyword.put_new(:parent, self())

    child_spec = %{
      id: {SourceSession, make_ref()},
      start: {SourceSession, :start_link, [request, opts]},
      restart: :temporary,
      shutdown: 2_000,
      type: :worker
    }

    {:ok, start_supervised!(child_spec)}
  end

  defp start_test_process(fun) when is_function(fun, 0) do
    supervisor =
      start_supervised!(%{
        id: {Task.Supervisor, make_ref()},
        start: {Task.Supervisor, :start_link, [[name: nil]]},
        restart: :temporary,
        type: :supervisor
      })

    {:ok, pid} = Task.Supervisor.start_child(supervisor, fun)
    pid
  end

  defp request(overrides \\ []) do
    %Request{
      plan: Keyword.get(overrides, :plan, plan()),
      resolved_source: Keyword.get(overrides, :resolved_source, resolved_source()),
      output_policy: Keyword.get(overrides, :output_policy, output_policy()),
      opts: Keyword.get(overrides, :opts, opts()),
      cache_key: Keyword.get(overrides, :cache_key)
    }
  end

  defp cache_key do
    %Key{
      hash: "test-cache-key",
      data: [source_identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]]]
    }
  end

  defp cache_opts(adapter, extra_opts) do
    [
      cache: {adapter, Keyword.merge([test_pid: self()], extra_opts)}
    ]
  end

  defp cached_request(extra_opts) do
    request(
      cache_key: Keyword.get(extra_opts, :cache_key, cache_key()),
      opts:
        opts()
        |> Keyword.merge(
          cache_opts(
            Keyword.get(extra_opts, :adapter, CacheSinkProbe),
            Keyword.get(extra_opts, :cache_opts, [])
          )
        )
        |> Keyword.merge(Keyword.get(extra_opts, :opts, []))
    )
  end

  defp plan do
    %Plan{
      source: %Path{segments: ["images", "beach.jpg"]},
      pipelines: [%Pipeline{operations: []}],
      output: %Output{mode: {:explicit, :jpeg}}
    }
  end

  defp resolved_source(fetch \\ :fixture) do
    %ResolvedSource{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]],
      internal_cache: :enabled,
      http_cache: :inherit,
      cache_semantics: %ImagePipe.Source.CacheSemantics{byte_identity: :none, stable?: false},
      fetch: fetch
    }
  end

  defp output_policy do
    %Policy{
      mode: {:explicit, :jpeg},
      modern_candidates: [],
      headers: [],
      quality: :default,
      format_qualities: %{},
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  defp resolved_output do
    %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  defp opts(extra_opts \\ []) do
    Keyword.merge(
      [
        sources: %{path: {ValidAdapter, []}},
        image_module: MultiChunkImage,
        max_body_bytes: 10_000_000,
        max_input_pixels: 40_000_000,
        max_result_width: 8_192,
        max_result_height: 8_192,
        max_result_pixels: 40_000_000
      ],
      extra_opts
    )
  end

  defp real_image_opts do
    opts() |> Keyword.delete(:image_module)
  end

  defp blocking_request do
    request(
      resolved_source: %{resolved_source({:block, self()}) | fetch: {:block, self()}},
      opts: opts(sources: %{path: {BlockingFetchAdapter, []}}, image_module: MultiChunkImage)
    )
  end

  defp register_stream_events! do
    if Process.whereis(__MODULE__.StreamEvents) do
      Process.unregister(__MODULE__.StreamEvents)
    end

    Process.register(self(), __MODULE__.StreamEvents)

    on_exit(fn ->
      if Process.whereis(__MODULE__.StreamEvents) do
        Process.unregister(__MODULE__.StreamEvents)
      end
    end)
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp attach_telemetry(events) do
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
