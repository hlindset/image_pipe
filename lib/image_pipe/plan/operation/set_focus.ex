defmodule ImagePipe.Plan.Operation.SetFocus do
  @moduledoc """
  Positional focus directive (TwicPics, #321).

  Resolves a focus operand against the running frame at its chain position and
  stores it as the carried `ImagePipe.Transform.State.focus`. Emits no pixel
  operation. The operand's units (literal px, relative ratio, or anchor) are
  resolved once, at execution, against the then-current dimensions; thereafter
  the focus is transformed as geometry by each op.
  """

  @enforce_keys [:point]
  defstruct @enforce_keys

  @type measure :: {:px, non_neg_integer()} | {:ratio, non_neg_integer(), pos_integer()}
  @type operand ::
          {:coord, measure(), measure()}
          | {:anchor, :left | :center | :right, :top | :center | :bottom}

  @type t :: %__MODULE__{point: operand()}
end
