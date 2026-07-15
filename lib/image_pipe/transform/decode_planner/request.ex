defmodule ImagePipe.Transform.DecodePlanner.Request do
  @moduledoc """
  Defunctionalized decode-plan input for
  `ImagePipe.Transform.DecodePlanner.open_options_for/5`.

  A dialect-owned pipeline (#454) does not build a semantic op chain before
  choosing decode load options — it speaks in resolved display-frame extents
  instead. This struct carries exactly the inputs the load-shrink math needs,
  independent of any `ImagePipe.Plan.Pipeline.operation()` chain.
  """

  @typedoc "A {width, height} extent in display-frame pixels."
  @type extent() :: {pos_integer(), pos_integer()}

  @typedoc """
  Whether the dialect's own rotate operations, applied before the residual
  resize, sum to a quarter turn (90°/270° mod 180).

  `open_options_for/5`'s caller supplies the EXIF turn separately; this field
  carries the *user* turn, which the planner XORs with it. A dialect that emits
  no rotate before its resize leaves this `false`.
  """
  @type t() :: %__MODULE__{
          resize_target: extent() | nil,
          crop_extent: extent() | nil,
          trim?: boolean(),
          terminal_reduction: extent() | nil,
          required_extent: extent() | nil,
          user_quarter_turn?: boolean()
        }

  defstruct resize_target: nil,
            crop_extent: nil,
            trim?: false,
            terminal_reduction: nil,
            required_extent: nil,
            user_quarter_turn?: false
end
