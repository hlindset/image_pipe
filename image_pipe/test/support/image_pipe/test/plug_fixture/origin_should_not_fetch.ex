defmodule ImagePipe.Test.PlugFixture.OriginShouldNotFetch do
  @moduledoc false

  use Boundary, top_level?: true, deps: []

  def call(_conn, _opts), do: raise("origin should not fetch")
end
