defmodule ImagePipe.SourceTest.InvalidAdapter do
  @moduledoc false

  def validate_options(_opts), do: {:ok, []}
  def resolve(_source, _opts, _runtime_opts), do: {:ok, :not_resolved}
  def fetch(_resolved, _opts, _runtime_opts), do: {:ok, :not_response}
end
