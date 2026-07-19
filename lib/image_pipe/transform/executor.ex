defmodule ImagePipe.Transform.Executor do
  @moduledoc false

  # Orchestrates plan execution: seeds the data-determined preamble (EXIF
  # orientation into State.pending_orientation and input color management, both
  # on the seed_orientation gate), then drives each pipeline through the fixed
  # neutral resolve loop below (`run_neutral/4`). Neutral lowering owns the
  # pending-orientation policy and compensation and emits explicit Flush ops.
  # Resize expansion/scale arithmetic lives in ImagePipe.Transform.ResizePlanning.
  #
  # The resolve loop: for each plan operation, overlay the neutral-advanced shape
  # onto State (THE one shape→State sync site), lower the op through
  # NeutralResolver, execute the emitted executable ops through the chain, then
  # advance the shape — purely for an `:advance` continuation, or, for a
  # `{:measure, tag, state}` continuation, from the measured post-execution dims
  # via NeutralResolver.continue/4 (injectable via `opts[:measure_dims]` so tests
  # can drive the geometry without pixels). A single resolve may execute in
  # several STAGES (spec §4.4 Stage 3): `continue/4` can return a further
  # `{ops, continuation}` stage — a multi-executable expansion (e.g. a cover =
  # [resize] then [crop]) split at the realized-dims seam — which the driver
  # executes and continues, recursing until a final `{shape, nil}`. The overlay
  # still runs once per *plan op*, before the first stage — the shape only
  # advances at the continuation's end, so mid-emission executables all read the
  # same overlaid frame. At the pipeline boundary any surviving non-identity
  # pending orientation is flushed through an explicit %Operation.Flush{}; an
  # identity pending is cleared on State without materializing (streaming fast
  # path preserved).
  #
  # The overlay routes every State.effective_source_dims / decode_shrink /
  # pending_orientation read at EXECUTE time — Resize.execute, OrientationFlush.
  # flush — through the neutral-advanced shape; the resolve-time reads (Lowering,
  # ResizePlanning) take the shape directly.

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.InputColorManagement
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @spec execute(Plan.t(), State.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def execute(%Plan{pipelines: pipelines} = plan, %State{} = state, opts) do
    with {:ok, state} <- seed_execution_state(plan, state, opts) do
      execute_pipelines(pipelines, state, opts)
    end
  end

  defp seed_execution_state(%Plan{auto_rotate: auto_rotate}, state, opts) do
    %State{} =
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

    seed_color_management(state, opts)
  end

  # Input color management is a data-determined preamble seeded once on the real-
  # execution path (the same gate as EXIF orientation), not a Plan operation. It
  # imports the embedded profile into a working space before any operation. The
  # `[:transform, :input_color_management]` span is emitted by
  # `InputColorManagement.condition/2` itself (via `state.telemetry_opts`), the
  # shared seam every stack runs; this gate only decides whether the preamble
  # runs at all (planning skips it). A failure is a decode failure
  # (corrupt/unsupported profile), surfaced as {:decode, _} to stay consistent
  # with the materialization contract.
  defp seed_color_management(%State{} = state, opts) do
    if Keyword.get(opts, :seed_orientation, false) do
      hdr? = Keyword.get(opts, :supports_hdr?, false)

      case InputColorManagement.condition(state, supports_hdr?: hdr?) do
        {:ok, %State{} = new_state} -> {:ok, new_state}
        {:error, {InputColorManagement, reason}} -> {:error, {:decode, reason}}
      end
    else
      {:ok, state}
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

  # Each pipeline runs through the resolve loop: the source shape seeds from
  # the state's effective source frame, neutral lowering decides ops and shape
  # advances per operation, and the loop's boundary rule resolves any still-
  # pending orientation (EXIF is seeded once for the whole plan and a pipeline's
  # output is the next pipeline's input, so each pipeline must end in the display
  # frame; an identity pending is cleared without materializing — the streaming
  # fast path).
  defp execute_pipeline(%Pipeline{operations: operations}, %State{} = state, opts) do
    {w, h} = State.effective_source_dims(state)

    shape =
      SourceShape.seed(%{
        width: w,
        height: h,
        pending_orientation: state.pending_orientation,
        decode_shrink: state.decode_shrink
      })

    run_neutral(operations, shape, state, opts)
  end

  @doc false
  # Fixed neutral execution driver: lowers each plan op through NeutralResolver
  # directly and keeps neutral staged measurement/continuation. Public only as an
  # internal test seam for resolved_plan_golden_test.exs.
  def run_neutral(pipeline, %SourceShape{} = shape, %State{} = state, opts \\ []) do
    measure_dims = Keyword.get(opts, :measure_dims, &default_measure_dims/1)
    chain = Keyword.get(opts, :chain, &Chain.execute/3)

    pipeline
    |> Enum.reduce_while({:ok, shape, state}, fn operation, acc ->
      {:ok, shape, state} = acc
      state = overlay(state, shape)

      {ops, continuation} = NeutralResolver.resolve(shape, nil, operation)

      case execute_stages(ops, continuation, shape, state, chain, measure_dims, opts) do
        {:ok, shape, state} -> {:cont, {:ok, shape, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, shape, state} -> flush_boundary(state, shape, chain, opts)
      {:error, _reason} = error -> error
    end
  end

  # THE sync rule, one site: the shape is authoritative for the source frame.
  # Exists solely to feed the executables' execute-time State reads (resolve-time
  # reads take the shape directly).
  defp overlay(%State{} = state, %SourceShape{} = shape) do
    %State{
      state
      | pending_orientation: shape.pending_orientation,
        decode_shrink: shape.decode_shrink,
        source_dimensions: {shape.width, shape.height}
    }
  end

  # One resolve may execute in several stages: run this stage's ops, then either
  # finish (final {shape, nil}) or measure the realized dims and run the next
  # stage NeutralResolver.continue/4 returns. `resolve_shape` is the pre-op shape
  # neutral lowering resolved against — the continue/4 contract. Recursion depth
  # is the emission's stage count (2 for a cover) — never unbounded.
  defp execute_stages(ops, continuation, resolve_shape, state, chain, measure_dims, opts) do
    case chain.(state, ops, opts) do
      {:ok, %State{} = state} ->
        continue(continuation, resolve_shape, state, chain, measure_dims, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp continue(
         {:advance, %SourceShape{} = shape, _neutral_state},
         _resolve_shape,
         state,
         _chain,
         _measure_dims,
         _opts
       ),
       do: {:ok, shape, state}

  defp continue(
         {:measure, tag, neutral_state},
         resolve_shape,
         state,
         chain,
         measure_dims,
         opts
       ) do
    case NeutralResolver.continue(tag, measure_dims.(state.image), resolve_shape, neutral_state) do
      {%SourceShape{} = shape, _neutral_state} ->
        {:ok, shape, state}

      {ops, continuation} when is_list(ops) ->
        execute_stages(ops, continuation, resolve_shape, state, chain, measure_dims, opts)
    end
  end

  defp default_measure_dims(image), do: {Image.width(image), Image.height(image)}

  # Pipeline boundary: a pipeline's output is the next pipeline's input, so each
  # pipeline must end in the display frame. A surviving non-identity pending is
  # flushed through the explicit op; an identity pending is cleared on State
  # without materializing. The source-frame fields sync from the final shape:
  # when shrink-on-load survived unconsumed the stored original extent still
  # answers effective_source_dims, otherwise the live image speaks for itself —
  # including after the boundary flush swaps the displayed axes.
  defp flush_boundary(%State{} = state, %SourceShape{} = shape, chain, opts) do
    state = %State{
      state
      | pending_orientation: shape.pending_orientation,
        decode_shrink: shape.decode_shrink,
        source_dimensions: boundary_source_dimensions(shape)
    }

    case shape.pending_orientation do
      nil ->
        {:ok, state}

      %PendingOrientation{} = po ->
        if PendingOrientation.identity?(po) do
          {:ok, %State{state | pending_orientation: nil}}
        else
          chain.(state, [%Flush{}], opts)
        end
    end
  end

  defp boundary_source_dimensions(%SourceShape{decode_shrink: nil}), do: nil
  defp boundary_source_dimensions(%SourceShape{width: w, height: h}), do: {w, h}
end
