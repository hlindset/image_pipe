defmodule ImagePipe.Transform.SequentialAccessTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Bitonal
  alias ImagePipe.Transform.Operation.Blur
  alias ImagePipe.Transform.Operation.Brightness
  alias ImagePipe.Transform.Operation.Contrast
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Duotone
  alias ImagePipe.Transform.Operation.ExtendCanvas
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
  # image — bypassing Chain, which would materialize first — must error when its
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

  test "fit resize streams" do
    assert_sequential_matches_random(
      [%Resize{mode: :fit, width: {:pixels, 120}, height: :auto}],
      File.read!(@dog)
    )
  end

  test "fill resize streams" do
    assert_sequential_matches_random(
      [%Resize{mode: :fill, width: {:pixels, 100}, height: {:pixels, 100}}],
      File.read!(@beach)
    )
  end

  test "force resize streams" do
    assert_sequential_matches_random(
      [%Resize{mode: :force, width: {:pixels, 100}, height: {:pixels, 100}}],
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
          rule: {:dimensions, {:pixels, 400}, {:pixels, 400}},
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

  test "Rotate op is materializing (known-random; cannot stream)" do
    assert ImagePipe.Transform.requires_materialization?(%Rotate{angle: 45})
    assert ImagePipe.Transform.requires_materialization?(%Rotate{angle: 90, mirror: true})
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

  property "fit resize streams across varied targets" do
    body = File.read!(@dog)

    check all(w <- integer(16..400), max_runs: 12) do
      assert_sequential_matches_random(
        [%Resize{mode: :fit, width: {:pixels, w}, height: :auto}],
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

  property "fill resize streams across varied targets" do
    body = File.read!(@beach)

    check all(
            w <- integer(16..400),
            h <- integer(16..300),
            max_runs: 12
          ) do
      assert_sequential_matches_random(
        [%Resize{mode: :fill, width: {:pixels, w}, height: {:pixels, h}}],
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

  defp run_chain(chain, access, body) when access in [:random, :sequential] do
    with {:ok, image} <- Image.open([body], access: access, fail_on: :error),
         {:ok, state} <- Chain.execute(%State{image: image}, chain),
         {:ok, %State{} = state} <- Materializer.materialize(state) do
      {:ok, state.image}
    end
  end

  defp assert_sequential_matches_random(chain, body) do
    {:ok, random_image} = run_chain(chain, :random, body)
    {:ok, sequential_image} = run_chain(chain, :sequential, body)

    assert Image.width(sequential_image) == Image.width(random_image)
    assert Image.height(sequential_image) == Image.height(random_image)
    assert Image.has_alpha?(sequential_image) == Image.has_alpha?(random_image)
    assert_sampled_pixels_match(sequential_image, random_image)
  end

  # Runs orientation flush (via Materializer.materialize, which routes through
  # OrientationFlush.flush) on both a :random and a :sequential open of `body`.
  # Asserts the output pixels match.  This is the new sequential-safety gate for
  # EXIF/user orientation: it proves that OrientationFlush produces the same result
  # whether the image was opened for random access or streamed sequentially —
  # i.e. that the flush path is safe to call on a sequential source.
  defp assert_orientation_flush_sequential_matches_random(%PendingOrientation{} = pending, body) do
    {:ok, random_image} = run_orientation_flush(pending, :random, body)
    {:ok, sequential_image} = run_orientation_flush(pending, :sequential, body)

    assert Image.width(sequential_image) == Image.width(random_image)
    assert Image.height(sequential_image) == Image.height(random_image)
    assert Image.has_alpha?(sequential_image) == Image.has_alpha?(random_image)
    assert_sampled_pixels_match(sequential_image, random_image)
  end

  defp run_orientation_flush(%PendingOrientation{} = pending, access, body)
       when access in [:random, :sequential] do
    with {:ok, image} <- Image.open([body], access: access, fail_on: :error),
         state = %State{image: image, pending_orientation: pending},
         {:ok, %State{} = state} <- Chain.execute(state, []),
         {:ok, %State{} = state} <- Materializer.materialize(state) do
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
