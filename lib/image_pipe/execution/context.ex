defmodule ImagePipe.Execution.Context do
  @moduledoc false
  @enforce_keys [:request, :source, :policy, :material, :representation, :config]
  @derive {Inspect, only: []}
  defstruct @enforce_keys ++
              [
                input_key: nil,
                acquisition: %ImagePipe.Execution.Acquisition{record: nil},
                stale?: false
              ]
end
