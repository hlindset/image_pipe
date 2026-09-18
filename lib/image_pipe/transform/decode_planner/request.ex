defmodule ImagePipe.Transform.DecodePlanner.Request do
  @moduledoc """
  Concrete decode geometry for
  `ImagePipe.Transform.DecodePlanner.open_options_for/5`.

  The executor resolves display-frame extents before choosing decode load
  options. This struct carries the inputs the load-shrink math needs.
  """

  @typedoc "A {width, height} extent in display-frame pixels."
  @type extent() :: {pos_integer(), pos_integer()}

  @typedoc """
  The residual resize's effective target, per axis, in display-frame pixels.

  Unlike `t:extent/0`, each axis is optional and may be fractional:

    * A single-axis resize (`w:400` with `:auto` height) uses only that axis's
      shrink ratio. Synthesizing the other target can unnecessarily constrain it.
    * `dpr`/`zoom` can produce fractional targets. Rounding changes the shrink
      ratio and can turn a sub-pixel target into zero.

  A resize with no target axes must normalize to `nil`. `{nil, nil}` would match
  the resize clause and suppress `terminal_reduction`:

      resize_target: nil,        terminal_reduction: {32, 32}  ->  shrink: 8
      resize_target: {nil, nil}, terminal_reduction: {32, 32}  ->  no shrink
  """
  @type resize_target() :: {number() | nil, number() | nil}

  @typedoc """
  Decode targets, crop extent, trim flag, and pre-resize user orientation.

  `user_quarter_turn?` is true for a 90°/270° user rotation. The planner XORs it
  with the separately supplied EXIF turn to determine whether to swap axes.
  """
  @type t() :: %__MODULE__{
          resize_target: resize_target() | nil,
          crop_extent: extent() | nil,
          trim?: boolean(),
          terminal_reduction: extent() | nil,
          user_quarter_turn?: boolean()
        }

  defstruct resize_target: nil,
            crop_extent: nil,
            trim?: false,
            terminal_reduction: nil,
            user_quarter_turn?: false
end
