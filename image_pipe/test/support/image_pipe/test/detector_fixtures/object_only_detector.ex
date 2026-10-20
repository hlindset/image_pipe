defmodule ImagePipe.Test.DetectorFixtures.ObjectOnlyDetector do
  @moduledoc false
  # Detects objects but has no face model.
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def supported_classes(_opts), do: ["car"]

  @impl true
  def available?(opts), do: "face" not in List.wrap(Keyword.get(opts, :classes, []))

  @impl true
  def identity(_opts), do: {__MODULE__, :v1}

  @impl true
  def detect(_image, _opts), do: {:ok, []}
end
