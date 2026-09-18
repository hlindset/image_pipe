defmodule ImagePipe.Dialect.Imgproxy.DecodePreflightTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Imgproxy.Assembly
  alias ImagePipe.Dialect.Imgproxy.CropRequest
  alias ImagePipe.Dialect.Imgproxy.Orientation
  alias ImagePipe.Dialect.Imgproxy.Pipeline
  alias ImagePipe.Dialect.Imgproxy.PipelineRequest
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry

  @source_dims {3200, 2400}

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

  defp geometry(display_dims \\ @source_dims, storage_dims \\ @source_dims) do
    %SourceGeometry{
      storage_dimensions: storage_dims,
      display_dimensions: display_dims,
      pending_orientation: %PendingOrientation{},
      source_format: :png
    }
  end

  defp decode_request(fields, dims \\ @source_dims, exif_qt? \\ false, auto_rotate? \\ false) do
    Pipeline.decode_request(
      request([preq(fields)]),
      geometry(display_dims_for(exif_qt?, auto_rotate?, dims), dims)
    )
  end

  defp preflight_options(fields, format, exif_qt?, auto_rotate?, dims \\ @source_dims) do
    fields
    |> decode_request(dims, exif_qt?, auto_rotate?)
    |> DecodePlanner.open_options_for(format, dims, exif_qt?, auto_rotate?)
  end

  defp display_dims_for(true, true, {w, h}), do: {h, w}
  defp display_dims_for(_exif_qt?, _auto_rotate?, dims), do: dims

  describe "decode request geometry" do
    test "a plain fit resize produces the target used for format-specific load reduction" do
      fields = [width: {:pixels, 400}, height: {:pixels, 300}]

      assert decode_request(fields).resize_target == {400.0, 300.0}
      assert preflight_options(fields, :jpeg, false, false)[:shrink] == 8
      assert preflight_options(fields, :webp, false, false)[:scale] == 0.125

      png = preflight_options(fields, :png, false, false)
      refute Keyword.has_key?(png, :shrink)
      refute Keyword.has_key?(png, :scale)
    end

    test "a single-axis resize constrains only that axis" do
      fields = [width: {:pixels, 400}]
      dims = {3200, 2405}

      assert decode_request(fields, dims).resize_target == {400.0, nil}
      assert preflight_options(fields, :jpeg, false, false, dims)[:shrink] == 8
    end

    test "a subpixel DPR target is retained without rounding to zero" do
      fields = [width: {:pixels, 1}, dpr: 0.4]

      assert decode_request(fields).resize_target == {0.4, nil}

      assert_in_delta preflight_options(fields, :webp, false, false)[:scale],
                      0.4 / 3200,
                      1.0e-15
    end

    test "a non-integral inflated target remains fractional" do
      fields = [width: {:pixels, 333}, dpr: 1.1]

      assert decode_request(fields).resize_target == {366.3, nil}

      assert_in_delta preflight_options(fields, :webp, false, false)[:scale],
                      366.3 / 3200,
                      1.0e-12
    end

    test "zero-sentinel and auto dimensions do not create targets" do
      assert decode_request(width: {:pixels, 0}, height: {:pixels, 300}).resize_target ==
               {nil, 300.0}

      assert decode_request(dpr: 2.0).resize_target == nil
    end

    test "DPR uses the exact rational carried by the resize operation" do
      fields = [width: {:pixels, 400}, height: {:pixels, 300}, dpr: 1.0000000000001]

      assert decode_request(fields).resize_target == {400.0, 300.0}
      assert preflight_options(fields, :jpeg, false, false)[:shrink] == 8
      assert preflight_options(fields, :webp, false, false)[:scale] == 0.125
    end

    test "a DPR with no rational produces no decode target" do
      fields = [width: {:pixels, 400}, height: {:pixels, 300}, dpr: 0.00000001]

      assert {:error, {:invalid_operation, :resize, _}} = Assembly.operations(preq(fields))
      assert decode_request(fields).resize_target == nil

      opts = preflight_options(fields, :jpeg, false, false)
      refute Keyword.has_key?(opts, :shrink)
    end

    test "DPR and per-axis zoom compose into the actual resize target" do
      fields = [
        width: {:pixels, 400},
        height: {:pixels, 300},
        dpr: 2.0,
        zoom_x: 1.5,
        zoom_y: 0.5
      ]

      assert decode_request(fields).resize_target == {1200.0, 300.0}
      assert preflight_options(fields, :jpeg, false, false)[:shrink] == 2
    end

    test "min dimensions disable shrink-on-load" do
      for fields <- [
            [width: {:pixels, 400}, height: {:pixels, 300}, min_width: {:pixels, 100}],
            [width: {:pixels, 400}, height: {:pixels, 300}, min_height: {:pixels, 100}]
          ] do
        assert decode_request(fields).resize_target == nil
        refute Keyword.has_key?(preflight_options(fields, :jpeg, false, false), :shrink)
      end
    end

    test "all resizing types produce the same decode target" do
      for type <- [:fit, :fill, :fill_down, :force, :auto] do
        assert decode_request(
                 resizing_type: type,
                 width: {:pixels, 400},
                 height: {:pixels, 300}
               ).resize_target == {400.0, 300.0}
      end
    end

    test "trim disables load reduction" do
      fields = [
        trim: [threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false],
        width: {:pixels, 400},
        height: {:pixels, 300}
      ]

      assert decode_request(fields).trim?
      refute Keyword.has_key?(preflight_options(fields, :jpeg, false, false), :shrink)
    end
  end

  describe "crop extent" do
    test "pixel crops narrow and clamp the extent feeding the resize" do
      fields = [
        crop: [width: {:pixels, 1600}, height: {:pixels, 1200}],
        width: {:pixels, 400},
        height: {:pixels, 300}
      ]

      assert decode_request(fields).crop_extent == {1600, 1200}
      assert preflight_options(fields, :jpeg, false, false)[:shrink] == 4

      oversized = [
        crop: [width: {:pixels, 99_999}, height: {:pixels, 99_999}],
        width: {:pixels, 400},
        height: {:pixels, 300}
      ]

      assert decode_request(oversized).crop_extent == @source_dims
      assert preflight_options(oversized, :jpeg, false, false)[:shrink] == 8
    end

    test "full-axis crop dimensions retain the source extent" do
      fields = [
        crop: [width: {:pixels, 0}, height: {:pixels, 1200}],
        width: {:pixels, 400},
        height: {:pixels, 300}
      ]

      assert decode_request(fields).crop_extent == {3200, 1200}
      assert preflight_options(fields, :jpeg, false, false)[:shrink] == 4

      assert decode_request(crop: [width: :auto, height: :auto]).crop_extent == @source_dims
    end

    test "scale crops resolve in the display frame" do
      fields = [
        crop: [width: {:scale, 0.5}, height: {:scale, 0.25}],
        width: {:pixels, 400},
        height: {:pixels, 300}
      ]

      assert decode_request(fields).crop_extent == {1600, 600}
      assert preflight_options(fields, :jpeg, false, false)[:shrink] == 2
    end

    test "scale crops use the exact rational carried by the crop operation" do
      dims = {2850, 2583}
      fields = [crop: [width: {:scale, 0.29}, height: {:scale, 0.29}], width: {:pixels, 400}]

      assert decode_request(fields, dims).crop_extent == {827, 749}

      assert_in_delta preflight_options(fields, :webp, false, false, dims)[:scale],
                      400 / 827,
                      1.0e-12
    end

    test "a single-axis resize is evaluated against the crop extent" do
      fields = [
        crop: [width: {:pixels, 1600}, height: {:pixels, 400}],
        width: {:pixels, 400}
      ]

      request = decode_request(fields)
      assert request.crop_extent == {1600, 400}
      assert request.resize_target == {400.0, nil}
      assert preflight_options(fields, :jpeg, false, false)[:shrink] == 4
    end
  end

  describe "user_quarter_turn?" do
    test "rot:90 sets it and swaps the shrink axes" do
      fields = [orientation: [rotate: 90], width: {:pixels, 400}]
      request = decode_request(fields)

      assert request.user_quarter_turn?
      assert DecodePlanner.open_options_for(request, :jpeg, @source_dims)[:shrink] == 4
    end

    test "rot:270 sets it while rot:0 and rot:180 do not" do
      assert decode_request(orientation: [rotate: 270]).user_quarter_turn?
      refute decode_request(orientation: [rotate: 0]).user_quarter_turn?
      refute decode_request(orientation: [rotate: 180]).user_quarter_turn?
    end

    test "an EXIF quarter turn and rot:90 cancel the axis swap" do
      fields = [orientation: [rotate: 90], width: {:pixels, 400}]
      request = decode_request(fields, @source_dims, true, true)

      assert request.user_quarter_turn?

      assert DecodePlanner.open_options_for(request, :jpeg, @source_dims, true, true)[:shrink] ==
               8
    end
  end

  describe "scoping" do
    test "only the first pipeline informs the decode" do
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

    test "trim and crop read the first pipeline only" do
      trim = [threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false]
      crop = [width: {:pixels, 100}, height: {:pixels, 100}]

      assert Pipeline.decode_request(request([preq(trim: trim), preq([])]), geometry()).trim?
      refute Pipeline.decode_request(request([preq([]), preq(trim: trim)]), geometry()).trim?

      assert Pipeline.decode_request(request([preq(crop: crop), preq([])]), geometry()).crop_extent ==
               {100, 100}

      assert Pipeline.decode_request(request([preq([]), preq(crop: crop)]), geometry()).crop_extent ==
               nil
    end

    test "terminal-only fields remain unset" do
      decode_request = Pipeline.decode_request(request([preq([])]), geometry())

      assert decode_request.terminal_reduction == nil
      assert decode_request.required_extent == nil
    end
  end
end
