defmodule ImagePipe.Transform.ResolveDriver do
  @moduledoc false

  # Per-pipeline execution loop: for each plan operation, overlay the
  # resolver-advanced shape onto State (THE one shape→State sync site), recompute
  # the execution context, resolve the op through the strategy, execute the
  # emitted executable ops through the chain, then advance the shape — purely for
  # an `:advance` continuation, or from the post-execution image dims for an
  # `:acquire` (injectable via `opts[:acquire_dims]` so tests can drive the
  # geometry without pixels). At the pipeline boundary any surviving non-identity
  # pending orientation is flushed through an explicit %Operation.Flush{}; an
  # identity pending is cleared on State without materializing (streaming fast
  # path preserved).
  #
  # The overlay routes every State.effective_source_dims / decode_shrink /
  # pending_orientation read — Lowering, ResizePlanning, Resize.execute at pixel
  # time, OrientationFlush.flush — through the resolver-advanced shape. It is
  # value-equal to the previous scattered State mutations whenever the shape
  # advance is correct.

  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Resolver
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.ResizePlanning
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State

  @initial_ctx %{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}

  @spec run([struct()], SourceShape.t(), Resolver.spec(), State.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def run(pipeline, %SourceShape{} = shape, spec, %State{} = state, opts \\ []) do
    acquire_dims = Keyword.get(opts, :acquire_dims, &default_acquire_dims/1)
    chain = Keyword.get(opts, :chain, &Chain.execute/3)

    pipeline
    |> Enum.reduce_while({:ok, shape, spec, state, @initial_ctx}, fn operation, acc ->
      {:ok, shape, spec, state, ctx} = acc
      state = overlay(state, shape)
      ctx = update_execution_context(operation, state, ctx)

      {ops, continuation, spec} =
        Resolver.resolve(spec, shape, %{state: state, ctx: ctx}, operation)

      case chain.(state, ops, opts) do
        {:ok, %State{} = state} ->
          {shape, spec} = advance(continuation, spec, state, acquire_dims)
          {:cont, {:ok, shape, spec, state, ctx}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, shape, _spec, state, _ctx} -> flush_boundary(state, shape, chain, opts)
      {:error, _reason} = error -> error
    end
  end

  # THE sync rule, one site: the shape is authoritative for the source frame.
  defp overlay(%State{} = state, %SourceShape{} = shape) do
    %State{
      state
      | pending_orientation: shape.pending_orientation,
        decode_shrink: shape.decode_shrink,
        source_dimensions: {shape.width, shape.height}
    }
  end

  defp advance({:advance, %SourceShape{} = shape, _strategy_state}, spec, _state, _acquire_dims),
    do: {shape, spec}

  defp advance({:acquire, then_fn}, {module, _strategy_state}, %State{} = state, acquire_dims) do
    {%SourceShape{} = shape, strategy_state} = then_fn.(acquire_dims.(state.image))
    {shape, {module, strategy_state}}
  end

  defp default_acquire_dims(image), do: {Image.width(image), Image.height(image)}

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

  # The two padding scales are computed at the resize from the pre-op overlaid
  # state and carried on the context for later padding/canvas lowering.
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
