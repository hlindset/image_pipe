defmodule ImagePipe.ContractKit.RequestSafety do
  @moduledoc """
  Executable contract kit for request-safety promises [pipelines design
  §Enforcement model, layer 4]: `use ImagePipe.ContractKit.RequestSafety,
  dialect: SomeDialect` generates ExUnit tests that make real
  `SomeDialect.call/2` requests and assert:

    * every rejectable request returns its declared status AND never
      touches the source or the cache (instrumented adapters, wired by this
      kit, prove it rather than asserting on internal call graphs);
    * a valid request's own ETag, echoed back as `If-None-Match`, returns
      `304` without a source fetch;
    * a valid request emits `[:request]` and `[:parse]` telemetry
      `:start`/`:stop` spans under a kit-owned, per-test-run unique
      `telemetry_prefix` (never the shared default prefix — see the
      `AGENTS.md` telemetry test guideline on cross-test telemetry leakage).

  The using module supplies concrete paths via the callbacks below; the
  functions in this module (called from the small generated `test` bodies)
  own request execution and the assertions. Reuses the existing wire-test
  rig: `ImagePipe.SourceTest.RootHTTPAdapter` as the source adapter,
  `ImgproxyWireConformanceTest.CountingOriginImage`/`OriginShouldNotFetch` as
  origin plugs, and `ImgproxyWireConformanceTest.CacheProbe` to observe
  cache access.
  """

  import ExUnit.Assertions
  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]
  import Plug.Test, only: [conn: 2]

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.CountingOriginImage
  alias ImgproxyWireConformanceTest.OriginShouldNotFetch

  @typedoc "A request-target path (dialect-specific wire syntax)."
  @type path :: String.t()

  @typedoc """
  A rejectable-request case: a path, its expected 4xx status, and optional
  per-case config overrides (e.g. `keys: [...]` for a signature case),
  merged onto `base_opts`. The 2-tuple form omits overrides (equivalent to
  `opts: []`).
  """
  @type rejectable_case :: {path, 400..499} | {path, 400..499, keyword()}

  @doc """
  Returns representative rejectable requests: a path, its expected 4xx
  status, and (optionally) per-case config overrides. `base_opts` is the
  kit's starter config (currently just `:sources`) — every rejectable
  request is run against `Keyword.merge(base_opts, item_opts)` (the kit
  adds its own instrumented source/cache adapters). Covers reject-before-
  fetch checkpoints across the request lifecycle: parse-stage 400s,
  signature-verification 403s, and past-`expires` 404s — every checkpoint
  must prove it never touches the source or the cache.
  """
  @callback rejectable_requests(base_opts :: keyword()) :: [rejectable_case]

  @doc "Returns a path for a plain, valid request (expected to return 200)."
  @callback valid_request(base_opts :: keyword()) :: path

  defmacro __using__(opts) do
    dialect = Keyword.fetch!(opts, :dialect)

    quote do
      use ExUnit.Case, async: true

      alias ImagePipe.ContractKit.RequestSafety, as: ContractKitRequestSafety

      @behaviour ImagePipe.ContractKit.RequestSafety

      @contract_kit_request_safety_dialect unquote(dialect)

      test "rejectable_requests/1 fail with the declared status and never touch source or cache" do
        ContractKitRequestSafety.assert_rejectable_requests(
          @contract_kit_request_safety_dialect,
          rejectable_requests(ContractKitRequestSafety.base_opts())
        )
      end

      test "valid_request/1's own ETag on If-None-Match returns 304 without a source fetch" do
        ContractKitRequestSafety.assert_conditional_get_skips_fetch(
          @contract_kit_request_safety_dialect,
          valid_request(ContractKitRequestSafety.base_opts())
        )
      end

      test "valid_request/1 emits [:request] and [:parse] telemetry start/stop under a kit-owned prefix" do
        ContractKitRequestSafety.assert_telemetry_stages(
          @contract_kit_request_safety_dialect,
          valid_request(ContractKitRequestSafety.base_opts())
        )
      end
    end
  end

  # ── kit-owned config assembly ────────────────────────────────────────────

  @doc false
  @spec base_opts() :: keyword()
  def base_opts do
    [
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://contract-kit-request-safety.test",
           req_options: [plug: {CountingOriginImage, test_pid: self()}]}
      ]
    ]
  end

  @doc false
  def build_config(dialect, opts) do
    config = dialect.init(Keyword.merge(opts, cache: {CacheProbe, []}))
    Keyword.merge(config, output_capabilities: %{avif: true, webp: true, jpeg_xl: true})
  end

  defp no_fetch_config(dialect, opts) do
    no_fetch_sources = [
      path:
        {RootHTTPAdapter,
         root_url: "http://contract-kit-request-safety.test",
         req_options: [plug: OriginShouldNotFetch]}
    ]

    build_config(dialect, Keyword.put(opts, :sources, no_fetch_sources))
  end

  # ── generated-test bodies ────────────────────────────────────────────────

  @doc false
  def assert_rejectable_requests(dialect, cases) do
    refute Enum.empty?(cases), "rejectable_requests/1 must return at least one case"

    for item <- cases do
      {path, expected_status, opts} = normalize_rejectable_case(item)
      config = build_config(dialect, Keyword.merge(base_opts(), opts))

      conn = dialect.call(conn(:get, path), config)

      assert conn.status == expected_status,
             "expected #{path} to return #{expected_status}, got #{conn.status}"

      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
      refute_received {:cache_put, _key, _body}
    end
  end

  defp normalize_rejectable_case({path, expected_status}), do: {path, expected_status, []}

  defp normalize_rejectable_case({path, expected_status, opts}),
    do: {path, expected_status, opts}

  @doc false
  def assert_conditional_get_skips_fetch(dialect, path) do
    config = build_config(dialect, base_opts())

    plain_conn = dialect.call(conn(:get, path), config)
    assert plain_conn.status == 200
    assert [etag] = get_resp_header(plain_conn, "etag")
    # Drain the plain request's own fetch signal so it can't be mistaken for
    # one triggered by the conditional request below.
    assert_received :origin_fetch

    conditional_conn =
      conn(:get, path)
      |> put_req_header("if-none-match", etag)
      |> then(&dialect.call(&1, no_fetch_config(dialect, base_opts())))

    assert conditional_conn.status == 304
    assert conditional_conn.resp_body == ""
    # No `refute_received :origin_fetch` here: `no_fetch_config`'s origin is
    # `OriginShouldNotFetch`, which raises (rather than sending a message) on
    # any fetch attempt — a fetch would already have crashed this test above.
  end

  @doc false
  def assert_telemetry_stages(dialect, path) do
    prefix = [:"contract_kit_request_safety_#{System.unique_integer([:positive])}"]
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    events =
      Enum.flat_map([:request, :parse], fn stage ->
        [prefix ++ [stage, :start], prefix ++ [stage, :stop]]
      end)

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, _measurements, _metadata, _config ->
        send(test_pid, {:telemetry_event, event})
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)

    config = build_config(dialect, Keyword.put(base_opts(), :telemetry_prefix, prefix))
    conn = dialect.call(conn(:get, path), config)
    assert conn.status == 200

    expected = MapSet.new(events)

    received =
      Enum.reduce(1..length(events), MapSet.new(), fn _n, acc ->
        assert_receive {:telemetry_event, event}
        MapSet.put(acc, event)
      end)

    assert received == expected,
           "expected telemetry events #{inspect(expected)}, got: #{inspect(received)}"
  end
end
