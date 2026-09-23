defmodule ImagePipe.Transform.Materializer do
  @moduledoc """
  Materialization boundary for transform execution.

  `materialize/1` copies the image to RAM (`copy_memory`) and sets
  `materialized?: true`. It leaves pending orientation untouched. The executor
  emits `ImagePipe.Transform.Operation.Flush` (via `flush/1`) before operations
  that need the display frame, including trim.

  `ImagePipe.Transform.run/3` materializes before the first operation requiring
  random access, allowing earlier operations to stream. Delivery calls the
  arity-2 callback before encoding if the state has not materialized.

  Both `materialize/1` and `flush/1` emit `[:transform, :materialize]` spans
  that measure the pixel work at each boundary.
  """

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.{OrientationFlush, State}
  alias Vix.Vips.Image, as: VipsImage

  @callback materialize(State.t(), keyword()) ::
              {:ok, State.t()} | {:error, term()}

  # Operation and delivery calls share one telemetry span.
  @spec materialize(State.t()) :: {:ok, State.t()} | {:error, term()}
  def materialize(%State{telemetry_opts: telemetry_opts} = state) do
    Telemetry.span(telemetry_opts, [:transform, :materialize], %{}, fn ->
      case copy_to_memory(state) do
        {:ok, new_state} -> {{:ok, new_state}, ok_metadata(new_state)}
        {:error, reason} -> {{:error, reason}, %{result: :materialize_error}}
      end
    end)
  end

  # Dimensions are a non-sensitive O(1) header read of the allocated buffer.
  defp ok_metadata(%State{image: image}),
    do: %{result: :ok, dims: {Image.width(image), Image.height(image)}}

  # Delivery uses telemetry options from State; delegation avoids a second span.
  @spec materialize(State.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def materialize(%State{} = state, _opts) do
    materialize(state)
  end

  @doc "Applies pending orientation and buffers its display frame, with materialization telemetry."
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

  # Callers wrap errors as {:materialize_error, reason}. The span's matching
  # result label controls Logger severity without changing the return value.
  defp copy_to_memory(%State{image: image} = state) do
    case VipsImage.copy_memory(image) do
      {:ok, image} -> {:ok, %State{state | image: image, materialized?: true}}
      {:error, _} = error -> error
    end
  end
end
