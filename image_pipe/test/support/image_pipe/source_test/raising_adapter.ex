defmodule ImagePipe.SourceTest.RaisingAdapter do
  @moduledoc false

  def identifiers(_options),
    do: [ImagePipe.Source.Path, ImagePipe.Source.URL, ImagePipe.Source.Object]

  def validate_options(opts), do: {:ok, opts}
  def resolve(_source, _opts, _runtime_opts), do: raise("raw resolve failure")
  def fetch(_resolved, _opts, _runtime_opts), do: raise("raw fetch failure")
end
