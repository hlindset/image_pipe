defmodule ImagePipe.API.TerminalDebugWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.CacheProbe

  @terminals ["output=info", "w=12/output=blurhash"]

  setup do
    body =
      24
      |> Image.new!(16, color: :red)
      |> Image.write!(:memory, suffix: ".jpg")

    %{body: body}
  end

  test "complete-body debug miss reports cache and terminal timing without invented dimensions",
       %{body: body} do
    for terminal <- @terminals do
      config = mount(body, allow_debug_headers: true)
      response = request("#{terminal}/debug", config)

      assert response.status == 200, terminal
      assert header(response, "x-imagepipe-cache") == "miss", terminal
      assert header(response, "x-imagepipe-cache-key") =~ ~r/^[0-9a-f]{64}$/, terminal
      assert header(response, "x-imagepipe-source-width") == nil, terminal
      assert header(response, "x-imagepipe-source-height") == nil, terminal
      assert header(response, "x-imagepipe-output-width") == nil, terminal
      assert header(response, "x-imagepipe-output-height") == nil, terminal

      case terminal do
        "output=info" -> assert header(response, "x-imagepipe-pipeline") == nil
        "w=12/output=blurhash" -> assert header(response, "x-imagepipe-pipeline") == "resize"
      end

      assert header(response, "server-timing") =~ "total;dur=", terminal
      refute header(response, "server-timing") =~ "cache;dur=", terminal
    end
  end

  test "plain and debug requests share a complete-body entry while current request controls headers",
       %{body: body} do
    for terminal <- @terminals do
      config = mount(body, allow_debug_headers: true)

      plain = request(terminal, config)
      assert plain.status == 200, terminal
      assert debug_headers(plain) == [], terminal
      assert header(plain, "server-timing") == nil, terminal
      assert_receive :origin_fetch

      debug = request("#{terminal}/debug", config)
      assert debug.status == 200, terminal
      assert debug.resp_body == plain.resp_body, terminal
      assert get_resp_header(debug, "etag") == get_resp_header(plain, "etag"), terminal
      assert header(debug, "x-imagepipe-cache") == "hit", terminal
      assert header(debug, "server-timing") =~ "total;dur=", terminal
      assert header(debug, "server-timing") =~ "cache;dur=", terminal
      refute_receive :origin_fetch

      plain_hit = request(terminal, config)
      assert plain_hit.resp_body == plain.resp_body, terminal
      assert debug_headers(plain_hit) == [], terminal
      assert header(plain_hit, "server-timing") == nil, terminal
      refute_receive :origin_fetch
    end
  end

  test "the current host policy can reveal facts stored while debug headers were denied", %{
    body: body
  } do
    for terminal <- @terminals do
      store = :ets.new(:api_terminal_debug_policy_cache, [:set, :public])
      denied_config = mount(body, store: store, allow_debug_headers: false)

      denied = request("#{terminal}/debug", denied_config)
      assert denied.status == 200, terminal
      assert debug_headers(denied) == [], terminal
      assert header(denied, "server-timing") == nil, terminal
      assert_receive :origin_fetch

      allowed_config = mount(body, store: store, allow_debug_headers: true)
      allowed = request("#{terminal}/debug", allowed_config)

      assert allowed.resp_body == denied.resp_body, terminal
      assert header(allowed, "x-imagepipe-cache") == "hit", terminal
      assert header(allowed, "server-timing") =~ "cache;dur=", terminal
      refute_receive :origin_fetch
    end
  end

  defp request(options, config) do
    conn(:get, "/#{options}/src/source.jpg")
    |> ImagePipe.Plug.call(config)
  end

  defp mount(body, options) do
    test_pid = self()

    store =
      Keyword.get_lazy(options, :store, fn ->
        :ets.new(:api_terminal_debug, [:set, :public])
      end)

    origin = fn conn ->
      send(test_pid, :origin_fetch)
      conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body)
    end

    ImagePipe.Plug.init(
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           byte_identity: :strong,
           internal_cache: :enabled,
           req_options: [plug: origin]}
      ],
      cache: {CacheProbe, store: store},
      http_cache: [mode: :enabled],
      allow_debug_headers: Keyword.fetch!(options, :allow_debug_headers)
    )
  end

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  defp debug_headers(conn) do
    Enum.filter(conn.resp_headers, fn {name, _value} ->
      String.starts_with?(name, "x-imagepipe-")
    end)
  end
end
