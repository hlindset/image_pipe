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
  The residual resize's effective target, per axis, in display-frame pixels.

  Wider than `t:extent/0` in two ways, both to let a dialect state exactly what
  the op-chain path (`open_options/5`) states, rather than an approximation of
  it:

    * **Each axis is independently optional.** A single-axis resize (`w:400`
      with an `:auto` height) targets that axis and no other, and the shrink is
      that axis's ratio alone. A dialect that had to fill the missing axis would
      have to synthesize one from the aspect ratio, which binds `min/2` tighter
      than the chain path does whenever the frame is not exactly proportional.
    * **An axis is a `number()`, not a `pos_integer()`.** `dpr`/`zoom` inflate
      the requested pixel extent to a fractional target; the chain path divides
      by that fraction directly. Rounding it to a whole pixel would move the
      resulting ratio, and rounding a sub-pixel target lands on zero.

  `{nil, nil}` and `nil` are equivalent (neither axis is a target); prefer `nil`.
  """
  @type resize_target() :: {number() | nil, number() | nil}

  @typedoc """
  Whether the dialect's own rotate operations, applied before the residual
  resize, sum to a quarter turn (90°/270° mod 180).

  `open_options_for/5`'s caller supplies the EXIF turn separately; this field
  carries the *user* turn, which the planner XORs with it. A dialect that emits
  no rotate before its resize leaves this `false`.
  """
  @type t() :: %__MODULE__{
          resize_target: resize_target() | nil,
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
