defmodule ImagePipe.Processing.Prepared do
  @moduledoc false
  @enforce_keys [:state, :geometry, :resolved_output, :policy, :shrink, :operations, :timings]
  defstruct @enforce_keys
end
