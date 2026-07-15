defmodule ImagePipe.Delivery.ContractTest do
  @moduledoc """
  The `ImagePipe.Delivery` primitive's contract, exercised directly with a
  synthetic `build_fun` — the surface a calling dialect builds against.

  Trace-context propagation is the one part of the contract not covered here;
  it needs the global trace exporter and so lives in
  `ImagePipe.Delivery.TraceParentageTest` (`async: false`).
  """

  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Key
  alias ImagePipe.Debug.Info
  alias ImagePipe.Delivery
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Response, as: PlanResponse

  defmodule ObservingCacheProbe do
    @moduledoc false
    @behaviour ImagePipe.Cache

    @impl true
    def get(_key, _opts), do: :miss

    @impl true
    def open_sink(key, metadata, _opts) do
      send(target(), {:cache_open_sink, key, metadata})
      {:ok, %{}}
    end

    @impl true
    def write_chunk(state, _chunk, _opts), do: {:ok, state}

    @impl true
    def commit_sink(_state, _opts), do: :ok

    @impl true
    def abort_sink(_state, _opts), do: :ok

    defp target do
      [pid | _rest] = Process.get(:"$callers")
      pid
    end
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

  defp cache_key, do: %Key{hash: "test-key", data: []}

  defp build_fun(debug) do
    fn pump -> pump.(Stream.map(["a", "b"], & &1), "image/jpeg", resolved_output(), debug) end
  end

  defp stream(cache_key, config, debug \\ nil) do
    Delivery.stream(self(), build_fun(debug), cache_key, %PlanResponse{}, config)
  end

  # ── the debug channel: producer → coordinator, on the first-chunk reply ──

  describe "debug info" do
    test "the %Info{} handed to pump reaches the PreparedStream" do
      debug = %Info{source_format: :png, output_format: :jpeg}

      assert {:ok, prepared} = stream(cache_key(), [cache: {ObservingCacheProbe, []}], debug)

      assert prepared.debug.source_format == :png
      assert prepared.debug.output_format == :jpeg
    end

    test "the %Info{} handed to pump reaches the cache entry's stored metadata" do
      debug = %Info{source_format: :png, output_format: :jpeg}

      assert {:ok, _prepared} = stream(cache_key(), [cache: {ObservingCacheProbe, []}], debug)

      assert_received {:cache_open_sink, _key, metadata}
      assert metadata.debug.source_format == :png
    end

    test "a dialect that collects no debug info leaves both channels nil" do
      assert {:ok, prepared} = stream(cache_key(), [cache: {ObservingCacheProbe, []}], nil)

      assert prepared.debug == nil
      assert_received {:cache_open_sink, _key, metadata}
      assert metadata.debug == nil
    end
  end

  # ── cost_us: time-to-first-chunk, measured by the coordinator ────────────

  describe "generation cost" do
    test "the cache entry records a real cost_us, which cache admission scores by" do
      assert {:ok, _prepared} = stream(cache_key(), cache: {ObservingCacheProbe, []})

      assert_received {:cache_open_sink, _key, metadata}
      assert metadata.cost_us > 0
    end

    test "cost_us completes the producer's stage timings as :total" do
      debug = %Info{timings: %{decode: 1, encode: 2}}

      assert {:ok, prepared} = stream(cache_key(), [cache: {ObservingCacheProbe, []}], debug)

      assert %{decode: 1, encode: 2, total: total} = prepared.debug.timings
      assert total > 0
    end
  end

  # ── a nil cache key: the calling dialect has caching off ─────────────────

  describe "nil cache key" do
    test "streams normally, stages nothing, and reports no cache key" do
      assert {:ok, prepared} = stream(nil, cache: {ObservingCacheProbe, []})

      assert prepared.first_chunk == "a"
      assert prepared.cache_key == nil
      refute_received {:cache_open_sink, _key, _metadata}
    end

    test "a cache key is reported by its hash" do
      assert {:ok, prepared} = stream(cache_key(), cache: {ObservingCacheProbe, []})

      assert prepared.cache_key == "test-key"
    end
  end
end
