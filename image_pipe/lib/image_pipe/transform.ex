defmodule ImagePipe.Transform do
  # The transform boundary, and detector resolution for the request.
  #
  # Operations are typed parameter structs with an `execute/2` over
  # `ImagePipe.Transform.State`. The executor owns their order, stage names and
  # materialization (`ImagePipe.Transform.Executor.Step`).
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Plan, ImagePipe.Telemetry],
    exports: [
      # Runtime execution contract.
      Executor,
      State,
      DecodePlanner,
      Materializer,
      Detector,
      Detector.Warmup,
      # Header geometry used by decode preflight.
      SourceGeometry,
      PendingOrientation
    ]

  alias ImagePipe.Transform.Detector

  @default_detector ImagePipe.Transform.Detector.Composite

  @spec resolve_detector(:default | nil | module()) :: module() | nil
  def resolve_detector(:default), do: @default_detector
  def resolve_detector(nil), do: nil
  def resolve_detector(module) when is_atom(module), do: module

  @spec detector_available?(:default | nil | module(), keyword()) :: boolean()
  def detector_available?(detector, opts) do
    case resolve_detector(detector) do
      nil -> false
      module -> module.available?(opts)
    end
  end

  @spec detector_ready?(:default | nil | module(), keyword()) :: boolean()
  def detector_ready?(detector, opts) do
    case resolve_detector(detector) do
      nil -> false
      module -> Detector.ready?(module, opts)
    end
  end

  @spec detector_identity(:default | nil | module(), keyword()) :: {module(), term()} | nil
  def detector_identity(detector, opts) do
    case resolve_detector(detector) do
      nil -> nil
      module -> module.identity(opts)
    end
  end
end
