defmodule ImagePipe.API.ExpiresCacheControlWireTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  import Plug.Conn
  import Plug.Test

  @now 1_000_000
  @expires @now + 3600
  @path "/expires=#{@expires}/format=png/src/beach.jpg"

  setup %{tmp_dir: tmp_dir} do
    clock = start_supervised!({Agent, fn -> @now end})
    %{clock: clock, cache: {ImagePipe.Cache.FileSystem, root: tmp_dir}}
  end

  defp mount(%{clock: clock, cache: cache}, overrides) do
    ImagePipe.Plug.init(
      Keyword.merge(
        [
          sources: [
            path: [
              adapter: ImagePipe.Source.File,
              match: :path,
              options: [root: "priv/static/images", root_id: "expires", stable: :immutable]
            ]
          ],
          cache: cache,
          clock: fn -> Agent.get(clock, & &1) end
        ],
        overrides
      )
    )
  end

  defp get(path, config, headers \\ []) do
    conn = conn(:get, path)

    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

    ImagePipe.Plug.call(conn, config)
  end

  test "generated Cache-Control never outlives the URL's expiry", ctx do
    config = mount(ctx, http_cache: :auto)

    response = get(@path, config)

    assert response.status == 200

    assert get_resp_header(response, "cache-control") == [
             "public, max-age=3600, immutable, must-revalidate"
           ]
  end

  test ":validators adds a Cache-Control bounded by the URL's expiry", ctx do
    response = get(@path, mount(ctx, http_cache: :validators))

    assert response.status == 200
    assert [_etag] = get_resp_header(response, "etag")
    assert get_resp_header(response, "cache-control") == ["public, max-age=3600, must-revalidate"]
  end

  test ":validators without expires still emits only the ETag", ctx do
    response = get("/format=png/src/beach.jpg", mount(ctx, http_cache: :validators))

    assert [_etag] = get_resp_header(response, "etag")
    assert get_resp_header(response, "cache-control") == ["max-age=0, private, must-revalidate"]
  end

  test "cookie storage inputs keep the bounded Cache-Control private", ctx do
    config = mount(ctx, http_cache: :validators, storage_inputs: [{:cookie, "session"}])

    response = get(@path, config, [{"cookie", "session=a"}])

    assert get_resp_header(response, "cache-control") == [
             "private, max-age=3600, must-revalidate"
           ]
  end

  test "a revalidation carries the remaining lifetime", %{clock: clock} = ctx do
    config = mount(ctx, http_cache: :auto)
    [etag] = get_resp_header(get(@path, config), "etag")

    Agent.update(clock, &(&1 + 3000))
    response = get(@path, config, [{"if-none-match", etag}])

    assert response.status == 304

    assert get_resp_header(response, "cache-control") == [
             "public, max-age=600, immutable, must-revalidate"
           ]
  end

  test "the exact expiry second is servable but not storable for later", %{clock: clock} = ctx do
    Agent.update(clock, fn _ -> @expires end)

    response = get(@path, mount(ctx, http_cache: :auto))

    assert response.status == 200

    assert get_resp_header(response, "cache-control") == [
             "public, max-age=0, immutable, must-revalidate"
           ]
  end

  test "a host Cache-Control is capped at the URL's expiry", ctx do
    for {host, expected} <- [
          {"public, max-age=86400", "public, max-age=3600, must-revalidate"},
          {"public, s-maxage=86400, max-age=60",
           "public, s-maxage=3600, max-age=60, must-revalidate"},
          {"no-store", "no-store"}
        ] do
      response =
        conn(:get, @path)
        |> put_resp_header("cache-control", host)
        |> ImagePipe.Plug.call(mount(ctx, http_cache: :auto))

      assert get_resp_header(response, "cache-control") == [expected],
             inspect({host, get_resp_header(response, "cache-control")})
    end
  end

  describe "a mutable origin" do
    setup %{clock: clock, cache: cache} do
      origin = start_supervised!({Agent, fn -> "public, max-age=86400" end}, id: :origin)
      body = File.read!("priv/static/images/beach.jpg")

      plug = fn conn ->
        conn
        |> put_resp_header("cache-control", Agent.get(origin, & &1))
        |> put_resp_header("age", "20")
        |> put_resp_content_type("image/jpeg")
        |> send_resp(200, body)
      end

      config =
        ImagePipe.Plug.init(
          sources: [
            url: [
              adapter: ImagePipe.Source.HTTP,
              match: [scheme: ["http", "https"]],
              options: [
                allowed_hosts: ["origin.test"],
                address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
                req_options: [plug: plug]
              ]
            ]
          ],
          cache: cache,
          http_cache: :auto,
          clock: fn -> Agent.get(clock, & &1) end
        )

      %{config: config, origin: origin}
    end

    test "a longer origin lifetime is cut to the expiry, counting the Age", %{config: config} do
      response = get(origin_path(@expires), config)

      assert response.status == 200
      assert get_resp_header(response, "age") == ["20"]
      # Caches subtract Age from max-age, leaving exactly the 3600 s until expiry.
      assert get_resp_header(response, "cache-control") == [
               "public, max-age=3620, must-revalidate"
             ]
    end

    test "stale-while-revalidate is trimmed to end at the expiry", %{
      config: config,
      origin: origin
    } do
      Agent.update(origin, fn _ -> "public, max-age=60, stale-while-revalidate=30" end)

      # 40 s of freshness remain (60 - Age 20); expiry is 50 s away.
      response = get(origin_path(@now + 50), config)

      assert get_resp_header(response, "cache-control") == [
               "public, max-age=60, stale-while-revalidate=10, must-revalidate"
             ]
    end

    test "an origin lifetime inside the expiry is kept", %{config: config, origin: origin} do
      Agent.update(origin, fn _ -> "public, max-age=60, stale-while-revalidate=30" end)

      response = get(origin_path(@expires), config)

      assert get_resp_header(response, "cache-control") == [
               "public, max-age=60, stale-while-revalidate=30, must-revalidate"
             ]
    end
  end

  defp origin_path(expires),
    do: "/expires=#{expires}/format=png/src/https://origin.test/image.jpg"
end
