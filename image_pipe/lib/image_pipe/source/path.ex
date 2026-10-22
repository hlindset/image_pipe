defmodule ImagePipe.Source.Path do
  @moduledoc """
  Root-relative path source.

  An adapter receives `segments` with the source's matching prefix or custom
  scheme removed, so `asset://catalog/42` reaches it as `["catalog", "42"]`.
  `scheme` is always `nil` in a path an adapter receives.
  """

  @enforce_keys [:segments]
  defstruct [:segments, scheme: nil]

  @type t :: %__MODULE__{segments: [String.t()], scheme: String.t() | nil}
end
