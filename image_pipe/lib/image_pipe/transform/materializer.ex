defmodule ImagePipe.Transform.Materializer do
  # Materialization boundary for transform execution.
  #
  # `materialize/1` copies the image to RAM (`copy_memory`) and sets
  # `materialized?: true`. It leaves pending orientation untouched. The executor
  # calls `flush/1` before operations
  # that need the display frame, including trim.
  #
  # `ImagePipe.Transform.run/3` materializes before the first operation requiring
  # random access, allowing earlier operations to stream. Delivery materializes
  # before encoding if the state has not materialized.
  #
  # Both `materialize/1` and `flush/1` emit `[:transform, :materialize]` spans
  # that measure the pixel work at each boundary.
  @moduledoc false

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.{MemoryCopy, OrientationFlush, State, WorkLimits}

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

  @doc "Applies pending orientation and buffers its display frame, with materialization telemetry."
  @spec flush(State.t()) :: {:ok, State.t()} | {:error, term()}
  def flush(%State{telemetry_opts: telemetry_opts} = state) do
    Telemetry.span(telemetry_opts, [:transform, :materialize], %{}, fn ->
      case guarded_flush(state) do
        {:ok, new_state} ->
          {{:ok, new_state}, ok_metadata(new_state)}

        {:error, reason} ->
          {{:error, reason}, %{result: :materialize_error}}
      end
    end)
  end

  defp guarded_flush(state) do
    with :ok <- WorkLimits.check(state), do: OrientationFlush.flush(state)
  end

  def error({:intermediate_pixel_limit, _pixels, _limit} = reason), do: {:transform, reason}
  def error(reason), do: {:decode, reason}

  # Callers wrap errors as {:materialize_error, reason}. The span's matching
  # result label controls Logger severity without changing the return value.
  defp copy_to_memory(%State{image: image} = state) do
    with :ok <- WorkLimits.check(state),
         {:ok, image} <- MemoryCopy.copy(image) do
      {:ok, %State{state | image: image, materialized?: true, buffer_before_resize?: false}}
    end
  end
end
