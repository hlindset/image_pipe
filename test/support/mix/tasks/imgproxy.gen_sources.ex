defmodule Mix.Tasks.Imgproxy.GenSources do
  @shortdoc "Build committed synthetic source images for imgproxy differential conformance"
  @moduledoc """
  One-shot builder for the committed source images. No Docker. Run once; commit
  the outputs. Regenerating sources is a deliberate act (a libvips bump must not
  silently change inputs).

      mise exec -- mix imgproxy.gen_sources
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  import Bitwise

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @dir "test/support/image_pipe/test/imgproxy_differential/sources"
  @w 1600
  @h 1200

  # Placement source (#239): a sharp, aperiodic, position-encoding color grid.
  # Each `@placement_step`-px cell carries a distinct xorshift-hashed color, so any
  # crop window crosses high-amplitude edges (a 1px placement shift → maxΔ≈255) AND
  # the unique per-cell colors disambiguate position, so a period-aligned shift
  # cannot alias the way a checkerboard/two-color ring would. The step is < the
  # smallest crop dimension (90, from `c:120:90`) and divides 1600/1200 evenly.
  @placement_step 50

  # EXIF-tagged placement base (#239 EXIF half): a 400×300 sibling of the placement
  # grid, retagged per orientation for the `crop_no` seam + `exif_crop_focal`. Step
  # 50 divides 400/300 evenly and is < the smallest EXIF inline-crop dimension (120,
  # from `c:200:120`), so every crop window crosses cell edges.
  @exif_placement_w 400
  @exif_placement_h 300
  @exif_placement_step 50

  # Odd-dimensioned placement grid (#318): both axes odd so a fractional crop
  # `c:0.5:0.5` lands on a `.5` tie (405·0.5 = 202.5, 305·0.5 = 152.5). imgproxy's
  # CalcCropSize rounds crop sizes half-away-from-zero (203×153); ties-to-even would
  # give 202×152 — a 1px crop-SIZE divergence the even-dimensioned sources can't hit.
  # Step 5 divides 405/305 evenly and stays aperiodic so a stray placement also shows.
  @placement_odd_w 405
  @placement_odd_h 305
  @placement_odd_step 5

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:image)
    File.mkdir_p!(@dir)

    chirp = chirp_image(@w, @h)
    write!(chirp, "high_freq.jpg", suffix: ".jpg", quality: 92)
    write!(chirp, "high_freq.webp", suffix: ".webp", quality: 92)

    marker =
      @w
      |> Image.new!(@h, color: [30, 30, 30])
      |> Image.Draw.rect!(div(@w, 8), div(@h, 8), div(@w, 6), div(@h, 6), color: [240, 40, 40])

    write!(marker, "marker.png", suffix: ".png")

    border =
      @w
      |> Image.new!(@h, color: [255, 255, 255])
      |> Image.Draw.rect!(120, 90, @w - 240, @h - 180, color: [20, 30, 200])

    write!(border, "border.png", suffix: ".png")

    # Asymmetric border for the trim `equal_hor`/`equal_ver` symmetrization branch.
    # The blue rect is off-center (left=100, right=200, top=60, bot=140 margins), so
    # the opposite margins are unequal. Plain trim crops to the tight 1300×1000 bbox
    # (all blue); `t:%th::1:1` symmetrizes each pair to the smaller inset, extending
    # the crop into the white border (→ 1400×1080 with white strips). On the centered
    # `border.png` the branch is a no-op (equal margins, diff==0), so this off-center
    # source is what makes the symmetrization differentially visible.
    border_asym =
      @w
      |> Image.new!(@h, color: [255, 255, 255])
      |> Image.Draw.rect!(100, 60, 1300, 1000, color: [20, 30, 200])

    write!(border_asym, "border_asym.png", suffix: ".png")

    {:ok, alpha} = Image.new(256, 256, color: [0, 200, 100, 128], bands: 4)
    write!(alpha, "alpha.png", suffix: ".png")

    exif_base =
      400
      |> Image.new!(300, color: [200, 180, 60])
      |> Image.Draw.rect!(0, 0, 200, 150, color: [40, 40, 200])

    for o <- [2, 3, 4, 5, 6, 7, 8] do
      exif_base
      |> Image.set_orientation!(o)
      |> write!("exif_#{o}.jpg", suffix: ".jpg", quality: 95)
    end

    # EXIF-tagged discriminating placement base (#239 EXIF half). The shared
    # `exif_base` corner-block field is near-uniform gold away from its one blue
    # quadrant, so a north/focal inline crop whose window lands in the gold ground
    # has zero discriminating power — a placement bug moves the window within a flat
    # field and yields identical pixels. The `exif_base` layout is load-bearing for
    # the #182 frame-of-reference fixtures, so it can't change; instead the `crop_no`
    # seam + `exif_crop_focal` route to this 400×300 aperiodic grid retagged per
    # orientation (the same per-cell-unique-color placement grid as `placement.png`,
    # so a 1px window misplacement → maxΔ≈255). Crop-only (no resample), so each
    # orientation matches imgproxy at maxΔ=0.
    exif_placement = placement_image(@exif_placement_w, @exif_placement_h, @exif_placement_step)

    for o <- [2, 3, 4, 5, 6, 7, 8] do
      exif_placement
      |> Image.set_orientation!(o)
      |> write!("exif_placement_#{o}.jpg", suffix: ".jpg", quality: 95)
    end

    icc =
      512
      |> Image.new!(512, color: [200, 50, 50])
      |> Image.Draw.rect!(0, 0, 64, 64, color: [255, 255, 255])
      |> Image.Draw.rect!(256, 0, 6, 512, color: [0, 255, 0])
      |> Image.Draw.rect!(0, 256, 512, 6, color: [0, 0, 255])

    {:ok, p3} = Image.to_colorspace(icc, :p3, [])
    write!(p3, "icc_p3.png", suffix: ".png")

    small =
      120
      |> Image.new!(90, color: [70, 130, 180])
      |> Image.Draw.rect!(10, 10, 40, 30, color: [255, 220, 0])

    write!(small, "small.png", suffix: ".png")

    write!(cmyk_image(), "cmyk.jpg", suffix: ".jpg", quality: 92)

    placement = placement_image(@w, @h, @placement_step)
    write!(placement, "placement.png", suffix: ".png")

    placement_odd = placement_image(@placement_odd_w, @placement_odd_h, @placement_odd_step)
    write!(placement_odd, "placement_odd.png", suffix: ".png")

    rgb16 = rgb16_image()
    write!(rgb16, "rgb16.png", suffix: ".png")
    write!(opaque_alpha(rgb16), "rgba16.png", suffix: ".png")

    Mix.shell().info("Wrote sources to #{@dir}")
  end

  @doc "Deterministic aperiodic placement grid: `w*h*3` uchar bytes, row-major."
  def placement_pixels(w, h, step) do
    ncols = div(w, step)
    nrows = div(h, step)
    colors = List.to_tuple(for i <- 0..(ncols * nrows - 1), do: cell_color(i))

    for y <- 0..(h - 1) do
      row = div(y, step)

      for col <- 0..(ncols - 1) do
        [r, g, b] = elem(colors, row * ncols + col)
        :binary.copy(<<r, g, b>>, step)
      end
    end
    |> IO.iodata_to_binary()
  end

  # Non-linear xorshift mix of the cell index → a saturated, position-encoding
  # color. Non-linear so adjacent cells are uncorrelated (no arithmetic-progression
  # aliasing), kept in 40..239 so every channel stays visible and high-amplitude.
  defp cell_color(i) do
    h = i + 1
    h = band(bxor(h, bsl(h, 13)), 0xFFFFFFFF)
    h = bxor(h, bsr(h, 7))
    h = band(bxor(h, bsl(h, 17)), 0xFFFFFFFF)

    [
      rem(bsr(h, 16), 200) + 40,
      rem(bsr(h, 8), 200) + 40,
      rem(h, 200) + 40
    ]
  end

  # 120×90 CMYK JPEG with an embedded CMYK ICC profile. `Image.to_colorspace/2`
  # converts the sRGB pattern to CMYK and embeds the built-in CMYK profile (which
  # survives the JPEG round-trip), so the source exercises both the stage-4 CMYK→
  # sRGB working-space import (cmyk_import) and the ICM profile-import path (the
  # `@cmyk_fixture` color-management test asserts color_imported?). Previously this
  # source was committed by hand, not generated here (#240 follow-up).
  defp cmyk_image do
    base =
      120
      |> Image.new!(90, color: [200, 60, 40])
      |> Image.Draw.rect!(10, 10, 40, 30, color: [40, 120, 220])

    {:ok, cmyk} = Image.to_colorspace(base, :cmyk)
    cmyk
  end

  defp placement_image(w, h, step) do
    {:ok, img} =
      VipsImage.new_from_binary(
        placement_pixels(w, h, step),
        w,
        h,
        3,
        :VIPS_FORMAT_UCHAR
      )

    img
  end

  # 16-bit RGB HDR source (#240). An 8-bit pattern (red field, green/blue cross
  # lines, white corner, a saturated highlight block) scaled ×257 into the FULL
  # 16-bit range and cast to RGB16, so the brightest regions sit in the high bits
  # that the `ph:0` tone-map compresses and `ph:1` preserves. Replaces the prior
  # source whose content was confined to the bottom 8 bits (~0.4% intensity), which
  # left preserve-vs-tonemap barely exercised.
  defp rgb16_image do
    base =
      512
      |> Image.new!(512, color: [200, 30, 30])
      |> Image.Draw.rect!(0, 0, 96, 96, color: [255, 255, 255])
      |> Image.Draw.rect!(253, 0, 6, 512, color: [40, 230, 70])
      |> Image.Draw.rect!(0, 253, 512, 6, color: [50, 70, 235])
      |> Image.Draw.rect!(384, 384, 128, 128, color: [255, 200, 0])

    {:ok, scaled} = Operation.linear(base, [257.0], [0.0])
    {:ok, ushort} = Operation.cast(scaled, :VIPS_FORMAT_USHORT)
    {:ok, rgb16} = Operation.copy(ushort, interpretation: :VIPS_INTERPRETATION_RGB16)
    rgb16
  end

  # Append a fully-opaque 16-bit alpha band (65535). The uniform-opaque alpha keeps
  # the #229 rgba16_preserve_hdr divergence (imgproxy perturbs a fully-opaque 16-bit
  # alpha; ImagePipe preserves it) meaningful after the RGB regen.
  defp opaque_alpha(rgb16) do
    {:ok, rgba16} = Operation.bandjoin_const(rgb16, [65_535.0])
    rgba16
  end

  @doc "Deterministic radial-chirp pixel buffer: `w*h*3` uchar bytes, row-major."
  def chirp_pixels(w, h) do
    cx = w / 2
    cy = h / 2
    k = 0.00025

    # Build an iolist then flatten once — avoids O(n^2) binary re-copy that a
    # `for … into: <<>>` accumulation incurs over millions of pixels.
    for y <- 0..(h - 1) do
      for x <- 0..(w - 1) do
        dx = x - cx
        dy = y - cy
        v = trunc(127.5 * (1.0 + :math.cos(k * (dx * dx + dy * dy))))
        <<v, v, v>>
      end
    end
    |> IO.iodata_to_binary()
  end

  defp chirp_image(w, h) do
    {:ok, img} = VipsImage.new_from_binary(chirp_pixels(w, h), w, h, 3, :VIPS_FORMAT_UCHAR)
    img
  end

  defp write!(image, filename, opts) do
    body = Image.write!(image, :memory, opts)
    File.write!(Path.join(@dir, filename), body)
  end
end
