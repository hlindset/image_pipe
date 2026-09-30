defmodule ImagePipe.Plan.Source.Path do
  @moduledoc """
  Root-relative path source.
  """

  @enforce_keys [:segments]
  defstruct @enforce_keys

  @type t :: %__MODULE__{segments: [String.t()]}
end
