defmodule ImagePipe.Dialect.IIIF.MountTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Dialect.IIIF
  alias ImagePipe.Dialect.IIIF.Resolver.Static
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.CacheProbe

  defmodule OriginImage do
    @moduledoc false

    # A 200×300 opaque PNG — tall enough that a width-only resize is unambiguous
    # and large enough that no request in this file hits an upscale path.
    def init(opts), do: opts

    def call(conn, _opts) do
      body = Image.new!(200, 300, color: [100, 150, 200]) |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defp sources do
    [path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}]
  end

  defp opts(extra \\ []) do
    ImagePipe.Plug.init(
      Keyword.merge(
        [
          dialect: IIIF,
          resolver: {Static, map: %{"beach" => %SourcePath{segments: ["images", "beach.jpg"]}}},
          sources: sources()
        ],
        extra
      )
    )
  end

  defp get(path, config), do: ImagePipe.Plug.call(conn(:get, path), config)

  test "serves an image request through the flat dialect mount" do
    conn = get("/beach/full/64,/0/default.jpg", opts())

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    {:ok, image} = Image.open(conn.resp_body)
    assert Image.width(image) == 64
  end

  test "info.json negotiates ld+json and varies, and touches no cache" do
    conn =
      :get
      |> conn("/beach/info.json")
      |> put_req_header("accept", "application/ld+json")
      |> ImagePipe.Plug.call(opts(cache: {CacheProbe, result: :miss}))

    assert conn.status == 200
    assert hd(get_resp_header(conn, "content-type")) =~ "application/ld+json"
    assert get_resp_header(conn, "vary") == ["Accept"]
    assert %{"type" => "ImageService3"} = JSON.decode!(conn.resp_body)

    # A CacheProbe adapter is mounted (rather than leaving the cache
    # unconfigured) so this refutation is observable: it would fail if
    # info.json ever read or wrote the internal cache.
    refute_received {:cache_lookup, _key}
    refute_received {:cache_open_sink, _key, _metadata}
    refute_received {:cache_put, _key, _body}
  end

  test "the base-URI redirect survives" do
    conn = get("/beach", opts())

    assert conn.status == 303
    assert [location] = get_resp_header(conn, "location")
    assert location =~ "/beach/info.json"
  end

  test "an unknown identifier is 404 and a bad grammar token is 400, both text/plain" do
    not_found = get("/nope/full/max/0/default.jpg", opts())
    assert not_found.status == 404
    assert hd(get_resp_header(not_found, "content-type")) =~ "text/plain"

    bad = get("/beach/full/max/0/nope.jpg", opts())
    assert bad.status == 400
    assert hd(get_resp_header(bad, "content-type")) =~ "text/plain"
  end

  test "a rejected region token (a second grammar tag) is also a 400, not a 500" do
    conn = get("/beach/-1,-1,0,0/max/0/default.jpg", opts())
    assert conn.status == 400
  end

  # Handlers are global, so the request span is captured under a prefix private
  # to this test rather than the default `[:image_pipe]` name.
  test "a client rejection reports :parser_error on the request span" do
    telemetry_prefix = [:"iiif_mount_#{System.unique_integer([:positive])}"]
    handler_id = "iiif-mount-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      telemetry_prefix ++ [:request, :stop],
      fn _event, _measurements, meta, _config -> send(test_pid, {:request_stop, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    conn = get("/nope/full/max/0/default.jpg", opts(telemetry_prefix: telemetry_prefix))

    assert conn.status == 404
    assert_receive {:request_stop, %{result: :parser_error}}
  end

  test "rejects an unknown config key with the dialect message" do
    assert_raise ArgumentError, ~r/unknown ImagePipe\.Dialect\.IIIF option/, fn ->
      ImagePipe.Plug.init(dialect: IIIF, resolver: {Static, map: %{}}, nope: 1)
    end
  end
end
