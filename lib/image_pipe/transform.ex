defmodule ImagePipe.Transform do
  @moduledoc """
  Behaviour and dispatch facade for transform operations.

  Operation modules implement this behaviour with a stable transform name and
  execution over `ImagePipe.Transform.State`. Runtime callers dispatch through
  this module's generic functions so the runtime boundary does not need to know
  concrete operation modules.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Plan, ImagePipe.Telemetry],
    exports: [
      # Runtime execution contract — consumed by the request layer.
      State,
      Chain,
      DecodePlanner,
      DecodePlanner.Request,
      Materializer,
      Detector,
      Detector.Warmup,
      # Decode-time geometry value produced by `ImagePipe.Decode.with_image/4`'s
      # header open and consumed by a dialect's decode preflight.
      SourceGeometry,
      # Dialect-pipeline contract — the structs and neutral lowering helpers the
      # in-tree dialect Pipelines consume directly: the shape value, the neutral
      # resolver, point/orientation geometry, and the executable operations a
      # Pipeline emits (including their pure geometry helpers, e.g.
      # `Crop.resolved_rect/3`).
      SourceShape,
      NeutralResolver,
      Focus,
      PendingOrientation,
      Operation.Resize,
      Operation.Rotate,
      Operation.ExtendCanvas,
      Operation.Padding,
      Operation.Background,
      Operation.Bitonal,
      Operation.Crop,
      Operation.Blur,
      Operation.Sharpen,
      Operation.Pixelate,
      Operation.Monochrome,
      Operation.Duotone,
      Operation.Gray,
      Operation.Brightness,
      Operation.Contrast,
      Operation.Saturation,
      Operation.Colorize,
      Operation.Gradient,
      Operation.Trim,
      Operation.Flush,
      # Internal lowering seams — exported only for the in-tree dialect
      # Pipelines; subject to change without notice.
      Lowering,
      ResizePlanning,
      # Input color-management preamble — dialect-callable (spec G4); the
      # framework's Executor seeds it internally.
      InputColorManagement
    ]

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.State

  @type attrs() :: keyword()
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

  @spec validate_prefetch_safe_plan(Plan.t()) ::
          {:ok, [Pipeline.t()]} | {:error, term()}
  def validate_prefetch_safe_plan(%Plan{} = plan) do
    case Plan.validate_shape(plan) do
      {:ok, %Plan{render: render, pipelines: pipelines}}
      when render != :image and is_list(pipelines) ->
        # A non-image render plan legitimately carries an empty pipeline (it has no
        # transform stage); allow it. Shape validation already ran above. The check
        # is plan-shape only, so Transform stays ignorant of renderer internals. The
        # plan is parser-produced (a host-implementable boundary), so the pipeline
        # shape is validated here rather than trusted.
        {:ok, pipelines}

      {:ok, %Plan{render: render, pipelines: pipelines}} when render != :image ->
        {:error, {:invalid_pipeline_plan, pipelines}}

      {:ok, %Plan{}} ->
        Plan.validated_pipelines(plan)

      {:error, _reason} = error ->
        error
    end
  end

  @spec execute(operation(), State.t()) :: {:ok, State.t()} | {:error, term()}
  def execute(%module{} = operation, %State{} = state) do
    module.execute(operation, state)
  end

  @spec execute_plan(Plan.t(), State.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def execute_plan(%Plan{} = plan, %State{} = state, opts \\ []) do
    Executor.execute(plan, state, opts)
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
