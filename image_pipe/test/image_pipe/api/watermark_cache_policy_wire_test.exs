defmodule ImagePipe.API.WatermarkCachePolicyWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe, as: IP

  @path "/wm=logo/format=png/src/https://origin.test/image.png"

  # A watermarked response may be cached only as long as both of its sources
  # allow.
  for {main, mark, expected} <- [
        {"public, max-age=60", "public, max-age=30, stale-while-revalidate=86400",
         "public, max-age=30, stale-while-revalidate=30"},
        {"public, max-age=60, must-revalidate", "public, max-age=30",
         "public, max-age=30, must-revalidate"},
        {"public, max-age=30, stale-while-revalidate=10", "public, max-age=60, no-cache",
         "public, max-age=0, no-cache"}
      ] do
    test "main #{inspect(main)} and mark #{inspect(mark)} give #{inspect(expected)}" do
      response = conn(:get, @path) |> IP.Plug.call(config(unquote(main), unquote(mark)))

      assert response.status == 200
      assert get_resp_header(response, "cache-control") == [unquote(expected)]
    end
  end

  defp config(main_control, mark_control) do
    controls = %{"image.png" => {main_control, :blue}, "mark.png" => {mark_control, :red}}

    origin = fn conn ->
      path = Enum.join(conn.path_info, "/")
      {control, color} = Map.fetch!(controls, path)

      conn
      |> put_resp_header("etag", ~s("#{path}"))
      |> put_resp_header("cache-control", control)
      |> put_resp_header("date", "Thu, 01 Jan 1970 00:16:40 GMT")
      |> put_resp_content_type("image/png")
      |> send_resp(200, Image.new!(8, 8, color: color) |> Image.write!(:memory, suffix: ".png"))
    end

    IP.Plug.init(
      sources: [
        url: [
          adapter: ImagePipe.Source.HTTP,
          match: [scheme: ["http", "https"]],
          options: [
            allowed_hosts: ["origin.test"],
            address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
            req_options: [plug: origin]
          ]
        ]
      ],
      clock: fn -> 1_000 end,
      watermarks: %{logo: [source: "https://origin.test/mark.png"]},
      http_cache: :auto
    )
  end
end
