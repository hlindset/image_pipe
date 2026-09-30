defmodule ImagePipe.Test.DetectorFixtures.PartialDetector do
  @moduledoc false
  @behaviour ImagePipe.Transform.Detector

  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.DetectorFixtures.GateTriadFaceFake
  alias ImagePipe.Test.DetectorFixtures.GateTriadUnavailableObjectFake
  alias ImagePipe.Transform.Detector.Composite

  defp c, do: Composite.new([GateTriadFaceFake, GateTriadUnavailableObjectFake])

  @impl true
  def supported_classes(_o), do: Composite.supported_classes(c())

  @impl true
  def detect(i, o), do: Composite.detect(c(), i, o)

  @impl true
  def available?(o), do: Composite.available?(c(), o)

  @impl true
  def identity(o), do: Composite.identity(c(), o)
end
