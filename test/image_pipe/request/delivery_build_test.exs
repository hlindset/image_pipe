defmodule ImagePipe.Request.DeliveryBuildTest do
  @moduledoc """
  The framework's `ImagePipe.Delivery` build_fun, driven through the real
  `Delivery.stream/5` surface with a real plan/policy/resolved source.

  Ported from the retired supervised-session tests: cache staging (commit,
  abort, body limit, fail-open write errors), owner-death cleanup, and the
  fetch/decode/encode error taxonomy. `ImagePipe.Delivery.DeliveryLifecycleTest`
  covers the same session lifecycle with synthetic `build_fun`s; this file is
  the framework-shaped half — it is what proves the runner's *own* stages tag
  their errors and stage their bytes the way `ImagePipe.Response` expects.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ImagePipe.Cache.Key
  alias ImagePipe.Delivery
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Request.DeliveryBuild
  alias ImagePipe.Source.Resolved, as: ResolvedSource
  alias ImagePipe.SourceTest.ValidAdapter

  @event_target __MODULE__.StreamEvents

  defmodule MultiChunkImage do
    def stream!(_image, suffix: ".jpg"), do: ["first chunk", "second chunk"]
  end

  defmodule SmallChunkImage do
    def stream!(_image, suffix: ".jpg"), do: ["abc", "def"]
  end

  defmodule EmptyStreamImage do
    def stream!(_image, suffix: ".jpg"), do: []
  end

  defmodule CacheSinkProbe do
    @behaviour ImagePipe.Cache

    @impl true
    def get(_key, _opts), do: :miss

    @impl true
    def open_sink(key, metadata, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:cache_open_sink, key, metadata})
      {:ok, %{chunks: [], opts: opts}}
    end

    @impl true
    def write_chunk(state, chunk, _opts) do
      send(Keyword.fetch!(state.opts, :test_pid), {:cache_write_chunk, chunk})
      {:ok, %{state | chunks: [chunk | state.chunks]}}
    end

    @impl true
    def commit_sink(state, _opts) do
      send(
        Keyword.fetch!(state.opts, :test_pid),
        {:cache_commit_sink, Enum.reverse(state.chunks)}
      )

      :ok
    end

    @impl true
    def abort_sink(state, _opts) do
      send(Keyword.fetch!(state.opts, :test_pid), {:cache_abort_sink, Enum.reverse(state.chunks)})
      :ok
    end
  end

  defmodule CacheSinkWriteErrorProbe do
    @behaviour ImagePipe.Cache

    @impl true
    def get(_key, _opts), do: :miss

    @impl true
    def open_sink(_key, _metadata, opts), do: {:ok, %{opts: opts}}

    @impl true
    def write_chunk(state, _chunk, _opts) do
      send(Keyword.fetch!(state.opts, :test_pid), :cache_write_attempted)
      {:error, :write_failed, state}
    end

    @impl true
    def commit_sink(_state, _opts), do: :ok

    @impl true
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule CleanupStreamImage do
    @event_target ImagePipe.Request.DeliveryBuildTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {["first chunk"], :second}
          :second -> {["second chunk"], :done}
          :done -> {:halt, :done}
        end,
        fn state ->
          if target = Process.whereis(@event_target), do: send(target, {:stream_finalized, state})
        end
      )
    end
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
    @event_target ImagePipe.Request.DeliveryBuildTest.StreamEvents

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
    @event_target ImagePipe.Request.DeliveryBuildTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {["first chunk"], :raise}
          :raise -> raise ImagePipe.Source.StreamError, reason: :stream_exception
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:source_error_stream_finalized, state})
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

  setup do
    if Process.whereis(@event_target), do: Process.unregister(@event_target)
    Process.register(self(), @event_target)

    on_exit(fn ->
      if Process.whereis(@event_target), do: Process.unregister(@event_target)
    end)

    :ok
  end

  # -- fixtures --------------------------------------------------------------

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

  defp cache_key do
    %Key{
      hash: "test-cache-key",
      data: [source_identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]]]
    }
  end

  defp cache_opts(adapter, extra_opts) do
    [cache: {adapter, Keyword.merge([test_pid: self()], extra_opts)}]
  end

  defp stream_delivery(build_opts \\ []) do
    config = Keyword.get(build_opts, :opts, opts())
    source = Keyword.get(build_opts, :resolved_source, resolved_source())

    build_fun = DeliveryBuild.build_fun(plan(), source, output_policy(), config)

    Delivery.stream(
      self(),
      build_fun,
      Keyword.get(build_opts, :cache_key),
      %PlanResponse{},
      config
    )
  end

  defp cached_delivery(extra_opts) do
    config =
      opts()
      |> Keyword.merge(
        cache_opts(
          Keyword.get(extra_opts, :adapter, CacheSinkProbe),
          Keyword.get(extra_opts, :cache_opts, [])
        )
      )
      |> Keyword.merge(Keyword.get(extra_opts, :opts, []))

    stream_delivery(
      cache_key: Keyword.get(extra_opts, :cache_key, cache_key()),
      opts: config
    )
  end

  # Starts a delivery owned by a separate process, so owner death is testable.
  defp start_owned_cached_delivery(extra_opts) do
    parent = self()
    test_pid = self()

    config =
      opts()
      |> Keyword.merge(cache_opts(CacheSinkProbe, test_pid: test_pid))
      |> Keyword.merge(Keyword.get(extra_opts, :opts, []))

    build_fun = DeliveryBuild.build_fun(plan(), resolved_source(), output_policy(), config)

    owner =
      spawn(fn ->
        result = Delivery.stream(self(), build_fun, cache_key(), %PlanResponse{}, config)
        send(parent, {:delivery, self(), result})

        receive do
          :stop_owner -> :ok
        end
      end)

    assert_receive {:delivery, ^owner, result}, 5_000
    {owner, result}
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp attach_telemetry(events) do
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach_many(handler_id, events, &__MODULE__.handle_telemetry_event/4, self())

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # -- delivery --------------------------------------------------------------

  test "the first encoded chunk is ready before next is called" do
    assert {:ok, prepared} = stream_delivery()

    assert prepared.first_chunk == "first chunk"
    assert prepared.content_type == "image/jpeg"
    assert prepared.resolved_output.format == :jpeg
    assert :ok = prepared.cancel.()
  end

  test "next returns one encoded chunk per call and then done" do
    assert {:ok, prepared} = stream_delivery()

    assert prepared.first_chunk == "first chunk"
    assert {:chunk, "second chunk"} = prepared.next.()
    assert :done = prepared.next.()
  end

  test "prepare and next exercise the real Image stream path" do
    assert {:ok, prepared} = stream_delivery(opts: Keyword.delete(opts(), :image_module))

    assert prepared.content_type == "image/jpeg"
    assert is_binary(prepared.first_chunk)
    assert byte_size(prepared.first_chunk) > 0

    case prepared.next.() do
      {:chunk, chunk} ->
        assert is_binary(chunk)
        assert byte_size(chunk) > 0
        assert :ok = prepared.cancel.()

      :done ->
        :ok
    end
  end

  test "cancel halts the suspended continuation and finalizes the stream" do
    assert {:ok, prepared} = stream_delivery(opts: opts(image_module: CleanupStreamImage))

    assert :ok = prepared.cancel.()
    assert_receive {:stream_finalized, :second}
  end

  # -- the encode span and stage timings -------------------------------------

  # The first-chunk pull is what forces libvips to encode, so it must happen
  # inside the [:encode] span and the measured encode timing — not later, in
  # the delivery pump. A regression here would leave the span and the timing
  # measuring only encoder-pipeline construction, which no other test (and in
  # particular not the OTel parentage baseline) would catch.
  test "the encode timing covers the forced first-chunk pull, not just pipeline construction" do
    attach_telemetry([[:image_pipe, :encode, :stop]])

    assert {:ok, prepared} = stream_delivery(opts: Keyword.delete(opts(), :image_module))

    assert_received {:telemetry_event, [:image_pipe, :encode, :stop], measurements,
                     %{result: :ok, output_format: :jpeg}}

    assert measurements.duration > 0
    assert prepared.debug.timings.encode > 0

    # A real JPEG encode of the fixture is not free; construction alone would
    # be orders of magnitude below this.
    assert prepared.debug.timings.encode > 100
    assert :ok = prepared.cancel.()
  end

  # -- cache staging ---------------------------------------------------------

  test "cache staging commits staged chunks only after next reaches done" do
    attach_telemetry([[:image_pipe, :cache, :write, :stop]])

    key = cache_key()
    assert {:ok, prepared} = cached_delivery(cache_key: key)

    assert prepared.first_chunk == "first chunk"
    assert_received {:cache_write_chunk, "first chunk"}
    refute_received {:cache_commit_sink, _chunks}

    assert {:chunk, "second chunk"} = prepared.next.()
    assert_received {:cache_write_chunk, "second chunk"}
    refute_received {:cache_commit_sink, _chunks}

    assert :done = prepared.next.()

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

    assert {:ok, prepared} =
             cached_delivery(
               opts: [image_module: SmallChunkImage],
               cache_opts: [max_body_bytes: 5]
             )

    assert prepared.first_chunk == "abc"
    assert {:chunk, "def"} = prepared.next.()
    assert :done = prepared.next.()

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
    attach_telemetry([[:image_pipe, :cache, :stage]])

    assert {:ok, prepared} = cached_delivery(opts: [image_module: CleanupStreamImage])

    assert prepared.first_chunk == "first chunk"
    assert :ok = prepared.cancel.()

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
    attach_telemetry([[:image_pipe, :cache, :stage]])

    assert {:ok, prepared} = cached_delivery(opts: [image_module: RaisingAfterFirstChunkImage])

    assert prepared.first_chunk == "first chunk"

    assert {:error, {:encode, %RuntimeError{message: "boom after first chunk"}, stacktrace}} =
             prepared.next.()

    assert is_list(stacktrace)
    refute_received {:cache_commit_sink, _chunks}
    assert_received {:cache_abort_sink, ["first chunk"]}
    assert_receive {:raising_stream_finalized, :raise}
    refute_receive {:raising_stream_finalized, _state}, 200

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
    attach_telemetry([[:image_pipe, :cache, :stage]])

    {owner, {:ok, prepared}} =
      start_owned_cached_delivery(opts: [image_module: CleanupStreamImage])

    owner_ref = Process.monitor(owner)
    assert prepared.first_chunk == "first chunk"

    send(owner, :stop_owner)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    assert_receive {:cache_abort_sink, ["first chunk"]}, 2_000
    refute_received {:cache_commit_sink, _chunks}

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

  test "cache staging write errors fail open after stream completion" do
    attach_telemetry([[:image_pipe, :cache, :stage]])

    assert {:ok, prepared} = cached_delivery(adapter: CacheSinkWriteErrorProbe)

    assert prepared.first_chunk == "first chunk"
    assert {:chunk, "second chunk"} = prepared.next.()
    assert :done = prepared.next.()

    assert_received :cache_write_attempted

    assert_receive {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                    %{
                      result: :cache_error,
                      cache: :stage_error,
                      error: :write_failed,
                      output_format: :jpeg
                    }}
  end

  # -- error taxonomy --------------------------------------------------------

  test "source stream failures before the first chunk return source errors" do
    bad_stream = Stream.map([:raise], fn _ -> raise "raw stream failure" end)

    capture_log(fn ->
      assert {:error, {:source, :stream_exception}} =
               stream_delivery(
                 resolved_source: %{
                   resolved_source({:stream, bad_stream})
                   | fetch: {:stream, bad_stream}
                 },
                 opts: opts(sources: %{path: {StreamFetchAdapter, []}})
               )
    end)
  end

  test "empty encoder streams stay pre-response encode errors" do
    assert {:error, {:encode, :empty_stream}} =
             stream_delivery(opts: opts(image_module: EmptyStreamImage))
  end

  test "encoder failures before the first chunk stay pre-response encode errors" do
    assert {:error, {:encode, %RuntimeError{message: "boom before first chunk"}, stacktrace}} =
             stream_delivery(opts: opts(image_module: RaisingBeforeFirstChunkImage))

    assert is_list(stacktrace)
  end

  test "encoder failures after the first chunk become next errors" do
    assert {:ok, prepared} =
             stream_delivery(opts: opts(image_module: RaisingAfterFirstChunkImage))

    assert prepared.first_chunk == "first chunk"

    assert {:error, {:encode, %RuntimeError{message: "boom after first chunk"}, stacktrace}} =
             prepared.next.()

    assert is_list(stacktrace)
    assert_receive {:raising_stream_finalized, :raise}
    refute_receive {:raising_stream_finalized, _state}, 200
  end

  # The ruled taxonomy guarantee: a Source.StreamError raised while the encoder
  # stream is being reduced keeps the SOURCE phase (a source-domain status),
  # rather than degrading to the 500 an {:encode, _} tag produces.
  test "source stream errors during encoder reduction keep source phase" do
    assert {:ok, prepared} =
             stream_delivery(opts: opts(image_module: SourceErrorAfterFirstChunkImage))

    assert prepared.first_chunk == "first chunk"
    assert {:error, {:source, :stream_exception}} = prepared.next.()
    assert_receive {:source_error_stream_finalized, :raise}
    refute_receive {:source_error_stream_finalized, _state}, 200
  end
end
