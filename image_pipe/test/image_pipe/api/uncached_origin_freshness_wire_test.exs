defmodule ImagePipe.API.UncachedOriginFreshnessWireTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test
  alias ImagePipe, as: IP

  setup do
    red = Image.new!(24, 16, color: :red) |> Image.write!(:memory, suffix: ".png")
    blue = Image.new!(24, 16, color: :blue) |> Image.write!(:memory, suffix: ".png")

    state =
      start_supervised!(
        {Agent, fn -> %{version: 1, control: "public, max-age=60, stale-while-revalidate=30"} end}
      )

    test_pid = self()

    plug = fn conn ->
      current = Agent.get(state, & &1)
      send(test_pid, :origin)

      conn
      |> put_resp_header("cache-control", current.control)
      |> put_resp_header("age", "20")
      |> put_resp_header("date", "Thu, 01 Jan 1970 00:16:40 GMT")
      |> put_resp_content_type("image/png")
      |> send_resp(200, if(current.version == 1, do: red, else: blue))
    end

    shared =
      IP.config(
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
        clock: fn -> 1_000 end
      )

    %{config: IP.Plug.init(config: shared, http_cache: :auto), state: state}
  end

  test "a mutable origin's freshness and a byte validator pass through without a cache", %{
    config: config
  } do
    response = request(config)

    assert response.status == 200
    assert_received :origin

    assert get_resp_header(response, "cache-control") == [
             "public, max-age=60, stale-while-revalidate=30"
           ]

    assert ["20"] = get_resp_header(response, "age")
    assert [~s("ipr1-) <> _] = get_resp_header(response, "etag")
  end

  test "a matching validator still fetches the origin and returns 304", %{config: config} do
    [etag] = get_resp_header(request(config), "etag")
    assert_received :origin

    response = request(config, [{"if-none-match", etag}])

    assert response.status == 304
    assert_received :origin
    assert get_resp_header(response, "etag") == [etag]
  end

  test "changed origin bytes change the validator", %{config: config, state: state} do
    [etag] = get_resp_header(request(config), "etag")
    Agent.update(state, &%{&1 | version: 2})

    response = request(config, [{"if-none-match", etag}])

    assert response.status == 200
    refute get_resp_header(response, "etag") == [etag]
  end

  test "origin no-store keeps the response unstorable", %{config: config, state: state} do
    Agent.update(state, &%{&1 | control: "no-store"})

    response = request(config)

    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "etag") == []
  end

  defp request(config, headers \\ []) do
    conn = conn(:get, "/w=12/format=png/src/https://origin.test/image.png")

    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

    ImagePipe.Plug.call(conn, config)
  end
end
