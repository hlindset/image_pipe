defmodule ImagePipe.Output.Ssim2MetricTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Output.Ssim2Metric
  alias Vix.Vips.Operation

  setup do
    {:ok, img} =
      Image.open("test/support/image_pipe/test/sources/high_freq.jpg")

    {:ok, ref} = Image.thumbnail(img, "256")
    %{ref: ref}
  end

  test "identical image scores ~100", %{ref: ref} do
    {:ok, reference} = Ssim2Metric.reference(ref)
    {:ok, score} = Ssim2Metric.score(reference, ref)
    assert score > 95.0
  end

  test "a heavily degraded re-encode scores lower than a light one", %{ref: ref} do
    {:ok, reference} = Ssim2Metric.reference(ref)
    {:ok, low} = Image.write(ref, :memory, suffix: ".jpg", quality: 15)
    {:ok, high} = Image.write(ref, :memory, suffix: ".jpg", quality: 92)
    {:ok, low_img} = Image.from_binary(low)
    {:ok, high_img} = Image.from_binary(high)
    {:ok, low_score} = Ssim2Metric.score(reference, low_img)
    {:ok, high_score} = Ssim2Metric.score(reference, high_img)
    assert high_score > low_score
  end

  describe "images with an alpha channel" do
    test "an alpha change to a dark or a light shape lowers the score" do
      for colour <- [[0, 0, 0], [255, 255, 255]] do
        reference = shape_on_transparent(colour, 255)
        faded = shape_on_transparent(colour, 128)

        {:ok, ref} = Ssim2Metric.reference(reference)
        {:ok, same} = Ssim2Metric.score(ref, reference)
        {:ok, score} = Ssim2Metric.score(ref, faded)

        assert same > 95.0
        assert score < 70.0, "#{inspect(colour)} shape scored #{score}"
      end
    end

    test "transparent margins don't raise the score", %{ref: ref} do
      {:ok, low} = Image.write(ref, :memory, suffix: ".jpg", quality: 15)
      {:ok, low} = Image.from_binary(low)

      {:ok, patch_ref} = Ssim2Metric.reference(ref)
      {:ok, patch_score} = Ssim2Metric.score(patch_ref, low)

      {:ok, padded_ref} = Ssim2Metric.reference(pad_transparent(ref))
      {:ok, padded_score} = Ssim2Metric.score(padded_ref, pad_transparent(low))

      assert_in_delta padded_score, patch_score, 0.5
    end

    test "a fully transparent image scores as identical to itself" do
      image = shape_on_transparent([0, 0, 0], 0)
      {:ok, ref} = Ssim2Metric.reference(image)
      {:ok, score} = Ssim2Metric.score(ref, image)
      assert score > 95.0
    end

    test "a 16-bit image scores against an 8-bit decode of itself" do
      image = shape_on_transparent([200, 40, 40], 255)
      {:ok, wide} = Operation.cast(image, :VIPS_FORMAT_USHORT, shift: true)
      {:ok, wide} = Operation.copy(wide, interpretation: :VIPS_INTERPRETATION_RGB16)

      {:ok, ref} = Ssim2Metric.reference(wide)
      {:ok, score} = Ssim2Metric.score(ref, image)
      assert score > 95.0
    end
  end

  # A 64×64 square of `colour` at `alpha` in the middle of a 128×128
  # transparent canvas, so its edges and alpha matter but most of it is empty.
  defp shape_on_transparent(colour, alpha) do
    {:ok, square} = Image.new(64, 64, color: colour ++ [alpha])
    {:ok, canvas} = Image.new(128, 128, color: [0, 0, 0, 0])
    {:ok, image} = Image.compose(canvas, square, x: 32, y: 32, blend_mode: :source)
    image
  end

  defp pad_transparent(image) do
    {:ok, image} = Image.add_alpha(image, 255)

    {:ok, padded} =
      Operation.embed(
        image,
        128,
        128,
        Image.width(image) + 256,
        Image.height(image) + 256,
        extend: :VIPS_EXTEND_BACKGROUND,
        background: [0.0, 0.0, 0.0, 0.0]
      )

    padded
  end
end
