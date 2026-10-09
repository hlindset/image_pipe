defmodule ImagePipe.API.CredentialedOriginWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Test.CacheObserver

  # Source credentials come from host configuration, so an authenticated
  # fetch follows the origin's cache directives like any other.
  test "credentialed originals are cached unless the origin forbids it" do
    for {directive, expected} <- [
          {"max-age=60", "public, max-age=60"},
          {"private, max-age=60", "no-store"}
        ] do
      response =
        :get
        |> conn("/w=12/format=png/src/https://origin.test/beach.jpg")
        |> ImagePipe.Plug.call(mount(directive))

      assert response.status == 200
      assert_received {:authorization, ["Bearer secret"]}
      assert [^expected <> _rest] = get_resp_header(response, "cache-control")
      assert get_resp_header(response, "etag") != [] == (expected != "no-store")
    end
  end

  defp mount(directive) do
    body = File.read!("priv/static/images/beach.jpg")
    pid = self()

    plug = fn conn ->
      send(pid, {:authorization, get_req_header(conn, "authorization")})

      conn
      |> put_resp_header("cache-control", directive)
      |> put_resp_content_type("image/jpeg")
      |> send_resp(200, body)
    end

    [
      sources: [
        url: [
          adapter: ImagePipe.Source.HTTP,
          match: [scheme: ["http", "https"]],
          options: [
            allowed_hosts: ["origin.test"],
            address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
            req_options: [plug: plug, auth: {:bearer, "secret"}]
          ]
        ]
      ],
      http_cache: :auto
    ]
    |> CacheObserver.observe()
    |> ImagePipe.Plug.init()
  end
end
