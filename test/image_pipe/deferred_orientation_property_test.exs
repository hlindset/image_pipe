defmodule ImagePipe.DeferredOrientationPropertyTest do
  # Real image encode/decode per case — keep it serial and bound the runs.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Plug.Test

  alias ImagePipe.Dialect.IIIF.Resolver.Static, as: StaticResolver
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Orientation1TwinOrigin
  alias ImagePipe.Test.OrientedFrameOrigin

  # Deferred orientation (#146): EXIF auto-orient and user rotate/mirror are
  # applied AFTER crop/resize in the canonical model, but ImagePipe defers the
  # flush for performance. This property pins the two observable invariants of
  # that deferral through the IIIF parser, whose rotation token is a clockwise
  # right angle (0|90|180|270) with an optional leading `!` horizontal mirror
  # applied *before* the rotation:
  #
  #   * No-geometry leg — EXIF 1..8 × IIIF rotation/mirror with no region crop or
  #     resize must EXACTLY match the same-primitive `autorotate ∘ mirror ∘
  #     rotate` reference (the flush and the mirrored-rotate op use these exact
  #     primitives, so equality is real, not tolerant).
  #
  #   * Crop/resize leg — the SAME IIIF request on the EXIF-oriented source and
  #     on the orientation-1 twin (same displayed pixels, no tag) must land
  #     within ±1px on each axis and match interior flat-region pixels. Identical
  #     operators on both legs ⇒ rounding cancels; the residual is the affine
  #     resize's own ±1px scale-rounding floor (the same drift
  #     `shrink_on_load_property_test` pins). This is NOT a synthesized
  #     `Image.thumbnail` reference — the pipeline resizes with affine
  #     `Image.resize`, so the only sound oracle is wire-vs-orientation-1.
  #
  # Both legs run the SAME IIIF request, so any frame-mismatch in the
  # compensation surfaces as a twin divergence: a region crop whose top-left
  # offset must rotate as a displacement vector under a quarter turn (#146
  # Bug 3), and a resize whose requested axes must swap into the storage frame
  # ahead of the flush (#146 Bug 2).

  property "no-geometry: EXIF 1..8 × IIIF rotation/mirror matches the same-primitive reference" do
    check all(
            orientation <- integer(1..8),
            angle <- member_of([0, 90, 180, 270]),
            mirror <- boolean(),
            max_runs: 60
          ) do
      base = sharp_quadrants(64, 96)
      rotation = rotation_token(mirror, angle)

      out =
        "/x/full/max/#{rotation}/default.png"
        |> request(oriented_opts(base, orientation))
        |> decoded()

      reference = orientation_only_reference(base, orientation, mirror, angle)

      assert {Image.width(out), Image.height(out)} ==
               {Image.width(reference), Image.height(reference)}

      for {x, y} <- interior_points(out) do
        assert Image.get_pixel!(out, x, y) == Image.get_pixel!(reference, x, y),
               "no-geometry EXIF-#{orientation} rot:#{angle} mirror:#{mirror} " <>
                 "mismatch at (#{x},#{y})"
      end
    end
  end

  property "crop/resize: EXIF 1..8 stays within ±1px of the orientation-1 twin" do
    check all(
            orientation <- integer(1..8),
            geometry <- geometry_path(),
            max_runs: 80
          ) do
      base = sharp_quadrants(120, 200)
      path = "/x/#{geometry}/0/default.png"

      oriented = path |> request(oriented_opts(base, orientation)) |> decoded()
      twin = path |> request(twin_opts(base, orientation)) |> decoded()

      label = "EXIF-#{orientation} #{path}"

      assert abs(Image.width(oriented) - Image.width(twin)) <= 1 and
               abs(Image.height(oriented) - Image.height(twin)) <= 1,
             "#{label}: dims #{Image.width(oriented)}x#{Image.height(oriented)} drifted >1px " <>
               "from twin #{Image.width(twin)}x#{Image.height(twin)}"

      for {x, y} <- shared_interior_points(oriented, twin) do
        assert pixels_close?(Image.get_pixel!(oriented, x, y), Image.get_pixel!(twin, x, y)),
               "#{label}: interior pixel mismatch at (#{x},#{y})"
      end
    end
  end

  # ── Generators ───────────────────────────────────────────────────────────────

  # IIIF geometry is `{region}/{size}`. Regions stay inside the 120×120 box shared
  # by every orientation of the 120×200 source (portrait 120×200 and the quarter-
  # turn landscape 200×120), so a single path is in-bounds for all 8 orientations.
  defp geometry_path do
    member_of([
      # region crop only (size max) — top-left offset rotates as a displacement
      "20,10,60,40/max",
      "square/max",
      "0,0,50,60/max",
      # resize only (full region)
      "full/91,",
      "full/,61",
      "full/91,61",
      "full/!91,61",
      # region crop + resize — offset + quarter-turn resize compensation
      "10,10,80,80/!60,60",
      "20,30,60,90/!50,50",
      "square/!90,90",
      "10,20,100,100/50,50"
    ])
  end

  # ── References & helpers ─────────────────────────────────────────────────────

  # Same primitives the pipeline uses: EXIF autorotate, then (IIIF `!`) horizontal
  # mirror, then the clockwise right-angle rotate. Right angles take the lossless
  # vips_rot path on both sides, so the comparison is exact.
  defp orientation_only_reference(base_bytes, orientation, mirror, angle) do
    oriented =
      base_bytes
      |> Image.open!(access: :random)
      |> Image.set_orientation!(orientation)
      |> Image.write!(:memory, suffix: ".jpg")
      |> Image.open!(access: :random)

    {:ok, {displayed, _flags}} = Image.autorotate(oriented)

    mirrored = if mirror, do: Image.flip!(displayed, :horizontal), else: displayed
    rotated = if angle != 0, do: Image.rotate!(mirrored, angle), else: mirrored

    rotated
    |> Image.write!(:memory, suffix: ".png")
    |> Image.open!(access: :random)
  end

  defp rotation_token(mirror, angle), do: "#{if mirror, do: "!"}#{angle}"

  defp sharp_quadrants(w, h) do
    Image.new!(w, h, color: :green)
    |> Image.Draw.rect!(0, 0, w, div(h, 2), color: :red)
    |> Image.Draw.rect!(0, 0, div(w, 4), div(w, 4), color: :blue)
    |> Image.write!(:memory, suffix: ".png")
  end

  defp oriented_opts(base_bytes, orientation),
    do: opts(OrientedFrameOrigin, base_bytes, orientation)

  defp twin_opts(base_bytes, orientation),
    do: opts(Orientation1TwinOrigin, base_bytes, orientation)

  defp opts(origin, base_bytes, orientation) do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [
        resolver: {StaticResolver, map: %{"x" => %SourcePath{segments: ["x.jpg"]}}}
      ],
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           req_options: [plug: {origin, {base_bytes, orientation}}]}
      ]
    ]
  end

  defp request(path, opts) do
    :get
    |> conn(path)
    |> ImagePipe.Plug.call(ImagePipe.Plug.init(opts))
  end

  defp decoded(%Plug.Conn{status: 200} = conn),
    do: Image.open!(conn.resp_body, access: :random, fail_on: :error)

  defp interior_points(image) do
    w = Image.width(image)
    h = Image.height(image)

    for x <- bounded(w), y <- bounded(h), do: {x, y}
  end

  defp shared_interior_points(a, b) do
    w = min(Image.width(a), Image.width(b))
    h = min(Image.height(a), Image.height(b))

    for x <- bounded(w), y <- bounded(h), do: {x, y}
  end

  # 1/8 and 7/8 sit inside the solid quadrants, away from the red/green seam where
  # a ±1px affine shift would ring.
  defp bounded(size) do
    last = max(size - 1, 0)
    Enum.uniq([div(last, 8), div(last * 7, 8)])
  end

  defp pixels_close?(a, b) when length(a) == length(b) do
    a
    |> Enum.zip(b)
    |> Enum.all?(fn {av, bv} -> abs(av - bv) <= 12 end)
  end

  defp pixels_close?(_a, _b), do: false
end
