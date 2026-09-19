defmodule ImagePipe.Test.DetectorFixtures.WeightedSceneDetector do
  @moduledoc false
  @behaviour ImagePipe.Transform.Detector

  @boxes [
    %{label: "person", score: 0.95, box: {2000, 800, 800, 1000}},
    %{label: "face", score: 0.95, box: {1400, 600, 400, 400}}
  ]

  @impl true
  def supported_classes(_), do: ["face", "person"]

  @impl true
  def available?(opts), do: Keyword.get(opts, :available?, true)

  @impl true
  def identity(_), do: {__MODULE__, :v1}

  @impl true
  def detect(_image, opts) do
    case Keyword.get(opts, :classes, :all) do
      :all -> {:ok, @boxes}
      classes -> {:ok, Enum.filter(@boxes, &(&1.label in List.wrap(classes)))}
    end
  end
end
