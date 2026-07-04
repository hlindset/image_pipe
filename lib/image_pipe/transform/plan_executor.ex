defmodule ImagePipe.Transform.PlanExecutor do
  @moduledoc false

  # Orchestrates plan execution: seeds the data-determined preamble (EXIF
  # orientation into State.pending_orientation and input color management, both on
  # the seed_orientation gate), then drives each pipeline through
  # ImagePipe.Transform.ResolveDriver with the Plan-carried resolution strategy
  # (plan.resolver, defaulting to ImagePipe.Transform.NeutralResolver when nil),
  # which owns the pending-orientation policy and compensation and emits explicit
  # Flush ops. Resize expansion/scale arithmetic lives in
  # ImagePipe.Transform.ResizePlanning.

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.InputColorManagement
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.ResolveDriver
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @spec execute(Plan.t(), State.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def execute(
        %Plan{pipelines: pipelines, auto_rotate: auto_rotate, resolver: resolver},
        %State{} = state,
        opts
      ) do
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
      execute_pipelines(pipelines, resolver || NeutralResolver, state, opts)
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

  defp execute_pipelines(pipelines, resolver, %State{} = state, opts) do
    Enum.reduce_while(pipelines, {:ok, state}, fn pipeline, {:ok, state} ->
      case execute_pipeline(pipeline, resolver, state, opts) do
        {:ok, %State{} = state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Each pipeline runs through the resolve driver: the source shape seeds from
  # the state's effective source frame, the Plan-carried strategy decides ops
  # and shape advances per operation (a fresh init/0 per pipeline, spec §4.4),
  # and the driver's boundary rule resolves any still-pending orientation (EXIF
  # is seeded once for the whole plan and a pipeline's output is the next
  # pipeline's input, so each pipeline must end in the display frame; an
  # identity pending is cleared without materializing — the streaming fast
  # path).
  defp execute_pipeline(%Pipeline{operations: operations}, resolver, %State{} = state, opts) do
    {w, h} = State.effective_source_dims(state)

    shape =
      SourceShape.seed(%{
        width: w,
        height: h,
        pending_orientation: state.pending_orientation,
        decode_shrink: state.decode_shrink
      })

    ResolveDriver.run(operations, shape, {resolver, resolver.init()}, state, opts)
  end
end
