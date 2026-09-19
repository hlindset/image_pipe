defmodule ImagePipe.Native.RequestSafetyTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]
  import Plug.Test, only: [conn: 2]

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.CacheProbe
  alias ImagePipe.Test.PlugFixture.CountingOriginImage
  alias ImagePipe.Test.PlugFixture.OriginShouldNotFetch

  @signing_key "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

  test "rejectable_requests/1 fail with the declared status and never touch source or cache" do
    assert_rejectable_requests(rejectable_requests(base_opts()))
  end

  test "valid_request/1's own ETag on If-None-Match returns 304 without a source fetch" do
    assert_conditional_get_skips_fetch(valid_request(base_opts()))
  end

  test "valid_request/1 emits [:request] and [:parse] telemetry start/stop under a kit-owned prefix" do
    assert_telemetry_stages(valid_request(base_opts()))
  end

  defp rejectable_requests(_base_opts) do
    [
      {"/bogus=10/src/images/cat.jpg", 400},
      {"/w=invalid/src/images/cat.jpg", 400},
      {"/w=800/w=900/src/images/cat.jpg", 400},
      {"/crop=100,100/region=0,0,10,10/src/images/cat.jpg", 400},
      {"/w=800/then/then/w=900/src/images/cat.jpg", 400},
      {"/w=64/src/images/cat.jpg?x=1", 400},
      # Signature verification (§Signing) runs before any parsing, on a
      # keyed instance: missing sig= and an invalid sig= both reject with
      # 403 before the source or cache are ever touched.
      {"/w=64/src/images/cat.jpg", 403, [keys: [@signing_key]]},
      {"/sig=" <> String.duplicate("A", 43) <> "/w=64/src/images/cat.jpg", 403,
       [keys: [@signing_key]]},
      # The `expires` gate (§Signing) runs before source resolve: a past
      # timestamp rejects with 404 before the source or cache are touched.
      {"/expires=#{System.os_time(:second) - 3600}/w=64/src/images/cat.jpg", 404}
    ]
  end

  defp valid_request(_base_opts), do: "/w=64/src/images/cat.jpg"
  @spec base_opts() :: keyword()
  defp base_opts do
    [
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://contract-kit-request-safety.test",
           byte_identity: :strong,
           req_options: [plug: {CountingOriginImage, test_pid: self()}]}
      ]
    ]
  end

  defp build_config(opts) do
    config =
      ImagePipe.Plug.init(Keyword.merge(opts, cache: {CacheProbe, []}))

    Keyword.merge(config, output_capabilities: %{avif: true, webp: true, jpeg_xl: true})
  end

  defp no_fetch_config(opts) do
    no_fetch_sources = [
      path:
        {RootHTTPAdapter,
         root_url: "http://contract-kit-request-safety.test",
         byte_identity: :strong,
         req_options: [plug: OriginShouldNotFetch]}
    ]

    build_config(Keyword.put(opts, :sources, no_fetch_sources))
  end

  # ── generated-test bodies ────────────────────────────────────────────────

  defp assert_rejectable_requests(cases) do
    refute Enum.empty?(cases), "rejectable_requests/1 must return at least one case"

    for item <- cases do
      {path, expected_status, opts} = normalize_rejectable_case(item)
      config = build_config(Keyword.merge(base_opts(), opts))

      conn = ImagePipe.Plug.call(conn(:get, path), config)

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

  defp assert_conditional_get_skips_fetch(path) do
    config = build_config(base_opts())

    plain_conn = ImagePipe.Plug.call(conn(:get, path), config)
    assert plain_conn.status == 200
    assert [etag] = get_resp_header(plain_conn, "etag")
    # Drain the plain request's own fetch signal so it can't be mistaken for
    # one triggered by the conditional request below.
    assert_received :origin_fetch

    conditional_conn =
      conn(:get, path)
      |> put_req_header("if-none-match", etag)
      |> then(&ImagePipe.Plug.call(&1, no_fetch_config(base_opts())))

    assert conditional_conn.status == 304
    assert conditional_conn.resp_body == ""
    # No `refute_received :origin_fetch` here: `no_fetch_config`'s origin is
    # `OriginShouldNotFetch`, which raises (rather than sending a message) on
    # any fetch attempt — a fetch would already have crashed this test above.
  end

  defp assert_telemetry_stages(path) do
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

    config = build_config(Keyword.put(base_opts(), :telemetry_prefix, prefix))
    conn = ImagePipe.Plug.call(conn(:get, path), config)
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
