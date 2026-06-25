defmodule ImagePipe.Output.EncoderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Resolved

  defp png_resolved do
    %Resolved{
      format: :png,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: false,
      color_profile: :srgb
    }
  end

  test "stream_output returns nil meta on the non-search (lazy) path" do
    {:ok, image} = Image.new(64, 64, color: [100, 150, 200])

    assert {:ok, _stream, "image/png", nil} = Encoder.stream_output(image, png_resolved(), [])
  end
end
