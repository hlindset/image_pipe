defmodule ImagePipe.Test.DetectorFixtures.ColdFaceDetector do
  @moduledoc false
  # Available, but its model never finishes warming up.
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def supported_classes(_opts), do: ["face"]

  @impl true
  def detect(_image, _opts), do: {:ok, []}

  @impl true
  def available?(_opts), do: true

  @impl true
  def ready?(_opts), do: false

  @impl true
  def identity(_opts), do: {__MODULE__, :v1}
end
