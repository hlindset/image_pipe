defmodule ImagePipe.Output.Ssim2MetricTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Output.Metric.Ssimulacra2, as: Ssim2Metric

  setup do
    {:ok, img} =
      Image.open("test/support/image_pipe/test/imgproxy_differential/sources/high_freq.jpg")

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
end
