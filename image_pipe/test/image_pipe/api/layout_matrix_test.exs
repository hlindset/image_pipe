defmodule ImagePipe.API.LayoutMatrixTest do
  @moduledoc """
  Runs every operation over every pixel layout ImagePipe accepts (band count,
  bit depth, embedded profile) and checks invariants that hold for all of them:
  the request succeeds, the band count fits the output's color space, alpha
  appears only where an operation adds it, 16-bit output stays 16-bit under
  `hdr=preserve`, and alpha an operation adds leaves the image itself opaque.

  It is a wide, shallow net: findings become focused tests elsewhere.
  """
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Output.ColorProfile
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @layouts ~w(rgb rgba gray gray_alpha bitonal palette rgb16 rgba16 grey16 cmyk p3 p3_16 tiny)

  # Operations whose result has alpha even when the source has none.
  @adds_alpha ~w(pad=6 w=80/h=80/fit=contain/extend w=96/h=40/fit=contain/extend-ratio rotate=30 pad=6/bg=ff0000,0.5 w=40/dpr=2/pad=2/-/pad=2)

  # Operations whose result is 8-bit whatever the source depth.
  @eight_bit ~w(bitonal)

  @operations [
    "w=40",
    "w=40/h=40/fit=cover",
    "w=40/h=40/fit=stretch",
    "crop=30,20/anchor=bottom-right",
    "crop=30,30/anchor=smart",
    "region=0,0,30,20",
    "rotate=90",
    "rotate=30",
    "flip=hv",
    "trim=auto",
    "w=80/h=80/fit=contain/extend",
    "w=96/h=40/fit=contain/extend-ratio",
    "pad=6",
    "pad=6/bg=ff0000",
    "pad=6/bg=808080",
    "pad=6/bg=ff0000,0.5",
    "blur=2",
    "sharpen=1",
    "pixelate=4",
    "progressive-blur=3",
    "gray",
    "bitonal",
    "monochrome=0.8,704214",
    "duotone=1,123456,efab89",
    "brightness=20",
    "contrast=1.3",
    "saturation=0.5",
    "colorize=0.5,ff0000",
    "gradient=0.7,000080,down",
    "wm=mark/wm-scale=0.3",
    "wm=mark/wm-tile/wm-scale=0.2",
    # Groups that change the layout partway through.
    "gray/-/pad=6/bg=ff0000",
    "w=40/-/rotate=30/bg=00ff00",
    "w=40/dpr=2/pad=2/-/pad=2"
  ]

  @modes [default: "", preserve: "hdr=preserve/profile=preserve/"]

  setup_all do
    files = Map.new(@layouts, &{&1, layout(&1)})
    {:ok, config: config(files)}
  end

  for layout <- @layouts, {mode, prefix} <- @modes, operation <- @operations do
    @layout layout
    @mode mode
    @request "/#{prefix}#{operation}/format=png/src/#{layout}"
    @operation operation

    test "#{layout} #{mode}: #{operation}", %{config: config} do
      source = source_facts(@layout)
      output = request_image(@request, config)
      check_invariants(output, source, @operation, @mode)
    end
  end

  for layout <- @layouts, format <- ~w(jpeg webp avif), operation <- ["w=40", "pad=6"] do
    @format format
    @request "/#{operation}/format=#{format}/src/#{layout}"

    test "#{layout} as #{format}: #{operation}", %{config: config} do
      output = request_image(@request, config)

      if @format == "jpeg",
        do: assert(VipsImage.bands(output) in [1, 3], "JPEG output has no alpha band")
    end
  end

  defp check_invariants(output, source, operation, mode) do
    check_bands(output)
    check_alpha_origin(output, source, operation)
    check_depth(output, source, operation, mode)
    check_opacity(output, source, operation)
  end

  defp check_bands(output) do
    bands = VipsImage.bands(output)

    case VipsImage.interpretation(output) do
      gray when gray in [:VIPS_INTERPRETATION_B_W, :VIPS_INTERPRETATION_GREY16] ->
        assert bands in [1, 2], "gray output with #{bands} bands"

      color when color in [:VIPS_INTERPRETATION_sRGB, :VIPS_INTERPRETATION_RGB16] ->
        assert bands in [3, 4], "color output with #{bands} bands"

      other ->
        flunk("unexpected output interpretation #{inspect(other)}")
    end
  end

  defp check_alpha_origin(output, source, operation) do
    unless source.alpha? or operation in @adds_alpha do
      refute Image.has_alpha?(output), "alpha appeared from an operation that doesn't add it"
    end
  end

  defp check_depth(output, source, operation, mode) do
    if mode == :preserve and source.sixteen_bit? and operation not in @eight_bit do
      assert VipsImage.format(output) == :VIPS_FORMAT_USHORT, "16-bit depth was lost"
    end
  end

  # Where an operation adds alpha around an opaque image (padding, canvas), the
  # image itself stays fully opaque.
  defp check_opacity(output, source, operation) do
    if Image.has_alpha?(output) and not source.alpha? and
         operation not in ~w(rotate=30 pad=6/bg=ff0000,0.5) do
      centre = Image.get_pixel!(output, div(Image.width(output), 2), div(Image.height(output), 2))
      full = if VipsImage.format(output) == :VIPS_FORMAT_USHORT, do: 65_535, else: 255
      assert List.last(centre) == full, "added alpha left the image #{List.last(centre)}/#{full}"
    end
  end

  defp source_facts(layout) do
    %{
      alpha?: layout in ~w(rgba gray_alpha rgba16),
      sixteen_bit?: layout in ~w(rgb16 rgba16 grey16 p3_16)
    }
  end

  # A 64×48 base with distinct regions, so crops, trim and smart crop have edges.
  defp base do
    64
    |> Image.new!(48, color: [40, 120, 200])
    |> Image.Draw.rect!(0, 0, 64, 6, color: [250, 250, 250])
    |> Image.Draw.rect!(10, 12, 20, 20, color: [220, 40, 40])
    |> Image.Draw.rect!(36, 20, 20, 20, color: [40, 200, 80])
  end

  defp alpha_band do
    {:ok, alpha} = Operation.xyz(64, 48)
    {:ok, alpha} = Operation.extract_band(alpha, 0)
    {:ok, alpha} = Operation.linear(alpha, [3.0], [60.0])
    {:ok, alpha} = Operation.cast(alpha, :VIPS_FORMAT_UCHAR)
    alpha
  end

  defp layout("rgb"), do: png(base())
  defp layout("rgba"), do: base() |> with_alpha() |> png()
  defp layout("gray"), do: base() |> gray() |> png()
  defp layout("gray_alpha"), do: base() |> gray() |> with_alpha() |> png()

  defp layout("bitonal") do
    {:ok, bits} =
      Operation.relational_const(gray(base()), :VIPS_OPERATION_RELATIONAL_MOREEQ, [128.0])

    {:ok, body} = VipsImage.write_to_buffer(bits, ".png[bitdepth=1]")
    body
  end

  defp layout("palette") do
    {:ok, body} = VipsImage.write_to_buffer(base(), ".png[palette]")
    body
  end

  defp layout("rgb16"), do: base() |> sixteen(:VIPS_INTERPRETATION_RGB16) |> png()

  defp layout("rgba16"),
    do: base() |> with_alpha() |> sixteen(:VIPS_INTERPRETATION_RGB16) |> png()

  defp layout("grey16"), do: base() |> gray() |> sixteen(:VIPS_INTERPRETATION_GREY16) |> png()
  defp layout("cmyk"), do: File.read!("test/support/image_pipe/test/sources/cmyk.jpg")
  defp layout("p3"), do: base() |> p3(8) |> png()
  defp layout("p3_16"), do: base() |> p3(16) |> png()
  defp layout("tiny"), do: png(Image.new!(1, 1, color: [200, 60, 40]))

  defp gray(image) do
    {:ok, gray} = Operation.colourspace(image, :VIPS_INTERPRETATION_B_W)
    gray
  end

  defp with_alpha(image) do
    {:ok, joined} = Operation.bandjoin([image, alpha_band()])
    joined
  end

  defp sixteen(image, interpretation) do
    {:ok, scaled} = Operation.linear(image, [257.0], [0.0])
    {:ok, cast} = Operation.cast(scaled, :VIPS_FORMAT_USHORT)
    {:ok, tagged} = Operation.copy(cast, interpretation: interpretation)
    tagged
  end

  defp p3(image, depth) do
    {:ok, p3} =
      Operation.icc_transform(image, ColorProfile.path!(:display_p3),
        input_profile: "sRGB",
        depth: depth
      )

    p3
  end

  defp png(image), do: Image.write!(image, :memory, suffix: ".png")

  defp config(files) do
    files = Map.put(files, "mark", File.read!("test/support/image_pipe/test/sources/alpha.png"))

    origin = fn conn ->
      body = Map.fetch!(files, Path.basename(conn.request_path))
      conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, body)
    end

    ImagePipe.Plug.init(
      sources: [
        path: [
          adapter: RootHTTPAdapter,
          match: :path,
          options: [root_url: "http://origin.test", req_options: [plug: origin]]
        ]
      ],
      watermarks: %{mark: [source: "mark"]}
    )
  end

  defp request_image(path, config) do
    response = conn(:get, path) |> ImagePipe.Plug.call(config)

    assert response.status == 200,
           "#{path}: #{response.status} #{String.slice(response.resp_body, 0, 200)}"

    Image.from_binary!(response.resp_body)
  end
end
