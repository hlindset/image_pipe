defmodule ImagePipe.BuilderWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe, as: IP
  alias ImagePipe.Plan
  alias ImagePipe.RequestSafetyTest.CacheProbe
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  setup do
    image =
      Image.new!(60, 40, color: [80, 120, 160])
      |> Image.Draw.rect!(5, 8, 20, 18, color: [200, 70, 40])

    body = Image.write!(image, :memory, suffix: ".png")
    pid = self()

    origin = fn conn ->
      send(pid, :source_fetch)
      conn |> put_resp_content_type("image/png") |> send_resp(200, body)
    end

    config =
      IP.Plug.init(
        sources: [
          path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
        ],
        cache: {CacheProbe, []}
      )

    %{image: Image.from_binary!(body), config: config}
  end

  test "plans execute the same pixels as HTTP, with and without geometry", context do
    effect = IP.new() |> IP.group(brightness: 20, colorize: [opacity: 0.3, color: "red"])

    grouped =
      IP.new()
      |> IP.group(resize: [width: 30, height: 20, fit: :stretch], dpr: 2)
      |> IP.group(region: {5, 3, 10, 8}, padding: 2, background: "white")

    for {plan, path, dimensions} <- [
          {effect, "brightness=20/colorize=0.3,red", {60, 40}},
          {grouped, "w=30/h=20/fit=stretch/dpr=2/-/region=5,3,10,8/pad=2/bg=white", {14, 12}}
        ] do
      assert {:ok, request} = Plan.to_request(IP.output(plan, format: :png).plan, "photo.png")
      assert {:ok, state} = Executor.execute(%State{image: context.image}, request, [])

      response = conn(:get, "/#{path}/format=png/src/photo.png") |> IP.Plug.call(context.config)
      assert response.status == 200
      assert get_resp_header(response, "content-type") == ["image/png"]
      output = Image.from_binary!(response.resp_body)
      assert {Image.width(output), Image.height(output)} == dimensions
      assert VipsImage.write_to_binary(output) == VipsImage.write_to_binary(state.image)
    end
  end

  test "shared semantic failures stop HTTP before source or cache access", %{config: config} do
    for path <- ["extend", "fit=cover", "output=info/blur=0", "q=80/autoquality=size"] do
      response = conn(:get, "/#{path}/src/photo.png") |> IP.Plug.call(config)
      assert response.status == 400
      refute_received :source_fetch
      refute_received :cache_lookup
      refute_received :cache_put
    end
  end
end
