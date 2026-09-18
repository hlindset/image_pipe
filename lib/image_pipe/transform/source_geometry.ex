defmodule ImagePipe.Transform.SourceGeometry do
  @moduledoc """
  Pre-decode geometry facts produced by `ImagePipe.Decode.with_image/4`'s
  header open. The native executor uses them to plan against the display frame,
  and the paired `Transform.State`-consuming callback receives them for output
  negotiation and source reporting.

  It contains the storage/display extents, the pending orientation observed
  during decode, and the resolved source format. Runtime image geometry and
  realized decode scaling belong to `ImagePipe.Transform.State`.

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
