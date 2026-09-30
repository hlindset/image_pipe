defmodule ImagePipe.Test.DetectorFixtures.FaceVerFakeV1 do
  @moduledoc false
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def supported_classes(_), do: ["face"]
  @impl true
  def available?(_), do: true
  @impl true
  def identity(_), do: {__MODULE__, :v1}
  @impl true
  def detect(_, _), do: {:ok, []}
end
