defmodule ImagePipe.Test.DetectorFixtures.PartialFailureDetector do
  @moduledoc false
  @behaviour ImagePipe.Transform.Detector

  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.DetectorFixtures.FailingObjectFake
  alias ImagePipe.Test.DetectorFixtures.GateTriadFaceFake
  alias ImagePipe.Transform.Detector.Composite

  defp c, do: [GateTriadFaceFake, FailingObjectFake]

  @impl true
  def supported_classes(_o), do: Composite.children_classes(c())

  @impl true
  def detect(i, o), do: Composite.detect(c(), i, o)

  @impl true
  def available?(o), do: Composite.available?(c(), o)

  @impl true
  def ready?(o), do: Composite.ready?(c(), o)

  @impl true
  def identity(o), do: Composite.identity(c(), o)
end
