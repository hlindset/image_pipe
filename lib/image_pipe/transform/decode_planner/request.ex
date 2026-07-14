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

  @type t() :: %__MODULE__{
          resize_target: extent() | nil,
          crop_extent: extent() | nil,
          trim?: boolean(),
          terminal_reduction: extent() | nil,
          required_extent: extent() | nil
        }

  defstruct resize_target: nil,
            crop_extent: nil,
            trim?: false,
            terminal_reduction: nil,
            required_extent: nil
end
