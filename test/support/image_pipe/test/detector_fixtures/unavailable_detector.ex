defmodule ImagePipe.Test.DetectorFixtures.UnavailableDetector do
  @moduledoc false
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def supported_classes(_opts), do: ["face"]

  @impl true
  def detect(_image, _opts), do: {:error, {:detector, :unavailable}}

  @impl true
  def available?(_opts), do: false

  @impl true
  def identity(_opts), do: {__MODULE__, :unavailable}
end
