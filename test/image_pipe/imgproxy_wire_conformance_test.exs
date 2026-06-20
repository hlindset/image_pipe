defmodule ImagePipe.ImgproxyWireConformanceTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Output.Ssim2Metric
  alias ImagePipe.Parser.Imgproxy
  alias ImagePipe.SourceTest.CredentialProvider
  alias ImagePipe.SourceTest.FoobarTranslator
  alias ImagePipe.SourceTest.PlugCustomAdapter
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Orientation1TwinOrigin
  alias ImagePipe.Test.OrientedFrameOrigin
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.CountingOriginImage
  alias ImgproxyWireConformanceTest.OriginImage
  alias ImgproxyWireConformanceTest.OriginShouldNotFetch
  alias Vix.Vips.Image, as: VipsImage

  @source_url_encryption_key "000102030405060708090a0b0c0d0e0f"
  @source_url_encryption_iv <<16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31>>
  @alternate_source_url_encryption_iv <<31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18,
                                        17, 16>>

  defmodule SvgOriginImage do
    @moduledoc false

    def init(opts), do: opts

    def call(conn, opts) do
      opts
      |> Keyword.fetch!(:test_pid)
      |> send(:origin_fetch)

      body = """
      <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20">
        <rect width="20" height="20" fill="red"/>
      </svg>
      """

      conn
      |> Plug.Conn.put_resp_content_type("image/svg+xml")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule ExifOrientationOriginImage do
    @moduledoc false

    def call(conn, _opts) do
      body =
        40
        |> Image.new!(80, color: :white)
        |> Image.Draw.rect!(0, 0, 40, 40, color: :red)
        |> Image.set_orientation!(6)
        |> Image.write!(:memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  # Deferred-orientation gate (#146) origins. Both serve the SAME displayed
  # pixels: `OrientedFrameOrigin` tags a stored image with an EXIF orientation
  # (so the pipeline must autorotate it), while `Orientation1TwinOrigin` decodes
  # that same tagged image, applies the autorotate in pixels, strips the tag, and
  # serves the result as a lossless orientation-1 PNG. Running an identical
  # imgproxy request against both is the wire-vs-orientation-1 oracle: the same
  # operators run on the same displayed content, so the decoded outputs match.
  #
  # The base content is a 120×200 portrait with sharp solid quadrants and a
  # corner marker; large enough that a ±1px affine-resize seam shift never reaches
  # the interior flat-region samples the oracle compares.
  defmodule OrientationFixture do
    @moduledoc false

    def base do
      120
      |> Image.new!(200, color: :green)
      |> Image.Draw.rect!(0, 0, 120, 100, color: :red)
      |> Image.Draw.rect!(0, 0, 30, 30, color: :blue)
    end

    # Lossless base bytes fed to the shared `ImagePipe.Test.OrientedFrameOrigin` /
    # `ImagePipe.Test.Orientation1TwinOrigin`, which tag/autorotate them per
    # orientation. PNG keeps the base pixels exact so the oracle compares identical
    # displayed content across both legs.
    def base_png, do: Image.write!(base(), :memory, suffix: ".png")
  end

  # A LOSSLESS oracle for fixed-coordinate / non-center / offset crops, where the
  # JPEG twin + flat-region sampling above is too insensitive to catch a 1px
  # placement error (#146 Bugs 2 & 3). The source is a sharp-feature 120×200 PNG;
  # the oriented leg tags it with an EXIF orientation (PNG carries the tag, the
  # pipeline must autorotate), and the eager-flush-first twin autorotates the same
  # tagged PNG into display pixels and stores it untagged. Both legs are lossless
  # PNG end-to-end, so an identical request that selects different content per
  # orientation still produces byte-comparable interiors — every pixel is asserted
  # within a tiny tolerance, so a 1px shift fails loudly.
  defmodule SharpOrientationFixture do
    @moduledoc false

    # 120×200 with distinct sharp features in every region: solid quadrants plus a
    # vertical and a horizontal white line at known storage coordinates so that any
    # placement error moves a feature relative to the comparison.
    def base do
      120
      |> Image.new!(200, color: :green)
      |> Image.Draw.rect!(0, 0, 60, 100, color: :red)
      |> Image.Draw.rect!(60, 0, 60, 100, color: :blue)
      |> Image.Draw.rect!(0, 100, 60, 100, color: :yellow)
      |> Image.Draw.rect!(61, 0, 1, 200, color: :white)
      |> Image.Draw.rect!(0, 131, 120, 1, color: :white)
    end

    def oriented_png(orientation) do
      base() |> Image.set_orientation!(orientation) |> Image.write!(:memory, suffix: ".png")
    end

    def twin_png(orientation) do
      reopened = Image.open!(oriented_png(orientation), access: :random)
      {:ok, {displayed, _flags}} = Image.autorotate(reopened)
      displayed |> Image.set_orientation!(1) |> Image.write!(:memory, suffix: ".png")
    end
  end

  defmodule SharpOrientedOrigin do
    @moduledoc false

    def init(orientation), do: orientation

    def call(conn, orientation) do
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, SharpOrientationFixture.oriented_png(orientation))
    end
  end

  defmodule SharpTwinOrigin do
    @moduledoc false

    def init(orientation), do: orientation

    def call(conn, orientation) do
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, SharpOrientationFixture.twin_png(orientation))
    end
  end

  defmodule LineOrigin do
    @moduledoc false
    # 120×200 black PNG with a single white row at storage y=150, for asserting the
    # exact vertical placement of a south-offset crop (#146 Bug 3 baseline).
    def init(_), do: nil

    def call(conn, _) do
      body =
        120
        |> Image.new!(200, color: :black)
        |> Image.Draw.rect!(0, 150, 120, 1, color: :white)
        |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule MetadataOriginImage do
    @moduledoc false

    alias Vix.Vips.Image, as: VixImage
    alias Vix.Vips.MutableImage, as: VixMutableImage

    # Generates a JPEG carrying EXIF (Copyright + ImageDescription) and XMP so
    # wire tests can assert that sm/kcr strip or retain them as expected.
    def init(opts), do: opts

    def call(conn, opts) do
      if pid = Keyword.get(List.wrap(opts), :test_pid), do: send(pid, :origin_fetch)

      img = Image.new!(100, 100, color: :white)

      {:ok, with_metadata} =
        VixImage.mutate(img, fn mut ->
          VixMutableImage.set(mut, "exif-ifd0-Copyright", :gchararray, "(c) ACME")
          VixMutableImage.set(mut, "exif-ifd0-ImageDescription", :gchararray, "A test image")
          VixMutableImage.set(mut, "xmp-data", :VipsBlob, "<x:xmpmeta/>")
          :ok
        end)

      body = Image.write!(with_metadata, :memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule ColorCharOriginImage do
    @moduledoc false

    alias Vix.Vips.Image, as: VixImage
    alias Vix.Vips.MutableImage, as: VixMutableImage

    # Generates a JPEG carrying the three EXIF color-characterization tags that
    # imgproxy's `vips_icc_remove` strips when it drops the profile, plus a
    # non-color EXIF field (ImageDescription) as a control so a wire test can
    # show the profile-drop path — not general metadata stripping — removes them.
    def call(conn, _opts) do
      img = Image.new!(64, 64, color: [10, 200, 30])

      {:ok, tagged} =
        VixImage.mutate(img, fn mut ->
          VixMutableImage.set(mut, "exif-ifd0-WhitePoint", :gchararray, "0.3127 0.329")

          VixMutableImage.set(
            mut,
            "exif-ifd0-PrimaryChromaticities",
            :gchararray,
            "0.64 0.33 0.3 0.6 0.15 0.06"
          )

          VixMutableImage.set(mut, "exif-ifd2-ColorSpace", :gchararray, "65535")
          VixMutableImage.set(mut, "exif-ifd0-ImageDescription", :gchararray, "A test image")
          :ok
        end)

      body = Image.write!(tagged, :memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule WideGamutOriginImage do
    @moduledoc false

    # Generates a P3 wide-gamut PNG carrying an embedded ICC profile.
    # `Image.to_colorspace(_, :p3, [])` attaches a P3 ICC profile to the
    # in-memory image, and libvips embeds it in the PNG stream on write.
    # Re-opening the PNG bytes confirms "icc-profile-data" is present.
    def call(conn, _opts) do
      {:ok, base} = Image.new(40, 40, color: [200, 50, 50])
      {:ok, p3_img} = Image.to_colorspace(base, :p3, [])
      body = Image.write!(p3_img, :memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule EffectOriginImage do
    @moduledoc false

    def call(conn, _opts) do
      body =
        64
        |> Image.new!(64, color: :black)
        |> Image.Draw.rect!(0, 0, 32, 64, color: :white)
        |> Image.Draw.rect!(16, 0, 16, 64, color: :red)
        |> Image.Draw.rect!(32, 0, 16, 64, color: :green)
        |> Image.Draw.rect!(48, 0, 16, 64, color: :blue)
        |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule AvifOriginImage do
    @moduledoc false

    # Serves a committed 64x64 AVIF fixture rather than encoding at request
    # time, so the source is available even on libvips builds without AVIF
    # *write* support (decoding an AVIF source needs only AVIF read).
    def call(conn, _opts) do
      body = File.read!("test/support/image_pipe/imgproxy_wire_conformance_test/cat.avif")

      conn
      |> Plug.Conn.put_resp_content_type("image/avif")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule AlphaOriginImage do
    @moduledoc false

    # Serves a 20×20 fully-transparent RGBA PNG. Used to verify that bl: + bg:
    # on an alpha source flattens the output (no alpha channel in response).
    def call(conn, _opts) do
      body =
        Image.new!(20, 20, color: [0, 0, 0, 0], bands: 4)
        |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule TrimOriginImage do
    @moduledoc false
    # 64x64 black border with a white 40x44 inner block at (12, 10).
    def call(conn, _opts) do
      body =
        64
        |> Image.new!(64, color: :black)
        |> Image.Draw.rect!(12, 10, 40, 44, color: :white)
        |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule UniformOriginImage do
    @moduledoc false
    # Solid 64x64 black — nothing to trim.
    def call(conn, _opts) do
      body = Image.new!(64, 64, color: :black) |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule WideGamutTrimOriginImage do
    @moduledoc false
    # 64x64 Display-P3 PNG with a 10px black border and a 44x44 colored inner block.
    # trim:10 = threshold 10; the solid-black border is within tolerance, so trim crops to the inner block.
    def call(conn, _opts) do
      {:ok, base} = Image.new(64, 64, color: [0, 0, 0])
      {:ok, p3_base} = Image.to_colorspace(base, :p3, [])
      {:ok, inner} = Image.new(44, 44, color: [200, 50, 50])
      {:ok, p3_inner} = Image.to_colorspace(inner, :p3, [])
      body = Image.Draw.image!(p3_base, p3_inner, 10, 10) |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule GreyscaleTrimOriginImage do
    @moduledoc false
    alias Vix.Vips.Operation

    # 64x64 B_W (greyscale) PNG with a white border and a black 40x44 inner block at (12, 10).
    # Mirrors TrimOriginImage geometry but as a single-band greyscale source so the
    # trim pipeline exercises the B_W working space.
    def call(conn, _opts) do
      {:ok, rgb_base} = Image.new(64, 64, color: :white)
      {:ok, grey_base} = Operation.colourspace(rgb_base, :VIPS_INTERPRETATION_B_W)
      {:ok, rgb_inner} = Image.new(40, 44, color: :black)
      {:ok, grey_inner} = Operation.colourspace(rgb_inner, :VIPS_INTERPRETATION_B_W)

      body =
        Image.Draw.image!(grey_base, grey_inner, 12, 10) |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule CmykOriginImage do
    @moduledoc false
    # Serves the committed CMYK JPEG fixture which carries an embedded CMYK ICC profile.
    def call(conn, _opts) do
      body = File.read!("test/support/image_pipe/test/imgproxy_differential/sources/cmyk.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule Hdr16OriginImage do
    @moduledoc false
    # Serves the committed genuine-16-bit RGB PNG fixture (interpretation RGB16).
    def call(conn, _opts) do
      body = File.read!("test/support/image_pipe/test/imgproxy_differential/sources/rgb16.png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule LinearLightOriginImage do
    @moduledoc false
    alias Vix.Vips.Operation

    # Serves a small scRGB (linear-light) PNG. libvips creates an scRGB image via
    # colourspace conversion from sRGB; the interpretation is :VIPS_INTERPRETATION_scRGB.
    # InputColorManagement treats this as a "linear-light" branch: it drops the profile
    # (no backup recorded) and converts to the working space.
    def call(conn, _opts) do
      {:ok, base} = Image.new(20, 20, color: [180, 60, 60])
      {:ok, linear} = Operation.colourspace(base, :VIPS_INTERPRETATION_scRGB)
      body = Image.write!(linear, :memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule CorruptSourceOriginImage do
    @moduledoc false
    # Returns a response with content-type image/png but a body that is not a
    # valid image. The pipeline decode step must surface {:decode, _} -> 415.
    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, "not a valid image \xFF\xFE\x00")
    end
  end

  defmodule SolidWideOrigin do
    @moduledoc false
    # Solid 400x300 (4:3) opaque red — larger than the extend targets below, so the
    # fit shrink keeps imgproxy's DprScale at the requested dpr (a source smaller than
    # the target collapses DprScale to 1.0 under enlarge-off). Opaque, so the
    # transparent extend background is detectable by the output alpha channel.
    def call(conn, _opts) do
      body = Image.new!(400, 300, color: [255, 0, 0]) |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule UnavailableDetector do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_opts), do: ["face"]

    @impl true
    def detect(_image, _opts), do: {:error, {:detector, :unavailable}}

    @impl true
    def available?(_opts), do: false

    @impl true
    def identity(_opts), do: {__MODULE__, :unavailable}
  end

  defmodule FaceVerFake do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_), do: ["face"]

    @impl true
    def available?(_), do: true

    @impl true
    def identity(opts), do: {__MODULE__, Keyword.get(opts, :face_ver, :v1)}

    @impl true
    def detect(_, _), do: {:ok, []}
  end

  defmodule ObjectVerFake do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_), do: ["car", "dog"]

    @impl true
    def available?(_), do: true

    @impl true
    def identity(opts), do: {__MODULE__, Keyword.get(opts, :object_ver, :v1)}

    @impl true
    def detect(_, _), do: {:ok, []}
  end

  defmodule VerComposite do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    alias ImagePipe.Transform.Detector.Composite

    defp c, do: Composite.new([FaceVerFake, ObjectVerFake])

    @impl true
    def supported_classes(_o), do: Composite.supported_classes(c())

    @impl true
    def detect(i, o), do: Composite.detect(c(), i, o)

    @impl true
    def available?(o), do: Composite.available?(c(), o)

    @impl true
    def identity(o), do: Composite.identity(c(), o)
  end

  # Task 10: CornerObjectDetector — places a small box near the top-left so a
  # fill-crop biases up-left, distinct from center and attention saliency.
  defmodule CornerObjectDetector do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_), do: ["car", "dog", "face", "person"]

    @impl true
    def available?(opts), do: Keyword.get(opts, :available?, true)

    @impl true
    def identity(_), do: {__MODULE__, :v1}

    @impl true
    def detect(_image, opts) do
      classes = Keyword.get(opts, :classes, :all)
      label = if classes == :all, do: "car", else: List.first(List.wrap(classes))
      {:ok, [%{label: label, score: 0.95, box: {2, 2, 20, 20}}]}
    end
  end

  # Slice 2: a large "person" box and a small "face" box, class-aware so obj:person
  # / obj:face filter to one box. Sized as large fractions of beach.jpg (4000×2667)
  # so the fill-crop window actually moves between weightings.
  defmodule WeightedSceneDetector do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @boxes [
      %{label: "person", score: 0.95, box: {2000, 800, 800, 1000}},
      %{label: "face", score: 0.95, box: {1400, 600, 400, 400}}
    ]

    @impl true
    def supported_classes(_), do: ["face", "person"]

    @impl true
    def available?(opts), do: Keyword.get(opts, :available?, true)

    @impl true
    def identity(_), do: {__MODULE__, :v1}

    @impl true
    def detect(_image, opts) do
      case Keyword.get(opts, :classes, :all) do
        :all -> {:ok, @boxes}
        classes -> {:ok, Enum.filter(@boxes, &(&1.label in List.wrap(classes)))}
      end
    end
  end

  # Task 10: PartialDetector — Composite with FaceFake (available) and
  # UnavailableObjectFake (available?=false), used for the gate triad.
  defmodule GateTriadFaceFake do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_), do: ["face"]

    @impl true
    def available?(_), do: true

    @impl true
    def identity(_), do: {__MODULE__, :face_v1}

    @impl true
    def detect(_image, opts) do
      {:ok, [%{label: "face", score: 0.9, box: {0, 0, 50, 50}}]}
      |> filter_classes(Keyword.get(opts, :classes, :all))
    end

    defp filter_classes({:ok, regions}, :all), do: {:ok, regions}

    defp filter_classes({:ok, regions}, classes) when is_list(classes) do
      wanted = MapSet.new(classes)
      {:ok, Enum.filter(regions, fn %{label: l} -> MapSet.member?(wanted, l) end)}
    end
  end

  defmodule GateTriadUnavailableObjectFake do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_), do: ["car"]

    @impl true
    def available?(_), do: false

    @impl true
    def identity(_), do: {__MODULE__, :unavailable}

    @impl true
    def detect(_image, _opts), do: {:error, {:detector, :unavailable}}
  end

  defmodule PartialDetector do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    alias ImagePipe.Transform.Detector.Composite

    defp c, do: Composite.new([GateTriadFaceFake, GateTriadUnavailableObjectFake])

    @impl true
    def supported_classes(_o), do: Composite.supported_classes(c())

    @impl true
    def detect(i, o), do: Composite.detect(c(), i, o)

    @impl true
    def available?(o), do: Composite.available?(c(), o)

    @impl true
    def identity(o), do: Composite.identity(c(), o)
  end

  @default_opts [
    parser: ImagePipe.Parser.Imgproxy,
    sources: [
      path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
    ]
  ]

  @hdr_opts [
    parser: ImagePipe.Parser.Imgproxy,
    sources: [
      path:
        {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: Hdr16OriginImage]}
    ]
  ]

  test "equivalent imgproxy option order shares filesystem cache through real Plug requests" do
    {opts, cache_root} = cached_opts()

    try do
      first_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/plain/images/beach.jpg", opts)

      assert first_conn.status == 200
      assert content_type(first_conn) == ["image/jpeg"]
      assert dimensions(first_conn) == {120, 90}
      assert_received :origin_fetch

      second_conn = call_imgproxy("/_/f:jpeg/h:90/rt:force/w:120/plain/images/beach.jpg", opts)

      assert second_conn.status == 200
      assert content_type(second_conn) == ["image/jpeg"]
      assert dimensions(second_conn) == {120, 90}
      assert second_conn.resp_body == first_conn.resp_body
      refute_received :origin_fetch
    after
      File.rm_rf!(cache_root)
    end
  end

  test "encoded path source succeeds through a real Plug request" do
    encoded = encoded_source("images/beach.jpg")

    conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/#{encoded}", @default_opts)

    assert conn.status == 200
    assert content_type(conn) == ["image/jpeg"]
    assert dimensions(conn) == {120, 90}
    assert byte_size(conn.resp_body) > 0
  end

  test "automatic output negotiates modern formats from Accept and sets Vary" do
    cases = [
      {"image/avif,image/webp", "image/avif"},
      {"image/webp", "image/webp"},
      {"image/avif;q=0,image/*;q=1", "image/webp"}
    ]

    for {accept, expected_content_type} <- cases do
      conn =
        "/_/plain/images/beach.jpg"
        |> call_imgproxy(@default_opts, accept)

      assert conn.status == 200
      assert content_type(conn) == [expected_content_type]
      assert get_resp_header(conn, "vary") == ["Accept"]
      assert byte_size(conn.resp_body) > 0
    end
  end

  test "automatic output treats missing empty and wildcard-only Accept as source fallback" do
    cases = [
      nil,
      "",
      "*/*",
      "*/*;q=1",
      "application/json,*/*;q=1"
    ]

    for accept <- cases do
      conn =
        "/_/plain/images/beach.jpg"
        |> call_imgproxy(@default_opts, accept)

      assert conn.status == 200
      assert content_type(conn) == ["image/jpeg"]
      assert get_resp_header(conn, "vary") == ["Accept"]
      assert byte_size(conn.resp_body) > 0
    end
  end

  test "explicit output formats bypass Accept and do not set Vary" do
    cases = [
      {"/_/f:webp/plain/images/beach.jpg", "image/webp"},
      {"/_/f:jpeg/plain/images/beach.jpg", "image/jpeg"},
      {"/_/plain/images/beach.jpg@webp", "image/webp"}
    ]

    for {path, expected_content_type} <- cases do
      conn = call_imgproxy(path, @default_opts, "image/avif,image/webp")

      assert conn.status == 200
      assert content_type(conn) == [expected_content_type]
      assert get_resp_header(conn, "vary") == []
      assert byte_size(conn.resp_body) > 0
    end
  end

  test "encoded output suffix bypasses Accept negotiation and does not set Vary" do
    encoded = encoded_source("images/beach.jpg")

    conn = call_imgproxy("/_/f:jpeg/#{encoded}.webp", @default_opts, "image/avif,image/webp")

    assert conn.status == 200
    assert content_type(conn) == ["image/webp"]
    assert get_resp_header(conn, "vary") == []
    assert byte_size(conn.resp_body) > 0
  end

  test "encrypted path source succeeds through a real Plug request" do
    encrypted = encrypted_source("images/beach.jpg")

    conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/enc/#{encrypted}", encrypted_opts())

    assert conn.status == 200
    assert content_type(conn) == ["image/jpeg"]
    assert dimensions(conn) == {120, 90}
    assert byte_size(conn.resp_body) > 0
  end

  test "encrypted output suffix bypasses Accept negotiation and does not set Vary" do
    encrypted = encrypted_source("images/beach.jpg")

    conn =
      call_imgproxy(
        "/_/f:jpeg/enc/#{encrypted}.webp",
        encrypted_opts(),
        "image/avif,image/webp"
      )

    assert conn.status == 200
    assert content_type(conn) == ["image/webp"]
    assert get_resp_header(conn, "vary") == []
    assert byte_size(conn.resp_body) > 0
  end

  test "automatic output rejects decoded SVG source responses as unsupported images" do
    if svg_supported?() do
      conn =
        "/_/plain/images/vector.svg"
        |> call_imgproxy(svg_origin_opts(), "image/avif,image/webp")

      assert conn.status == 415
      assert conn.resp_body == "source response is not a supported image"
      assert get_resp_header(conn, "vary") == ["Accept"]
      assert_received {:cache_lookup, _key}
      assert_received :origin_fetch
      refute_received {:cache_put, _key, _entry}
    end
  end

  test "explicit output rejects decoded SVG source responses without Vary" do
    if svg_supported?() do
      for path <- ["/_/f:png/plain/images/vector.svg", "/_/plain/images/vector.svg@png"] do
        conn = call_imgproxy(path, svg_origin_opts(), "image/avif,image/webp")

        assert conn.status == 415
        assert conn.resp_body == "source response is not a supported image"
        assert get_resp_header(conn, "vary") == []
        assert_received {:cache_lookup, _key}
        assert_received :origin_fetch
        refute_received {:cache_put, _key, _entry}
      end
    end
  end

  test "representative geometry options produce expected decoded dimensions" do
    cases = [
      {"/_/rs:fit:120:90/f:jpeg/plain/images/beach.jpg", {120, 80}},
      {"/_/rs:fill:120:90/g:ce/f:jpeg/plain/images/beach.jpg", {120, 90}},
      {"/_/rt:force/w:120/h:90/f:jpeg/plain/images/beach.jpg", {120, 90}},
      {"/_/c:120:90/f:jpeg/plain/images/beach.jpg", {120, 90}},
      {"/_/g:soea/rs:fill:120:90/f:jpeg/plain/images/beach.jpg", {120, 90}}
    ]

    for {path, expected_dimensions} <- cases do
      conn = call_imgproxy(path, @default_opts)

      assert conn.status == 200
      assert content_type(conn) == ["image/jpeg"]
      assert dimensions(conn) == expected_dimensions
    end
  end

  test "g:sm smart gravity returns a smart-cropped image of the requested size" do
    conn = call_imgproxy("/_/rs:fill:80:80/g:sm/f:jpeg/plain/images/beach.jpg", @default_opts)

    assert conn.status == 200
    assert content_type(conn) == ["image/jpeg"]
    assert dimensions(conn) == {80, 80}

    # A silent fallback to center gravity would make smart and center crops
    # identical; assert the smart crop genuinely picks a different region.
    centered = call_imgproxy("/_/rs:fill:80:80/g:ce/f:jpeg/plain/images/beach.jpg", @default_opts)

    assert centered.status == 200
    refute conn.resp_body == centered.resp_body
  end

  test "exar:1 under fit extends the canvas to the resize aspect ratio" do
    # beach.jpg is 4000x2667 (landscape). rs:fit:300:300 scales it to 300x200 (width
    # is the binding axis). exar:1 extends the canvas to the 1:1 requested ratio,
    # padding the deficient axis: height grows from 200 to 300, giving a 300x300 output.
    conn = call_imgproxy("/_/rs:fit:300:300/exar:1/f:jpeg/plain/images/beach.jpg", @default_opts)

    assert conn.status == 200
    assert dimensions(conn) == {300, 300}
  end

  test "exar:1 under force is a no-op when the image already matches the requested ratio" do
    # beach.jpg is 4000x2667. rs:force:300:200 hard-scales it to exactly 300x200.
    # exar:1 would extend to the requested 300:200 (3:2) ratio, but the canvas is
    # already 3:2, so no padding is added and output dimensions are identical.
    base = call_imgproxy("/_/rs:force:300:200/f:jpeg/plain/images/beach.jpg", @default_opts)

    with_exar =
      call_imgproxy("/_/rs:force:300:200/exar:1/f:jpeg/plain/images/beach.jpg", @default_opts)

    assert base.status == 200
    assert with_exar.status == 200
    assert dimensions(base) == {300, 200}
    assert dimensions(with_exar) == {300, 200}
    # A true no-op must produce byte-identical output, not merely the same size.
    assert with_exar.resp_body == base.resp_body
  end

  test "effect options change decoded response pixels without geometry options" do
    baseline =
      "/_/f:png/plain/images/effects.png"
      |> call_imgproxy(effect_origin_opts())
      |> decoded_image()

    cases = [
      "/_/bl:4/f:png/plain/images/effects.png",
      "/_/sh:10/f:png/plain/images/effects.png",
      # pix:7 (not a divisor of the 16px stripes) so a block straddles each stripe
      # edge and the box mean visibly shifts those pixels. A block-aligned size (e.g.
      # pix:8) would be a true no-op on this striped source — imgproxy's box-mean
      # pixelate cannot change a block that lies within a single uniform stripe (#238).
      "/_/pix:7/f:png/plain/images/effects.png",
      "/_/mc:1:ffcc00/f:png/plain/images/effects.png",
      "/_/dt:1:112233:ffeecc/f:png/plain/images/effects.png",
      "/_/br:25/f:png/plain/images/effects.png",
      "/_/co:1.5/f:png/plain/images/effects.png",
      "/_/sa:0.4/f:png/plain/images/effects.png"
    ]

    for path <- cases do
      image =
        path
        |> call_imgproxy(effect_origin_opts())
        |> decoded_image()

      assert dimensions(image) == dimensions(baseline)
      assert sampled_pixels(image) != sampled_pixels(baseline)
    end
  end

  test "colorize/gradient/adjust change decoded pixels without geometry" do
    baseline =
      "/_/f:png/plain/images/effects.png"
      |> call_imgproxy(effect_origin_opts())
      |> decoded_image()

    for path <- [
          "/_/col:0.5:ff0000/f:png/plain/images/effects.png",
          "/_/gr:0.6:000000:down/f:png/plain/images/effects.png",
          "/_/a:40:1.4:0.7/f:png/plain/images/effects.png"
        ] do
      image = path |> call_imgproxy(effect_origin_opts()) |> decoded_image()
      assert dimensions(image) == dimensions(baseline)
      assert sampled_pixels(image) != sampled_pixels(baseline)
    end
  end

  test "adjust produces the same bytes as the equivalent br/co/sa" do
    via_adjust =
      "/_/a:40:1.4:0.7/f:png/plain/images/effects.png" |> call_imgproxy(effect_origin_opts())

    via_long =
      "/_/br:40/co:1.4/sa:0.7/f:png/plain/images/effects.png"
      |> call_imgproxy(effect_origin_opts())

    assert via_adjust.resp_body == via_long.resp_body
  end

  test "imgproxy auto_rotate config and URL options control EXIF autorotation" do
    default_conn =
      "/_/f:jpeg/plain/images/oriented.jpg"
      |> call_imgproxy(exif_orientation_origin_opts())

    assert default_conn.status == 200
    assert content_type(default_conn) == ["image/jpeg"]
    assert dimensions(default_conn) == {80, 40}

    configured_disabled_conn =
      "/_/f:jpeg/plain/images/oriented.jpg"
      |> call_imgproxy(exif_orientation_origin_opts(imgproxy: [auto_rotate: false]))

    assert configured_disabled_conn.status == 200
    assert dimensions(configured_disabled_conn) == {40, 80}

    url_enabled_conn =
      "/_/ar:true/f:jpeg/plain/images/oriented.jpg"
      |> call_imgproxy(exif_orientation_origin_opts(imgproxy: [auto_rotate: false]))

    assert url_enabled_conn.status == 200
    assert dimensions(url_enabled_conn) == {80, 40}

    url_disabled_conn =
      "/_/ar:false/f:jpeg/plain/images/oriented.jpg"
      |> call_imgproxy(exif_orientation_origin_opts(imgproxy: [auto_rotate: true]))

    assert url_disabled_conn.status == 200
    assert dimensions(url_disabled_conn) == {40, 80}
  end

  test "ar:0 + EXIF-6 + user rot:90 applies only the user rotation (regression guard)" do
    conn =
      "/_/ar:false/rot:90/f:jpeg/plain/images/oriented.jpg"
      |> call_imgproxy(exif_orientation_origin_opts(imgproxy: [auto_rotate: true]))

    assert conn.status == 200
    # ar:0 ignores the EXIF tag; user rot:90 on the STORED 40x80 -> 80x40.
    assert dimensions(conn) == {80, 40}
    assert_oriented_pixels_match(decoded_image(conn), reference_user_rot90_storage())
  end

  test "no-geometry: rot:90 on EXIF-6 (ar:1) = 180 deg net" do
    conn =
      "/_/rot:90/f:jpeg/plain/images/oriented.jpg"
      |> call_imgproxy(exif_orientation_origin_opts(imgproxy: [auto_rotate: true]))

    assert conn.status == 200
    # EXIF-6 (90 deg) THEN user 90 deg = 180 deg net on the stored 40x80 -> stays 40x80.
    assert dimensions(conn) == {40, 80}
    assert_oriented_pixels_match(decoded_image(conn), reference_180_of_stored())
  end

  # ── Deferred-orientation Slice A gates (#146) ────────────────────────────────

  # Regression guard for the deferred-orientation cutover: an EXIF-oriented source
  # combined with a gravity / region / focus-point / cover crop must SUCCEED.
  # Before the offset-unit fix in PlanExecutor.compensate_crop/2, the executable
  # crop's tagged offset ({:pixels, 0.0}) reached Orientation's bare-float
  # arithmetic and raised, turning every EXIF-2..7 + crop request into a 500.
  test "EXIF-oriented source with a gravity/region/fp/cover crop succeeds (no compensation crash)" do
    paths = [
      "/_/rs:fill:90:90/g:no/f:png/plain/images/x.jpg",
      "/_/rs:fill:90:60/g:ce/f:png/plain/images/x.jpg",
      "/_/c:60:40:no/f:png/plain/images/x.jpg",
      "/_/c:60:40:no:5:6/f:png/plain/images/x.jpg",
      "/_/rs:fill:90:90/g:so:0:8/f:png/plain/images/x.jpg",
      "/_/g:fp:0.25:0.75/rs:fill:80:80/f:png/plain/images/x.jpg",
      "/_/c:90:90:fp:0.25:0.75/f:png/plain/images/x.jpg"
    ]

    for orientation <- 1..8, path <- paths do
      conn = call_imgproxy(path, oriented_frame_opts(orientation))

      assert conn.status == 200,
             "EXIF-#{orientation} #{path} returned #{conn.status} (expected 200)"
    end
  end

  # The wire-vs-orientation-1 oracle. For each EXIF orientation 1..8 (including the
  # mirrors 2/4/5/7 and the axis-swapping quarter turns 5/6/7/8), the SAME imgproxy
  # request is run against the EXIF-oriented source and against the orientation-1
  # twin carrying the same displayed pixels. Identical operators on both legs ⇒ the
  # decoded interior pixels match (lossless PNG twin; the oriented leg is JPEG, so
  # a small interior tolerance absorbs decode noise — direction is still pinned).
  #
  # Covered geometry forms (the orientation-1 twin is an exact equivalence):
  # center / non-center anchor crop, focus-point crop, smart crop, explicit region
  # crop, cover/fill result crop with center AND non-center gravity, fit / force
  # including coprime (91×61) source-divergent targets, min-dimension (mw/mh) under
  # a quarter turn (cover resolved in the display frame — #146 Bug 2), and the FP
  # crop whose separate offset rotates as a vector (#146 Bug 3).
  test "crop/resize matrix matches the orientation-1 twin across EXIF 1..8" do
    paths = [
      # anchor crops: center + non-center
      "/_/c:60:40:ce/f:png/plain/images/x.jpg",
      "/_/c:60:40:no/f:png/plain/images/x.jpg",
      "/_/c:50:60:we/f:png/plain/images/x.jpg",
      # focus-point crop (center-ish and off-center) — exercises the FP offset
      # (zero) transforming as a vector under quarter turns (#146 Bug 3)
      "/_/c:90:90:fp:0.25:0.75/f:png/plain/images/x.jpg",
      # smart crop (attention saliency on the displayed pixels)
      "/_/rs:fill:80:80/g:sm/f:png/plain/images/x.jpg",
      # cover/fill result crop: center + non-center gravity
      "/_/rs:fill:90:90/g:ce/f:png/plain/images/x.jpg",
      "/_/rs:fill:90:90/g:no/f:png/plain/images/x.jpg",
      "/_/rs:fill:90:60/g:so/f:png/plain/images/x.jpg",
      # fp-guided cover
      "/_/g:fp:0.25:0.75/rs:fill:80:80/f:png/plain/images/x.jpg",
      # rounding-sensitive coprime targets: fit / force / fill
      "/_/rs:fit:91:61/f:png/plain/images/x.jpg",
      "/_/rs:force:91:61/f:png/plain/images/x.jpg",
      "/_/rs:fill:91:61/g:ce/f:png/plain/images/x.jpg",
      # cover + min-dimension under a quarter turn: the cross-axis min-dim
      # coupling must resolve in the display frame (#146 Bug 2)
      "/_/rs:fill:91:61/mw:140/g:no/f:png/plain/images/x.jpg",
      "/_/rs:fill:90:90/mh:130/g:ce/f:png/plain/images/x.jpg",
      # fit + min-dimension under a quarter turn (#194): mw/mh force a uniform
      # upscale past the requested box, so the new fit result-crop fires; its box
      # and the cross-axis coupling must land in the display frame too. Both crop in
      # portrait (mw binds) and landscape (mh binds) display orientations.
      "/_/rs:fit:80:80/mw:70/mh:70/f:png/plain/images/x.jpg",
      "/_/rs:fit:91:61/mh:130/f:png/plain/images/x.jpg"
    ]

    for orientation <- 1..8, path <- paths do
      oriented = call_imgproxy(path, oriented_frame_opts(orientation))
      twin = call_imgproxy(path, orientation1_twin_opts(orientation))

      assert oriented.status == 200, "oriented EXIF-#{orientation} #{path}: #{oriented.status}"
      assert twin.status == 200, "twin EXIF-#{orientation} #{path}: #{twin.status}"

      assert_twin_oracle_match(
        decoded_image(oriented),
        decoded_image(twin),
        "EXIF-#{orientation} #{path}"
      )
    end
  end

  # #146 Bug 2 regression: cover + min-dimension under a quarter turn. The
  # cross-axis min-dim coupling (prepare.go:146-158) must close over the DISPLAY
  # axes, so this is resolved in the display frame and the resolved dims swapped
  # back to storage. The mw:140 min-dimension drives the cover scale past the
  # requested box, and the universal cropToResult trims back to the literal
  # requested 91×61 (#236); a coupling bug would shift which pixels land in that
  # window, which the twin pixel match still catches.
  test "cover + min-dimension under a quarter turn matches the twin (display-frame resolve)" do
    path = "/_/rs:fill:91:61/mw:140/f:png/plain/images/x.jpg"

    oriented = call_imgproxy(path, oriented_frame_opts(6))
    twin = call_imgproxy(path, orientation1_twin_opts(6))

    assert oriented.status == 200 and twin.status == 200
    assert dimensions(oriented) == {91, 61}
    assert_twin_oracle_match(decoded_image(oriented), decoded_image(twin), "EXIF-6 #{path}")
  end

  # #146 Bug 3 regression: an FP crop carries the focus in the gravity tuple AND a
  # separate (zero) crop offset. The separate offset must rotate as a displacement
  # vector, not via the FP `1 - x` fraction rule — otherwise the zero offset
  # became {:pixels, 1.0} at 90/270, a 1px divergence. The twin pins maxdiff 0
  # (lossless on both legs for this exact-dim center crop).
  test "FP crop under a quarter turn matches the twin exactly (no spurious 1px offset)" do
    path = "/_/c:90:90:fp:0.25:0.75/f:png/plain/images/x.jpg"

    for orientation <- [6, 7] do
      oriented = call_imgproxy(path, oriented_frame_opts(orientation))
      twin = call_imgproxy(path, orientation1_twin_opts(orientation))

      assert oriented.status == 200 and twin.status == 200
      assert dimensions(oriented) == dimensions(twin)

      assert_twin_oracle_match(
        decoded_image(oriented),
        decoded_image(twin),
        "EXIF-#{orientation} #{path}"
      )
    end
  end

  # Embedded EXIF orientation tag in the OUTPUT, asserted only under sm:0
  # (strip_metadata=false). The default sm:1 strips the tag regardless of ar, so
  # the ar:0-keeps-the-tag case below holds only because sm:0 disables stripping
  # — it does NOT generalize. imgproxy's autorotate consumes and removes the tag;
  # ar:0 leaves the bytes (and tag) untouched.
  test "ar/sm control the residual output orientation tag (sm:0)" do
    # (a) ar:1 + tagged source: tag absent (autorotate stripped it), pixels rotated.
    rotated = call_imgproxy("/_/sm:0/f:png/plain/images/x.jpg", oriented_frame_opts(6))
    assert rotated.status == 200
    assert output_orientation_tag(rotated) in [nil, 1]
    # EXIF-6 displays the 120×200 portrait as 200×120 landscape.
    assert dimensions(rotated) == {200, 120}

    # (b) ar:0 + tagged source under sm:0: tag PRESENT, pixels unrotated (stored).
    unrotated =
      call_imgproxy(
        "/_/ar:0/sm:0/f:png/plain/images/x.jpg",
        oriented_frame_opts(6, imgproxy: [auto_rotate: true])
      )

    assert unrotated.status == 200
    assert output_orientation_tag(unrotated) == 6
    assert dimensions(unrotated) == {120, 200}

    # (c) ar:1 + orientation-1 source: nothing to rotate, no tag introduced.
    twin = call_imgproxy("/_/sm:0/f:png/plain/images/x.jpg", orientation1_twin_opts(6))
    assert twin.status == 200
    assert output_orientation_tag(twin) in [nil, 1]
    assert dimensions(twin) == {200, 120}
  end

  # #146 Bug 3: a positive gravity offset moves the crop window INWARD from the
  # named edge, so on the far edges (:right/:bottom) imgproxy SUBTRACTS the offset
  # (calc_position.go:45,49) where ImagePipe used to add it unconditionally. The
  # baseline (non-oriented) case: c:60:40:so:0:15 on a 120×200 source must place
  # the crop at top = 200 - 40 - 15 = 145 (was 175 → clamped to 160). Asserted by
  # the displayed position of a white line drawn at storage row 150 (local row 5).
  test "Bug 3 baseline: south offset crop subtracts from the far edge (top=145)" do
    # White horizontal line at storage row 150; c:60:40:so:0:15 -> top 145 -> local 5.
    opts = [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: {LineOrigin, nil}]}
      ]
    ]

    conn = call_imgproxy("/_/c:60:40:so:0:15/f:png/plain/images/x.jpg", opts)
    assert conn.status == 200
    image = decoded_image(conn)
    assert dimensions(image) == {60, 40}

    white_rows =
      Enum.filter(0..39, fn y -> image |> Image.get_pixel!(30, y) |> hd() > 180 end)

    # top = 145 puts storage row 150 at local row 5; the old add-then-clamp (top=160)
    # would push storage row 150 off the bottom of the crop entirely.
    assert white_rows == [5],
           "expected white line at local row 5 (top=145), got rows #{inspect(white_rows)}"
  end

  # #146 Bug 3 under orientation: explicit c: and gravity g: crops with NON-ZERO
  # offsets on south/east/corner anchors, EXIF 1..8. compensate_gravity_for remaps
  # the anchor (e.g. North→South under EXIF-3) and vector-transforms the offset
  # BEFORE the executable applies the per-axis sign, so the executable sees the
  # post-remap anchor and uses ITS edge. The lossless sharp oracle catches any 1px
  # divergence that the flat-region JPEG twin would miss.
  test "Bug 3: non-zero offset crops on so/ea/corner anchors match the eager oracle (EXIF 1-8)" do
    paths = [
      # explicit coordinate-style gravity crops with offsets
      "/_/c:60:40:so:0:15/f:png/plain/images/x.jpg",
      "/_/c:50:60:ea:12:0/f:png/plain/images/x.jpg",
      "/_/c:60:60:soea:10:8/f:png/plain/images/x.jpg",
      "/_/c:60:60:noea:6:6/f:png/plain/images/x.jpg",
      "/_/c:60:60:nowe:8:8/f:png/plain/images/x.jpg",
      # cover/fill result crops with offsets on the far edges
      "/_/rs:fill:90:60:0/g:so:0:10/f:png/plain/images/x.jpg",
      "/_/rs:fill:60:90:0/g:ea:10:0/f:png/plain/images/x.jpg"
    ]

    for orientation <- 1..8, path <- paths do
      oriented = call_imgproxy(path, sharp_oriented_opts(orientation))
      twin = call_imgproxy(path, sharp_twin_opts(orientation))

      assert oriented.status == 200, "oriented EXIF-#{orientation} #{path}: #{oriented.status}"
      assert twin.status == 200, "twin EXIF-#{orientation} #{path}: #{twin.status}"

      assert_sharp_oracle_match(
        decoded_image(oriented),
        decoded_image(twin),
        "Bug3 EXIF-#{orientation} #{path}"
      )
    end
  end

  # #146 Bug 2: a centered crop with an odd extent difference on BOTH axes discards
  # one extra pixel; the storage-frame near-side rounding lands on the wrong display
  # side under a net 180/270 turn (and under mirror orientations that reverse a
  # storage axis). center_discard_sides flips the per-axis rounding so the kept
  # pixel matches imgproxy's display-frame placement. Verified 1px-exact against the
  # lossless eager oracle for EXIF 1..8 with odd discards on both axes.
  test "Bug 2: center crop/cover with odd discard on both axes matches the eager oracle (EXIF 1-8)" do
    paths = [
      # center crop, odd storage discards on both axes (120-61=59, 200-39=161)
      "/_/c:61:39:ce/f:png/plain/images/x.jpg",
      "/_/c:39:61:ce/f:png/plain/images/x.jpg",
      # center cover result crops with odd discards
      "/_/rs:fill:91:39/g:ce/f:png/plain/images/x.jpg",
      "/_/rs:fill:39:91/g:ce/f:png/plain/images/x.jpg"
    ]

    for orientation <- 1..8, path <- paths do
      oriented = call_imgproxy(path, sharp_oriented_opts(orientation))
      twin = call_imgproxy(path, sharp_twin_opts(orientation))

      assert oriented.status == 200, "oriented EXIF-#{orientation} #{path}: #{oriented.status}"
      assert twin.status == 200, "twin EXIF-#{orientation} #{path}: #{twin.status}"

      assert_sharp_oracle_match(
        decoded_image(oriented),
        decoded_image(twin),
        "Bug2 EXIF-#{orientation} #{path}"
      )
    end
  end

  test "invalid signatures, paths, options, and expiry stop before cache and origin access" do
    signed_opts =
      Keyword.merge(@default_opts,
        imgproxy: [
          signature: [
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"]
          ]
        ]
      )

    cases = [
      {"/invalid/w:120/plain/images/beach.jpg", 403, signed_opts},
      {"/", 400, @default_opts},
      {"/_/w:-1/plain/images/beach.jpg", 400, @default_opts},
      {"/_/exp:100/plain/images/beach.jpg", 400,
       Keyword.put(@default_opts, :clock, fn -> DateTime.from_unix!(101) end)}
    ]

    for {path, expected_status, opts} <- cases do
      conn =
        call_imgproxy(
          path,
          Keyword.merge(opts,
            cache: {CacheProbe, []},
            sources: [
              path:
                {RootHTTPAdapter,
                 root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
            ]
          )
        )

      assert conn.status == expected_status
      refute_received :cache_lookup
      refute_received :cache_put
      refute_received :origin_fetch
    end
  end

  test "malformed encoded source stops before cache lookup and origin fetch" do
    telemetry_prefix = [:image_pipe_wire_safety]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_source_resolve_telemetry(telemetry_prefix)

    opts =
      Keyword.merge(@default_opts,
        telemetry_prefix: telemetry_prefix,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ]
      )

    for path <- ["/_/not+base64", "/_/#{Base.url_encode64(<<255>>, padding: false)}"] do
      conn = call_imgproxy(path, opts)

      assert conn.status == 400
      refute_received {:telemetry_event, ^source_resolve_start, _, _}
      refute_received {:cache_lookup, _key}
      refute_received {:cache_put, _key, _entry}
      refute_received :origin_fetch
    end
  end

  test "unsupported decoded source scheme stops before cache lookup and origin fetch" do
    telemetry_prefix = [:image_pipe_wire_safety]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_source_resolve_telemetry(telemetry_prefix)

    encoded = encoded_source("ftp://example.com/cat.jpg")

    opts =
      Keyword.merge(@default_opts,
        telemetry_prefix: telemetry_prefix,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ]
      )

    conn = call_imgproxy("/_/#{encoded}", opts)

    assert conn.status == 400
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end

  test "detector_required + unavailable detector rejects before source AND cache access" do
    telemetry_prefix = [:image_pipe_wire_safety]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_source_resolve_telemetry(telemetry_prefix)

    opts =
      Keyword.merge(@default_opts,
        telemetry_prefix: telemetry_prefix,
        detector: UnavailableDetector,
        detector_required: true,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ]
      )

    conn = call_imgproxy("/_/rs:fill:80:80/g:obj:face/plain/images/beach.jpg", opts)

    assert conn.status == 422
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end

  test "encrypted unsupported decoded source scheme stops before cache lookup and origin fetch" do
    telemetry_prefix = [:image_pipe_wire_safety]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_source_resolve_telemetry(telemetry_prefix)

    encrypted = encrypted_source("ftp://example.com/cat.jpg")

    opts =
      encrypted_opts(
        telemetry_prefix: telemetry_prefix,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ]
      )

    conn = call_imgproxy("/_/enc/#{encrypted}", opts)

    assert conn.status == 400
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end

  test "encrypted source marker without configured key stops before cache lookup and origin fetch" do
    telemetry_prefix = [:image_pipe_wire_safety]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_source_resolve_telemetry(telemetry_prefix)

    opts =
      Keyword.merge(@default_opts,
        telemetry_prefix: telemetry_prefix,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ]
      )

    conn = call_imgproxy("/_/enc/payload", opts)

    assert conn.status == 400
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end

  test "malformed encrypted source collapses parser errors and stops before cache lookup and origin fetch" do
    telemetry_prefix = [:image_pipe_wire_encrypted_safety]
    parse_stop = telemetry_prefix ++ [:parse, :stop]
    parse_exception = telemetry_prefix ++ [:parse, :exception]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_safety_telemetry(telemetry_prefix)

    opts =
      encrypted_opts(
        telemetry_prefix: telemetry_prefix,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ]
      )

    malformed_paths = [
      "/_/enc/not+base64",
      "/_/enc/#{Base.url_encode64(String.duplicate("x", 31), padding: false)}",
      "/_/enc/#{Base.url_encode64(@source_url_encryption_iv <> String.duplicate("x", 17), padding: false)}",
      "/_/enc/#{Base.url_encode64(@source_url_encryption_iv <> String.duplicate("x", 16), padding: false)}"
    ]

    bodies =
      for path <- malformed_paths do
        conn = call_imgproxy(path, opts)

        assert conn.status == 400

        assert_received {:telemetry_event, ^parse_stop, _measurements,
                         %{result: :error, error: :error}}

        conn.resp_body
      end

    assert Enum.uniq(bodies) == ["invalid image request: :invalid_encrypted_source"]
    refute_received {:telemetry_event, ^parse_exception, _, _}
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end

  test "filesystem cache reuses normalized automatic Accept candidates" do
    {opts, cache_root} = cached_opts()

    try do
      first_conn =
        "/_/plain/images/beach.jpg"
        |> call_imgproxy(opts, "image/webp;q=1,image/avif;q=0.1")

      assert first_conn.status == 200
      assert content_type(first_conn) == ["image/avif"]
      assert get_resp_header(first_conn, "vary") == ["Accept"]
      assert_received :origin_fetch

      second_conn =
        "/_/plain/images/beach.jpg"
        |> call_imgproxy(opts, "image/avif,image/webp")

      assert second_conn.status == 200
      assert content_type(second_conn) == ["image/avif"]
      assert get_resp_header(second_conn, "vary") == ["Accept"]
      assert second_conn.resp_body == first_conn.resp_body
      refute_received :origin_fetch
    after
      File.rm_rf!(cache_root)
    end
  end

  test "plain and matching encoded source requests share the same filesystem cache entry" do
    {opts, cache_root} = cached_opts()

    try do
      plain_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/plain/images/beach.jpg", opts)

      assert plain_conn.status == 200
      assert_received :origin_fetch

      encoded = encoded_source("images/beach.jpg")
      encoded_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/#{encoded}", opts)

      assert encoded_conn.status == 200
      assert encoded_conn.resp_body == plain_conn.resp_body
      refute_received :origin_fetch
    after
      File.rm_rf!(cache_root)
    end
  end

  test "plain encoded encrypted and SEO filename spellings share the same filesystem cache entry" do
    {opts, cache_root} =
      cached_opts(
        imgproxy: [
          source_url_encryption_key: @source_url_encryption_key,
          base64_url_includes_filename: true
        ]
      )

    try do
      first_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/plain/images/beach.jpg", opts)

      assert first_conn.status == 200
      assert_received :origin_fetch

      encoded = encoded_source("images/beach.jpg")
      encoded_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/#{encoded}/puppy.jpg", opts)

      assert encoded_conn.status == 200
      assert encoded_conn.resp_body == first_conn.resp_body
      refute_received :origin_fetch

      encrypted = encrypted_source("images/beach.jpg")

      encrypted_conn =
        call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/enc/#{encrypted}/kitten.jpg", opts)

      assert encrypted_conn.status == 200
      assert encrypted_conn.resp_body == first_conn.resp_body
      refute_received :origin_fetch

      alternate_encrypted =
        encrypted_source("images/beach.jpg", iv: @alternate_source_url_encryption_iv)

      alternate_conn =
        call_imgproxy(
          "/_/rt:force/w:120/h:90/f:jpeg/enc/#{alternate_encrypted}/puppy.jpg",
          opts
        )

      assert alternate_conn.status == 200
      assert alternate_conn.resp_body == first_conn.resp_body
      refute_received :origin_fetch
    after
      File.rm_rf!(cache_root)
    end
  end

  test "signed encrypted URLs verify the SEO filename before decrypting the source" do
    telemetry_prefix = [:image_pipe_signed_encrypted_safety]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_source_resolve_telemetry(telemetry_prefix)

    encrypted = encrypted_source("images/beach.jpg")
    signed_path = "/rt:force/w:120/h:90/f:jpeg/enc/#{encrypted}.webp/puppy.jpg"

    imgproxy =
      [
        signature: [
          keys: ["746573742d6b6579"],
          salts: ["746573742d73616c74"]
        ],
        source_url_encryption_key: @source_url_encryption_key,
        base64_url_includes_filename: true
      ]

    assert call_imgproxy(
             signed_request_path(signed_path),
             Keyword.put(@default_opts, :imgproxy, imgproxy)
           ).status ==
             200

    opts =
      encrypted_opts(
        telemetry_prefix: telemetry_prefix,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ],
        imgproxy: imgproxy
      )

    tampered_path =
      signed_path
      |> signed_request_path()
      |> String.replace_suffix("puppy.jpg", "kitten.jpg")

    conn = call_imgproxy(tampered_path, opts)

    assert conn.status == 403
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end

  test "signed encrypted URLs reject invalid signatures before malformed source decryption" do
    telemetry_prefix = [:image_pipe_signed_malformed_encrypted_safety]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_source_resolve_telemetry(telemetry_prefix)

    imgproxy =
      [
        signature: [
          keys: ["746573742d6b6579"],
          salts: ["746573742d73616c74"]
        ],
        source_url_encryption_key: @source_url_encryption_key,
        base64_url_includes_filename: true
      ]

    opts =
      encrypted_opts(
        telemetry_prefix: telemetry_prefix,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ],
        imgproxy: imgproxy
      )

    conn =
      call_imgproxy(
        "/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/rt:force/w:120/h:90/f:jpeg/enc/not+base64.webp/puppy.jpg",
        opts
      )

    assert conn.status == 403
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end

  test "whole chunked and padded encoded source spellings share the same filesystem cache entry" do
    {opts, cache_root} = cached_opts()

    try do
      whole = encoded_source("images/beach.jpg")
      chunked = chunked_encoded_source("images/beach.jpg")
      padded = encoded_source("images/beach.jpg", padding: true)

      first_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/#{whole}", opts)

      assert first_conn.status == 200
      assert_received :origin_fetch

      chunked_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/#{chunked}", opts)

      assert chunked_conn.status == 200
      assert chunked_conn.resp_body == first_conn.resp_body
      refute_received :origin_fetch

      padded_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/#{padded}", opts)

      assert padded_conn.status == 200
      assert padded_conn.resp_body == first_conn.resp_body
      refute_received :origin_fetch
    after
      File.rm_rf!(cache_root)
    end
  end

  test "custom imgproxy scheme translator and custom source adapter fetch only on cache miss" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        imgproxy: [
          source_schemes: %{
            "foobar" => {FoobarTranslator, []}
          }
        ],
        sources: [
          foobar: {PlugCustomAdapter, adapter: :foobar}
        ],
        cache: {CacheProbe, []}
      )

    conn =
      conn(:get, "/_/plain/foobar://asset/cat.jpg")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert_received {:foobar_translate, "foobar://asset/cat.jpg"}
    assert_received {:custom_resolve, _source}
    assert_received {:custom_fetch, :cat}
  end

  test "cache hit resolves custom source but does not fetch" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        imgproxy: [
          source_schemes: %{"foobar" => {FoobarTranslator, []}}
        ],
        sources: [foobar: {PlugCustomAdapter, adapter: :foobar}],
        cache: {CacheProbe, result: {:hit, cache_entry()}}
      )

    conn =
      conn(:get, "/_/plain/foobar://asset/cat.jpg")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert_received {:custom_resolve, _source}
    assert_received {:cache_lookup, _key}
    refute_received {:custom_fetch, _fetch}
    refute_received {:cache_put, _key, _entry}
    assert source_order() == [:resolve, :cache_lookup]
  end

  test "cache miss fetches custom source and writes successful encoded response" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        imgproxy: [
          source_schemes: %{"foobar" => {FoobarTranslator, []}}
        ],
        sources: [foobar: {PlugCustomAdapter, adapter: :foobar}],
        cache: {CacheProbe, result: :miss}
      )

    conn =
      conn(:get, "/_/plain/foobar://asset/cat.jpg")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert_received {:custom_resolve, _source}
    assert_received {:cache_lookup, _key}
    assert_received {:custom_fetch, :cat}
    assert_received {:cache_open_sink, _key, %{cost_us: cost_us}}
    assert cost_us > 0
    assert_received {:cache_put, _key, _entry}
    assert source_order() == [:resolve, :cache_lookup, :fetch, :cache_put]
  end

  test "cache skip fetches custom source without cache lookup or write" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        imgproxy: [
          source_schemes: %{"foobar" => {FoobarTranslator, []}}
        ],
        sources: [
          foobar: {PlugCustomAdapter, adapter: :foobar, internal_cache: :disabled}
        ],
        cache: {CacheProbe, result: :miss}
      )

    conn =
      conn(:get, "/_/plain/foobar://asset/cat.jpg")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert_received {:custom_resolve, _source}
    assert_received {:custom_fetch, :cat}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    assert source_order() == [:resolve, :fetch]
  end

  test "S3 cache hit resolves identity without asking credential providers" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          s3:
            {ImagePipe.Source.S3,
             default: [
               endpoint: "https://minio.test",
               region: "eu-west-1",
               credentials: {:provider, CredentialProvider, []}
             ],
             buckets: %{
               "tenant-a" => [
                 credentials: {:provider, CredentialProvider, []}
               ]
             }}
        ],
        cache: {CacheProbe, result: {:hit, cache_entry()}}
      )

    conn =
      conn(:get, "/_/plain/s3://tenant-a/images/cat.jpg%3Fabc")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert_received {:cache_lookup, _key}
    refute_received {:fetch_credentials, _, _, _}
  end

  test "car corrects the crop area aspect ratio (enlarge)" do
    # beach.jpg is 4000x2667. c:100:200:ce crops a 100x200 region (centered).
    # car:1:1 (ratio=1, enlarge) grows the short axis: 100 -> 200, giving 200x200.
    # Because gravity is unchanged, the corrected crop must sample the same region
    # as a direct 200x200 centered crop, so the decoded bytes are identical.
    conn = call_imgproxy("/_/c:100:200:ce/car:1:1/f:jpeg/plain/images/beach.jpg", @default_opts)
    direct = call_imgproxy("/_/c:200:200:ce/f:jpeg/plain/images/beach.jpg", @default_opts)

    assert conn.status == 200
    assert dimensions(conn) == {200, 200}
    assert conn.resp_body == direct.resp_body
  end

  test "car works without a resize (no-geometry-resize case)" do
    # beach.jpg is 4000x2667. c:100:200:ce crops a 100x200 region.
    # car:1 (ratio=1, default reduce) shrinks the long axis: 200 -> 100, giving 100x100.
    # The corrected crop must equal a direct 100x100 centered crop, pixel for pixel.
    conn = call_imgproxy("/_/c:100:200:ce/car:1/f:jpeg/plain/images/beach.jpg", @default_opts)
    direct = call_imgproxy("/_/c:100:100:ce/f:jpeg/plain/images/beach.jpg", @default_opts)

    assert conn.status == 200
    assert dimensions(conn) == {100, 100}
    assert conn.resp_body == direct.resp_body
  end

  test "car leaves gravity placement unchanged" do
    # c:200:400:no + car:1:1 (enlarge) grows short axis: 200 -> 400, giving 400x400 anchored north.
    # c:400:400:no directly crops 400x400 anchored north. The decoded bytes must be
    # identical, proving the correction changed only the size and kept the gravity region.
    via_car =
      call_imgproxy("/_/c:200:400:no/car:1:1/f:jpeg/plain/images/beach.jpg", @default_opts)

    direct = call_imgproxy("/_/c:400:400:no/f:jpeg/plain/images/beach.jpg", @default_opts)

    assert via_car.status == 200
    assert direct.status == 200
    assert dimensions(via_car) == dimensions(direct)
    assert via_car.resp_body == direct.resp_body
  end

  test "S3 cache miss asks only the selected bucket credential provider before fetch" do
    plug = fn conn ->
      Plug.Conn.send_resp(conn, 200, File.read!("priv/static/images/beach.jpg"))
    end

    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          s3:
            {ImagePipe.Source.S3,
             default: [
               endpoint: "https://minio.test",
               region: "eu-west-1",
               credentials: {:provider, CredentialProvider, role: "default"},
               req_options: [plug: plug]
             ],
             buckets: %{
               "tenant-a" => [
                 credentials: {:provider, CredentialProvider, role: "tenant-a"}
               ],
               "tenant-b" => [
                 credentials: {:provider, CredentialProvider, role: "tenant-b"}
               ]
             }}
        ],
        cache: {CacheProbe, result: :miss}
      )

    conn =
      conn(:get, "/_/plain/s3://tenant-a/images/cat.jpg%3Fabc")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert_received {:fetch_credentials, "tenant-a", [role: "tenant-a"], _runtime_opts}
    refute_received {:fetch_credentials, "tenant-a", [role: "default"], _runtime_opts}
    refute_received {:fetch_credentials, "tenant-b", [role: "tenant-b"], _runtime_opts}
  end

  describe "sm/kcr metadata stripping" do
    # Note on libvips JPEG behavior: libvips always writes a minimal EXIF block
    # on JPEG encode (with image dimensions, color space, etc.) regardless of
    # metadata stripping. Therefore "exif-data present" is always true after JPEG
    # encode and cannot be used to assert stripping. The meaningful assertions are
    # on specific EXIF field values (e.g. copyright, image_description) and on
    # xmp-data, which is only present when the source carried it.

    test "sm:0 retains EXIF copyright, ImageDescription, and XMP; default (sm on) strips them" do
      # Establish the sm:0 baseline first: if the fixture itself lacks metadata,
      # these assertions will fail loudly rather than letting the default-strips
      # assertions pass as false negatives.
      kept_conn =
        call_imgproxy(
          "/_/sm:0/scp:0/f:jpeg/plain/images/meta.jpg",
          metadata_origin_opts()
        )

      assert kept_conn.status == 200

      {kept_image, kept_fields} = response_metadata(kept_conn)
      {:ok, kept_exif} = Image.exif(kept_image)

      assert Map.get(kept_exif, :copyright) == "(c) ACME",
             "sm:0 baseline: copyright must be present; fixture is missing EXIF copyright"

      assert Map.get(kept_exif, :image_description) == "A test image",
             "sm:0 baseline: ImageDescription must be present; fixture is missing EXIF ImageDescription"

      assert "xmp-data" in kept_fields,
             "sm:0 baseline: xmp-data must be present; fixture is missing XMP metadata"

      # Default request (sm on, kcr on): XMP and non-copyright EXIF fields must
      # be stripped. Copyright is preserved by kcr:1 (the default).
      default_conn =
        call_imgproxy(
          "/_/scp:0/f:jpeg/plain/images/meta.jpg",
          metadata_origin_opts()
        )

      assert default_conn.status == 200

      {default_image, default_fields} = response_metadata(default_conn)
      {:ok, default_exif} = Image.exif(default_image)

      refute "xmp-data" in default_fields,
             "default (sm on): xmp-data must be stripped from the response"

      refute Map.has_key?(default_exif, :image_description),
             "default (sm on): non-copyright EXIF field (ImageDescription) must be stripped"

      assert Map.get(default_exif, :copyright) == "(c) ACME",
             "default (kcr on): copyright must be retained"
    end

    test "sm:1/kcr:0 strips copyright along with other EXIF and XMP" do
      # Baseline: the fixture carries copyright, so the refute below is meaningful
      # even when this test runs in isolation.
      baseline =
        call_imgproxy("/_/sm:0/scp:0/f:jpeg/plain/images/meta.jpg", metadata_origin_opts())

      {baseline_image, _baseline_fields} = response_metadata(baseline)
      {:ok, baseline_exif} = Image.exif(baseline_image)
      assert Map.get(baseline_exif, :copyright) == "(c) ACME"

      conn =
        call_imgproxy(
          "/_/sm:1/kcr:0/scp:0/f:jpeg/plain/images/meta.jpg",
          metadata_origin_opts()
        )

      assert conn.status == 200

      {image, field_names} = response_metadata(conn)
      {:ok, exif} = Image.exif(image)

      refute Map.has_key?(exif, :copyright),
             "kcr:0: copyright must be stripped along with other metadata"

      refute "xmp-data" in field_names,
             "kcr:0: xmp-data must be stripped"
    end

    test "sm:1/kcr:1 keeps EXIF copyright while stripping non-copyright EXIF and XMP" do
      # Baseline: confirm the fixture actually carries the non-copyright EXIF
      # field, so the "stripped" refute below cannot pass vacuously even when
      # this test runs in isolation.
      baseline =
        call_imgproxy("/_/sm:0/scp:0/f:jpeg/plain/images/meta.jpg", metadata_origin_opts())

      {baseline_image, _baseline_fields} = response_metadata(baseline)
      {:ok, baseline_exif} = Image.exif(baseline_image)
      assert Map.get(baseline_exif, :image_description) == "A test image"

      conn =
        call_imgproxy(
          "/_/sm:1/kcr:1/scp:0/f:jpeg/plain/images/meta.jpg",
          metadata_origin_opts()
        )

      assert conn.status == 200

      {image, field_names} = response_metadata(conn)
      {:ok, exif} = Image.exif(image)

      # Copyright must be retained.
      assert Map.get(exif, :copyright) == "(c) ACME",
             "kcr:1: copyright must equal the original value"

      # Non-copyright EXIF field (ImageDescription) must be gone.
      refute Map.has_key?(exif, :image_description),
             "kcr:1: non-copyright EXIF field (ImageDescription) must be stripped"

      # XMP must be stripped.
      refute "xmp-data" in field_names,
             "kcr:1: xmp-data must be stripped"
    end

    test "sm flag produces an isolated filesystem-cache variant" do
      {opts, cache_root} =
        cached_opts(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               req_options: [plug: {MetadataOriginImage, test_pid: self()}]}
          ]
        )

      try do
        # Default (sm on): cache miss, EXIF stripped.
        stripped = call_imgproxy("/_/scp:0/f:jpeg/plain/images/meta.jpg", opts)
        assert stripped.status == 200
        assert_received :origin_fetch

        # sm:0: distinct cache key -> cache miss, EXIF retained, different bytes.
        kept = call_imgproxy("/_/sm:0/scp:0/f:jpeg/plain/images/meta.jpg", opts)
        assert kept.status == 200
        assert_received :origin_fetch
        refute kept.resp_body == stripped.resp_body

        # Re-request sm:0: cache hit (no origin fetch), identical bytes — the
        # variant was cached separately, not cross-served from the default entry.
        kept_again = call_imgproxy("/_/sm:0/scp:0/f:jpeg/plain/images/meta.jpg", opts)
        assert kept_again.status == 200
        refute_received :origin_fetch
        assert kept_again.resp_body == kept.resp_body
      after
        File.rm_rf!(cache_root)
      end
    end
  end

  describe "scp color-profile normalization" do
    # Note: `Image.to_colorspace(img, :p3, [])` attaches a P3 ICC profile to the
    # in-memory image, which libvips embeds in PNG output. Re-opening the PNG bytes
    # confirms "icc-profile-data" is present, so the scp:0 baseline assertion will
    # fail loudly if the source generation ever loses the profile, preventing the
    # scp:1 "dropped" assertion from passing as a false negative.
    #
    # Unlike EXIF (which libvips regenerates minimally on JPEG encode), libvips does
    # NOT synthesize an ICC profile — it embeds one only when the image carries it.
    # Therefore "icc-profile-data" presence/absence is a meaningful scp assertion.

    test "scp:0 retains the embedded ICC profile; scp:1 (default) drops it and outputs sRGB" do
      # Establish the scp:0 baseline first: if the source lost its ICC profile,
      # these assertions fail loudly and prevent the scp:1 refute from passing
      # vacuously against a profile-less output.
      scp0_conn =
        call_imgproxy(
          "/_/scp:0/f:png/plain/images/wide.png",
          wide_gamut_origin_opts()
        )

      assert scp0_conn.status == 200

      {_scp0_image, scp0_fields} = response_metadata(scp0_conn)

      assert "icc-profile-data" in scp0_fields,
             "scp:0 baseline: icc-profile-data must be present; source lost its ICC profile"

      # scp:1 → color_profile: :strip: the finalize colorspace-to-result transforms
      # pixels to the standard sRGB space and drops the icc-profile-data header.
      scp1_conn =
        call_imgproxy(
          "/_/scp:1/f:png/plain/images/wide.png",
          wide_gamut_origin_opts()
        )

      assert scp1_conn.status == 200

      {scp1_image, scp1_fields} = response_metadata(scp1_conn)

      refute "icc-profile-data" in scp1_fields,
             "scp:1: icc-profile-data must be absent from the response"

      assert Image.colorspace(scp1_image) == :srgb,
             "scp:1: output colorspace must be sRGB (colorspace-to-result transformed pixels)"
    end

    test "default request (no scp in URL) drops the ICC profile" do
      # Same as scp:1 but exercises the default plan: color_profile is :strip
      # by default in Plan.Output, so no explicit scp option is needed.
      default_conn =
        call_imgproxy(
          "/_/f:png/plain/images/wide.png",
          wide_gamut_origin_opts()
        )

      assert default_conn.status == 200

      {_default_image, default_fields} = response_metadata(default_conn)

      refute "icc-profile-data" in default_fields,
             "default (scp on): icc-profile-data must be absent from the response"
    end

    test "scp:1 + sm:0 also strips the EXIF color-characterization tags (vips_icc_remove)" do
      # imgproxy's `vips_icc_remove` (called by colorspaceToResult when the profile
      # is dropped) removes three EXIF color tags alongside the ICC blob — and does
      # so independent of StripMetadata. So with scp:1 (default) + sm:0 (keep
      # metadata), the profile-drop path must strip them even though sm:0 keeps
      # everything else.
      #
      # sm:0/scp:0 baseline first: keeping the profile (scp:0) must leave the color
      # tags in place, so the scp:1 refute below cannot pass against a tag-less
      # source. WhitePoint and PrimaryChromaticities are the observable tags;
      # ImageDescription is the control proving sm:0 itself strips nothing.
      kept_conn =
        call_imgproxy("/_/scp:0/sm:0/f:jpeg/plain/images/char.jpg", color_char_origin_opts())

      assert kept_conn.status == 200

      {_kept_image, kept_fields} = response_metadata(kept_conn)

      assert "exif-ifd0-WhitePoint" in kept_fields,
             "sm:0/scp:0 baseline: WhitePoint must be present; source is missing the tag"

      assert "exif-ifd0-PrimaryChromaticities" in kept_fields,
             "sm:0/scp:0 baseline: PrimaryChromaticities must be present; source is missing the tag"

      # scp:1 (default) + sm:0: the profile-drop path runs vips_icc_remove's field
      # list. WhitePoint and PrimaryChromaticities are removed; ImageDescription
      # stays (sm:0 strips nothing). exif-ifd2-ColorSpace is on the removal list
      # too, but is NOT asserted here: libvips reconstructs it from the encoded
      # image's color interpretation on JPEG write, so it reappears on imgproxy
      # output identically — it is not an output-observable divergence.
      stripped_conn =
        call_imgproxy("/_/sm:0/f:jpeg/plain/images/char.jpg", color_char_origin_opts())

      assert stripped_conn.status == 200

      {_stripped_image, stripped_fields} = response_metadata(stripped_conn)

      refute "exif-ifd0-WhitePoint" in stripped_fields,
             "scp:1 + sm:0: WhitePoint must be stripped by the profile-drop path"

      refute "exif-ifd0-PrimaryChromaticities" in stripped_fields,
             "scp:1 + sm:0: PrimaryChromaticities must be stripped by the profile-drop path"

      assert "exif-ifd0-ImageDescription" in stripped_fields,
             "scp:1 + sm:0: ImageDescription must survive (sm:0 strips no general metadata)"
    end

    test "scp:0 option-order equivalence: same output regardless of URL position" do
      # scp:0 in different URL positions must parse to the same plan (order-insensitive)
      # and therefore produce byte-identical output.
      first =
        call_imgproxy(
          "/_/scp:0/rs:fit:80:80/f:png/plain/images/wide.png",
          wide_gamut_origin_opts()
        )

      second =
        call_imgproxy(
          "/_/rs:fit:80:80/scp:0/f:png/plain/images/wide.png",
          wide_gamut_origin_opts()
        )

      assert first.status == 200
      assert second.status == 200
      assert first.resp_body == second.resp_body
    end

    test "scp:0 filesystem cache reuses the same entry for semantically-equivalent requests" do
      {opts, cache_root} =
        cached_opts(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               req_options: [plug: {CountingOriginImage, test_pid: self()}]}
          ]
        )

      try do
        first =
          call_imgproxy(
            "/_/scp:0/rs:fit:80:80/f:jpeg/plain/images/beach.jpg",
            opts
          )

        assert first.status == 200
        assert_received :origin_fetch

        # Same plan, different URL option order -> same cache key -> cache hit.
        second =
          call_imgproxy(
            "/_/rs:fit:80:80/scp:0/f:jpeg/plain/images/beach.jpg",
            opts
          )

        assert second.status == 200
        assert second.resp_body == first.resp_body
        refute_received :origin_fetch
      after
        File.rm_rf!(cache_root)
      end
    end
  end

  # #124: request-boundary pixel tests for input color management.
  #
  # The behavioral contract for scp:0 on a wide-gamut (Display-P3) source:
  # - The input is color-managed to the working space (sRGB) before any
  #   processing step (`colorspaceToProcessing` preamble).
  # - With scp:0 the source ICC profile is re-embedded in the finalized output.
  # - With scp:1 (default) the profile is dropped and pixels are mapped to sRGB.
  #
  # These tests assert on the decoded response body, not just headers.
  describe "scp:0 pixel behavior (#124)" do
    test "resize-only scp:0 on a wide-gamut source: profile present, correct dimensions" do
      conn =
        call_imgproxy(
          "/_/rs:fit:200:200/scp:0/f:png/plain/images/wide.png",
          wide_gamut_origin_opts()
        )

      assert conn.status == 200

      {image, fields} = response_metadata(conn)

      # The re-embedded profile must be present in the decoded output.
      assert "icc-profile-data" in fields,
             "scp:0 + resize: icc-profile-data must be present in the decoded output"

      # Dimensions: rs:fit:200:200 on a 40×40 source without el (no-enlarge) leaves it
      # at 40×40 (source is already within the fit box).
      assert dimensions(image) == {40, 40}
    end

    test "scp:0 output differs from scp:1 (working-space round-trip visible in pixels)" do
      # The working-space import transforms out-of-gamut P3 reds: scp:0 re-embeds
      # the P3 profile (so the pixels stay in P3 representation), while scp:1 maps
      # to sRGB (clipping out-of-gamut values). The two outputs must differ.
      scp0 =
        call_imgproxy(
          "/_/scp:0/f:png/plain/images/wide.png",
          wide_gamut_origin_opts()
        )

      scp1 =
        call_imgproxy(
          "/_/scp:1/f:png/plain/images/wide.png",
          wide_gamut_origin_opts()
        )

      assert scp0.status == 200
      assert scp1.status == 200

      refute scp0.resp_body == scp1.resp_body,
             "scp:0 and scp:1 outputs must differ (working-space round-trip is observable)"
    end
  end

  describe "cp/icc target color profile (wire)" do
    test "cp:display-p3 embeds the target and changes pixels vs strip" do
      # The 40×40 P3 source: cp:display-p3 keeps the wide gamut and re-embeds a
      # target ICC profile, while scp:1 maps to sRGB and drops the profile. The
      # two encoded outputs must differ (embedded profile + remapped pixels).
      p3_conn =
        call_imgproxy("/_/cp:display-p3/f:png/plain/images/wide.png", wide_gamut_origin_opts())

      strip_conn =
        call_imgproxy("/_/scp:1/f:png/plain/images/wide.png", wide_gamut_origin_opts())

      {_p3_img, p3_fields} = response_metadata(p3_conn)
      {_strip_img, strip_fields} = response_metadata(strip_conn)

      assert "icc-profile-data" in p3_fields

      refute "icc-profile-data" in strip_fields,
             "scp:1 baseline: icc-profile-data must be absent so the diff is not tautological"

      refute p3_conn.resp_body == strip_conn.resp_body,
             "cp:display-p3 and scp:1 outputs must differ (target profile + remapped pixels)"
    end

    test "cp works without geometry (no-geometry form)" do
      {_img, fields} =
        response_metadata(
          call_imgproxy("/_/cp:adobe-rgb/f:png/plain/images/wide.png", wide_gamut_origin_opts())
        )

      assert "icc-profile-data" in fields
    end

    test "cp overrides scp: target embedded, not stripped" do
      {_img, fields} =
        response_metadata(
          call_imgproxy("/_/cp:p3/scp:1/f:png/plain/images/wide.png", wide_gamut_origin_opts())
        )

      assert "icc-profile-data" in fields
    end

    test "EXIF/XMP still stripped under a cp target (target does not suppress metadata strip)" do
      # default strip_metadata; keep_copyright defaults true, so assert a NON-copyright
      # EXIF field + XMP are gone while the cp target ICC is present.
      {_img, fields} =
        response_metadata(
          call_imgproxy("/_/cp:display-p3/f:jpeg/plain/images/meta.jpg", metadata_origin_opts())
        )

      assert "icc-profile-data" in fields
      refute "exif-ifd0-ImageDescription" in fields
      refute "xmp-data" in fields
    end

    test "equal cp requests reuse the filesystem cache (different option order)" do
      {opts, cache_root} =
        cached_opts(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               req_options: [plug: {CountingOriginImage, test_pid: self()}]}
          ]
        )

      try do
        first = call_imgproxy("/_/cp:p3/rs:fit:80:80/f:jpeg/plain/images/beach.jpg", opts)
        assert first.status == 200
        assert_received :origin_fetch

        second = call_imgproxy("/_/rs:fit:80:80/cp:p3/f:jpeg/plain/images/beach.jpg", opts)
        assert second.status == 200
        assert second.resp_body == first.resp_body
        refute_received :origin_fetch
      after
        File.rm_rf!(cache_root)
      end
    end
  end

  describe "output capability handling" do
    test "automatic negotiation drops avif when the build cannot write it" do
      opts = Keyword.put(@default_opts, :output_capabilities, %{avif: false, webp: true})

      conn = call_imgproxy("/_/plain/images/beach.jpg", opts, "image/avif,image/webp")

      assert conn.status == 200
      assert content_type(conn) == ["image/webp"]
      assert get_resp_header(conn, "vary") == ["Accept"]
    end

    test "automatic negotiation keeps avif when the build supports it" do
      opts = Keyword.put(@default_opts, :output_capabilities, %{avif: true, webp: true})

      conn = call_imgproxy("/_/plain/images/beach.jpg", opts, "image/avif,image/webp")

      assert conn.status == 200
      assert content_type(conn) == ["image/avif"]
    end

    test "an avif source with a jpeg-only Accept transcodes to raster regardless of capability" do
      base = [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: AvifOriginImage]}
        ]
      ]

      for capability <- [%{avif: true}, %{avif: false}] do
        opts = Keyword.put(base, :output_capabilities, capability)

        conn = call_imgproxy("/_/plain/images/cat.avif", opts, "image/jpeg")

        assert conn.status == 200
        # 64x64 solid red has no alpha -> JPEG, never AVIF, for either build.
        assert content_type(conn) == ["image/jpeg"]
        # Decode confirms valid raster output at the source dimensions.
        assert dimensions(conn) == {64, 64}
      end
    end

    test "automatic format is state-driven: opaque padding on a non-passthrough source stays JPEG (#235)" do
      base = [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: AvifOriginImage]}
        ]
      ]

      # cat.avif is 64×64 solid red (opaque). An opaque padding fill keeps the result
      # opaque, so ImagePipe's automatic format — resolved from the *final* image's
      # `has_alpha?` — picks JPEG. imgproxy is request-driven: the mere presence of
      # padding makes `determineOutputFormat` expect transparency (`PaddingEnabled()`,
      # processing.go), so it would emit PNG here. ImagePipe deliberately diverges,
      # serving the smaller opaque container; this pins that choice (a documented
      # surface divergence — docs/imgproxy_support_matrix.md, #235).
      conn = call_imgproxy("/_/pd:10/bg:255:0:0/plain/images/cat.avif", base, "image/jpeg")

      assert conn.status == 200
      assert content_type(conn) == ["image/jpeg"]
      assert dimensions(conn) == {84, 84}
    end

    test "an avif-capable and avif-less build caches distinct variants for the same Accept" do
      {base, cache_root} = cached_opts()

      try do
        capable = Keyword.put(base, :output_capabilities, %{avif: true, webp: true})
        incapable = Keyword.put(base, :output_capabilities, %{avif: false, webp: true})
        accept = "image/avif,image/webp"
        path = "/_/plain/images/beach.jpg"

        capable_conn = call_imgproxy(path, capable, accept)
        assert content_type(capable_conn) == ["image/avif"]
        assert_received :origin_fetch

        incapable_conn = call_imgproxy(path, incapable, accept)
        assert content_type(incapable_conn) == ["image/webp"]
        # Distinct filtered candidate list -> distinct key -> a second origin fetch.
        assert_received :origin_fetch

        # A repeat under the capable profile is served from cache without
        # re-fetching the origin, proving the filtered candidate list keys the two
        # variants apart (no cross-contamination from the webp entry).
        repeat_capable = call_imgproxy(path, capable, accept)
        assert content_type(repeat_capable) == ["image/avif"]
        assert repeat_capable.resp_body == capable_conn.resp_body
        refute_received :origin_fetch
      after
        File.rm_rf!(cache_root)
      end
    end

    test "a jpeg source with a jpeg-only Accept passes through as jpeg" do
      conn = call_imgproxy("/_/plain/images/beach.jpg", @default_opts, "image/jpeg")

      assert conn.status == 200
      assert content_type(conn) == ["image/jpeg"]
    end

    test "explicit avif is rejected before source fetch on an avif-less build" do
      opts = [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ],
        output_capabilities: %{avif: false}
      ]

      conn = call_imgproxy("/_/f:avif/plain/images/beach.jpg", opts)

      assert conn.status == 501
      # OriginShouldNotFetch flunks/raises if the source is fetched; reaching 501
      # without that proves the rejection happened pre-fetch.
    end

    test "explicit avif succeeds on a capable build" do
      opts = Keyword.put(@default_opts, :output_capabilities, %{avif: true})

      conn = call_imgproxy("/_/f:avif/plain/images/beach.jpg", opts)

      assert conn.status == 200
      assert content_type(conn) == ["image/avif"]
      assert get_resp_header(conn, "vary") == []
    end
  end

  # Task 10: Pixel divergence — g:obj:car crop biases toward the detected corner
  # object, distinct from both center gravity and attention (smart) gravity.
  test "g:obj:car crop biases toward the detected object, differing from center and attention" do
    opts = Keyword.merge(@default_opts, detector: CornerObjectDetector)

    obj = call_imgproxy("/_/rs:fill:50:50/g:obj:car/f:jpeg/plain/images/beach.jpg", opts)
    centered = call_imgproxy("/_/rs:fill:50:50/g:ce/f:jpeg/plain/images/beach.jpg", opts)
    attention = call_imgproxy("/_/rs:fill:50:50/g:sm/f:jpeg/plain/images/beach.jpg", opts)

    assert obj.status == 200
    assert dimensions(obj) == {50, 50}
    refute obj.resp_body == centered.resp_body
    refute obj.resp_body == attention.resp_body
  end

  # Task 10: No-geometry — g:obj:car without resize/crop must return 200.
  test "no-geometry g:obj:car returns 200 without a resize or crop" do
    opts = Keyword.merge(@default_opts, detector: CornerObjectDetector)

    conn = call_imgproxy("/_/g:obj:car/plain/images/beach.jpg", opts)

    assert conn.status == 200
  end

  # Task 10: Gate triad — class-aware strict gate with PartialDetector.
  # Face child: available, owns ["face"]. Object child: unavailable, owns ["car"].
  test "detector_required gate triad: face->200, unicorn->200(degrade), car->422 pre-fetch" do
    opts = Keyword.merge(@default_opts, detector: PartialDetector, detector_required: true)

    # face child available -> routes and succeeds
    face_conn = call_imgproxy("/_/rs:fill:50:50/g:obj:face/f:jpeg/plain/images/beach.jpg", opts)
    assert face_conn.status == 200

    # unknown class routes to no child -> available? vacuously true -> degrades to 200
    unicorn_conn =
      call_imgproxy("/_/rs:fill:50:50/g:obj:unicorn/f:jpeg/plain/images/beach.jpg", opts)

    assert unicorn_conn.status == 200

    # object child unavailable -> 422 BEFORE any source fetch or cache access.
    # Copy the exact setup from "detector_required + unavailable detector" test (~line 599).
    telemetry_prefix = [:image_pipe_wire_gate_triad]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_source_resolve_telemetry(telemetry_prefix)

    gate_opts =
      Keyword.merge(opts,
        telemetry_prefix: telemetry_prefix,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ]
      )

    car_conn =
      call_imgproxy("/_/rs:fill:50:50/g:obj:car/f:jpeg/plain/images/beach.jpg", gate_opts)

    assert car_conn.status == 422
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end

  # Slice 2: a face weight measurably changes the crop end-to-end. Exact focal
  # math is pinned in FocalTest; here we only prove the weight reaches pixels.
  # rs:fill:2000:2000 on beach.jpg (4000×2667) scales to 3000×2000, large enough
  # that the WeightedSceneDetector boxes ({2000,800,800,1000} and {1400,600,400,400})
  # both fit and the uniform vs boosted centroids land at different crop positions.
  test "objw face weight changes the rendered crop vs uniform" do
    opts = Keyword.merge(@default_opts, detector: WeightedSceneDetector)

    uniform =
      call_imgproxy("/_/rs:fill:2000:2000/g:obj:all/f:jpeg/plain/images/beach.jpg", opts)

    boosted =
      call_imgproxy(
        "/_/rs:fill:2000:2000/g:objw:all:1:face:8/f:jpeg/plain/images/beach.jpg",
        opts
      )

    assert uniform.status == 200
    assert boosted.status == 200
    assert dimensions(boosted) == {2000, 2000}
    refute boosted.resp_body == uniform.resp_body
  end

  # Slice 2: uniform-weight objw canonicalizes to obj:all (the weight scalar
  # cancels in the centroid), so it renders identically. (Cache-key identity is a
  # separate question, covered in the cache task — not asserted here.)
  test "objw with all-equal weights renders identically to obj:all" do
    opts = Keyword.merge(@default_opts, detector: WeightedSceneDetector)

    objw =
      call_imgproxy("/_/rs:fill:2000:2000/g:objw:all:2/f:jpeg/plain/images/beach.jpg", opts)

    obj = call_imgproxy("/_/rs:fill:2000:2000/g:obj:all/f:jpeg/plain/images/beach.jpg", opts)

    assert objw.resp_body == obj.resp_body
  end

  # Slice 2: the c:W:H:objw crop form reaches the crop path and applies the weight.
  test "c:W:H:objw crop form applies the weight" do
    opts = Keyword.merge(@default_opts, detector: WeightedSceneDetector)

    weighted =
      call_imgproxy("/_/c:2000:2000:objw:all:1:face:8/f:jpeg/plain/images/beach.jpg", opts)

    uniform = call_imgproxy("/_/c:2000:2000:obj:all/f:jpeg/plain/images/beach.jpg", opts)

    assert weighted.status == 200
    refute weighted.resp_body == uniform.resp_body
  end

  # Slice 2: no-geometry objw returns 200.
  test "no-geometry g:objw returns 200 without a resize or crop" do
    opts = Keyword.merge(@default_opts, detector: WeightedSceneDetector)
    conn = call_imgproxy("/_/g:objw:all:1:face:3/plain/images/beach.jpg", opts)
    assert conn.status == 200
  end

  # Filtering: objw:face:3 must gate detection to the face class only (not all),
  # so its crop matches obj:face (face box only) and DIFFERS from obj:all (both boxes).
  # WeightedSceneDetector returns a person box (large, right-of-center) and a face box
  # (small, left-of-center), filtered by opts[:classes].
  #
  # Beach.jpg is 4000x2667. WeightedSceneDetector boxes:
  #   person: {2000,800,800,1000} center_x=2400 (60% across) — right side
  #   face:   {1400,600,400,400}  center_x=1600 (40% across) — left side
  # rs:fill:2000:2000 scales to 3000×2000, crops 1000px horizontally:
  #   face-only focal_x_scaled ≈ 1200 → crop_x=200
  #   obj:all focal_x_scaled ≈ 1614 → crop_x=614
  # These are 414px apart in a 1000px-crop range, reliably different bytes.
  test "g:objw:face:3 filters to face class — matches obj:face, differs from obj:all" do
    opts = Keyword.merge(@default_opts, detector: WeightedSceneDetector)

    # objw:face:3 — spec is ["face"], detects only face box (single class → weight inert)
    objw_face =
      call_imgproxy(
        "/_/rs:fill:2000:2000/g:objw:face:3/f:jpeg/plain/images/beach.jpg",
        opts
      )

    # obj:face — spec is ["face"], same face-only detection
    obj_face =
      call_imgproxy("/_/rs:fill:2000:2000/g:obj:face/f:jpeg/plain/images/beach.jpg", opts)

    # obj:all — spec is :all, both person and face boxes counted (person dominates due to size)
    obj_all =
      call_imgproxy("/_/rs:fill:2000:2000/g:obj:all/f:jpeg/plain/images/beach.jpg", opts)

    assert objw_face.status == 200
    assert obj_face.status == 200
    assert obj_all.status == 200

    # objw:face:3 detects only face -> same crop focus as obj:face
    assert objw_face.resp_body == obj_face.resp_body

    # objw:face:3 differs from obj:all because detection set differs (face-only vs all)
    # The face (left-of-center, crop_x≈200) vs all-classes (crop_x≈614) produces different crops.
    refute objw_face.resp_body == obj_all.resp_body
  end

  # Task 19: autoquality + max_bytes wire-level acceptance.
  #
  # All sizes below were probed against the real beach.jpg origin through this
  # harness at `rs:fit:400:400` (a 400×267 JPEG): floor q=1 ≈ 2.7 KB, the default
  # (no-autoquality) encode ≈ 11.9 KB, max q=100 ≈ 102 KB. The chosen byte budgets
  # sit between the floor and default encodes so each descent/hit is real, not
  # vacuously satisfied. Grammar, the binary search, and the precise metric are
  # unit-tested (encode_search*_test.exs, ssim2_metric_test.exs); these tests only
  # assert the user-visible wire contract: status, content-type, byte budget, that
  # the body decodes, and that rejected methods stop before any source fetch.
  describe "autoquality + max_bytes (wire)" do
    test "mb:N reduces a JPEG response below the byte budget" do
      # mb:8000 sits below the ~11.9 KB default encode, so the search must descend.
      conn =
        call_imgproxy("/_/rs:fit:400:400/mb:8000/f:jpeg/plain/images/beach.jpg", @default_opts)

      assert conn.status == 200
      assert content_type(conn) == ["image/jpeg"]
      assert byte_size(conn.resp_body) <= 8000
      assert {:ok, _} = Image.from_binary(conn.resp_body)
    end

    test "autoquality:size keeps the response within the target byte budget" do
      conn =
        call_imgproxy(
          "/_/rs:fit:400:400/autoquality:size:15000:60:90/f:jpeg/plain/images/beach.jpg",
          @default_opts
        )

      assert conn.status == 200
      assert content_type(conn) == ["image/jpeg"]
      assert byte_size(conn.resp_body) <= 15_000
      assert {:ok, _} = Image.from_binary(conn.resp_body)
    end

    test "autoquality:ssim2 yields a decodable JPEG perceptually close to a high-quality baseline" do
      conn =
        call_imgproxy(
          "/_/rs:fit:400:400/autoquality:ssim2:85:50:95/f:jpeg/plain/images/beach.jpg",
          @default_opts
        )

      assert conn.status == 200
      assert content_type(conn) == ["image/jpeg"]
      assert {:ok, body_image} = Image.from_binary(conn.resp_body)

      # Robust perceptual check: compare the search output against a high-quality
      # (q:95) encode of the same pipeline. The exact target-vs-score relationship
      # is unit-tested; here we only prove the path runs and yields a sane image
      # (a comfortably high similarity to a near-lossless reference).
      baseline =
        call_imgproxy("/_/rs:fit:400:400/q:95/f:jpeg/plain/images/beach.jpg", @default_opts)

      {:ok, baseline_image} = Image.from_binary(baseline.resp_body)
      {:ok, reference} = Ssim2Metric.reference(baseline_image)
      {:ok, score} = Ssim2Metric.score(reference, body_image)

      assert score > 50
    end

    test "best-effort: an mb: below the floor-quality encode still returns 200" do
      # mb:1000 is below even the floor (q=1 ≈ 2.7 KB) encode, so the target can't
      # be met. The search must return the floor result (best-effort), never error.
      conn =
        call_imgproxy("/_/rs:fit:400:400/mb:1000/f:jpeg/plain/images/beach.jpg", @default_opts)

      assert conn.status == 200
      assert content_type(conn) == ["image/jpeg"]
      assert byte_size(conn.resp_body) > 0
      assert {:ok, _} = Image.from_binary(conn.resp_body)
    end

    test "autoquality:ml (unknown method) is rejected with 4xx before any source fetch" do
      assert_rejected_before_fetch(
        "/_/autoquality:ml:0.02:70:80/f:jpeg/plain/images/beach.jpg",
        [:image_pipe_wire_autoquality_ml]
      )
    end

    test "autoquality:dssim with inline args is rejected with 4xx before any source fetch" do
      assert_rejected_before_fetch(
        "/_/autoquality:dssim:0.02/f:jpeg/plain/images/beach.jpg",
        [:image_pipe_wire_autoquality_dssim]
      )
    end
  end

  # Asserts a request fails with a 4xx parser rejection and never touches the
  # origin: OriginShouldNotFetch raises if fetched, and the source-resolve span is
  # refuted under a unique telemetry prefix as belt-and-suspenders.
  defp assert_rejected_before_fetch(path, telemetry_prefix) do
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]
    attach_source_resolve_telemetry(telemetry_prefix)

    opts =
      Keyword.merge(@default_opts,
        telemetry_prefix: telemetry_prefix,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ]
      )

    conn = call_imgproxy(path, opts)

    assert conn.status in 400..499
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received :origin_fetch
  end

  # Security: near-max-float objw weight must be rejected cleanly (4xx), not crash (500).
  # WeightedSceneDetector returns face and person boxes in a large region of beach.jpg
  # (4000x2667), so rs:fill:2000:2000 keeps them in-bounds after resize; without the
  # fix, weighted_centroid raises ArithmeticError with a 1e308 face weight. With the
  # fix, the weight is rejected at parse time and the source is never fetched.
  test "objw weight at 1e308 is rejected with 4xx before any source fetch" do
    opts =
      Keyword.merge(@default_opts,
        detector: WeightedSceneDetector,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             req_options: [plug: {CountingOriginImage, test_pid: self()}]}
        ]
      )

    conn =
      call_imgproxy(
        "/_/rs:fill:2000:2000/g:objw:face:1e308/f:jpeg/plain/images/beach.jpg",
        opts
      )

    assert conn.status in 400..499
    refute_received :origin_fetch
  end

  # Layer 4 — wire conformance for now-sequential chains

  # Anchor crop + blur: c:40:30:no (north gravity) + bl:4 were previously forced to
  # random access by the blur; they are now fully sequential. Assert the crop
  # dimensions are preserved and the body decodes cleanly.
  test "anchor crop + blur produces the requested crop dimensions and decodes" do
    conn =
      call_imgproxy(
        "/_/c:40:30:no/bl:4/f:png/plain/images/effects.png",
        effect_origin_opts()
      )

    assert conn.status == 200
    assert content_type(conn) == ["image/png"]
    assert dimensions(conn) == {40, 30}
  end

  # Resize fill + padding + background: rs:fill:100:100/g:ce + pd:10 + bg:ffffff.
  # Each pd:10 side adds 10px → final canvas is 120×120. The corner pixel (0,0)
  # sits in the padding region and must match the background color (white).
  test "resize fill + padding + background produces padded dimensions with background fill" do
    conn =
      call_imgproxy(
        "/_/rs:fill:100:100/g:ce/pd:10/bg:ffffff/f:png/plain/images/beach.jpg",
        @default_opts
      )

    assert conn.status == 200
    assert content_type(conn) == ["image/png"]
    assert dimensions(conn) == {120, 120}

    image = decoded_image(conn)

    # Corner (0,0) is in the padding region → must be the background white.
    assert Image.get_pixel!(image, 0, 0) == [255, 255, 255]
  end

  # Transparent source + blur + background: a fully-transparent RGBA source with
  # bl:2 + bg:ff0000 must produce an opaque output (no alpha channel) whose pixels
  # are the background red (the transparent source contributes 0 color, so
  # flatten fills with the background color).
  test "transparent source + blur + background flattens to background color" do
    alpha_opts = [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {ImagePipe.SourceTest.RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: AlphaOriginImage]}
      ]
    ]

    conn =
      call_imgproxy(
        "/_/bl:2/bg:ff0000/f:png/plain/images/alpha.png",
        alpha_opts
      )

    assert conn.status == 200
    assert content_type(conn) == ["image/png"]

    image = decoded_image(conn)

    assert Image.has_alpha?(image) == false
    # Fully transparent source + red background → all pixels must be red.
    assert Image.get_pixel!(image, 0, 0) == [255, 0, 0]
    assert Image.get_pixel!(image, 10, 10) == [255, 0, 0]
  end

  # Explicit non-alpha output format (f:jpg) on an alpha-bearing source with NO
  # bg: option must flatten onto the imgproxy-default white background and emit a
  # valid JPEG, not 500 (#268). imgproxy's `flatten` step composites onto
  # `po.Background()`, which defaults to `color.White`, whenever the result
  # format can't carry alpha. Covers the no-geometry form: only an explicit
  # format on an RGBA image, no resize/crop/padding/background.
  test "explicit non-alpha format on an alpha source flattens to the default white background" do
    alpha_opts = [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {ImagePipe.SourceTest.RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: AlphaOriginImage]}
      ]
    ]

    conn =
      call_imgproxy(
        "/_/f:jpg/plain/images/alpha.png",
        alpha_opts
      )

    assert conn.status == 200
    assert content_type(conn) == ["image/jpeg"]

    image = decoded_image(conn)

    assert Image.has_alpha?(image) == false
    # Default white flatten; JPEG is lossy, so allow a small tolerance around 255.
    assert [r, g, b] = Image.get_pixel!(image, 10, 10)
    assert r > 250 and g > 250 and b > 250
  end

  # Capture the cache key the plug looked up for one request. Uses the file's
  # existing CacheProbe (it sends {:cache_lookup, key}) and call_imgproxy/2.
  defp lookup_key(path, opts) do
    call_imgproxy(path, opts)
    assert_received {:cache_lookup, key}
    key
  end

  defp probe_opts do
    Keyword.merge(@default_opts, cache: {CacheProbe, []})
  end

  defp ver_opts(extra) do
    Keyword.merge(probe_opts(), [detector: VerComposite] ++ extra)
  end

  test "object-only request key is independent of the face model identity" do
    assert lookup_key(
             "/_/rs:fill:50:50/g:obj:car/plain/images/beach.jpg",
             ver_opts(face_ver: :v1)
           ) ==
             lookup_key(
               "/_/rs:fill:50:50/g:obj:car/plain/images/beach.jpg",
               ver_opts(face_ver: :v2)
             )
  end

  test "face-only request key is independent of the object model identity" do
    assert lookup_key(
             "/_/rs:fill:50:50/g:obj:face/plain/images/beach.jpg",
             ver_opts(object_ver: :v1)
           ) ==
             lookup_key(
               "/_/rs:fill:50:50/g:obj:face/plain/images/beach.jpg",
               ver_opts(object_ver: :v2)
             )
  end

  test "mixed request key changes when either model identity changes" do
    base =
      lookup_key(
        "/_/rs:fill:50:50/g:obj:face:car/plain/images/beach.jpg",
        ver_opts(face_ver: :v1, object_ver: :v1)
      )

    diff_face =
      lookup_key(
        "/_/rs:fill:50:50/g:obj:face:car/plain/images/beach.jpg",
        ver_opts(face_ver: :v2, object_ver: :v1)
      )

    diff_obj =
      lookup_key(
        "/_/rs:fill:50:50/g:obj:face:car/plain/images/beach.jpg",
        ver_opts(face_ver: :v1, object_ver: :v2)
      )

    assert base != diff_face
    assert base != diff_obj
  end

  # Scope the clamp tests' telemetry to a private prefix so a concurrently
  # running async module emitting the default-prefix output clamp event cannot
  # leak into these tests' mailboxes (which would flake the refute_received
  # assertions). The clamp request opts below set this same prefix.
  @clamp_telemetry_prefix [:image_pipe_clamp_test]
  @clamp_event @clamp_telemetry_prefix ++ [:output, :clamp]

  describe "output encoder dimension clamp (#150)" do
    defp attach_clamp_telemetry do
      handler_id = {__MODULE__, self(), :output_clamp}

      :telemetry.attach(
        handler_id,
        @clamp_event,
        &__MODULE__.handle_telemetry_event/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    @clamp_opts [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
      ],
      max_result_width: 40_000,
      max_result_height: 40_000,
      max_result_pixels: 2_000_000_000,
      output_capabilities: %{avif: true, webp: true},
      telemetry_prefix: @clamp_telemetry_prefix
    ]

    test "clamp telemetry is isolated from concurrent foreign emissions" do
      attach_clamp_telemetry()

      # A concurrently-running async module (e.g. the TwicPics wire suite, which
      # legitimately clamps an oversized result) emits the output clamp event
      # while this module's refute_received clamp tests are in flight. A global
      # handler keyed on the shared event name would receive that foreign event
      # and flake the refute. The handler must be scoped so it never does.
      # Regression for CI run 27481152591.
      :telemetry.execute(
        [:image_pipe, :output, :clamp],
        %{scale: 0.306},
        %{format: :jpeg, dimensions: {1224, 816}, source_dimensions: {4000, 2667}, limits: %{}}
      )

      refute_received {:telemetry_event, _event, _measurements, _meta}
    end

    test "downscales a WebP result above the 16383 encoder limit and serves it" do
      attach_clamp_telemetry()

      conn =
        call_imgproxy("/_/el:1/rs:force:18000:200/f:webp/plain/images/beach.jpg", @clamp_opts)

      assert conn.status == 200
      assert content_type(conn) == ["image/webp"]

      {w, h} = dimensions(conn)
      assert max(w, h) <= 16_383
      assert max(w, h) > 8_192

      assert_received {:telemetry_event, @clamp_event, %{scale: scale}, meta}

      assert scale < 1.0
      assert meta.format == :webp
      assert meta.limits.max_width == 16_383
      assert meta.limits.max_height == 16_383
      assert meta.dimensions == {w, h}
      {sw, sh} = meta.source_dimensions
      assert max(sw, sh) > 16_383
    end

    test "downscales an AVIF result above the 16384 encoder limit and serves it" do
      attach_clamp_telemetry()

      conn =
        call_imgproxy("/_/el:1/rs:force:18000:200/f:avif/plain/images/beach.jpg", @clamp_opts)

      assert conn.status == 200
      assert content_type(conn) == ["image/avif"]

      {w, h} = dimensions(conn)
      assert max(w, h) <= 16_384
      assert max(w, h) > 8_192

      assert_received {:telemetry_event, @clamp_event, %{scale: scale}, meta}

      assert scale < 1.0
      assert meta.format == :avif
      assert meta.limits.max_width == 16_384
      assert meta.limits.max_height == 16_384
      assert meta.dimensions == {w, h}
    end

    test "does not clamp or emit when a WebP result is within the encoder limit" do
      attach_clamp_telemetry()

      conn = call_imgproxy("/_/w:120/f:webp/plain/images/beach.jpg", @clamp_opts)

      assert conn.status == 200
      assert content_type(conn) == ["image/webp"]
      {w, _h} = dimensions(conn)
      assert w == 120

      refute_received {:telemetry_event, @clamp_event, _measurements, _meta}
    end
  end

  describe "host result cap downscale (#165, limitScale parity)" do
    # Default host caps: max_result_width/height = 8192, max_result_pixels = 40M.
    @host_default_opts [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
      ],
      output_capabilities: %{avif: true, webp: true},
      telemetry_prefix: @clamp_telemetry_prefix
    ]

    test "downscales a result above the default 8192 host cap and serves 200" do
      attach_clamp_telemetry()

      conn =
        call_imgproxy(
          "/_/el:1/rs:force:12000:200/f:jpeg/plain/images/beach.jpg",
          @host_default_opts
        )

      assert conn.status == 200
      assert content_type(conn) == ["image/jpeg"]

      {w, h} = dimensions(conn)
      # Parity, not just safety: when the width cap binds on a non-degenerate
      # aspect, the long axis lands EXACTLY on 8192 — byte-intent identical to
      # imgproxy's linear `downScale = maxResultDim/max(outW,outH)`.
      assert w == 8192

      assert_received {:telemetry_event, @clamp_event, %{scale: scale}, meta}
      assert scale < 1.0
      assert meta.limits.max_width == 8192
      assert meta.limits.max_height == 8192
      assert meta.dimensions == {w, h}
      {sw, _sh} = meta.source_dimensions
      assert sw > 8192
    end

    # The one place ImagePipe and imgproxy observably diverge: a PADDED request
    # whose composited frame exceeds the cap. imgproxy folds the downscale into
    # the resize scale before re-applying padding (prepare.go:233-263); ImagePipe
    # clamps the already-composited frame. Both land <= cap; the framing differs.
    # This test pins ImagePipe's contract (status 200, composite <= cap, clamp
    # fired) so a future change to the clamp point can't silently alter padded
    # behavior with a green suite.
    test "clamps a padded result whose composited frame exceeds the host cap" do
      attach_clamp_telemetry()

      # w:100 then pad 5000px each side -> composited width ~10100 > 8192.
      conn =
        call_imgproxy("/_/w:100/pd:5000/f:jpeg/plain/images/beach.jpg", @host_default_opts)

      assert conn.status == 200
      {w, h} = dimensions(conn)
      assert max(w, h) <= 8192

      assert_received {:telemetry_event, @clamp_event, %{scale: scale}, _meta}
      assert scale < 1.0
    end

    test "honors asymmetric per-axis caps without over-shrinking" do
      attach_clamp_telemetry()

      # Realize ~6000x200, raise width cap above it, keep height cap slack:
      # both axes within caps -> NO clamp, served at full requested size.
      conn =
        call_imgproxy(
          "/_/el:1/rs:force:6000:200/f:jpeg/plain/images/beach.jpg",
          Keyword.merge(@host_default_opts, max_result_width: 10_000, max_result_height: 8192)
        )

      assert conn.status == 200
      {w, h} = dimensions(conn)
      assert w == 6000
      assert h == 200
      refute_received {:telemetry_event, @clamp_event, _m, _meta}
    end

    test "downscales on the host pixel cap with dims within the per-axis caps" do
      attach_clamp_telemetry()

      # ~5000x5000 = 25M px. Per-axis caps slack (8000), pixel cap 4M -> clamp on pixels.
      conn =
        call_imgproxy(
          "/_/el:1/rs:force:5000:5000/f:jpeg/plain/images/beach.jpg",
          Keyword.merge(@host_default_opts,
            max_result_width: 8000,
            max_result_height: 8000,
            max_result_pixels: 4_000_000
          )
        )

      assert conn.status == 200
      {w, h} = dimensions(conn)
      assert w <= 8000 and h <= 8000
      assert w * h <= 4_000_000

      assert_received {:telemetry_event, @clamp_event, %{scale: scale}, _meta}
      assert scale < 1.0
    end

    test "does not clamp or emit when the result is within all default caps" do
      attach_clamp_telemetry()

      conn = call_imgproxy("/_/w:300/f:jpeg/plain/images/beach.jpg", @host_default_opts)

      assert conn.status == 200
      {w, _h} = dimensions(conn)
      assert w == 300
      refute_received {:telemetry_event, @clamp_event, _m, _meta}
    end
  end

  describe "trim (wire)" do
    test "trims a uniform border to the inner block, no resize" do
      conn = call_imgproxy("/_/trim:10/f:png/plain/images/trim.png", trim_origin_opts())
      assert conn.status == 200
      assert dimensions(conn) == {40, 44}
    end

    test "uniform image returns unchanged (no-op), no geometry options" do
      conn = call_imgproxy("/_/trim:10/f:png/plain/images/uniform.png", uniform_origin_opts())
      assert conn.status == 200
      assert dimensions(conn) == {64, 64}
    end

    test "malformed trim threshold is rejected before cache lookup and origin fetch" do
      opts =
        Keyword.merge(@default_opts,
          cache: {CacheProbe, []},
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
          ]
        )

      conn = call_imgproxy("/_/trim:nope/plain/images/beach.jpg", opts)

      assert conn.status == 400
      refute_received :cache_lookup
      refute_received :cache_put
      refute_received :origin_fetch
    end

    # #124: trim on a wide-gamut (Display-P3) source. After the color-management
    # preamble the image is in the sRGB working space, so trim detects against those
    # pixels. The border here is pure black (identical in P3 and sRGB) so the trim
    # box is stable and the inner 44×44 block is always detected.
    test "trim on a wide-gamut (P3) source detects the border after color management" do
      conn =
        call_imgproxy(
          "/_/trim:10/f:png/plain/images/wide.png",
          origin_opts(WideGamutTrimOriginImage)
        )

      assert conn.status == 200
      # The inner block is 44×44; trim must crop down to it.
      assert dimensions(conn) == {44, 44}
    end

    # #124: trim on a greyscale (B_W working-space) source. The color-management
    # preamble converts to the B_W working space, then trim detects against single-band
    # pixels. The border is white and the inner block is black (high contrast), so
    # the standard trim threshold detects the box reliably.
    test "trim on a greyscale source detects the border in the B_W working space" do
      conn =
        call_imgproxy(
          "/_/trim:10/f:png/plain/images/grey.png",
          origin_opts(GreyscaleTrimOriginImage)
        )

      assert conn.status == 200
      # GreyscaleTrimOriginImage geometry: 40×44 inner block at (12, 10).
      assert dimensions(conn) == {40, 44}
    end
  end

  describe "extend dpr (wire)" do
    # imgproxy dpr-scales BOTH the extend target box (TargetWidth = Scale(w, dpr),
    # prepare.go) and the absolute extend offset (RoundToEven(offset * dpr),
    # calc_position.go), keeping the composition dpr-stable. West gravity on a
    # horizontally-letterboxed image (4:3 source into a 2:1 box) gives the x-offset
    # real horizontal play, so both effects are observable at the response boundary.
    test "dpr scales the extend canvas box and the absolute offset together" do
      base =
        call_imgproxy("/_/rs:fit:100:50/ex:1:we:5:0/plain/images/wide.png", solid_wide_opts())

      dpr2 =
        call_imgproxy(
          "/_/rs:fit:100:50/ex:1:we:5:0/dpr:2/plain/images/wide.png",
          solid_wide_opts()
        )

      assert base.status == 200
      assert dpr2.status == 200

      # The extend canvas box scales by dpr: 100×50 → Scale(100,2)×Scale(50,2).
      assert dimensions(base) == {100, 50}
      assert dimensions(dpr2) == {200, 100}

      # The absolute west offset scales by dpr: image left edge 5 → RoundToEven(5×2).
      assert image_left(base) == 5
      assert image_left(dpr2) == 10
    end
  end

  defp trim_origin_opts, do: origin_opts(TrimOriginImage)
  defp uniform_origin_opts, do: origin_opts(UniformOriginImage)
  defp solid_wide_opts, do: origin_opts(SolidWideOrigin)

  # First column at mid-height whose pixel is opaque — the left edge of the embedded
  # image inside the transparent extend canvas.
  defp image_left(%Plug.Conn{} = conn) do
    image = decoded_image(conn)
    {width, height} = dimensions(image)
    row = div(height, 2)

    Enum.find(0..(width - 1), fn x -> opaque_pixel?(Image.get_pixel!(image, x, row)) end)
  end

  defp opaque_pixel?([_red, _green, _blue, alpha]), do: alpha > 0
  defp opaque_pixel?([_red, _green, _blue]), do: true

  defp origin_opts(plug) do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: plug]}
      ]
    ]
  end

  defp cached_opts(overrides \\ []) do
    cache_root =
      Path.join(
        System.tmp_dir!(),
        "image_pipe_imgproxy_wire_cache_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(cache_root)
    File.mkdir_p!(cache_root)

    opts =
      @default_opts
      |> Keyword.merge(
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             req_options: [plug: {CountingOriginImage, test_pid: self()}]}
        ],
        cache:
          {ImagePipe.Cache.FileSystem,
           root: cache_root,
           path_prefix: "processed",
           max_body_bytes: 10_000_000,
           key_headers: [],
           key_cookies: []}
      )
      |> Keyword.merge(overrides)

    {opts, cache_root}
  end

  defp encrypted_opts(overrides \\ []) do
    @default_opts
    |> Keyword.merge(imgproxy: [source_url_encryption_key: @source_url_encryption_key])
    |> Keyword.merge(overrides)
  end

  defp encoded_source(source, opts \\ []) do
    padding = Keyword.get(opts, :padding, false)
    Base.url_encode64(source, padding: padding)
  end

  defp chunked_encoded_source(source) do
    encoded = encoded_source(source)
    first_size = div(byte_size(encoded), 2)
    first = binary_part(encoded, 0, first_size)
    second = binary_part(encoded, first_size, byte_size(encoded) - first_size)
    first <> "/" <> second
  end

  defp encrypted_source(source, opts \\ []) do
    iv = Keyword.get(opts, :iv, @source_url_encryption_iv)

    {:ok, segment} =
      Imgproxy.encrypt_source_url(source, @source_url_encryption_key, iv: iv)

    segment
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp attach_source_resolve_telemetry(telemetry_prefix) do
    handler_id = {__MODULE__, self(), :source_resolve}

    :telemetry.attach_many(
      handler_id,
      [
        telemetry_prefix ++ [:source, :resolve, :start],
        telemetry_prefix ++ [:source, :resolve, :stop],
        telemetry_prefix ++ [:source, :resolve, :exception]
      ],
      &__MODULE__.handle_telemetry_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp attach_safety_telemetry(telemetry_prefix) do
    handler_id = {__MODULE__, self(), :safety}

    :telemetry.attach_many(
      handler_id,
      [
        telemetry_prefix ++ [:parse, :stop],
        telemetry_prefix ++ [:parse, :exception],
        telemetry_prefix ++ [:source, :resolve, :start],
        telemetry_prefix ++ [:source, :resolve, :stop],
        telemetry_prefix ++ [:source, :resolve, :exception]
      ],
      &__MODULE__.handle_telemetry_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp signed_request_path(signed_path) do
    key = Base.decode16!("746573742d6b6579", case: :lower)
    salt = Base.decode16!("746573742d73616c74", case: :lower)

    signature =
      :crypto.mac(:hmac, :sha256, key, salt <> signed_path)
      |> Base.url_encode64(padding: false)

    "/" <> signature <> signed_path
  end

  defp svg_origin_opts do
    Keyword.merge(@default_opts,
      cache: {CacheProbe, result: :miss},
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: {SvgOriginImage, test_pid: self()}]}
      ]
    )
  end

  defp exif_orientation_origin_opts(overrides \\ []) do
    Keyword.merge(
      [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: ExifOrientationOriginImage]}
        ]
      ],
      overrides
    )
  end

  defp oriented_frame_opts(orientation, overrides \\ []) do
    Keyword.merge(
      [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             req_options: [
               plug: {OrientedFrameOrigin, {OrientationFixture.base_png(), orientation}}
             ]}
        ]
      ],
      overrides
    )
  end

  defp orientation1_twin_opts(orientation, overrides \\ []) do
    Keyword.merge(
      [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             req_options: [
               plug: {Orientation1TwinOrigin, {OrientationFixture.base_png(), orientation}}
             ]}
        ]
      ],
      overrides
    )
  end

  defp sharp_oriented_opts(orientation, overrides \\ []) do
    Keyword.merge(
      [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             req_options: [plug: {SharpOrientedOrigin, orientation}]}
        ]
      ],
      overrides
    )
  end

  defp sharp_twin_opts(orientation, overrides \\ []) do
    Keyword.merge(
      [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: {SharpTwinOrigin, orientation}]}
        ]
      ],
      overrides
    )
  end

  # Strict full-frame oracle for the lossless sharp fixture: identical dims and
  # every pixel within a tiny tolerance (both legs are lossless PNG; the small
  # tolerance only absorbs an affine-resize sub-pixel seam, never a 1px placement
  # shift, which moves whole flat regions). Counts far-off pixels so a placement
  # bug fails with a concrete count.
  defp assert_sharp_oracle_match(oriented, twin, label) do
    w = Image.width(oriented)
    h = Image.height(oriented)

    assert {w, h} == {Image.width(twin), Image.height(twin)},
           "#{label}: dims #{inspect({w, h})} != twin #{inspect({Image.width(twin), Image.height(twin)})}"

    # Read each frame to a raw row-major band buffer ONCE, then index it in BEAM.
    # The per-pixel Image.get_pixel!/3 path crosses the libvips FFI boundary on
    # every sample; across the EXIF 1..8 × multi-path matrix that is ~150k calls
    # and ~20s of CPU, which tips this async test past the 60s per-test timeout
    # under CI contention. Two write_to_binary/1 calls per leg collapse that to a
    # pair of buffer reads with identical sampling and tolerance semantics.
    {:ok, ob} = VipsImage.write_to_binary(oriented)
    {:ok, tb} = VipsImage.write_to_binary(twin)

    assert byte_size(ob) == byte_size(tb),
           "#{label}: band layout mismatch #{byte_size(ob)} != twin #{byte_size(tb)}"

    bands = div(byte_size(ob), w * h)

    # Sample a dense grid (every 2px) rather than every pixel — far finer than any
    # sharp feature (1px lines, quadrant seams), so a 1px placement shift still
    # moves many sampled points and the far-diverging count blows past the
    # thin-seam budget.
    xs = Enum.take_every(0..(w - 1), 2)
    ys = Enum.take_every(0..(h - 1), 2)

    far =
      Enum.reduce(for(x <- xs, y <- ys, do: {x, y}), 0, fn {x, y}, acc ->
        offset = (y * w + x) * bands
        op = :binary.part(ob, offset, bands)
        tp = :binary.part(tb, offset, bands)
        if pixel_diverges?(op, tp), do: acc + 1, else: acc
      end)

    # Allow a thin seam (≤ one edge's worth of sampled points) for affine-resize
    # cases; a 1px placement shift moves whole flat regions and far exceeds this.
    assert far <= div(max(w, h), 2),
           "#{label}: #{far} far-diverging sampled pixels — placement mismatch"
  end

  # Two same-length band slices "diverge" when any band differs by more than the
  # lossless tolerance — the per-pixel form of the old get_pixel! band compare.
  defp pixel_diverges?(<<a, arest::binary>>, <<b, brest::binary>>),
    do: abs(a - b) > 24 or pixel_diverges?(arest, brest)

  defp pixel_diverges?(<<>>, <<>>), do: false

  defp output_orientation_tag(%Plug.Conn{} = conn) do
    image = decoded_image(conn)

    case VipsImage.header_value(image, "orientation") do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  # Wire-vs-orientation-1 oracle assertion: same dimensions, and interior flat-region
  # pixels match within a small tolerance (the oriented leg round-trips through JPEG;
  # the twin is lossless PNG). Sampling at 1/8 and 7/8 stays inside the solid
  # quadrants, away from the red/green seam where a ±1px affine shift would ring.
  defp assert_twin_oracle_match(oriented, twin, label) do
    assert {Image.width(oriented), Image.height(oriented)} ==
             {Image.width(twin), Image.height(twin)},
           "#{label}: dims #{inspect({Image.width(oriented), Image.height(oriented)})} != twin #{inspect({Image.width(twin), Image.height(twin)})}"

    xs = bounded_samples(Image.width(oriented))
    ys = bounded_samples(Image.height(oriented))

    for x <- xs, y <- ys do
      op = Image.get_pixel!(oriented, x, y)
      tp = Image.get_pixel!(twin, x, y)

      assert pixels_close?(op, tp),
             "#{label}: pixel mismatch at (#{x},#{y}): #{inspect(op)} vs twin #{inspect(tp)}"
    end
  end

  # #124 edge cases: CMYK, linear-light, and corrupt-source handling.
  describe "scp edge cases (#124)" do
    # CMYK → sRGB working space: scp:0 re-embeds the source profile in formats that
    # support color profiles. JPEG is used here because PNG forces sRGB on write and
    # drops any CMYK profile; JPEG preserves the CMYK interpretation. The cmyk.jpg
    # fixture carries an embedded CMYK ICC profile; after color management to the sRGB
    # working space, scp:0 restores the original CMYK profile into the JPEG output.
    # The scp:1 counter-assertion verifies the re-embed is scp-driven, not unconditional:
    # scp:1 must either drop the profile or differ in body (if libvips tags CMYK-JPEG
    # output regardless, scp:0 carries the original CMYK profile bytes and scp:1 does not).
    test "scp:0 on a CMYK source re-embeds the source profile when the format supports it" do
      scp0_conn =
        call_imgproxy("/_/scp:0/f:jpeg/plain/images/cmyk.jpg", origin_opts(CmykOriginImage))

      scp1_conn =
        call_imgproxy("/_/scp:1/f:jpeg/plain/images/cmyk.jpg", origin_opts(CmykOriginImage))

      assert scp0_conn.status == 200
      assert scp1_conn.status == 200

      {_image, scp0_fields} = response_metadata(scp0_conn)

      assert "icc-profile-data" in scp0_fields,
             "scp:0 on CMYK: icc-profile-data must be present (format supports color profiles)"

      # Counter-assertion: scp:0 vs scp:1 outputs must differ, proving the re-embed
      # is scp-driven. Whether scp:1 carries its own minimal profile tag or none,
      # the bodies differ because scp:0 embeds the original CMYK profile data.
      refute scp0_conn.resp_body == scp1_conn.resp_body,
             "scp:0 and scp:1 CMYK outputs must differ (re-embed is scp-driven, not unconditional)"
    end

    # Linear-light (scRGB) branch: InputColorManagement drops the embedded profile
    # for scRGB sources (no backup recorded, color_imported? stays false), then
    # converts to the working space. With scp:0 there is no source profile to
    # re-embed, so the output must NOT carry icc-profile-data.
    test "scp:0 on a linear-light (scRGB) source does not embed a profile in the output" do
      conn =
        call_imgproxy(
          "/_/scp:0/f:png/plain/images/linear.png",
          origin_opts(LinearLightOriginImage)
        )

      assert conn.status == 200

      {_image, fields} = response_metadata(conn)

      refute "icc-profile-data" in fields,
             "scp:0 on linear-light: no source profile was imported, so none should be re-embedded"
    end

    # Corrupt/undecodable source must surface as HTTP 415 at the wire boundary.
    # The decode failure propagates as {:decode, _} and the plug maps it to 415.
    test "corrupt source body is rejected with 415 at the wire boundary" do
      conn =
        call_imgproxy(
          "/_/scp:0/f:png/plain/images/bad.png",
          origin_opts(CorruptSourceOriginImage)
        )

      assert conn.status == 415
    end
  end

  describe "preserve_hdr (ph)" do
    # The 512×512 source is downscaled, so the 16-bit working space must survive
    # the resize/scale (and shrink-on-load) stages, not just decode→encode.
    test "PNG output preserves 16-bit through resize with ph:1 and tone-maps with ph:0" do
      preserved =
        call_imgproxy("/_/rs:fill:200:200/g:ce/ph:1/f:png/plain/images/rgb16.png", @hdr_opts)

      tonemapped =
        call_imgproxy("/_/rs:fill:200:200/g:ce/ph:0/f:png/plain/images/rgb16.png", @hdr_opts)

      assert preserved.status == 200
      assert tonemapped.status == 200
      assert dimensions(preserved) == {200, 200}
      assert dimensions(tonemapped) == {200, 200}
      assert band_format(preserved) == :VIPS_FORMAT_USHORT
      assert band_format(tonemapped) == :VIPS_FORMAT_UCHAR
    end

    test "ph:1 preserves 16-bit with no geometry option" do
      conn = call_imgproxy("/_/ph:1/f:png/plain/images/rgb16.png", @hdr_opts)

      assert conn.status == 200
      assert band_format(conn) == :VIPS_FORMAT_USHORT
    end

    test "JPEG output tone-maps even with ph:1 (per-format fallback)" do
      conn = call_imgproxy("/_/ph:1/f:jpeg/plain/images/rgb16.png", @hdr_opts)

      assert conn.status == 200
      assert band_format(conn) == :VIPS_FORMAT_UCHAR
    end
  end

  defp effect_origin_opts do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: EffectOriginImage]}
      ]
    ]
  end

  defp metadata_origin_opts do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: MetadataOriginImage]}
      ]
    ]
  end

  defp color_char_origin_opts do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: ColorCharOriginImage]}
      ]
    ]
  end

  defp wide_gamut_origin_opts do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: WideGamutOriginImage]}
      ]
    ]
  end

  defp call_imgproxy(path, opts, accept \\ nil) do
    conn =
      :get
      |> conn(path)
      |> put_accept(accept)

    ImagePipe.Plug.call(conn, ImagePipe.Plug.init(opts))
  end

  defp put_accept(conn, nil), do: conn
  defp put_accept(conn, accept), do: put_req_header(conn, "accept", accept)

  defp content_type(conn), do: get_resp_header(conn, "content-type")

  defp svg_supported? do
    case VipsImage.supported_loader_suffixes() do
      {:ok, suffixes} -> ".svg" in suffixes
      {:error, _reason} -> false
    end
  end

  defp dimensions(%Plug.Conn{} = conn) do
    conn
    |> decoded_image()
    |> dimensions()
  end

  defp dimensions(%VipsImage{} = image) do
    {Image.width(image), Image.height(image)}
  end

  defp decoded_image(%Plug.Conn{} = conn) do
    Image.open!(conn.resp_body, access: :random, fail_on: :error)
  end

  defp band_format(%Plug.Conn{} = conn) do
    {:ok, format} = VipsImage.header_value(decoded_image(conn), "format")
    format
  end

  defp response_metadata(%Plug.Conn{} = conn) do
    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    {:ok, field_names} = VipsImage.header_field_names(image)
    {image, field_names}
  end

  defp sampled_pixels(image) do
    for x <- [8, 16, 24, 32, 40, 48, 56],
        y <- [8, 24, 40, 56] do
      Image.get_pixel!(image, x, y)
    end
  end

  # The oriented.jpg fixture's STORED pixels (40w x 80h, red 40x40 at top), with NO
  # EXIF orientation tag so reference primitives never autorotate.
  defp oriented_fixture_storage do
    40
    |> Image.new!(80, color: :white)
    |> Image.Draw.rect!(0, 0, 40, 40, color: :red)
  end

  defp reference_user_rot90_storage,
    do: oriented_fixture_storage() |> Image.rotate!(90) |> jpeg_roundtrip()

  defp reference_180_of_stored,
    do: oriented_fixture_storage() |> Image.rotate!(180) |> jpeg_roundtrip()

  # Round-trip through JPEG so the reference carries the same lossy artifacts as the
  # pipeline output; direction is pinned by the flat-region comparison.
  defp jpeg_roundtrip(image) do
    image
    |> Image.write!(:memory, suffix: ".jpg")
    |> Image.open!(access: :random, fail_on: :error)
  end

  # Sample within the (possibly small) bounds shared by both images.
  defp assert_oriented_pixels_match(actual, reference) do
    assert dimensions(actual) == dimensions(reference)

    {w, h} = dimensions(actual)
    xs = bounded_samples(w)
    ys = bounded_samples(h)

    for x <- xs, y <- ys do
      actual_px = Image.get_pixel!(actual, x, y)
      reference_px = Image.get_pixel!(reference, x, y)

      assert pixels_close?(actual_px, reference_px),
             "pixel mismatch at (#{x},#{y}): #{inspect(actual_px)} vs #{inspect(reference_px)}"
    end
  end

  # The pipeline output is JPEG-encoded then decoded, so allow small lossy deltas;
  # direction (which corner is red vs white) is still pinned by the flat-region match.
  defp pixels_close?(a, b) when length(a) == length(b) do
    a
    |> Enum.zip(b)
    |> Enum.all?(fn {av, bv} -> abs(av - bv) <= 12 end)
  end

  # Sample deep inside each half of the image, avoiding both the outer edges (libvips
  # rotate can leave sub-pixel artifacts there) and the geometric mid-seam between the
  # fixture's red block and white fill (JPEG ringing). 1/8 and 7/8 sit firmly in the
  # flat fill regions, so direction is still pinned without straddling a boundary.
  defp bounded_samples(size) do
    last = max(size - 1, 0)
    Enum.uniq([div(last, 8), div(last * 7, 8)])
  end

  defp cache_entry do
    %Entry{
      body: File.read!("priv/static/images/beach.jpg"),
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }
  end

  defp source_order, do: receive_source_order([])

  defp receive_source_order(events) do
    receive do
      {:source_order, event} -> receive_source_order([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  describe "/info endpoint" do
    test "returns 200 application/json with the header field set" do
      conn = call_imgproxy("/info/unsafe/plain/images/beach.jpg", @default_opts)

      assert conn.status == 200
      assert content_type(conn) == ["application/json; charset=utf-8"]

      json = JSON.decode!(conn.resp_body)
      assert json["format"] == "jpeg"
      assert json["mime_type"] == "image/jpeg"
      assert is_integer(json["width"]) and json["width"] > 0
      assert is_integer(json["height"]) and json["height"] > 0
      assert json["orientation"] in 1..8
    end

    test "omits size when not cheaply available (Phase 1)" do
      conn = call_imgproxy("/info/unsafe/plain/images/beach.jpg", @default_opts)
      json = JSON.decode!(conn.resp_body)
      refute Map.has_key?(json, "size")
    end

    test "does not emit Vary: Accept" do
      conn = call_imgproxy("/info/unsafe/plain/images/beach.jpg", @default_opts)
      vary = Plug.Conn.get_resp_header(conn, "vary")
      refute Enum.any?(vary, &String.contains?(String.downcase(&1), "accept"))
    end

    test "reports orientation-adjusted (swapped) dimensions for a quarter-turn EXIF source" do
      conn =
        call_imgproxy("/info/unsafe/plain/images/oriented.jpg", exif_orientation_origin_opts())

      json = JSON.decode!(conn.resp_body)
      # ExifOrientationOriginImage creates a 40x80 image with EXIF orientation 6
      # (90-degree clockwise). /info reports the display (swapped) dimensions.
      assert json["orientation"] == 6
      assert json["width"] == 80
      assert json["height"] == 40
    end

    test "a bad signature is rejected (403) before any source fetch" do
      signed_opts =
        Keyword.merge(@default_opts,
          imgproxy: [signature: [keys: ["746573742d6b6579"], salts: ["746573742d73616c74"]]],
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
          ]
        )

      conn = call_imgproxy("/info/invalidsig/plain/images/beach.jpg", signed_opts)
      assert conn.status == 403
    end

    test "an expired /info URL returns 400" do
      opts = Keyword.put(@default_opts, :clock, fn -> DateTime.from_unix!(101) end)
      conn = call_imgproxy("/info/unsafe/exp:100/plain/images/beach.jpg", opts)
      assert conn.status == 400
    end

    test "a non-image source returns 415" do
      opts =
        Keyword.put(@default_opts, :sources,
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: CorruptSourceOriginImage]}
        )

      conn = call_imgproxy("/info/unsafe/plain/images/whatever.jpg", opts)
      assert conn.status == 415
    end
  end
end
