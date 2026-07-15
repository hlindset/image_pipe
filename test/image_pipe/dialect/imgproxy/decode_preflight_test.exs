defmodule ImagePipe.Dialect.Imgproxy.DecodePreflightTest do
  use ExUnit.Case, async: true

  # `Pipeline.decode_request/2` feeds `DecodePlanner.open_options_for/5`, the
  # defunctionalized entry point. The framework arm reaches the SAME decision
  # through `open_options/5`, walking the op chain — so the two must agree, and
  # this file proves it the same way `pipeline_assembly_test.exs` does: by
  # comparing against the framework's own code rather than restating its rules.
  #
  # The oracle here is `open_options/5` applied to `Assembly.operations/1`'s
  # output. That is exactly the chain the framework arm builds for the same
  # request (pipeline_assembly_test.exs pins that equality op for op), so any
  # disagreement is this preflight's.

  alias ImagePipe.Dialect.Imgproxy.Assembly
  alias ImagePipe.Dialect.Imgproxy.CropRequest
  alias ImagePipe.Dialect.Imgproxy.Orientation
  alias ImagePipe.Dialect.Imgproxy.Pipeline
  alias ImagePipe.Dialect.Imgproxy.PipelineRequest
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry

  @formats [:jpeg, :webp, :png]
  @source_dims {3200, 2400}

  # `orientation:` and `crop:` are given as plain keyword lists and built here.
  defp preq(fields) do
    fields
    |> Enum.map(fn
      {:orientation, value} when is_list(value) -> {:orientation, struct!(Orientation, value)}
      {:crop, value} when is_list(value) -> {:crop, struct!(CropRequest, value)}
      field -> field
    end)
    |> then(&struct!(PipelineRequest, &1))
  end

  defp request(pipelines), do: %{pipelines: pipelines}

  defp geometry(display_dims \\ @source_dims) do
    %SourceGeometry{
      storage_dimensions: @source_dims,
      display_dimensions: display_dims,
      pending_orientation: %PendingOrientation{},
      source_format: :png
    }
  end

  # The framework arm's answer for the same first pipeline.
  defp chain_options(fields, format, exif_qt?, auto_rotate?) do
    {:ok, ops} = Assembly.operations(preq(fields))
    DecodePlanner.open_options(ops, format, @source_dims, exif_qt?, auto_rotate?)
  end

  defp preflight_options(fields, format, exif_qt?, auto_rotate?) do
    decode_request =
      Pipeline.decode_request(
        request([preq(fields)]),
        geometry(display_dims_for(exif_qt?, auto_rotate?))
      )

    DecodePlanner.open_options_for(decode_request, format, @source_dims, exif_qt?, auto_rotate?)
  end

  # What `Decode.with_image/4` actually seeds: `display_dimensions` is the storage
  # dims already swapped when an EXIF quarter turn is being honoured. Feeding the
  # preflight unswapped dims on that arm would be testing a state Decode never
  # produces.
  defp display_dims_for(true, true), do: {2400, 3200}
  defp display_dims_for(_exif_qt?, _auto_rotate?), do: @source_dims

  # Asserts the preflight agrees with the chain path across every format and both
  # EXIF settings, and returns the plain (no-EXIF) jpeg options so a caller can
  # additionally pin the concrete shrink.
  defp assert_agrees_with_chain(fields) do
    for format <- @formats, {exif_qt?, auto_rotate?} <- [{false, false}, {true, true}] do
      expected = chain_options(fields, format, exif_qt?, auto_rotate?)
      actual = preflight_options(fields, format, exif_qt?, auto_rotate?)

      assert actual == expected,
             """
             preflight disagrees with the chain path
             fields:    #{inspect(fields)}
             format:    #{format}, exif_quarter_turn?: #{exif_qt?}, auto_rotate?: #{auto_rotate?}
             chain:     #{inspect(expected)}
             preflight: #{inspect(actual)}
             """
    end

    preflight_options(fields, :jpeg, false, false)
  end

  describe "agreement with the framework arm's chain path" do
    test "a plain fit resize" do
      # ratio = min(3200/400, 2400/300) = 8 -> jpeg shrink 8.
      assert assert_agrees_with_chain(width: {:pixels, 400}, height: {:pixels, 300})[:shrink] == 8
    end

    test "a single-axis resize resolves :auto against the planning frame" do
      # Only one axis is targeted, so the chain's ratio is that axis alone:
      # 3200/400 = 8, and 2400/300 = 8. The aspect resolution must land on the
      # same factor, which it does because it is proportional by construction.
      assert assert_agrees_with_chain(width: {:pixels, 400})[:shrink] == 8
      assert assert_agrees_with_chain(height: {:pixels, 300})[:shrink] == 8
    end

    test "a zero-sentinel dimension is not a target" do
      assert_agrees_with_chain(width: {:pixels, 0}, height: {:pixels, 300})
      assert_agrees_with_chain(width: {:pixels, 0}, dpr: 2.0)
    end

    test "an auto/auto resize yields no target at all" do
      # A bare `dpr:` emits a Resize(:auto, :auto) — a real op, but with no pixel
      # target, so neither arm shrinks.
      opts = assert_agrees_with_chain(dpr: 2.0)
      refute Keyword.has_key?(opts, :shrink)
    end

    test "dpr inflates the target" do
      # Without the dpr the preflight would size the shrink against 400x300 and
      # decode BELOW the residual resize's real 800x600 target, softening the
      # result: chain ratio = min(3200/800, 2400/600) = 4 -> shrink 4, where the
      # uninflated box would give 8.
      assert assert_agrees_with_chain(width: {:pixels, 400}, height: {:pixels, 300}, dpr: 2.0)[
               :shrink
             ] == 4
    end

    test "zoom inflates the target, per axis" do
      assert_agrees_with_chain(width: {:pixels, 400}, height: {:pixels, 300}, zoom_x: 2.0)
      assert_agrees_with_chain(width: {:pixels, 400}, height: {:pixels, 300}, zoom_y: 2.0)

      assert_agrees_with_chain(
        width: {:pixels, 400},
        height: {:pixels, 300},
        zoom_x: 2.0,
        zoom_y: 4.0
      )
    end

    test "dpr and zoom compose" do
      assert_agrees_with_chain(
        width: {:pixels, 400},
        height: {:pixels, 300},
        dpr: 2.0,
        zoom_x: 1.5,
        zoom_y: 0.5
      )
    end

    test "min_width/min_height disable shrink outright" do
      # `resize_load_shrink/3`'s first clause. A preflight that emitted a target
      # box here would shrink where the framework arm does not.
      for fields <- [
            [width: {:pixels, 400}, height: {:pixels, 300}, min_width: {:pixels, 100}],
            [width: {:pixels, 400}, height: {:pixels, 300}, min_height: {:pixels, 100}],
            [width: {:pixels, 400}, height: {:pixels, 300}, min_width: {:pixels, 0}]
          ] do
        opts = assert_agrees_with_chain(fields)
        refute Keyword.has_key?(opts, :shrink)
      end
    end

    test "every resizing type" do
      for type <- [:fit, :fill, :fill_down, :force, :auto] do
        assert_agrees_with_chain(
          resizing_type: type,
          width: {:pixels, 400},
          height: {:pixels, 300}
        )
      end
    end

    test "a trim disables shrink" do
      opts =
        assert_agrees_with_chain(
          trim: [threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false],
          width: {:pixels, 400},
          height: {:pixels, 300}
        )

      refute Keyword.has_key?(opts, :shrink)
    end

    test "a crop narrows the extent feeding the resize" do
      assert_agrees_with_chain(
        crop: [width: {:pixels, 1600}, height: {:pixels, 1200}],
        width: {:pixels, 400},
        height: {:pixels, 300}
      )
    end

    test "a crop dimension larger than the source clamps" do
      assert_agrees_with_chain(
        crop: [width: {:pixels, 99_999}, height: {:pixels, 99_999}],
        width: {:pixels, 400},
        height: {:pixels, 300}
      )
    end

    test "a full-axis crop dimension leaves that axis at full extent" do
      assert_agrees_with_chain(
        crop: [width: {:pixels, 0}, height: {:pixels, 1200}],
        width: {:pixels, 400},
        height: {:pixels, 300}
      )

      assert_agrees_with_chain(
        crop: [width: :auto, height: :auto],
        width: {:pixels, 400},
        height: {:pixels, 300}
      )
    end

    test "a scale crop dimension resolves against the display frame" do
      assert_agrees_with_chain(
        crop: [width: {:scale, 0.5}, height: {:scale, 0.25}],
        width: {:pixels, 400},
        height: {:pixels, 300}
      )
    end

    test "a crop with a single-axis resize resolves :auto against the CROP extent" do
      # The resize runs against the post-crop image, so its :auto axis follows the
      # crop's aspect, not the source's.
      assert_agrees_with_chain(
        crop: [width: {:pixels, 1600}, height: {:pixels, 400}],
        width: {:pixels, 400}
      )
    end
  end

  # --- the user-rotate axis swap (the 9a field, consumed) -----------------

  describe "user_quarter_turn?" do
    test "a rot:90 before the resize sets it and swaps the shrink axes" do
      decode_request =
        Pipeline.decode_request(
          request([preq(orientation: [rotate: 90], width: {:pixels, 400})]),
          geometry()
        )

      assert decode_request.user_quarter_turn?

      # EXIF-1 + rot:90 -> net 90 -> swap: the 400 target is against the DISPLAYED
      # width, which is the stored height (2400). ratio = 2400/400 = 6 -> shrink 4.
      # Without the swap it would be 3200/400 = 8 -> shrink 8.
      assert DecodePlanner.open_options_for(decode_request, :jpeg, @source_dims, false, false)[
               :shrink
             ] == 4
    end

    test "rot:270 also sets it" do
      assert Pipeline.decode_request(
               request([preq(orientation: [rotate: 270])]),
               geometry()
             ).user_quarter_turn?
    end

    test "rot:180 and rot:0 do not" do
      for angle <- [0, 180] do
        refute Pipeline.decode_request(
                 request([preq(orientation: [rotate: angle])]),
                 geometry()
               ).user_quarter_turn?
      end
    end

    test "an EXIF quarter turn plus rot:90 cancels to no swap" do
      # The `exif_5_cover_rot90` regression shape (constellations.ex:849-850):
      # EXIF 5/6/7/8 + rot:90 = net 180, so the displayed axes are NOT transposed.
      # An unpatched dialect reading only the EXIF term would swap and pick the
      # wrong axis. Display dims are the EXIF-swapped source, as Decode seeds them.
      fields = [orientation: [rotate: 90], width: {:pixels, 400}]

      # Decode seeds display_dimensions EXIF-swapped: {2400, 3200}.
      decode_request = Pipeline.decode_request(request([preq(fields)]), geometry({2400, 3200}))

      assert decode_request.user_quarter_turn?

      # Net turn 180 -> NO swap -> shrink against the stored {3200, 2400}, and the
      # w:400 target belongs to that same unswapped frame: ratio = 3200/400 = 8.
      #
      # Resolving the :auto height against display_dimensions instead of the net
      # frame yields a {400, 533} box and ratio min(8, 2400/533) = 4.5 -> shrink 4,
      # the exact bug `planning_dims/2` exists to prevent.
      assert DecodePlanner.open_options_for(decode_request, :jpeg, @source_dims, true, true)[
               :shrink
             ] == 8

      # And it matches the framework arm's chain path for the same request.
      {:ok, ops} = Assembly.operations(preq(fields))

      assert DecodePlanner.open_options_for(decode_request, :jpeg, @source_dims, true, true) ==
               DecodePlanner.open_options(ops, :jpeg, @source_dims, true, true)
    end

    test "the rotate agrees with the chain path across formats and EXIF settings" do
      for angle <- [0, 90, 180, 270] do
        assert_agrees_with_chain(
          orientation: [rotate: angle],
          width: {:pixels, 400},
          height: {:pixels, 300}
        )
      end
    end
  end

  # --- first-pipeline-only scoping ----------------------------------------

  describe "scoping" do
    test "only the first pipeline informs the decode" do
      # Decode happens once, before any pipeline runs, so a second pipeline's
      # resize cannot inform it — that resize runs on the first's output.
      decode_request =
        Pipeline.decode_request(
          request([preq([]), preq(width: {:pixels, 400}, height: {:pixels, 300})]),
          geometry()
        )

      assert decode_request.resize_target == nil
      refute decode_request.trim?

      refute Keyword.has_key?(
               DecodePlanner.open_options_for(decode_request, :jpeg, @source_dims),
               :shrink
             )
    end

    test "trim? reads the first pipeline only" do
      trim = [threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false]

      assert Pipeline.decode_request(
               request([preq(trim: trim), preq([])]),
               geometry()
             ).trim?

      refute Pipeline.decode_request(
               request([preq([]), preq(trim: trim)]),
               geometry()
             ).trim?
    end

    test "crop_extent reads the first pipeline only" do
      crop = [width: {:pixels, 100}, height: {:pixels, 100}]

      assert Pipeline.decode_request(
               request([preq(crop: crop), preq([])]),
               geometry()
             ).crop_extent == {100, 100}

      assert Pipeline.decode_request(
               request([preq([]), preq(crop: crop)]),
               geometry()
             ).crop_extent == nil
    end

    test "the terminal fields the imgproxy dialect does not use stay nil" do
      decode_request = Pipeline.decode_request(request([preq([])]), geometry())

      assert decode_request.terminal_reduction == nil
      assert decode_request.required_extent == nil
    end
  end
end
