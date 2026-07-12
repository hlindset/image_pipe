defmodule ImagePipe.Transform.ResolveDriver do
  @moduledoc false

  # Per-pipeline execution loop: for each plan operation, overlay the
  # resolver-advanced shape onto State (THE one shape→State sync site), resolve
  # the op through the strategy, execute the emitted executable ops through the
  # chain, then advance the shape — purely for an `:advance` continuation, or
  # from the post-execution image dims for a `:measure` (injectable via
  # `opts[:measure_dims]` so tests can drive the geometry without pixels). A
  # single resolve may execute in several STAGES (spec §4.4 Stage 3): a
  # `:measure` continuation's `after_measure` fun can return a further `{ops, continuation}` stage — a
  # multi-executable expansion (e.g. a cover = [resize] then [crop]) split at
  # the realized-dims seam — which the driver executes and continues, recursing
  # until a final `{shape, strategy_state}`. The overlay still runs once per
  # *plan op*, before the first stage — the shape only advances at the
  # continuation's end, so mid-emission executables read the same overlaid frame
  # they do today. At the pipeline boundary any surviving non-identity pending
  # orientation is flushed through an explicit %Operation.Flush{}; an identity
  # pending is cleared on State without materializing (streaming fast path
  # preserved).
  #
  # The overlay routes every State.effective_source_dims / decode_shrink /
  # pending_orientation read at EXECUTE time — Resize.execute, OrientationFlush.
  # flush — through the resolver-advanced shape; the resolve-time reads (Lowering,
  # ResizePlanning) take the shape directly. It is value-equal to the previous
  # scattered State mutations whenever the shape advance is correct.
  #
  # The strategy's own per-pipeline state (e.g. the imgproxy resolver's stashed
  # padding scales) is threaded through `strategy`, carried forward via the
  # continuation the strategy returns — the driver never reads or computes
  # strategy-specific state itself.

  alias ImagePipe.Resolver
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State

  @spec run([struct()], SourceShape.t(), Resolver.strategy(), State.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def run(pipeline, %SourceShape{} = shape, strategy, %State{} = state, opts \\ []) do
    measure_dims = Keyword.get(opts, :measure_dims, &default_measure_dims/1)
    chain = Keyword.get(opts, :chain, &Chain.execute/3)

    pipeline
    |> Enum.reduce_while({:ok, shape, strategy, state}, fn operation, acc ->
      {:ok, shape, strategy, state} = acc
      state = overlay(state, shape)

      {ops, continuation} = Resolver.resolve(strategy, shape, operation)

      case execute_stages(ops, continuation, strategy, state, chain, measure_dims, opts) do
        {:ok, shape, strategy, state} -> {:cont, {:ok, shape, strategy, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, shape, _strategy, state} -> flush_boundary(state, shape, chain, opts)
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
  # finish (final {shape, strategy_state}) or measure the realized dims and run
  # the next stage the after_measure returns. Recursion depth is the emission's stage
  # count (2 for a cover) — never unbounded.
  defp execute_stages(ops, continuation, strategy, state, chain, measure_dims, opts) do
    case chain.(state, ops, opts) do
      {:ok, %State{} = state} ->
        continue(continuation, strategy, state, chain, measure_dims, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp continue(
         {:advance, %SourceShape{} = shape, strategy_state},
         {module, _},
         state,
         _chain,
         _measure_dims,
         _opts
       ),
       do: {:ok, shape, {module, strategy_state}, state}

  defp continue(
         {:measure, after_measure},
         {module, _} = strategy,
         state,
         chain,
         measure_dims,
         opts
       ) do
    case after_measure.(measure_dims.(state.image)) do
      {%SourceShape{} = shape, strategy_state} ->
        {:ok, shape, {module, strategy_state}, state}

      {ops, continuation} when is_list(ops) ->
        execute_stages(ops, continuation, strategy, state, chain, measure_dims, opts)
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
  #
  # This flush never touches a strategy's carried point: nothing consumes a
  # point after the pipeline boundary (TwicPics plans are single-pipeline), so
  # the omission is unobservable for every parser-reachable pipeline.
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
