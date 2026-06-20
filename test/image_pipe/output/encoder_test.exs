defmodule ImagePipe.Output.EncoderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Resolved

  @fixture "test/support/image_pipe/test/imgproxy_differential/sources/high_freq.jpg"

  defp resolved do
    %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  describe "encode_to_buffer/3" do
    test "encodes to an in-memory binary; lower quality yields fewer bytes" do
      {:ok, img} = Image.open(@fixture)

      assert {:ok, q20} = Encoder.encode_to_buffer(img, resolved(), 20)
      assert {:ok, q90} = Encoder.encode_to_buffer(img, resolved(), 90)
      assert is_binary(q20)
      assert is_binary(q90)
      assert byte_size(q20) < byte_size(q90)
    end
  end

  describe "stream_output/3 (no-search path)" do
    test "produces a streamable encode with the right mime type" do
      {:ok, img} = Image.open(@fixture)

      assert {:ok, stream, "image/jpeg"} = Encoder.stream_output(img, resolved(), [])

      binary = stream |> Enum.into([]) |> IO.iodata_to_binary()
      assert byte_size(binary) > 0
      assert {:ok, _decoded} = Image.from_binary(binary)
    end
  end
end
