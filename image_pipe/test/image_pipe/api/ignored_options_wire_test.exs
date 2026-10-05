defmodule ImagePipe.API.IgnoredOptionsWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter

  @prefix [:api_ignored_options_wire]
  @event @prefix ++ [:request, :ignored_options]

  setup do
    ref = make_ref()
    pid = self()

    :telemetry.attach(
      ref,
      @event,
      fn _event, _measurements, metadata, _config -> send(pid, {:ignored, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
    %{body: 32 |> Image.new!(24, color: :red) |> Image.write!(:memory, suffix: ".jpg")}
  end

  test "an inert option is dropped and served like the URL without it", %{body: body} do
    config = mount(body)
    inert = request("w=16/anchor=top", config)
    clean = request("w=16", config)

    assert inert.status == 200
    assert inert.resp_body == clean.resp_body
    assert get_resp_header(inert, "etag") == get_resp_header(clean, "etag")
    assert_received {:ignored, %{options: ["anchor"]}}
  end

  test "debug headers list the ignored options", %{body: body} do
    config = mount(body, allow_debug_headers: true)

    response = request("w=16/fit=cover/-/zoom=2/debug", config)
    assert get_resp_header(response, "x-imagepipe-ignored-options") == ["zoom"]

    response = request("w=16/-/zoom=2", config)
    assert get_resp_header(response, "x-imagepipe-ignored-options") == []
  end

  test "inherited inert options are dropped without a report", %{body: body} do
    config = mount(body, request_defaults: "jpeg-options=progressive")
    response = request("w=16/format=webp", config)

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/webp"]
    refute_received {:ignored, _metadata}
  end

  defp request(options, config) do
    conn(:get, "/#{options}/src/source.jpg")
    |> put_req_header("accept", "*/*")
    |> ImagePipe.Plug.call(config)
  end

  defp mount(body, extra \\ []) do
    origin = fn conn -> conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body) end

    [
      telemetry_prefix: @prefix,
      sources: [
        path: [
          adapter: RootHTTPAdapter,
          match: :path,
          options: [root_url: "http://origin.test", req_options: [plug: origin]]
        ]
      ]
    ]
    |> Keyword.merge(extra)
    |> ImagePipe.Plug.init()
  end
end
