defmodule ImagePipe.Transform do
  @moduledoc """
  Operation behaviour and single-operation execution.

  Operations provide a stable name and execute over `ImagePipe.Transform.State`.
  `run/3` handles telemetry, materialization, and errors. The executor owns order.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Plan, ImagePipe.Telemetry],
    exports: [
      # Runtime execution contract.
      Executor,
      State,
      DecodePlanner,
      DecodePlanner.Request,
      Materializer,
      Detector,
      Detector.Warmup,
      # Header geometry used by decode preflight.
      SourceGeometry,
      PendingOrientation
    ]

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State

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

  @doc """
  Runs one operation, materializing first when it requires random pixel access.

  Emits a `[:transform, :operation]` span with the operation name, parameters,
  outcome, and resulting dimensions. libvips defers most pixel work, so this
  span measures pipeline construction plus any materialization it triggers.

  Returns transform failures as `{:error, {:transform, reason}}` and
  materialization failures as `{:error, {:decode, reason}}`. Programmer errors
  propagate through the span unchanged.
  """
  @spec run(State.t(), operation(), keyword()) ::
          {:ok, State.t()} | {:error, {:transform, term()} | {:decode, term()}}
  def run(%State{} = state, %module{} = operation, opts \\ []) do
    Telemetry.span(
      Telemetry.telemetry_opts(opts),
      [:transform, :operation],
      %{operation: module.name(operation), params: operation},
      fn ->
        result =
          with {:ok, state} <- prepare(state, operation) do
            module.execute(operation, state)
          end

        {operation_result(result), stop_metadata(result)}
      end
    )
  end

  defp prepare(%State{materialized?: true} = state, _operation), do: {:ok, state}

  defp prepare(%State{} = state, %module{} = operation) do
    case module.requires_materialization?(operation) do
      false -> {:ok, state}
      true -> materialize(state)
    end
  end

  defp materialize(state) do
    case Materializer.materialize(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:materialize_error, reason}}
    end
  end

  defp operation_result({:ok, state}), do: {:ok, state}
  defp operation_result({:error, {:materialize_error, reason}}), do: {:error, {:decode, reason}}
  defp operation_result({:error, reason}), do: {:error, {:transform, reason}}

  defp stop_metadata({:ok, %State{image: image}}),
    do: %{result: :ok, dims: {Image.width(image), Image.height(image)}}

  defp stop_metadata({:error, _reason}), do: %{result: :error}

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
