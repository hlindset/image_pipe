defmodule ImagePipe.Test.DetectorFixtures.VerCompositeV1V2 do
  @moduledoc false
  @behaviour ImagePipe.Transform.Detector

  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.DetectorFixtures.FaceVerFakeV1
  alias ImagePipe.Test.DetectorFixtures.ObjectVerFakeV2
  alias ImagePipe.Transform.Detector.Composite

  defp c, do: Composite.new([FaceVerFakeV1, ObjectVerFakeV2])

  @impl true
  def supported_classes(_o), do: Composite.supported_classes(c())
  @impl true
  def detect(i, o), do: Composite.detect(c(), i, o)
  @impl true
  def available?(o), do: Composite.available?(c(), o)
  @impl true
  def identity(o), do: Composite.identity(c(), o)
end
