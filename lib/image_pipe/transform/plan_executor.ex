defmodule ImagePipe.Transform.PlanExecutor do
  @moduledoc false

  # Orchestrates plan execution: seeds the data-determined preamble (EXIF
  # orientation into State.pending_orientation and input color management, both on
  # the seed_orientation gate), reduces over pipelines/operations threading State +
  # execution context, and dispatches each operation. Plain operations lower via
  # ImagePipe.Transform.Lowering and run through the Chain; deferred-orientation
  # operations (#146) delegate to ImagePipe.Transform.OrientationScheduler, which
  # owns the pending-orientation policy and compensation and the pipeline-boundary
  # flush. Resize expansion/scale arithmetic lives in ImagePipe.Transform.ResizePlanning.

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Flip, as: PlanFlip
  alias ImagePipe.Plan.Operation.Gradient, as: PlanGradient
  alias ImagePipe.Plan.Operation.Padding, as: PlanPadding
  alias ImagePipe.Plan.Operation.Pixelate, as: PlanPixelate
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Plan.Operation.Rotate, as: PlanRotate
  alias ImagePipe.Plan.Operation.SetFocus
  alias ImagePipe.Plan.Operation.Trim, as: PlanTrim
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.InputColorManagement
  alias ImagePipe.Transform.Lowering
  alias ImagePipe.Transform.OrientationScheduler
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.ResizePlanning
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @spec execute(Plan.t(), State.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def execute(%Plan{pipelines: pipelines, auto_rotate: auto_rotate}, %State{} = state, opts) do
    state = %{
      state
      | detector: ImagePipe.Transform.resolve_detector(Keyword.get(opts, :detector, :default)),
        detector_required: Keyword.get(opts, :detector_required, false),
        telemetry_opts: Telemetry.telemetry_opts(opts)
    }

    state =
      if Keyword.get(opts, :seed_orientation, false) do
        %State{
          state
          | pending_orientation:
              PendingOrientation.from_exif(exif_orientation(state.image), auto_rotate)
        }
      else
        state
      end

    with {:ok, state} <- seed_color_management(state, opts) do
      execute_pipelines(pipelines, state, opts)
    end
  end

  # Input color management is a data-determined preamble seeded once on the real-
  # execution path (the same gate as EXIF orientation), not a Plan operation. It
  # imports the embedded profile into a working space before any operation. A
  # failure is a decode failure (corrupt/unsupported profile), surfaced as
  # {:decode, _} to stay consistent with the materialization contract.
  defp seed_color_management(%State{telemetry_opts: telemetry_opts} = state, opts) do
    if Keyword.get(opts, :seed_orientation, false) do
      Telemetry.span(telemetry_opts, [:transform, :input_color_management], %{}, fn ->
        run_color_management(state, opts)
      end)
    else
      {:ok, state}
    end
  end

  defp run_color_management(%State{image: image} = state, opts) do
    hdr? = Keyword.get(opts, :supports_hdr?, false)
    working_space = InputColorManagement.working_space(VipsImage.interpretation(image), hdr?)

    case InputColorManagement.condition(state, supports_hdr?: hdr?) do
      {:ok, %State{} = new_state} ->
        {{:ok, new_state},
         %{result: :ok, working_space: working_space, imported?: new_state.color_imported?}}

      {:error, {InputColorManagement, reason}} ->
        {{:error, {:decode, reason}},
         %{result: :processing_error, working_space: working_space, imported?: false}}
    end
  end

  defp exif_orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) -> value
      _ -> 1
    end
  end

  defp execute_pipelines(pipelines, %State{} = state, opts) do
    Enum.reduce_while(pipelines, {:ok, state}, fn pipeline, {:ok, state} ->
      case execute_pipeline(pipeline, state, opts) do
        {:ok, %State{} = state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp execute_pipeline(%Pipeline{operations: operations}, %State{} = state, opts) do
    initial_context = %{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}

    Enum.reduce_while(operations, {:ok, state, initial_context}, fn operation,
                                                                    {:ok, state, context} ->
      context = update_execution_context(operation, state, context)

      case execute_operation(operation, state, context, opts) do
        {:ok, %State{} = state} -> {:cont, {:ok, state, context}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    # Resolve any still-pending orientation at the pipeline boundary. EXIF is
    # seeded once for the whole plan (on the first pipeline) and a pipeline's
    # output is the next pipeline's input, so each pipeline must end in the
    # display frame — deferral is scoped to a single pipeline rather than spanning
    # the chain. This is a backstop: an earlier resize / materializing op / region
    # crop usually flushed already (making this a no-op), and an identity
    # orientation is cleared without materializing (streaming fast path). It does
    # real pixel work only when a rotation is still pending here (e.g. a pipeline
    # of rotate + streaming effects, with no resize to trigger an earlier flush).
    |> case do
      {:ok, state, _context} -> OrientationScheduler.flush_if_pending(state)
      {:error, _reason} = error -> error
    end
  end

  # Deferred-orientation operations delegate to OrientationScheduler, which owns the
  # pending-orientation policy and compensation. Rotate/flip/focus/crop always route
  # there; resize/padding/pixelate/gradient/trim route there only when an orientation
  # is pending — a nil-pending one falls through to the plain path below.
  defp execute_operation(%PlanRotate{} = op, %State{} = state, ctx, opts),
    do: OrientationScheduler.execute_operation(op, state, ctx, opts)

  defp execute_operation(%PlanFlip{} = op, %State{} = state, ctx, opts),
    do: OrientationScheduler.execute_operation(op, state, ctx, opts)

  defp execute_operation(%SetFocus{} = op, %State{} = state, ctx, opts),
    do: OrientationScheduler.execute_operation(op, state, ctx, opts)

  defp execute_operation(%CropRegion{} = op, %State{} = state, ctx, opts),
    do: OrientationScheduler.execute_operation(op, state, ctx, opts)

  defp execute_operation(%CropGuided{} = op, %State{} = state, ctx, opts),
    do: OrientationScheduler.execute_operation(op, state, ctx, opts)

  defp execute_operation(%PlanResize{} = op, %State{pending_orientation: po} = state, ctx, opts)
       when not is_nil(po),
       do: OrientationScheduler.execute_operation(op, state, ctx, opts)

  defp execute_operation(%PlanPadding{} = op, %State{pending_orientation: po} = state, ctx, opts)
       when not is_nil(po),
       do: OrientationScheduler.execute_operation(op, state, ctx, opts)

  defp execute_operation(%PlanPixelate{} = op, %State{pending_orientation: po} = state, ctx, opts)
       when not is_nil(po),
       do: OrientationScheduler.execute_operation(op, state, ctx, opts)

  defp execute_operation(%PlanGradient{} = op, %State{pending_orientation: po} = state, ctx, opts)
       when not is_nil(po),
       do: OrientationScheduler.execute_operation(op, state, ctx, opts)

  defp execute_operation(%PlanTrim{} = op, %State{pending_orientation: po} = state, ctx, opts)
       when not is_nil(po),
       do: OrientationScheduler.execute_operation(op, state, ctx, opts)

  # Plain operation, no pending-orientation handling.
  defp execute_operation(operation, %State{} = state, context, opts) do
    run_executable(operation, state, context, opts)
  end

  defp run_executable(operation, %State{} = state, context, opts) do
    operation
    |> Lowering.executable_operations(state, context)
    |> then(&Chain.execute(state, &1, opts))
  end

  defp update_execution_context(%PlanResize{} = operation, %State{} = state, context) do
    scale = ResizePlanning.resize_padding_scale(operation, state, :resize)

    canvas_preserving_scale =
      ResizePlanning.resize_padding_scale(operation, state, :canvas_preserving)

    %{
      context
      | effective_padding_scale: scale,
        canvas_preserving_padding_scale: canvas_preserving_scale
    }
  end

  defp update_execution_context(_operation, %State{}, context), do: context
end
