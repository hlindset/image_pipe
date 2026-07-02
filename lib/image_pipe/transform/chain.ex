defmodule ImagePipe.Transform.Chain do
  @moduledoc """
  Executes ordered transform operation chains.

  A chain is the ordered list of executable transform operation structs selected
  by transform execution. Execution proceeds left to right through
  `ImagePipe.Transform` and stops at the first operation error.

  Each operation is wrapped in a `[:transform, :operation]` telemetry span for
  tracing. The span duration mostly reflects pipeline *construction* time, not
  pixel work — libvips is lazy and defers/fuses compute to materialization/encode.
  The exception is a materializing operation: its `copy_memory` runs inside the
  operation span, so that span's duration includes a real pixel copy (a nested
  `[:transform, :materialize]` span isolates that cost). Either way, per-operation
  duration is for tracing execution structure, not timing; honest aggregate timing
  lives on the coarse `[:transform, :execute]` stage span.
  """

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State

  @typedoc """
  A struct whose module implements `ImagePipe.Transform`.
  """
  @type item() :: Transform.operation()

  @type t() :: [item()]

  @doc """
  Executes a transform chain.

  ## Examples

      iex> chain = [
      ...>   %ImagePipe.Transform.Operation.Resize{
      ...>     mode: :fit,
      ...>     width: {:pixels, 100},
      ...>     height: :auto
      ...>   }
      ...> ]
      ...> {:ok, empty_image} = Image.new(500, 500)
      ...> initial_state = %ImagePipe.Transform.State{image: empty_image}
      ...> {:ok, %ImagePipe.Transform.State{}} = ImagePipe.Transform.Chain.execute(initial_state, chain)
  """
  @spec execute(State.t(), t()) ::
          {:ok, State.t()}
          | {:error, {:transform_error, term()} | {:materialize_error, term()}}
  @spec execute(State.t(), t(), keyword()) ::
          {:ok, State.t()}
          | {:error, {:transform_error, term()} | {:materialize_error, term()}}
  def execute(state, transform_chain, opts \\ [])

  def execute(%State{} = state, transform_chain, opts) do
    telemetry_opts = Telemetry.telemetry_opts(opts)

    transform_chain
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state}, fn {operation, index}, {:ok, state} ->
      name = Transform.transform_name(operation)

      result =
        Telemetry.span(
          telemetry_opts,
          [:transform, :operation],
          %{operation: name, index: index, params: operation},
          fn ->
            res = run_operation(operation, state)
            {res, stop_metadata(res)}
          end
        )

      case result do
        {:ok, %State{} = next_state} -> {:cont, {:ok, next_state}}
        {:error, {:materialize_error, _} = error} -> {:halt, {:error, error}}
        {:error, reason} -> {:halt, {:error, {:transform_error, reason}}}
      end
    end)
  end

  # Successful stops also carry the realized post-op image dimensions (an O(1)
  # header read) — decoded dimensions are product-neutral, non-sensitive metadata.
  defp stop_metadata({:ok, %State{image: image}}),
    do: %{result: :ok, dims: {Image.width(image), Image.height(image)}}

  defp stop_metadata(res), do: %{result: elem(res, 0)}

  defp run_operation(operation, %State{} = state) do
    case maybe_materialize(state, operation) do
      {:ok, %State{} = state} -> Transform.execute(operation, state)
      {:error, reason} -> {:error, {:materialize_error, reason}}
    end
  end

  defp maybe_materialize(%State{materialized?: true} = state, _operation), do: {:ok, state}

  defp maybe_materialize(%State{} = state, operation) do
    if Transform.requires_materialization?(operation) do
      Materializer.materialize(state)
    else
      {:ok, state}
    end
  end
end
