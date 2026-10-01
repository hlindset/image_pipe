defmodule ImagePipe.Execution.Context do
  @moduledoc false
  @enforce_keys [:request, :source, :policy, :material, :representation, :config]
  @derive {Inspect, only: []}
  defstruct @enforce_keys ++
              [
                input_key: nil,
                inputs: nil,
                watermarks: [],
                watermark_tasks: [],
                acquisition: %ImagePipe.Execution.Acquisition{record: nil},
                stale?: false
              ]
end
