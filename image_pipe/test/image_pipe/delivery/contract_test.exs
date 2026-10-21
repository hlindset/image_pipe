defmodule ImagePipe.Delivery.ContractTest do
  @moduledoc """
  The `ImagePipe.Delivery` primitive's contract, exercised directly with a
  synthetic `build_fun` — the surface `ImagePipe.Execution` builds against.

  Trace-context propagation is the one part of the contract not covered here;
  it needs the global trace exporter and so lives in
  `ImagePipe.Delivery.TraceParentageTest` (`async: false`).
  """

  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Cost
  alias ImagePipe.Cache.Key
  alias ImagePipe.Debug.Info
  alias ImagePipe.Delivery
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Test.CacheObserver

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

  @hash String.duplicate("c3", 32)

  defp cache_key, do: %Key{hash: @hash, data: []}

  defp cache_config, do: CacheObserver.observe([])

  defp build_fun(debug) do
    fn pump -> pump.(Stream.map(["a", "b"], & &1), "image/jpeg", resolved_output(), debug) end
  end

  defp stream(cache_key, config, debug \\ nil) do
    Delivery.stream(build_fun(debug), cache_key, config)
  end

  # Reads the stream to EOF, which commits the cache entry.
  defp drain(prepared) do
    case prepared.next.() do
      {:chunk, _chunk} -> drain(prepared)
      :done -> :ok
    end
  end

  # ── the debug channel: producer → coordinator, on the first-chunk reply ──

  describe "debug info" do
    test "the %Info{} handed to pump reaches the PreparedStream" do
      debug = %Info{source_format: :png, output_format: :jpeg}

      assert {:ok, prepared} = stream(cache_key(), cache_config(), debug)

      assert prepared.debug.source_format == :png
      assert prepared.debug.output_format == :jpeg
      assert prepared.headers == []
    end

    test "the %Info{} handed to pump reaches the cache entry's stored metadata" do
      debug = %Info{source_format: :png, output_format: :jpeg}

      assert {:ok, prepared} = stream(cache_key(), cache_config(), debug)
      :ok = drain(prepared)

      assert_receive {:cache_open_sink, @hash, metadata}
      assert metadata.debug.source_format == :png
    end

    test "generation without debug info leaves both channels nil" do
      assert {:ok, prepared} = stream(cache_key(), cache_config(), nil)

      assert prepared.debug == nil
      :ok = drain(prepared)
      assert_receive {:cache_open_sink, @hash, metadata}
      assert metadata.debug == nil
    end
  end

  # ── cost_us: estimated from the debug info by the coordinator ────────────

  describe "generation cost" do
    test "the cache entry records the cost estimated from the debug info" do
      debug = %Info{
        source_format: :png,
        source_width: 400,
        source_height: 300,
        output_format: :jpeg,
        output_width: 200,
        output_height: 150
      }

      assert {:ok, prepared} = stream(cache_key(), cache_config(), debug)
      :ok = drain(prepared)

      assert_receive {:cache_open_sink, @hash, metadata}
      assert metadata.cost_us == Cost.render(debug, resolved_output())
      assert metadata.cost_us > 0
    end

    test "time to first chunk completes the producer's stage timings as :total" do
      debug = %Info{timings: %{decode: 1, encode: 2}}

      assert {:ok, prepared} = stream(cache_key(), cache_config(), debug)

      assert %{decode: 1, encode: 2, total: total} = prepared.debug.timings
      assert total > 0
    end
  end

  # ── a nil cache key: the request has caching off ─────────────────────────

  describe "nil cache key" do
    test "streams normally, stages nothing, and reports no cache key" do
      assert {:ok, prepared} = stream(nil, cache_config())

      assert prepared.first_chunk == "a"
      assert prepared.cache_key == nil
      :ok = drain(prepared)
      refute_received {:cache_open_sink, _hash, _metadata}
    end

    test "a cache key is reported by its hash" do
      assert {:ok, prepared} = stream(cache_key(), cache_config())

      assert prepared.cache_key == @hash
    end
  end
end
