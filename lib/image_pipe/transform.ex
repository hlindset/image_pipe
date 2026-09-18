defmodule ImagePipe.Transform do
  @moduledoc """
  Behaviour and dispatch facade for transform operations.

  Operations provide a stable name and execute over `ImagePipe.Transform.State`.
  Runtime callers use this facade without depending on concrete operation modules.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Plan, ImagePipe.Telemetry],
    exports: [
      # Runtime execution contract.
      Executor,
      State,
      DecodePlanner,
      DecodePlanner.Request,
      Materializer,
      Detector,
      Detector.Warmup,
      # Header geometry used by decode preflight.
      SourceGeometry,
      PendingOrientation
    ]

  alias ImagePipe.Transform.State

  @type operation() :: struct()

  @callback name(operation()) :: atom()
  @callback execute(operation(), State.t()) :: {:ok, State.t()} | {:error, term()}
  @callback requires_materialization?(operation()) :: boolean()

  defmacro __using__(_opts) do
    quote do
      @behaviour ImagePipe.Transform

      @impl ImagePipe.Transform
      def requires_materialization?(_operation), do: false

      defoverridable requires_materialization?: 1
    end
  end

  @spec transform_name(operation()) :: atom()
  def transform_name(%module{} = operation) do
    module.name(operation)
  end

  @spec requires_materialization?(operation()) :: boolean()
  def requires_materialization?(%module{} = operation) do
    module.requires_materialization?(operation)
  end

  @spec execute(operation(), State.t()) :: {:ok, State.t()} | {:error, term()}
  def execute(%module{} = operation, %State{} = state) do
    module.execute(operation, state)
  end

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

  @spec detector_identity(:default | nil | module(), keyword()) :: {module(), term()} | nil
  def detector_identity(detector, opts) do
    case resolve_detector(detector) do
      nil -> nil
      module -> module.identity(opts)
    end
  end
end
