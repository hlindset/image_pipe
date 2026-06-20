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

  describe "stream_output/3 (search path)" do
    test "honors a max_bytes ceiling (best-effort)" do
      {:ok, img} = Image.open(@fixture)

      resolved = %Resolved{
        format: :jpeg,
        quality: :default,
        response_headers: [],
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip,
        max_bytes: 200_000
      }

      {:ok, stream, mime} = Encoder.stream_output(img, resolved, [])
      body = stream |> Enum.to_list() |> IO.iodata_to_binary()
      assert mime == "image/jpeg"
      assert byte_size(body) <= 200_000
    end

    test "runs an ssim2 search and produces a decodable body" do
      {:ok, img} = Image.open(@fixture)

      rs = %ImagePipe.Output.ResolvedQualitySearch{
        objective: :ssim2,
        target: 85.0,
        min_quality: 50,
        max_quality: 90,
        allowed_error: 1.0
      }

      resolved = %Resolved{
        format: :jpeg,
        quality: :default,
        response_headers: [],
        strip_metadata: true,
        keep_copyright: true,
        color_profile: :strip,
        quality_search: rs
      }

      {:ok, stream, _mime} = Encoder.stream_output(img, resolved, [])
      body = stream |> Enum.to_list() |> IO.iodata_to_binary()
      assert {:ok, _decoded} = Image.from_binary(body)
    end
  end
end
