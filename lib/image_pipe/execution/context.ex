defmodule ImagePipe.Execution.Context do
  @moduledoc false
  @enforce_keys [:request, :source, :policy, :material, :representation, :config]
  @derive {Inspect, only: []}
  defstruct @enforce_keys ++
              [input_key: nil, record: nil, response: nil, lease: nil, stale?: false]
end
