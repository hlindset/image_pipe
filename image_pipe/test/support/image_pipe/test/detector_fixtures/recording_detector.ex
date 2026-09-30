defmodule ImagePipe.Test.DetectorFixtures.RecordingDetector do
  @moduledoc false
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def supported_classes(_opts), do: ["face"]

  @impl true
  def available?(_opts), do: true

  @impl true
  def identity(_opts), do: {__MODULE__, :v1}

  @impl true
  def detect(image, opts) do
    target =
      case Process.get(:"$callers") do
        [pid | _] -> pid
        _ -> self()
      end

    send(target, {:detect_input, Image.width(image), Image.height(image), opts[:classes]})
    {:ok, []}
  end
end
