defmodule ImagePipe.API.EncodeAheadWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Delivery.StreamPull
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Output.JpegOptions
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: VipsImage

  @moduletag :tmp_dir

  @source Path.expand("../../support/image_pipe/test/sources/high_freq.jpg", __DIR__)

  setup_all do
    bytes = File.read!(@source)
    %{truncated: binary_part(bytes, 0, div(byte_size(bytes), 2))}
  end

  # Without a transform, nothing buffers the frame before the encoder, which
  # reads the corrupt tail while it encodes. The response still hasn't
  # started, so the failure is a 415.
  for options <-
        ~w(format=jpeg format=webp format=avif format=png format=jpeg/jpeg-options=progressive) do
    test "a truncated source fails as 415 with #{options}", %{truncated: truncated} do
      response = response(unquote(options), truncated)

      assert response.status == 415
    end
  end

  # Encoding ahead is right only for an encoder that writes nothing before it
  # has read every pixel: it then sends nothing earlier by streaming. Each
  # format encoded ahead must fail on a source that breaks halfway before it
  # yields a byte. If a libvips upgrade makes one stream, this fails, and
  # `Encoder.encode_ahead?/1` should stream that format instead.
  for {format, suffix} <- [jpeg: ".jpg[optimize-coding=true]", webp: ".webp", avif: ".avif"] do
    test "the #{format} encoder yields nothing before reading every pixel",
         %{tmp_dir: dir, truncated: truncated} do
      assert Encoder.encode_ahead?(resolved(unquote(format)))

      path = Path.join(dir, "truncated.jpg")
      File.write!(path, truncated)
      {:ok, image} = VipsImage.new_from_file(path <> "[access=sequential,fail_on=error]")

      assert {:error, {:encode, _exception, _stack}} =
               StreamPull.translate(fn ->
                 StreamPull.first_chunk(VipsImage.write_to_stream(image, unquote(suffix)))
               end)
    end
  end

  test "PNG and progressive JPEG stream instead" do
    refute Encoder.encode_ahead?(resolved(:png))

    refute Encoder.encode_ahead?(%{
             resolved(:jpeg)
             | encoder_options: %JpegOptions{interlace: true}
           })
  end

  defp resolved(format) do
    %Resolved{
      format: format,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  defp response(options, body) do
    origin = fn conn -> conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body) end

    config =
      ImagePipe.Plug.init(
        allow_unsigned: true,
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ]
      )

    conn(:get, "/#{options}/src/image") |> ImagePipe.Plug.call(config)
  end
end
