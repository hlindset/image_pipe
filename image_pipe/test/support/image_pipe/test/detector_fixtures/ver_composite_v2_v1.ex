defmodule ImagePipe.Test.DetectorFixtures.VerCompositeV2V1 do
  @moduledoc false
  @behaviour ImagePipe.Transform.Detector

  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.DetectorFixtures.FaceVerFakeV2
  alias ImagePipe.Test.DetectorFixtures.ObjectVerFakeV1
  alias ImagePipe.Transform.Detector.Composite

  defp c, do: Composite.new([FaceVerFakeV2, ObjectVerFakeV1])

  @impl true
  def supported_classes(_o), do: Composite.supported_classes(c())
  @impl true
  def detect(i, o), do: Composite.detect(c(), i, o)
  @impl true
  def available?(o), do: Composite.available?(c(), o)
  @impl true
  def identity(o), do: Composite.identity(c(), o)
end
