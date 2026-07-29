defmodule ImagePipe.ShrinkThroughCropTest do
  # Real image encode/decode per case — keep it serial.
  use ExUnit.Case, async: false

  alias ImagePipe.Decode
  alias ImagePipe.Dialect.Declarative
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  # Shrink-on-load through a preceding crop (#151). Today a crop before the resize
  # forces a full-resolution decode; this exercises the imgproxy-parity path where
  # the JPEG is shrunk on load and the crop's pixel dims + absolute gravity offsets
  # are rescaled by the realized shrink. The output must stay pixel-equivalent
  # (±1px on each axis, and perceptually identical) to the full-decode + crop path.
  #
  # Equivalence is proven against the SAME source encoded as PNG, which is not
  # shrink-eligible and therefore decodes full-resolution and crops at full res.
  # Any divergence beyond the resampling floor is attributable to the rescale.

  # A structured source so a misplaced crop shows up as pixel differences. Paint
  # distinguishable rectangles at known positions so crop placement is observable:
  # top-left quadrant red, bottom-right quadrant green, a centred blue marker.
  # Solid colours would hide crop-offset errors.
  defp structured(width, height, suffix) do
    width
    |> Image.new!(height, color: [10, 20, 30])
    |> Image.Draw.rect!(0, 0, div(width, 2), div(height, 2), color: [240, 40, 40])
    |> Image.Draw.rect!(div(width, 2), div(height, 2), div(width, 2), div(height, 2),
      color: [40, 240, 40]
    )
    |> Image.Draw.rect!(div(width, 4), div(height, 4), div(width, 2), div(height, 2),
      color: [40, 40, 240]
    )
    |> Image.write!(:memory, suffix: suffix)
  end

  defp plan(operations) do
    %Plan{
      source: %Path{segments: ["crop.img"]},
      output: %Plan.Output{mode: :automatic},
      pipelines: [%Pipeline{operations: operations}]
    }
  end

  defp run(body, operations) do
    decode_execute(body, plan(operations))
  end

  # Fetch + decode through the shared bracket with the declarative dialect's
  # decode preflight, then run the plan through the declarative pipeline —
  # the same two seams `ImagePipe.Plug.DialectRunner` drives.
  defp decode_execute(body, plan) do
    opts = opts(body)
    {:ok, source} = Source.resolve(plan.source, opts, [])

    Decode.with_image(
      source,
      Keyword.put(opts, :auto_rotate?, plan.auto_rotate),
      &Declarative.decode_request(plan, &1),
      fn state, geometry ->
        {:ok, %State{} = final} = Declarative.execute(state, geometry, plan, opts)
        {final.image, shrink_factor(state.decode_shrink)}
      end
    )
  end

  # The realized load shrink, rounded back to the libjpeg block factor the
  # planner asked for. `nil` when the decode was not shrunk at all.
  defp shrink_factor(nil), do: nil
  defp shrink_factor(%{w: w}), do: round(w)

  defp opts(body) do
    Source.validate_config!(
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: origin_plug(body)]}
      ],
      max_input_pixels: 100_000_000,
      max_result_width: 100_000,
      max_result_height: 100_000,
      max_result_pixels: 1_000_000_000,
      max_body_bytes: 100_000_000
    )
  end

  defp origin_plug(body) do
    content_type =
      case body do
        <<0xFF, 0xD8, _rest::binary>> -> "image/jpeg"
        _other -> "image/png"
      end

    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.send_resp(200, body)
    end
  end

  # Mean absolute error across all pixels/bands, after downsampling both to ~48px
  # wide. Coarse enough to be insensitive to sub-pixel decode-kernel differences,
  # fine enough to catch a misplaced crop (which moves whole colour blocks).
  defp coarse_mae(img_a, img_b) do
    target_w = 48
    {:ok, ds_a} = Image.resize(img_a, target_w / Image.width(img_a))
    {:ok, ds_b} = Image.resize(img_b, target_w / Image.width(img_b))

    w = min(Image.width(ds_a), Image.width(ds_b))
    h = min(Image.height(ds_a), Image.height(ds_b))
    bands = length(Image.get_pixel!(ds_a, 0, 0))

    total =
      for x <- 0..(w - 1), y <- 0..(h - 1), reduce: 0 do
        acc ->
          pa = Image.get_pixel!(ds_a, x, y)
          pb = Image.get_pixel!(ds_b, x, y)
          acc + (Enum.zip(pa, pb) |> Enum.map(fn {a, b} -> abs(a - b) end) |> Enum.sum())
      end

    total / (w * h * bands)
  end

  defp assert_equivalent(jpeg_img, png_img, shrink, label) do
    assert shrink in [2, 4, 8],
           "expected JPEG shrink to fire for #{label}, got #{inspect(shrink)}"

    jw = Image.width(jpeg_img)
    jh = Image.height(jpeg_img)
    pw = Image.width(png_img)
    ph = Image.height(png_img)

    assert abs(jw - pw) <= 1 and abs(jh - ph) <= 1,
           "shrink path #{jw}x#{jh} drifted >1px from full-decode #{pw}x#{ph} for #{label} (shrink #{shrink})"

    mae = coarse_mae(jpeg_img, png_img)

    assert mae < 4.0,
           "shrink-through-crop coarse MAE #{mae} exceeds 4.0 for #{label} — crop likely misplaced"
  end

  # 3200×3200 source so a width-only fit:400 drives load_shrink ~8 even after a
  # crop; the crop dim governs the realized shrink (imgproxy widthToScale).
  @src 3200

  describe "CropRegion (explicit pixel coords) then resize" do
    test "centre region crop + fit resize is pixel-equivalent across shrink and full decode" do
      {:ok, crop} = Operation.crop_region({:px, 800}, {:px, 800}, {:px, 1600}, {:px, 1600})
      {:ok, resize} = Operation.resize(:fit, {:px, 400}, {:px, 400})
      ops = [crop, resize]

      {jpeg_img, shrink} = run(structured(@src, @src, ".jpg"), ops)
      {png_img, no_shrink} = run(structured(@src, @src, ".png"), ops)

      assert no_shrink == nil, "PNG baseline must not shrink"
      assert_equivalent(jpeg_img, png_img, shrink, "region 800,800 1600x1600 -> fit:400:400")
    end

    test "off-centre region crop preserves placement" do
      {:ok, crop} = Operation.crop_region({:px, 1200}, {:px, 400}, {:px, 1200}, {:px, 1200})
      {:ok, resize} = Operation.resize(:fit, {:px, 300}, {:px, 300})
      ops = [crop, resize]

      {jpeg_img, shrink} = run(structured(@src, @src, ".jpg"), ops)
      {png_img, _} = run(structured(@src, @src, ".png"), ops)

      assert_equivalent(jpeg_img, png_img, shrink, "region 1200,400 1200x1200 -> fit:300:300")
    end
  end

  describe "CropGuided absolute pixel-offset gravity then resize" do
    test "anchor gravity with absolute pixel offset rescales correctly" do
      {:ok, crop} =
        Operation.crop_guided({:px, 1600}, {:px, 1600}, {:anchor, :left, :top},
          x_offset: {:pixels, 600},
          y_offset: {:pixels, 400}
        )

      {:ok, resize} = Operation.resize(:fit, {:px, 400}, {:px, 400})
      ops = [crop, resize]

      {jpeg_img, shrink} = run(structured(@src, @src, ".jpg"), ops)
      {png_img, _} = run(structured(@src, @src, ".png"), ops)

      assert_equivalent(
        jpeg_img,
        png_img,
        shrink,
        "guided 1600x1600 left-top +600+400 -> fit:400"
      )
    end
  end

  describe "CropGuided focus-point gravity (relative) then resize" do
    test "focus-point gravity is unaffected by the shrink rescale" do
      {:ok, crop} =
        Operation.crop_guided({:px, 1600}, {:px, 1600}, {:focal, {:ratio, 1, 4}, {:ratio, 3, 4}})

      {:ok, resize} = Operation.resize(:fit, {:px, 400}, {:px, 400})
      ops = [crop, resize]

      {jpeg_img, shrink} = run(structured(@src, @src, ".jpg"), ops)
      {png_img, _} = run(structured(@src, @src, ".png"), ops)

      assert_equivalent(jpeg_img, png_img, shrink, "guided 1600x1600 focal(0.25,0.75) -> fit:400")
    end
  end

  describe "relative (ratio) crop dimensions then resize" do
    test "ratio crop dims need no rescale and stay equivalent" do
      {:ok, crop} =
        Operation.crop_guided({:ratio, 1, 2}, {:ratio, 1, 2}, {:anchor, :center, :center})

      {:ok, resize} = Operation.resize(:fit, {:px, 400}, {:px, 400})
      ops = [crop, resize]

      {jpeg_img, shrink} = run(structured(@src, @src, ".jpg"), ops)
      {png_img, _} = run(structured(@src, @src, ".png"), ops)

      assert_equivalent(jpeg_img, png_img, shrink, "guided ratio 1/2 center -> fit:400")
    end
  end

  describe "decode-limit guardrail" do
    # An over-limit source with a crop+resize that WOULD shrink must STILL fail the
    # input-pixel gate, because validate_original_pixels keys off the un-shrunk
    # header dims read before the shrink-aware open. Shrink-through-crop must not
    # smuggle an over-budget source past the limit.
    test "over-limit JPEG with crop+resize is rejected before decode" do
      body = structured(@src, @src, ".jpg")

      {:ok, crop} = Operation.crop_region({:px, 0}, {:px, 0}, {:px, 1600}, {:px, 1600})
      {:ok, resize} = Operation.resize(:fit, {:px, 400}, {:px, 400})
      plan = plan([crop, resize])

      over_limit =
        body
        |> opts()
        |> Keyword.put(:max_input_pixels, @src * @src - 1)
        |> Keyword.put(:auto_rotate?, plan.auto_rotate)

      {:ok, source} = Source.resolve(plan.source, over_limit, [])

      assert {:error, {:input_limit, {:too_many_input_pixels, pixels, limit}}} =
               Decode.with_image(
                 source,
                 over_limit,
                 &Declarative.decode_request(plan, &1),
                 fn _state, _geometry ->
                   flunk("decode must not run past the pixel-limit gate")
                 end
               )

      assert pixels == @src * @src
      assert limit == @src * @src - 1
    end
  end

  describe "composition with EXIF orientation (#146)" do
    # A gravity crop + resize on an EXIF-oriented source: the deferred-orientation
    # compensation (compensate_crop: gravity remap + dim swap) and the shrink-on-load
    # coordinate rescale must BOTH apply to the same executable %Crop{}. The rescale
    # is a uniform scalar (both axes ÷ the realized shrink), so it commutes with the
    # quarter-turn axis swap. Compared against the same oriented source as PNG (full
    # decode), output must stay pixel-equivalent.
    test "gravity crop + resize on orientation-6 source composes orientation and shrink" do
      jpeg = oriented(@src, @src, 6, ".jpg")
      png = oriented(@src, @src, 6, ".png")

      {:ok, crop} =
        Operation.crop_guided({:px, 1600}, {:px, 1200}, {:anchor, :left, :top},
          x_offset: {:pixels, 600},
          y_offset: {:pixels, 400}
        )

      {:ok, resize} = Operation.resize(:fit, {:px, 400}, {:px, 300})
      ops = [crop, resize]

      {jpeg_img, shrink} = run_auto_rotate(jpeg, ops)
      {png_img, no_shrink} = run_auto_rotate(png, ops)

      assert no_shrink == nil
      assert_equivalent(jpeg_img, png_img, shrink, "oriented-6 gravity crop -> fit:400:300")
    end
  end

  # #146 region-crop / rotate-only flush regression. A region crop (or any path
  # that force-flushes pending orientation before an op) on an EXIF-oriented
  # source used to fail at large sizes: the quarter/half-turn flush ran on top of
  # the *un-materialized* sequential decode, and copy_memory then raised
  # `{:decode, "Failed to memory copy image"}` once the image was large enough
  # that libvips could no longer silently buffer the random read (orientation 1
  # streamed fine at every size; 3/6/8 failed at 3200 but not 800).
  # OrientationFlush now materializes the un-rotated image to RAM before applying
  # a random-access-requiring orientation, giving the rotate a random-access
  # source. These run at @src (3200), squarely in the previously-failing range.
  #
  # Oracle: the deferred-orientation result must equal applying the orientation
  # eagerly *first* (full random-access autorotate, outside the pipeline), then
  # running the same operations on the now-upright, untagged image. Fixed-coord
  # region crops select different content per orientation, so the orientation-1
  # twin is NOT a valid oracle here; eager-flush-first is.
  describe "region-crop / rotate-only flush on large EXIF-oriented source (#146)" do
    for orientation <- [6, 3, 8] do
      test "EXIF #{orientation}: region crop + resize succeeds and matches eager flush at #{@src}px" do
        orientation = unquote(orientation)
        {:ok, crop} = Operation.crop_region({:px, 800}, {:px, 600}, {:px, 1200}, {:px, 900})
        {:ok, resize} = Operation.resize(:fit, {:px, 400}, {:px, 300})
        ops = [crop, resize]

        body = oriented(@src, @src, orientation, ".png")
        {deferred, _} = run_auto_rotate(body, ops)
        eager = run_eager_reference(body, ops)

        assert_orientation_equivalent(deferred, eager, "EXIF #{orientation} region crop")
      end
    end

    test "no-geometry rotate:90 on a large oriented source flushes at delivery (#146)" do
      {:ok, rotate} = Operation.rotate(90)
      ops = [rotate]

      # auto_rotate on an orientation-6 source plus a user 90° rotate: the entire
      # turn is deferred and flushed at delivery (no resize/crop to flush behind).
      body = oriented(@src, @src, 6, ".png")
      {deferred, _} = run_auto_rotate(body, ops)
      eager = run_eager_reference(body, ops)

      assert_orientation_equivalent(deferred, eager, "rotate:90 delivery flush")
    end
  end

  # Per-stage random-access gate (#146). OrientationFlush applies the EXIF autorotate
  # and the user rotate as SEPARATE libvips ops; EACH stage that rotates 90/180/270 —
  # or vertically flips — reads out of row order and independently needs a
  # random-access source. The fixed predicate
  # (`exif_angle != 0 or user_angle != 0 or user_flip_y`, in
  # `ImagePipe.Transform.OrientationFlush`) fires on ANY such stage; the earlier
  # net-angle predicate (`rem(exif_angle + user_angle, 360) != 0 or user_flip_y`)
  # pre-copied only on the COMBINED angle, so when an EXIF quarter/half-turn and a
  # user rotate cancel (net 0 mod 360) the per-stage rotations still ran on the
  # un-materialized `access: :sequential` decode and copy_memory raised
  # `{:decode, "Failed to memory copy image"}` at large sizes — a user-reachable
  # HTTP 415 on a valid request (e.g. `/_/rot:270/.../EXIF-5 source`).
  #
  # The two predicates DIVERGE on exactly six (orientation, user_rotate) pairs: the
  # net-cancel holes where `exif_angle != 0` but the angles sum to 0 mod 360 —
  # EXIF{3,4}+rot:180, EXIF{5,6}+rot:270, EXIF{7,8}+rot:90. Those six are the entire
  # falsifiable surface of the fix; every other orientation/rotation/flip passes
  # under both predicates. Composition correctness of the flush across the full
  # EXIF × rotate × flip space is covered pixel-exact at small size by
  # `ImagePipe.Transform.DeferredOrientationTest`, so it is not re-tested here — this
  # guard exists solely to keep the large-size materialization fix non-tautological.
  #
  # Each hole drives the NO-GEOMETRY delivery-flush path: a bare rotate carries the
  # whole orientation to delivery and flushes at full resolution, with no crop/resize
  # to reshape libvips' lazy pipeline. That matters — a trailing region crop
  # reorganizes the pipeline and lets libvips SILENTLY BUFFER the random read,
  # masking the wall, so a crop-driven flush would pass even with the buggy
  # predicate. The source is decoded `access: :sequential, fail_on: :error` by the
  # real processor path (a genuinely streamed open, NOT a buffered `from_binary`).
  # Each hole must (a) succeed (no sequential-wall crash) and (b) match the eager
  # autorotate-first reference (dims ±1px, coarse MAE < 4).
  #
  # Runs at @src (3200), in the previously-failing range. Under the broken predicate
  # the EXIF-5+rot:270 and EXIF-7+rot:90 holes crash here while libvips silently
  # buffers 3/4/6/8 (masked, not absent) — keeping all six holds the guard to the
  # complete divergence surface rather than today's-crashing subset, since a libvips
  # buffering shift could expose any of them.
  @net_cancel_holes [{3, 180}, {4, 180}, {5, 270}, {6, 270}, {7, 90}, {8, 90}]

  describe "per-stage orientation flush materialization holes (#146)" do
    # Non-tautology self-check: prove the streamed open at @src genuinely LACKS random
    # access, so the hole successes below are not tautological. A raw quarter-turn
    # rotate (transpose) on a source opened `access: :sequential, fail_on: :error`
    # followed by copy_memory must FAIL the sequential-access wall at this size. If it
    # ever starts passing, libvips has grown a silent buffer and the holes prove
    # nothing — this size must match the holes below.
    test "known-random transpose on the streamed #{@src}px decode trips the sequential wall" do
      body = oriented(@src, @src, 1, ".png")
      streamed = decode_streamed(body)
      {:ok, transposed} = Image.rotate(streamed, 90)

      assert {:error, _} = VipsImage.copy_memory(transposed),
             "expected the streamed transpose to trip the sequential wall at #{@src}px; " <>
               "if it succeeded, libvips silently buffered and the holes are tautological"
    end

    for {orientation, angle} <- @net_cancel_holes do
      test "EXIF #{orientation} + rot:#{angle} (net-cancel) materializes and matches eager at #{@src}px" do
        orientation = unquote(orientation)
        angle = unquote(angle)
        {:ok, rotate} = Operation.rotate(angle)

        body = oriented(@src, @src, orientation, ".png")
        assert {final, _shrink} = run_auto_rotate(body, [rotate])

        eager = run_eager_reference(body, [rotate])

        assert_orientation_equivalent(final, eager, "EXIF #{orientation} + rot:#{angle}")
      end
    end
  end

  # Decode + autorotate to upright with a random-access open OUTSIDE the pipeline,
  # re-encode untagged, then run the SAME operations through the plain path. This
  # is the displayed-frame result the deferred path must reproduce. Takes the
  # already-built oriented body so the deferred and eager legs share one fixture.
  defp run_eager_reference(body, operations) do
    {:ok, img} = Image.open(body, access: :random)
    {:ok, {upright, _flags}} = Image.autorotate(img)
    upright_body = Image.write!(upright, :memory, suffix: ".png")
    {img_out, _shrink} = run(upright_body, operations)
    img_out
  end

  defp assert_orientation_equivalent(deferred, eager, label) do
    dw = Image.width(deferred)
    dh = Image.height(deferred)
    ew = Image.width(eager)
    eh = Image.height(eager)

    assert abs(dw - ew) <= 1 and abs(dh - eh) <= 1,
           "deferred #{dw}x#{dh} drifted >1px from eager flush #{ew}x#{eh} for #{label}"

    mae = coarse_mae(deferred, eager)

    assert mae < 4.0,
           "deferred-orientation coarse MAE #{mae} exceeds 4.0 for #{label} — orientation/crop misplaced"
  end

  defp oriented(width, height, orientation, suffix) do
    width
    |> Image.new!(height, color: [10, 20, 30])
    |> Image.Draw.rect!(0, 0, div(width, 2), div(height, 2), color: [240, 40, 40])
    |> Image.Draw.rect!(div(width, 2), div(height, 2), div(width, 2), div(height, 2),
      color: [40, 40, 240]
    )
    |> Image.set_orientation!(orientation)
    |> Image.write!(:memory, suffix: suffix)
  end

  # The streamed full-res decode the bracket produces (access: :sequential,
  # fail_on: :error over the source-response seekable input). No ops → no shrink.
  defp decode_streamed(body) do
    plan = plan([])
    opts = opts(body)
    {:ok, source} = Source.resolve(plan.source, opts, [])

    Decode.with_image(
      source,
      Keyword.put(opts, :auto_rotate?, plan.auto_rotate),
      &Declarative.decode_request(plan, &1),
      fn state, _geometry -> state.image end
    )
  end

  defp run_auto_rotate(body, operations) do
    decode_execute(body, %Plan{
      source: %Path{segments: ["crop.img"]},
      output: %Plan.Output{mode: :automatic},
      pipelines: [%Pipeline{operations: operations}],
      auto_rotate: true
    })
  end
end
