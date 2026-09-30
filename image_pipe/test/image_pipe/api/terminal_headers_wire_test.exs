defmodule ImagePipe.API.TerminalHeadersWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.CacheProbe

  setup do
    body = Image.new!(24, 16, color: :red) |> Image.write!(:memory, suffix: ".jpg")
    owner = self()

    origin = fn conn ->
      send(owner, :origin_fetch)
      conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body)
    end

    config =
      ImagePipe.Plug.init(
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             byte_identity: :strong,
             internal_cache: :enabled,
             req_options: [plug: origin]}
        ],
        cache: {CacheProbe, store: :ets.new(:terminal_headers, [:set, :public])},
        http_cache: [mode: :enabled]
      )

    %{config: config}
  end

  for terminal <- ["w=12", "output=info", "w=12/output=blurhash", "w=12/output=lqip-css"] do
    test "#{terminal} preserves current host headers on cache miss and hit", %{config: config} do
      path = "/#{unquote(terminal)}/src/source.jpg"

      miss = request(path, config, "first")
      assert_receive :origin_fetch
      hit = request(path, config, "second")
      refute_received :origin_fetch

      assert hit.resp_body == miss.resp_body

      for {response, name} <- [{miss, "first"}, {hit, "second"}] do
        assert response.status == 200

        assert get_resp_header(response, "content-disposition") ==
                 [~s(attachment; filename="#{name}.dat")]

        assert get_resp_header(response, "cache-control") == ["private, max-age=17"]
        assert get_resp_header(response, "etag") == [~s("#{name}")]
      end
    end
  end

  defp request(path, config, name) do
    conn(:get, path)
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}.dat"))
    |> put_resp_header("cache-control", "private, max-age=17")
    |> put_resp_header("etag", ~s("#{name}"))
    |> ImagePipe.Plug.call(config)
  end
end
