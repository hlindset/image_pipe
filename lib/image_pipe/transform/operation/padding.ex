defmodule ImagePipe.Transform.Operation.Padding do
  @moduledoc """
  Executable edge padding operation.
  """

  use ImagePipe.Transform

  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.State

  @enforce_keys [:top, :right, :bottom, :left, :fill]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          top: non_neg_integer(),
          right: non_neg_integer(),
          bottom: non_neg_integer(),
          left: non_neg_integer(),
          fill: term()
        }

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :padding

  @impl ImagePipe.Transform
  def execute(%__MODULE__{top: 0, right: 0, bottom: 0, left: 0}, %State{} = state),
    do: {:ok, state}

  def execute(%__MODULE__{} = operation, %State{} = state) do
    width = Image.width(state.image) + operation.left + operation.right
    height = Image.height(state.image) + operation.top + operation.bottom

    canvas = %ExtendCanvas{
      rule: {:dimensions, width, height},
      gravity: {:anchor, :left, :top},
      x_offset: operation.left,
      y_offset: operation.top,
      background: operation.fill
    }

    ExtendCanvas.execute(canvas, state)
  end
end
