defmodule ImagePipe.API.SkipProcessingWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe, as: IP
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: VipsImage

  @prefix [:skip_processing_wire]
  @accept "image/avif,image/webp,image/*"

  setup do
    gif = encode(Image.new!(32, 24, color: [200, 40, 40]), ".gif")

    files = %{
      "image.gif" => gif,
      "image.png" => encode(Image.new!(32, 24, color: [40, 40, 200]), ".png"),
      "mark.png" => encode(Image.new!(4, 4, color: [0, 255, 0]), ".png"),
      "corrupt.gif" => "GIF89a" <> :binary.copy(<<7>>, 64)
    }

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        [
          @prefix ++ [:source, :fetch_decode, :stop],
          @prefix ++ [:transform, :execute, :stop],
          @prefix ++ [:encode, :stop]
        ],
        fn event, _measurements, metadata, pid ->
          send(pid, {Enum.take(event, -2), event, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{files: files, gif: gif}
  end

  describe "a skipped request" do
    test "returns the listed source bytes unchanged, whatever the options", %{files: files} do
      response = request("w=10/blur=2", mount(files), "image.gif")

      assert response.status == 200
      assert response.resp_body == files["image.gif"]
      assert header(response, "content-type") == "image/gif"
      assert header(response, "x-content-type-options") == "nosniff"
      assert header(response, "vary") == "Accept"
    end

    test "skips an explicit format equal to the source format", %{files: files} do
      config = mount(files, skip_processing_formats: [:png])
      response = request("w=10/format=png", config, "image.png")

      assert response.resp_body == files["image.png"]
    end

    test "serves a listed source without image checks", %{files: files} do
      assert request("w=10", mount(files), "corrupt.gif").resp_body == files["corrupt.gif"]

      limited = mount(files, max_input_pixels: 10, max_result_width: 8)
      assert request("w=10", limited, "image.gif").resp_body == files["image.gif"]
    end

    test "keeps the source body limit", %{files: files} do
      limit = byte_size(files["image.gif"]) - 1
      skipped = request("", mount(files, max_body_bytes: limit), "image.gif")

      processed =
        request("", mount(files, max_body_bytes: limit, skip_processing_formats: []), "image.gif")

      assert skipped.status == processed.status
      assert skipped.status >= 400
    end

    test "decodes, transforms, and encodes nothing", %{files: files} do
      request("w=10", mount(files), "image.gif")

      assert_received {[:fetch_decode, :stop], _event,
                       %{result: :ok, skipped: true, detected_source_format: :gif}}

      refute_received {[:execute, :stop], _event, _metadata}
      refute_received {[:encode, :stop], _event, _metadata}
    end

    test "answers a matching conditional GET with 304", %{files: files} do
      config = mount(files)
      etag = header(request("w=10", config, "image.gif"), "etag")

      conditional =
        conn(:get, "/w=10/src/image.gif")
        |> put_req_header("accept", @accept)
        |> put_req_header("if-none-match", etag)
        |> IP.Plug.call(config)

      assert conditional.status == 304
    end

    test "is not written to the output cache", %{files: files} do
      root = Path.join(System.tmp_dir!(), "skip-processing-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)
      config = mount(files, cache: {FileSystem, root: root})

      assert request("w=10", config, "image.gif").resp_body == files["image.gif"]
      assert cached_files(root) == []

      assert request("w=10", config, "image.png").status == 200
      refute cached_files(root) == []
    end
  end

  describe "an ineligible request is processed" do
    test "when the explicit format differs from the source format", %{files: files} do
      response = request("w=10/format=png", mount(files), "image.gif")

      assert header(response, "content-type") == "image/png"
      assert dimensions(response) == {10, 8}
    end

    test "when the request draws a watermark", %{files: files} do
      config = mount(files, watermarks: %{logo: [source: "mark.png"]})
      response = request("w=10/wm=logo", config, "image.gif")

      refute response.resp_body == files["image.gif"]
      assert dimensions(response) == {10, 8}
    end

    test "when the source format is not listed", %{files: files} do
      response = request("w=10", mount(files), "image.png")

      refute response.resp_body == files["image.png"]
      assert dimensions(response) == {10, 8}
    end

    test "for non-image terminals", %{files: files} do
      response = request("output=info", mount(files), "image.gif")

      assert %{"format" => "gif", "width" => 32} = JSON.decode!(response.resp_body)
    end
  end

  describe "identity" do
    test "the listed formats change the ETag of affected requests only", %{files: files} do
      listed = mount(files)
      unlisted = mount(files, skip_processing_formats: [])

      refute etag("w=10", listed) == etag("w=10", unlisted)
      assert etag("w=10/format=png", listed) == etag("w=10/format=png", unlisted)
    end
  end

  test "native execution returns the skipped source as an image result", %{gif: gif} do
    config = IP.config(skip_processing_formats: [:gif])
    plan = IP.URL.new() |> IP.URL.group(resize: [width: 10])

    assert {:ok, result} = IP.run(config, plan, {:binary, gif})
    assert %IP.Result{terminal: :image, format: :gif, data: ^gif} = result
    assert {result.width, result.height} == {32, 24}
  end

  test "configuration rejects formats that are not source formats" do
    assert_raise ArgumentError, ~r/skip_processing_formats/, fn ->
      IP.Plug.init(skip_processing_formats: [:svg])
    end
  end

  defp etag(options, config), do: header(request(options, config, "image.gif"), "etag")

  defp request(options, config, path) do
    conn(:get, "/#{options}/src/#{path}")
    |> put_req_header("accept", @accept)
    |> IP.Plug.call(config)
  end

  defp header(response, name) do
    [value] = get_resp_header(response, name)
    value
  end

  defp dimensions(response) do
    image = Image.from_binary!(response.resp_body)
    {Image.width(image), Image.height(image)}
  end

  defp cached_files(root) do
    if File.dir?(root), do: Path.wildcard(Path.join(root, "**/*.*")), else: []
  end

  defp encode(image, suffix) do
    {:ok, body} = VipsImage.write_to_buffer(image, suffix)
    body
  end

  defp mount(files, extra \\ []) do
    origin = fn conn ->
      case Map.fetch(files, String.trim_leading(conn.request_path, "/")) do
        {:ok, body} -> send_resp(conn, 200, body)
        :error -> send_resp(conn, 404, "")
      end
    end

    [
      sources: [
        path: [
          adapter: RootHTTPAdapter,
          match: :path,
          options: [
            root_url: "http://origin.test",
            byte_identity: :strong,
            req_options: [plug: origin]
          ]
        ]
      ],
      skip_processing_formats: [:gif],
      http_cache: [mode: :enabled],
      telemetry_prefix: @prefix
    ]
    |> Keyword.merge(extra)
    |> IP.Plug.init()
  end
end
