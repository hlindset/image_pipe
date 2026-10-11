defmodule ImagePipe.SVG.Fonts do
  @moduledoc """
  The fonts SVG text renders with, loaded once from the host's font files.

  `fingerprint` changes whenever a font file is added, removed, renamed, or
  changed, so ImagePipe can put it in the cache key.
  """

  @enforce_keys [:ref, :fingerprint]
  defstruct [:ref, :fingerprint]

  @type t :: %__MODULE__{ref: reference(), fingerprint: String.t()}
end
