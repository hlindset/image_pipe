defmodule ImagePipe.API.ExpiresCacheControlWireTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Test.Caches

  @now 1_000_000
  @expires @now + 3600
  @path "/expires=#{@expires}/format=png/src/beach.jpg"

  setup do
    %{clock: start_supervised!({Agent, fn -> @now end})}
  end

  defp mount(%{clock: clock, tmp_dir: tmp_dir}, overrides) do
    [
      sources: [
        path: [
          adapter: ImagePipe.Source.File,
          match: :path,
          options: [root: "priv/static/images", root_id: "expires", stable: :immutable]
        ]
      ],
      cache: [root: tmp_dir],
      clock: fn -> Agent.get(clock, & &1) end
    ]
    |> Keyword.merge(overrides)
    |> Caches.start!()
    |> Caches.plug()
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

  test "cookie vary_on inputs keep the bounded Cache-Control private", ctx do
    config = mount(ctx, http_cache: :validators, vary_on: [{:cookie, "session"}])

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
    config = mount(ctx, http_cache: :auto)

    for {host, expected} <- [
          {"public, max-age=86400", "public, max-age=3600, must-revalidate"},
          {"public, s-maxage=86400, max-age=60",
           "public, s-maxage=3600, max-age=60, must-revalidate"},
          {"public, max-age=60, stale-while-revalidate=30, stale-if-error=60",
           "public, max-age=60, must-revalidate"},
          {"no-store", "no-store"},
          {"public, max-age=\"86400\"", "public, max-age=3600, must-revalidate"},
          {"public, max-age=86400.5", "public, max-age=3600, must-revalidate"},
          {"public, max-age=abc", "public, max-age=3600, must-revalidate"},
          {"public, MAX-AGE=86400", "public, max-age=3600, must-revalidate"},
          {"public, S-MaxAge=86400, max-age=60",
           "public, s-maxage=3600, max-age=60, must-revalidate"},
          {"public, s-maxage=abc, max-age=60", "public, max-age=60, must-revalidate"},
          {"public", "public, max-age=3600, must-revalidate"},
          {"public, max-age=60, Must-Revalidate", "public, max-age=60, Must-Revalidate"},
          {"No-Store", "No-Store"}
        ] do
      response =
        conn(:get, @path)
        |> put_resp_header("cache-control", host)
        |> ImagePipe.Plug.call(config)

      assert get_resp_header(response, "cache-control") == [expected],
             inspect({host, get_resp_header(response, "cache-control")})
    end
  end

  test "a host Cache-Control on a client error is capped at the URL's expiry", ctx do
    config = mount(ctx, http_cache: :auto)

    for {path, expected} <- [
          {"/expires=#{@expires}/format=png/src/missing.jpg",
           "public, max-age=3600, must-revalidate"},
          {"/expires=#{@expires}/format=png/src/https://origin.test/beach.jpg",
           "public, max-age=3600, must-revalidate"},
          {"/format=png/src/missing.jpg", "public, max-age=86400"}
        ] do
      response =
        conn(:get, path)
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> ImagePipe.Plug.call(config)

      assert response.status in 400..499
      assert get_resp_header(response, "cache-control") == [expected], path
    end
  end

  test "an expired URL's 410 keeps the host Cache-Control", %{clock: clock} = ctx do
    config = mount(ctx, http_cache: :auto)
    Agent.update(clock, fn _ -> @expires + 1 end)

    response =
      conn(:get, @path)
      |> put_resp_header("cache-control", "public, max-age=86400")
      |> ImagePipe.Plug.call(config)

    assert response.status == 410
    assert get_resp_header(response, "cache-control") == ["public, max-age=86400"]
  end

  describe "a mutable origin" do
    setup %{clock: clock, tmp_dir: tmp_dir} do
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
        Caches.plug(
          Caches.start!(
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
            cache: [root: tmp_dir],
            http_cache: :auto,
            clock: fn -> Agent.get(clock, & &1) end
          )
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

    # must-revalidate forbids serving stale responses (RFC 9111 §4.2.4), so a
    # stale window next to it would never be used.
    test "stale-while-revalidate is dropped", %{config: config, origin: origin} do
      Agent.update(origin, fn _ -> "public, max-age=60, stale-while-revalidate=30" end)

      # 40 s of freshness remain (60 - Age 20). The first expiry falls inside
      # the stale window, the second after it.
      for expires <- [@now + 50, @expires] do
        response = get(origin_path(expires), config)

        assert get_resp_header(response, "cache-control") == [
                 "public, max-age=60, must-revalidate"
               ]
      end
    end

    test "an unstorable origin stays no-store under a host Cache-Control", %{
      config: config,
      origin: origin
    } do
      for control <- ["no-store", "private, max-age=600"] do
        Agent.update(origin, fn _ -> control end)

        response =
          conn(:get, origin_path(@expires))
          |> put_resp_header("cache-control", "public, max-age=86400")
          |> ImagePipe.Plug.call(config)

        assert response.status == 200
        assert get_resp_header(response, "cache-control") == ["no-store"], control
        assert get_resp_header(response, "etag") == []
      end
    end
  end

  defp origin_path(expires),
    do: "/expires=#{expires}/format=png/src/https://origin.test/image.jpg"
end
