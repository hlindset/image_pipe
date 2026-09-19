defmodule ImagePipe.Output.EncoderOptionsEncodeTest do
  use ExUnit.Case, async: true

  alias ImagePipe.API.Config
  alias ImagePipe.API.Output, as: APIOutput
  alias ImagePipe.API.Parser
  alias ImagePipe.Output.{Encoder, Policy, Resolved}
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, JxlOptions, PngOptions, WebpOptions}

  defp finalized(w \\ 64, h \\ 64) do
    {:ok, img} = Image.new(w, h, color: [120, 30, 30])
    img
  end

  defp resolved(format, encoder_options) do
    %Resolved{
      format: format,
      quality: {:quality, 75},
      response_headers: [],
      strip_metadata: true,
      keep_copyright: false,
      color_profile: :strip,
      encoder_options: encoder_options
    }
  end

  test "encode_to_buffer with no encoder options produces a decodable image" do
    {:ok, bin} = Encoder.encode_to_buffer(finalized(), resolved(:jpeg, nil), 75)
    {:ok, decoded} = Image.from_binary(bin)
    assert Image.width(decoded) == 64
  end

  test "progressive jpeg via encoder options is interlaced and decodable" do
    opts = %JpegOptions{interlace: true, trellis_quant: true, quant_table: 3}
    {:ok, bin} = Encoder.encode_to_buffer(finalized(), resolved(:jpeg, opts), 75)
    {:ok, decoded} = Image.from_binary(bin)
    assert Image.width(decoded) == 64
    # progressive marker SOF2 (0xFFC2) present in a progressive JPEG
    assert :binary.match(bin, <<0xFF, 0xC2>>) != :nomatch
  end

  test "API encoder options reach encoding through output policy" do
    config = Config.validate!([])
    segments = ["format=jpeg", "q=75", "jpeg-options=progressive"]

    lexed = %{
      segments: Enum.map(segments, &{&1, {0, byte_size(&1)}}),
      source: {:src, "test.jpg", {0, 8}}
    }

    assert {:ok, request} = Parser.parse(lexed, config)
    assert {:ok, policy} = APIOutput.resolve(request.output, config, "")
    {:ok, resolved} = Policy.resolve(policy, :jpeg)
    assert resolved.encoder_options == %JpegOptions{interlace: true}

    {:ok, bin} = Encoder.encode_to_buffer(finalized(), resolved, 75)
    assert :binary.match(bin, <<0xFF, 0xC2>>) != :nomatch
  end

  test "palette png via encoder options is decodable" do
    opts = %PngOptions{palette: true, bitdepth: 4, filter: :none}
    {:ok, bin} = Encoder.encode_to_buffer(finalized(), resolved(:png, opts), 75)
    {:ok, decoded} = Image.from_binary(bin)
    assert Image.width(decoded) == 64
  end

  test "webp + avif options encode via the Vix path and decode" do
    {:ok, wbin} =
      Encoder.encode_to_buffer(
        finalized(),
        resolved(:webp, %WebpOptions{preset: :photo, smart_subsample: true}),
        75
      )

    assert {:ok, wimg} = Image.from_binary(wbin)
    assert Image.width(wimg) == 64

    {:ok, abin} =
      Encoder.encode_to_buffer(
        finalized(),
        resolved(:avif, %AvifOptions{subsample_mode: :off, effort: 0}),
        75
      )

    assert {:ok, aimg} = Image.from_binary(abin)
    assert Image.width(aimg) == 64
  end

  test "byte-neutral: empty options == nil options for the same source/quality" do
    a = Encoder.encode_to_buffer(finalized(), resolved(:jpeg, nil), 75)
    b = Encoder.encode_to_buffer(finalized(), resolved(:jpeg, %JpegOptions{}), 75)
    assert a == b
  end

  test "JXL effort: unset JxlOptions encodes identically to nil (libvips default 7)" do
    a = Encoder.encode_to_buffer(finalized(), resolved(:jpeg_xl, nil), 75)
    b = Encoder.encode_to_buffer(finalized(), resolved(:jpeg_xl, %JxlOptions{}), 75)
    assert a == b
  end
end
