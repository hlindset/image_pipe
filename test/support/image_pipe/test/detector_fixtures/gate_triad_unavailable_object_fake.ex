defmodule ImagePipe.Test.DetectorFixtures.GateTriadUnavailableObjectFake do
  @moduledoc false
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def supported_classes(_), do: ["car"]

  @impl true
  def available?(_), do: false

  @impl true
  def identity(_), do: {__MODULE__, :unavailable}

  @impl true
  def detect(_image, _opts), do: {:error, {:detector, :unavailable}}
end
