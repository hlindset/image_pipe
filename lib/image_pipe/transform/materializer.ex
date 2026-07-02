defmodule ImagePipe.Transform.Materializer do
  @moduledoc """
  Materialization boundary for transform execution.

  `materialize/1` copies the current image to a RAM-resident buffer
  (`copy_memory`) and marks the state `materialized?: true`. It is
  orientation-agnostic: applying a pending orientation is the explicit
  `ImagePipe.Transform.Operation.Flush` operation's job (via `flush/1`), emitted
  by the resolver at every site that needs the display frame — so no operation
  reaches a materialize with a non-identity pending that a `Flush` hasn't
  already cleared. Trim deliberately materializes pre-orientation (the storage
  frame), which is exactly this plain copy.

  Per-op materialization (`ImagePipe.Transform.Chain`) calls this before the
  first operation that requires random access, so a sequential decode can stream
  through earlier ops and only copy when an op genuinely needs arbitrary pixel
  access. `Request.Processor.materialize_for_delivery/2` also calls the arity-2
  callback form once before delivery for any chain that never materialized
  mid-pipeline.

  `materialize/1` and `flush/1` emit a `[:transform, :materialize]` telemetry
  span, giving honest per-barrier timing regardless of which call site triggered
  the materialization.
  """

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.{OrientationFlush, State}
  alias Vix.Vips.Image, as: VipsImage

  @callback materialize(State.t(), keyword()) ::
              {:ok, State.t()} | {:error, term()}

  # Arity-1 (chain mid-pipeline) and arity-2 (delivery backstop) both route through
  # here, so a single [:transform, :materialize] span covers both entry points.
  @spec materialize(State.t()) :: {:ok, State.t()} | {:error, term()}
  def materialize(%State{telemetry_opts: telemetry_opts} = state) do
    Telemetry.span(telemetry_opts, [:transform, :materialize], %{}, fn ->
      case copy_to_memory(state) do
        {:ok, new_state} -> {{:ok, new_state}, ok_metadata(new_state)}
        {:error, reason} -> {{:error, reason}, %{result: :materialize_error}}
      end
    end)
  end

  # Successful stops also carry the realized post-materialize image dimensions
  # (an O(1) header read) — non-sensitive, and they surface the display-frame
  # swap when the materialization flushed a pending quarter turn.
  defp ok_metadata(%State{image: image}),
    do: %{result: :ok, dims: {Image.width(image), Image.height(image)}}

  # Delivery backstop delegates to the wrapped arity-1; it ignores opts (telemetry
  # metadata rides on the State). Do not add a second span here.
  @spec materialize(State.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def materialize(%State{} = state, _opts) do
    materialize(state)
  end

  # copy_to_memory returns a BARE {:ok, state} | {:error, reason}. The
  # {:materialize_error, reason} TUPLE wrapping is owned by callers (Chain); the
  # :materialize_error SPAN metadata label is set in the wrapper above only to
  # drive Logger level escalation. Never re-wrap the error tuple here.
  defp copy_to_memory(%State{image: image} = state) do
    case VipsImage.copy_memory(image) do
      {:ok, image} -> {:ok, %State{state | image: image, materialized?: true}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Flushes pending orientation as an explicit operation.

  Wraps `OrientationFlush.flush/1` in a `[:transform, :materialize]` telemetry
  span and tags failures as `{:materialize_error, reason}` to preserve decode-error
  → 415 response mapping. The operation is self-managing: it performs its own
  random-access preparation and pixel copy, so callers should mark it
  `requires_materialization?: false`.

  Returns `{:ok, State.t()}` on success or `{:error, {:materialize_error, term()}}`
  on failure.
  """
  @spec flush(State.t()) :: {:ok, State.t()} | {:error, {:materialize_error, term()}}
  def flush(%State{telemetry_opts: telemetry_opts} = state) do
    Telemetry.span(telemetry_opts, [:transform, :materialize], %{}, fn ->
      case OrientationFlush.flush(state) do
        {:ok, new_state} ->
          {{:ok, new_state}, ok_metadata(new_state)}

        {:error, reason} ->
          {{:error, {:materialize_error, reason}}, %{result: :materialize_error}}
      end
    end)
  end
end
