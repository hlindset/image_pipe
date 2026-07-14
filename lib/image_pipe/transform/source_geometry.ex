defmodule ImagePipe.Transform.SourceGeometry do
  @moduledoc """
  Pre-decode geometry facts produced by `ImagePipe.Decode.with_image/4`'s
  header open, handed to a dialect's `decode_request_fun` (and to the paired
  `Transform.State`-consuming callback) so it can plan against the display
  frame without re-deriving orientation compensation itself.

  Distinct from `ImagePipe.Transform.SourceShape` (the *execute-time* shape
  threaded through the resolve driver, which also carries `decode_shrink` and
  a mutable `frame`): `SourceGeometry` is a smaller, decode-time-only value —
  the two storage/display extents, the (possibly identity) pending
  orientation the decode observed, and the resolved source format.
  """

  alias ImagePipe.Format
  alias ImagePipe.Transform.PendingOrientation

  @enforce_keys [:storage_dimensions, :display_dimensions, :pending_orientation, :source_format]
  defstruct [:storage_dimensions, :display_dimensions, :pending_orientation, :source_format]

  @type t :: %__MODULE__{
          storage_dimensions: {pos_integer(), pos_integer()},
          display_dimensions: {pos_integer(), pos_integer()},
          pending_orientation: PendingOrientation.t(),
          source_format: Format.source_format()
        }

  @doc """
  The frame a dialect should plan geometry against: `display_dimensions` when
  `auto_rotate?` is true, `storage_dimensions` otherwise. The caller's own
  EXIF policy choice (never baked into this struct's shape) selects the
  answer; `display_dimensions` itself was already computed at construction
  time from whatever pending orientation the decode was seeded with.
  """
  @spec planning_frame(t(), boolean()) :: {pos_integer(), pos_integer()}
  def planning_frame(%__MODULE__{display_dimensions: dims}, true), do: dims
  def planning_frame(%__MODULE__{storage_dimensions: dims}, false), do: dims
end
