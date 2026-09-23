defmodule ImagePipe.Decode.StreamingTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Decode.Streaming
  alias ImagePipe.Source.Download
  alias Vix.Vips.Image, as: VipsImage

  test "accepts a progressive JPEG prefix from the overlap benchmark" do
    body = File.read!("priv/static/images/waterfall.jpg")
    prefix = binary_part(body, 0, 256 * 1024)
    assert {:ok, image} = Image.from_binary(prefix)
    assert {:ok, 1} = VipsImage.header_value(image, "jpeg-multiscan")
    assert Streaming.eligible?(prefix)
  end

  test "accepts baseline JPEG headers" do
    body = File.read!("priv/static/images/woman.jpg")
    assert {:ok, image} = Image.from_binary(body)
    assert {:ok, 0} = VipsImage.header_value(image, "jpeg-multiscan")
    assert Streaming.eligible?(body)
  end

  test "falls back when the native decoder cannot open the prefix" do
    assert Streaming.eligible?(<<0xFF, 0xD8>>) == false
    assert Streaming.eligible?("invalid image") == false
  end

  test "accepts a PNG header without waiting for its complete body" do
    body = File.read!("priv/static/images/cooking.png")
    assert Streaming.eligible?(binary_part(body, 0, min(byte_size(body), 256 * 1024)))
  end

  test "keeps WebP on the buffered path" do
    body = Image.new!(8, 8) |> Image.write!(:memory, suffix: ".webp")
    refute Streaming.eligible?(body)
  end

  test "streamed progressive JPEG produces the same pixels as a buffered open" do
    path = "priv/static/images/waterfall.jpg"
    body = File.read!(path)

    download =
      start_supervised!({Download, owner: self(), path: path, available: byte_size(body)})

    :ok = Download.finish(download)
    assert {:ok, streamed} = Streaming.open(download, access: :sequential, shrink: 8)
    assert {:ok, buffered} = Image.from_binary(body, access: :sequential, shrink: 8)
    assert VipsImage.write_to_binary(streamed) == VipsImage.write_to_binary(buffered)
  end
end
