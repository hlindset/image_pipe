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

  @doc "The detector module a `:detector` option names. Configuration resolves it once."
  @spec resolve_detector(:default | nil | module()) :: module() | nil
  def resolve_detector(:default), do: @default_detector
  def resolve_detector(nil), do: nil
  def resolve_detector(module) when is_atom(module), do: module

  @spec detector_available?(module() | nil, keyword()) :: boolean()
  def detector_available?(nil, _opts), do: false
  def detector_available?(detector, opts), do: detector.available?(opts)

  @spec detector_ready?(module() | nil, keyword()) :: boolean()
  def detector_ready?(nil, _opts), do: false
  def detector_ready?(detector, opts), do: Detector.ready?(detector, opts)

  @spec detector_identity(module() | nil, keyword()) :: {module(), term()} | nil
  def detector_identity(nil, _opts), do: nil
  def detector_identity(detector, opts), do: detector.identity(opts)
end
