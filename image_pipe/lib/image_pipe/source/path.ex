defmodule ImagePipe.Source.Path do
  @moduledoc """
  Root-relative path source.

  An adapter receives `segments` with the source's matching prefix or custom
  scheme removed, so `asset://catalog/42` reaches it as `["catalog", "42"]`.
  """

  @enforce_keys [:segments]
  defstruct @enforce_keys

  @type t :: %__MODULE__{segments: [String.t()]}
end
