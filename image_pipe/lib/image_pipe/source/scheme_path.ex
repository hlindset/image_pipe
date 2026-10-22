defmodule ImagePipe.Source.SchemePath do
  # A path written with a custom scheme, such as `asset://catalog/42`.
  # Routing picks the source that matches `scheme`, and its adapter receives
  # the segments as an `ImagePipe.Source.Path`.
  @moduledoc false

  @enforce_keys [:scheme, :segments]
  defstruct @enforce_keys

  @type t :: %__MODULE__{scheme: String.t(), segments: [String.t()]}
end
