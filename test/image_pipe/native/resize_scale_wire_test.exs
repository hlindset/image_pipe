defmodule ImagePipe.Native.ResizeScaleWireTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter

  for {options, source, expected} <- [
        {"w=100/h=100/dpr=2/pad=10", {150, 150}, {180, 180}},
        {"w=100/h=100/dpr=2/pad=10/enlarge", {150, 150}, {240, 240}},
        {"dpr=2/pad=10", {150, 150}, {190, 190}},
        {"w=300/pad=10", {150, 150}, {160, 160}},
        {"w=100/h=50/fit=stretch/dpr=2", {150, 100}, {150, 75}},
        {"w=50/zoom=2/pad=10", {150, 150}, {120, 120}},
        {"w=40/h=40/fit=stretch/zoom=2,0.5/dpr=2", {200, 200}, {160, 40}},
        {"w=100/dpr=2/pad=10", {150, 100}, {180, 130}},
        {"w=50/dpr=2/then/pad=10", {150, 150}, {120, 120}},
        {"crop=50,50/dpr=2/pad=10", {150, 150}, {90, 90}},
        {"crop=50pct,100pct", {401, 300}, {201, 300}},
        {"w=50/min-w=100", {150, 150}, {100, 100}},
        {"min-w=200/pad=10", {150, 150}, {166, 166}},
        {"min-w=200/enlarge", {150, 150}, {200, 200}},
        {"min-w=50", {150, 150}, {150, 150}},
        {"min-w=1/zoom=2,1", {200, 100}, {200, 100}},
        {"w=50/min-h=100", {200, 100}, {200, 100}},
        {"w=300/h=20/fit=stretch/min-w=100/enlarge", {200, 100}, {300, 20}},
        {"w=50/zoom=2,1", {150, 150}, {100, 100}},
        {"h=50/zoom=1,2", {150, 150}, {100, 100}},
        {"w=100/h=100/zoom=2,1", {200, 100}, {200, 100}},
        {"w=100/h=200/zoom=3,1/fit=auto/enlarge", {200, 100}, {300, 200}},
        {"w=200", {201, 101}, {200, 100}},
        {"w=128", {201, 101}, {128, 64}},
        {"h=100", {100, 113}, {88, 100}},
        {"w=100/h=80", {101, 118}, {68, 80}},
        {"w=100/zoom=2", {201, 101}, {200, 100}},
        {"w=100/min-w=200", {201, 101}, {200, 100}},
        {"w=100/dpr=0.00000001", {150, 150}, {1, 1}},
        {"rotate=90/w=50/dpr=2/pad=10", {150, 100}, {140, 190}},
        {"w=100/h=100/fit=cover/dpr=2", {150, 100}, {100, 100}},
        {"w=100/h=100/fit=cover-down/dpr=2/enlarge", {150, 100}, {100, 100}}
      ] do
    test "#{options} on #{inspect(source)} produces #{inspect(expected)}" do
      output = request(unquote(options), unquote(source)) |> decode()
      assert {Image.width(output), Image.height(output)} == unquote(expected)
    end
  end

  test "DPR-only padding preserves source pixels and adds transparent physical borders" do
    output = request("dpr=2/pad=10", {150, 150}) |> decode()
    assert Image.get_pixel!(output, 19, 20) == [0, 0, 0, 0]
    assert Image.get_pixel!(output, 20, 20) == [20, 40, 60, 255]
    assert Image.get_pixel!(output, 169, 169) == [20, 40, 60, 255]
    assert Image.get_pixel!(output, 170, 169) == [0, 0, 0, 0]
  end

  test "numeric spellings and option order produce the same response" do
    first = request("w=50/dpr=2/zoom=1.5", {150, 150})
    second = request("zoom=1.50,1.5/dpr=2.0/w=50", {150, 150})
    assert first.status == 200
    assert second.status == 200
    assert [_etag] = get_resp_header(first, "etag")
    assert get_resp_header(first, "etag") == get_resp_header(second, "etag")
    assert first.resp_body == second.resp_body
  end

  test "fractional DPR rounds each padding side half to even" do
    output = request("dpr=0.5/pad=1,3,5,7", {60, 30}) |> decode()
    assert {Image.width(output), Image.height(output)} == {66, 32}
    assert Image.get_pixel!(output, 3, 0) == [0, 0, 0, 0]
    assert Image.get_pixel!(output, 4, 0) == [20, 40, 60, 255]
    assert Image.get_pixel!(output, 63, 29) == [20, 40, 60, 255]
    assert Image.get_pixel!(output, 64, 29) == [0, 0, 0, 0]
    assert Image.get_pixel!(output, 4, 30) == [0, 0, 0, 0]
  end

  test "invalid scale and minimum options fail before source access" do
    origin = fn _conn -> flunk("invalid request fetched its source") end

    config =
      ImagePipe.Plug.init(
        sources: [
          path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
        ]
      )

    for options <- ["dpr=0", "dpr=-1", "zoom=0", "zoom=2", "min-w=0", "min-h=auto"] do
      response = conn(:get, "/#{options}/src/image.png") |> ImagePipe.Plug.call(config)
      assert response.status == 400
    end
  end

  property "no-enlarge uniformly caps stretch at either source axis" do
    check all width <- integer(30..100),
              height <- integer(30..100),
              target <- integer(20..150),
              dpr <- member_of([0.5, 1.0, 1.5, 2.0]),
              max_runs: 24 do
      output =
        request("w=#{target}/h=#{target}/fit=stretch/dpr=#{dpr}", {width, height}) |> decode()

      side = max(1, round(min(target * dpr, min(width, height))))
      assert {Image.width(output), Image.height(output)} == {side, side}
    end
  end

  defp request(options, {width, height}) do
    body = Image.new!(width, height, color: [20, 40, 60]) |> Image.write!(:memory, suffix: ".png")
    origin = fn conn -> conn |> put_resp_content_type("image/png") |> send_resp(200, body) end

    config =
      ImagePipe.Plug.init(
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: origin]}
        ],
        http_cache: [mode: :enabled]
      )

    conn(:get, "/#{options}/format=png/src/image.png") |> ImagePipe.Plug.call(config)
  end

  defp decode(response) do
    assert response.status == 200
    Image.from_binary!(response.resp_body)
  end
end
