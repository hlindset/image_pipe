defmodule ImagePipe.API.SrgbProfileWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage
  alias Vix.Vips.Operation

  # An sRGB-equivalent embedded profile is treated as no profile: a source
  # tagged with one gives the same response bytes as its untagged copy.

  @facebook_srgb "priv/static/images/woman.jpg"

  setup_all do
    {:ok, woman} = VipsImage.new_from_file(@facebook_srgb)
    {:ok, facebook} = VipsImage.header_value(woman, "icc-profile-data")
    content = content()

    files = %{
      "untagged.png" => png(content),
      "facebook.png" => png(tag(content, facebook)),
      "srgb.png" => png(tag(content, File.read!("priv/icc/sRGB.icc"))),
      "p3.png" => png(tag(content, File.read!("priv/icc/DisplayP3.icc"))),
      "mark.png" => png(Image.new!(12, 12, color: [200, 30, 90]))
    }

    %{config: mount(files), facebook: facebook}
  end

  @requests [
    "w=60",
    "w=60/gray",
    "w=60/monochrome=0.8",
    "w=60/duotone=1,123456,efab89",
    "w=60/colorize=0.5,red",
    "w=60/gradient=0.8,black",
    "w=60/gray/pad=10/bg=ff0000",
    "w=60/gray/wm=logo",
    "w=60/pad=10/bg=ff0000",
    "w=60/wm=logo/wm-scale=0.2",
    "trim=auto/w=60"
  ]

  for source <- ["facebook.png", "srgb.png"] do
    test "#{source} gives the untagged source's response bytes", %{config: config} do
      for options <- @requests, format <- ["png", "jpeg"] do
        tagged = response("#{options}/format=#{format}", unquote(source), config)
        untagged = response("#{options}/format=#{format}", "untagged.png", config)

        assert tagged.resp_body == untagged.resp_body, "#{options}/format=#{format}"
      end
    end
  end

  test "a wide-gamut profile still converts", %{config: config} do
    p3 = response("w=60/format=png", "p3.png", config)
    untagged = response("w=60/format=png", "untagged.png", config)

    refute p3.resp_body == untagged.resp_body
  end

  test "preserving the profile keeps it on a plain request and drops it after gray",
       %{config: config, facebook: facebook} do
    kept = response("w=60/format=png/profile=preserve", "facebook.png", config) |> decoded()
    assert header(kept, "icc-profile-data") == facebook

    gray = response("w=60/gray/format=png/profile=preserve", "facebook.png", config)
    assert header(decoded(gray), "icc-profile-data") == nil

    assert gray.resp_body ==
             response("w=60/gray/format=png/profile=preserve", "untagged.png", config).resp_body
  end

  # Every 8-bit color on a 16-level lattice, framed by a white border for trim
  # and with a transparent strip for the background tests.
  defp content do
    steps = Enum.map(0..16, &min(&1 * 16, 255))
    bytes = for r <- steps, g <- steps, b <- steps, into: <<>>, do: <<r, g, b, 255>>
    {:ok, lattice} = VipsImage.new_from_binary(bytes, 289, 17, 4, :VIPS_FORMAT_UCHAR)
    {:ok, lattice} = Operation.copy(lattice, interpretation: :VIPS_INTERPRETATION_sRGB)

    clear = Image.new!(289, 6, color: [10, 120, 200, 0])
    {:ok, body} = Operation.join(lattice, clear, :VIPS_DIRECTION_VERTICAL)

    {:ok, framed} =
      Operation.embed(body, 8, 8, 305, 39,
        extend: :VIPS_EXTEND_BACKGROUND,
        background: [255.0, 255.0, 255.0, 255.0]
      )

    framed
  end

  defp tag(image, profile) do
    {:ok, tagged} =
      VipsImage.mutate(image, fn mutable ->
        MutableImage.set(mutable, "icc-profile-data", :VipsBlob, profile)
      end)

    tagged
  end

  defp png(image), do: Image.write!(image, :memory, suffix: ".png")

  defp mount(files) do
    origin = fn conn ->
      case Map.fetch(files, Enum.join(conn.path_info, "/")) do
        {:ok, body} -> conn |> put_resp_content_type("image/png") |> send_resp(200, body)
        :error -> send_resp(conn, 404, "missing")
      end
    end

    ImagePipe.Plug.init(
      allow_unsigned: true,
      sources: [
        path: [
          match: :path,
          adapter: RootHTTPAdapter,
          options: [root_url: "http://origin.test", req_options: [plug: origin]]
        ]
      ],
      watermarks: %{logo: [source: "mark.png"]}
    )
  end

  defp response(options, name, config) do
    response = conn(:get, "/#{options}/src/#{name}") |> ImagePipe.Plug.call(config)
    assert response.status == 200, "#{options}: HTTP #{response.status} #{response.resp_body}"
    response
  end

  defp decoded(response), do: Image.from_binary!(response.resp_body)

  defp header(image, field) do
    case VipsImage.header_value(image, field) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end
end
