defmodule ImagePipe.Test.DetectorFixtures.SmallFaceDetector do
  @moduledoc false
  # Finds one small face near the right edge, but only in a frame whose long
  # edge is at least 640 pixels, as a real model misses faces that a small
  # frame has shrunk to a few pixels. Reports each frame it gets to the test.
  @behaviour ImagePipe.Transform.Detector

  alias Vix.Vips.Image, as: VipsImage

  @impl true
  def supported_classes(_opts), do: ["face"]

  @impl true
  def available?(_opts), do: true

  @impl true
  def identity(_opts), do: {__MODULE__, :v1}

  @impl true
  def detect(image, _opts) do
    {width, height} = {Image.width(image), Image.height(image)}

    orientation =
      case VipsImage.header_value(image, "orientation") do
        {:ok, value} -> value
        {:error, _reason} -> nil
      end

    send(test_pid(), {:detect_frame, width, height, orientation})

    case max(width, height) >= 640 do
      true -> {:ok, [%{label: "face", score: 0.9, box: face_box(width, height)}]}
      false -> {:ok, []}
    end
  end

  defp face_box(width, height), do: {0.85 * width, 0.45 * height, 0.04 * width, 0.06 * height}

  defp test_pid do
    case Process.get(:"$callers") do
      [pid | _] -> pid
      _ -> self()
    end
  end
end
