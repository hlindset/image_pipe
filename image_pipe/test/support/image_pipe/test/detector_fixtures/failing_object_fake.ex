defmodule ImagePipe.Test.DetectorFixtures.FailingObjectFake do
  @moduledoc false
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def supported_classes(_opts), do: ["car"]

  @impl true
  def available?(_opts), do: true

  @impl true
  def identity(_opts), do: {__MODULE__, :v1}

  @impl true
  def detect(_image, _opts), do: {:error, {:detector, :model_crashed}}
end
