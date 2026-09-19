defmodule ImagePipe.Transform.SequentialAccessTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Transform
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Bitonal
  alias ImagePipe.Transform.Operation.Blur
  alias ImagePipe.Transform.Operation.Brightness
  alias ImagePipe.Transform.Operation.Colorize
  alias ImagePipe.Transform.Operation.Contrast
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Duotone
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Gradient
  alias ImagePipe.Transform.Operation.Gray
  alias ImagePipe.Transform.Operation.Monochrome
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Pixelate
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Operation.Rotate
  alias ImagePipe.Transform.Operation.Saturation
  alias ImagePipe.Transform.Operation.Sharpen
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @beach "priv/static/images/beach.jpg"
  @dog "priv/static/images/dog.jpg"

  # Harness self-check: prove the sequential open GENUINELY streams (does not
  # silently buffer). A 90-degree transpose built directly on the sequential
  # image — bypassing Transform.run, which would materialize first — must error when its
  # pixels are pulled, because vips_rot does a non-sequential read. If copy_memory
  # succeeds here, the open is buffering and every equivalence assertion below
  # would be a tautology.
  test "sequential open genuinely streams (a raw transpose errors at evaluation)" do
    body = File.read!(@beach)
    {:ok, image} = Image.open([body], access: :sequential, fail_on: :error)
    {:ok, rotated} = Image.rotate(image, 90)

    assert {:error, _reason} = VipsImage.copy_memory(rotated)
  end

  test "anchor crop streams" do
    assert_sequential_matches_random(
      [
        %Crop{
          width: {:pixels, 80},
          height: {:pixels, 60},
          crop_from: :gravity,
          gravity: {:anchor, :center, :center}
        }
      ],
      File.read!(@beach)
    )
  end

  test "focal-point gravity crop streams" do
    assert_sequential_matches_random(
      [
        %Crop{
          width: {:pixels, 120},
          height: {:pixels, 90},
          crop_from: :gravity,
          gravity: {:fp, 0.25, 0.75}
        }
      ],
      File.read!(@beach)
    )
  end

  test "region crop streams" do
    assert_sequential_matches_random(
      [
        %Crop{
          width: {:pixels, 120},
          height: {:pixels, 90},
          crop_from: %{left: {:pixels, 30}, top: {:pixels, 20}}
        }
      ],
      File.read!(@beach)
    )
  end

  test "resize to a landscape target streams" do
    assert_sequential_matches_random(
      [%Resize{width: 120, height: 80}],
      File.read!(@dog)
    )
  end

  test "resize to a portrait target streams" do
    assert_sequential_matches_random(
      [%Resize{width: 100, height: 200}],
      File.read!(@beach)
    )
  end

  test "resize to a square target streams" do
    assert_sequential_matches_random(
      [%Resize{width: 100, height: 100}],
      File.read!(@beach)
    )
  end

  test "blur streams" do
    assert_sequential_matches_random([%Blur{sigma: 2.0}], File.read!(@beach))
  end

  test "sharpen streams" do
    assert_sequential_matches_random([%Sharpen{sigma: 1.5}], File.read!(@beach))
  end

  test "background flatten streams (alpha png)" do
    assert_sequential_matches_random(
      [%Background{color: [255, 0, 0, 255]}],
      alpha_png_body()
    )
  end

  test "padding streams" do
    assert_sequential_matches_random(
      [%Padding{top: 10, right: 10, bottom: 10, left: 10, fill: :transparent}],
      File.read!(@beach)
    )
  end

  test "canvas extend streams" do
    assert_sequential_matches_random(
      [
        %ExtendCanvas{
          rule: {:dimensions, 400, 400},
          gravity: {:anchor, :center, :center},
          background: :transparent
        }
      ],
      File.read!(@beach)
    )
  end

  test "pixelate streams" do
    assert_sequential_matches_random([%Pixelate{size: 8}], File.read!(@beach))
  end

  test "brightness streams" do
    assert_sequential_matches_random([%Brightness{value: 20}], File.read!(@beach))
  end

  test "contrast streams" do
    assert_sequential_matches_random([%Contrast{value: 1.5}], File.read!(@beach))
  end

  test "saturation streams" do
    assert_sequential_matches_random([%Saturation{value: 1.5}], File.read!(@beach))
  end

  test "colorize streams" do
    assert_sequential_matches_random(
      [%Colorize{opacity: 0.5, color: [0, 0, 0], keep_alpha: false}],
      File.read!(@beach)
    )
  end

  test "gradient streams" do
    assert_sequential_matches_random(
      [%Gradient{opacity: 1.0, color: [0, 0, 0], angle: 0.0, start: 0.0, stop: 1.0}],
      File.read!(@beach)
    )
  end

  test "gray streams" do
    assert_sequential_matches_random([%Gray{}], File.read!(@beach))
  end

  test "bitonal streams" do
    assert_sequential_matches_random([%Bitonal{}], File.read!(@beach))
  end

  test "monochrome streams" do
    assert_sequential_matches_random(
      [%Monochrome{intensity: 0.8, color: [179, 179, 179]}],
      File.read!(@beach)
    )
  end

  test "duotone streams" do
    assert_sequential_matches_random(
      [%Duotone{intensity: 0.8, shadow: [0, 0, 0], highlight: [255, 255, 255]}],
      File.read!(@beach)
    )
  end

  test "duotone streams from a gray input" do
    assert_sequential_matches_random(
      [
        %Gray{},
        %Duotone{intensity: 0.8, shadow: [0, 0, 0], highlight: [255, 255, 255]}
      ],
      File.read!(@beach)
    )
  end

  test "rotation materializes a streamed source before reading pixels out of order" do
    body = File.read!(@beach)

    for angle <- [10, 45] do
      {:ok, sequential} = Image.open([body], access: :sequential, fail_on: :error)
      {:ok, random} = Image.open([body], access: :random, fail_on: :error)
      operation = %Rotate{angle: angle}

      assert {:ok, %State{materialized?: true, image: actual}} =
               Transform.run(%State{image: sequential}, operation)

      assert {:ok, %State{image: expected}} = Rotate.execute(operation, %State{image: random})
      assert_sampled_pixels_match(actual, expected)
    end
  end

  defp oriented_jpeg_body(orientation) do
    {:ok, image} = Image.new(120, 80, color: :red)

    image
    |> Image.set_orientation!(orientation)
    |> Image.write!(:memory, suffix: ".jpg")
  end

  for orientation <- [1, 2, 3, 4, 5, 6, 7, 8] do
    @orientation orientation
    test "orientation flush streams for EXIF orientation #{orientation}" do
      body = oriented_jpeg_body(@orientation)
      pending = PendingOrientation.from_exif(@orientation, true)
      assert_orientation_flush_sequential_matches_random(pending, body)
    end
  end

  test "Flush op (quarter-turn user rotation) streams on sequential source" do
    body = oriented_jpeg_body(1)
    pending = %PendingOrientation{user_angle: 90}
    assert_orientation_flush_sequential_matches_random(pending, body)
  end

  defp alpha_png_body do
    {:ok, image} = Image.new(320, 180, color: [0, 255, 0, 255], bands: 4)
    Image.write!(image, :memory, suffix: ".png")
  end

  property "anchor crop streams across varied dimensions and anchors" do
    body = File.read!(@beach)

    check all(
            w <- integer(8..200),
            h <- integer(8..150),
            anchor <-
              member_of([:center, :left, :right, :top, :bottom, :top_left, :bottom_right]),
            max_runs: 18
          ) do
      {ax, ay} = anchor_to_xy(anchor)

      assert_sequential_matches_random(
        [
          %Crop{
            width: {:pixels, w},
            height: {:pixels, h},
            crop_from: :gravity,
            gravity: {:anchor, ax, ay}
          }
        ],
        body
      )
    end
  end

  property "proportional resize streams across varied targets" do
    body = File.read!(@dog)

    check all(w <- integer(16..400), max_runs: 12) do
      assert_sequential_matches_random(
        [%Resize{width: w, height: w * 2}],
        body
      )
    end
  end

  property "focal-point crop streams across varied focal points and sizes" do
    body = File.read!(@beach)

    check all(
            w <- integer(8..200),
            h <- integer(8..150),
            fx_tenths <- integer(0..10),
            fy_tenths <- integer(0..10),
            max_runs: 18
          ) do
      assert_sequential_matches_random(
        [
          %Crop{
            width: {:pixels, w},
            height: {:pixels, h},
            crop_from: :gravity,
            gravity: {:fp, fx_tenths / 10, fy_tenths / 10}
          }
        ],
        body
      )
    end
  end

  property "region crop streams across varied origins and sizes" do
    body = File.read!(@beach)

    check all(
            left <- integer(0..200),
            top <- integer(0..150),
            w <- integer(8..200),
            h <- integer(8..150),
            max_runs: 18
          ) do
      assert_sequential_matches_random(
        [
          %Crop{
            width: {:pixels, w},
            height: {:pixels, h},
            crop_from: %{left: {:pixels, left}, top: {:pixels, top}}
          }
        ],
        body
      )
    end
  end

  property "resize streams across independently varied target axes" do
    body = File.read!(@beach)

    check all(
            w <- integer(16..400),
            h <- integer(16..300),
            max_runs: 12
          ) do
      assert_sequential_matches_random(
        [%Resize{width: w, height: h}],
        body
      )
    end
  end

  property "blur streams across varied sigma" do
    body = File.read!(@beach)

    check all(sigma_tenths <- integer(5..40), max_runs: 12) do
      assert_sequential_matches_random([%Blur{sigma: sigma_tenths / 10}], body)
    end
  end

  property "duotone streams from gray inputs across dimensions and alpha layouts" do
    check all(
            width <- integer(7..64),
            height <- integer(7..64),
            alpha? <- boolean(),
            max_runs: 16
          ) do
      {base, marker, bands} =
        if alpha?,
          do: {[40, 120, 200, 177], [220, 30, 80, 63], 4},
          else: {[40, 120, 200], [220, 30, 80], 3}

      body =
        Image.new!(width, height, color: base, bands: bands)
        |> Image.Draw.rect!(1, 1, max(1, div(width, 2)), max(1, div(height, 2)), color: marker)
        |> Image.write!(:memory, suffix: ".png")

      assert_sequential_matches_random(
        [
          %Gray{},
          %Duotone{intensity: 0.8, shadow: [10, 20, 30], highlight: [220, 230, 240]}
        ],
        body
      )
    end
  end

  property "orientation flush streams across EXIF orientations and sizes" do
    check all(
            orientation <- member_of([1, 2, 3, 4, 5, 6, 7, 8]),
            w <- integer(20..160),
            h <- integer(20..160),
            max_runs: 24
          ) do
      {:ok, image} = Image.new(w, h, color: :red)
      body = image |> Image.set_orientation!(orientation) |> Image.write!(:memory, suffix: ".jpg")
      pending = PendingOrientation.from_exif(orientation, true)
      assert_orientation_flush_sequential_matches_random(pending, body)
    end
  end

  defp anchor_to_xy(:center), do: {:center, :center}
  defp anchor_to_xy(:left), do: {:left, :center}
  defp anchor_to_xy(:right), do: {:right, :center}
  defp anchor_to_xy(:top), do: {:center, :top}
  defp anchor_to_xy(:bottom), do: {:center, :bottom}
  defp anchor_to_xy(:top_left), do: {:left, :top}
  defp anchor_to_xy(:bottom_right), do: {:right, :bottom}

  defp run_operations(operations, access, body) when access in [:random, :sequential] do
    {:ok, image} = Image.open([body], access: access, fail_on: :error)

    state =
      Enum.reduce(operations, %State{image: image}, fn operation, state ->
        assert {:ok, state} = Transform.run(state, operation)
        refute state.materialized?
        state
      end)

    {:ok, state} = Materializer.materialize(state)
    {:ok, state.image}
  end

  defp assert_sequential_matches_random(operations, body) do
    {:ok, random_image} = run_operations(operations, :random, body)
    {:ok, sequential_image} = run_operations(operations, :sequential, body)

    assert Image.width(sequential_image) == Image.width(random_image)
    assert Image.height(sequential_image) == Image.height(random_image)
    assert Image.has_alpha?(sequential_image) == Image.has_alpha?(random_image)
    assert_sampled_pixels_match(sequential_image, random_image)
  end

  # Compare the actual orientation flush on random and streamed opens.
  defp assert_orientation_flush_sequential_matches_random(%PendingOrientation{} = pending, body) do
    {:ok, random_image} = run_orientation_flush(pending, :random, body)
    {:ok, sequential_image} = run_orientation_flush(pending, :sequential, body)
    {:ok, source} = Image.open([body], access: :random, fail_on: :error)

    expected_dims =
      PendingOrientation.display_dims({Image.width(source), Image.height(source)}, pending)

    assert {Image.width(random_image), Image.height(random_image)} == expected_dims
    assert {Image.width(sequential_image), Image.height(sequential_image)} == expected_dims
    assert Image.has_alpha?(sequential_image) == Image.has_alpha?(random_image)
    assert_sampled_pixels_match(sequential_image, random_image)
  end

  defp run_orientation_flush(%PendingOrientation{} = pending, access, body)
       when access in [:random, :sequential] do
    with {:ok, image} <- Image.open([body], access: access, fail_on: :error),
         state = %State{image: image, pending_orientation: pending},
         {:ok, %State{} = state} <- Transform.run(state, %Flush{}) do
      {:ok, state.image}
    end
  end

  defp assert_sampled_pixels_match(left, right) do
    for x <- sample_positions(Image.width(left)),
        y <- sample_positions(Image.height(left)) do
      assert Image.get_pixel!(left, x, y) == Image.get_pixel!(right, x, y)
    end
  end

  defp sample_positions(size) do
    last = max(size - 1, 0)
    Enum.uniq([0, div(last, 4), div(last, 2), div(last * 3, 4), last])
  end
end
