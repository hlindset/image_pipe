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

  Wider than `t:extent/0` in two ways, both to let a dialect state its resize
  target exactly rather than as an approximation of it:

    * **Each axis is independently optional.** A single-axis resize (`w:400`
      with an `:auto` height) targets that axis and no other, and the shrink is
      that axis's ratio alone. A dialect that had to fill the missing axis would
      have to synthesize one from the aspect ratio, which binds `min/2` tighter
      whenever the frame is not exactly proportional.
    * **An axis is a `number()`, not a `pos_integer()`.** `dpr`/`zoom` inflate
      the requested pixel extent to a fractional target, and the planner divides
      by that fraction directly. Rounding it to a whole pixel would move the
      resulting ratio, and rounding a sub-pixel target lands on zero.

  **A resize with no targeted axis MUST normalize to `nil`, never `{nil, nil}`.**
  The two are not interchangeable: `open_options_for/5`'s precedence reads this
  field's *presence*, so `{nil, nil}` matches the `resize_target` clause and
  shadows `terminal_reduction`, silently costing a terminal its load shrink —

      resize_target: nil,        terminal_reduction: {32, 32}  ->  shrink: 8
      resize_target: {nil, nil}, terminal_reduction: {32, 32}  ->  no shrink

  A dialect that uses no terminal is unaffected today, which is exactly why the
  distinction is stated here rather than left to be rediscovered: both shipped
  pipelines normalize (`Native.Pipeline.resize_target/1`,
  `Imgproxy.Pipeline.resize_target/1`), and the next one must too.
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
