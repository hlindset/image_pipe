defmodule ImagePipe.SourceTest.RaisingAdapter do
  @moduledoc false

  def identifiers(_options),
    do: [ImagePipe.Plan.Source.Path, ImagePipe.Plan.Source.URL, ImagePipe.Plan.Source.Object]

  def validate_options(opts), do: {:ok, opts}
  def resolve(_source, _opts, _runtime_opts), do: raise("raw resolve failure")
  def fetch(_resolved, _opts, _runtime_opts), do: raise("raw fetch failure")
end
