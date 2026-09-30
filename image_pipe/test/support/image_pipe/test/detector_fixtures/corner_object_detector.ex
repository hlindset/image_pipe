defmodule ImagePipe.Test.DetectorFixtures.CornerObjectDetector do
  @moduledoc false
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def supported_classes(_), do: ["car", "dog", "face", "person"]

  @impl true
  def available?(opts), do: Keyword.get(opts, :available?, true)

  @impl true
  def identity(_), do: {__MODULE__, :v1}

  @impl true
  def detect(_image, opts) do
    classes = Keyword.get(opts, :classes, :all)
    label = if classes == :all, do: "car", else: List.first(List.wrap(classes))
    {:ok, [%{label: label, score: 0.95, box: {2, 2, 20, 20}}]}
  end
end
