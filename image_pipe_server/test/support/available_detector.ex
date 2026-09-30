defmodule ImagePipeServer.Test.AvailableDetector do
  @moduledoc false
  # Stands in for a detector that is present in the build.

  def available?(_opts), do: true
end
