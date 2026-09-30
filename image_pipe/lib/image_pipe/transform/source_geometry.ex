defmodule ImagePipe.Transform.SourceGeometry do
  @moduledoc """
  Source geometry read by `ImagePipe.Decode.with_image/4` during header open.

  Carries storage/display extents, pending orientation, and source format for
  executor planning, output negotiation, and source reporting. Current image
  geometry and realized decode scaling belong to `ImagePipe.Transform.State`.

  `debug_facts` carries best-effort, non-sensitive source facts collected by
  `ImagePipe.Decode` for the debug headers; `%{}` when collection failed or
  the geometry was built elsewhere.
  """

  alias ImagePipe.Format
  alias ImagePipe.Transform.PendingOrientation

  @enforce_keys [:storage_dimensions, :display_dimensions, :pending_orientation, :source_format]
  defstruct [
    :storage_dimensions,
    :display_dimensions,
    :pending_orientation,
    :source_format,
    debug_facts: %{}
  ]

  @type t :: %__MODULE__{
          storage_dimensions: {pos_integer(), pos_integer()},
          display_dimensions: {pos_integer(), pos_integer()},
          pending_orientation: PendingOrientation.t(),
          source_format: Format.source_format(),
          debug_facts: map()
        }
end
