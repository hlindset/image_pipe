defmodule ImagePipe.SourceTest.InvalidIdentityAdapter do
  @moduledoc false

  use Boundary, top_level?: true, deps: [ImagePipe.Source]

  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved

  @behaviour Source

  @impl Source
  def validate_options(opts), do: {:ok, opts}

  @impl Source
  def resolve(_source, opts, _runtime_opts) do
    {:ok,
     %Resolved{
       adapter: :path,
       source_kind: :path,
       identity: Keyword.get(opts, :identity, kind: :path, client: self()),
       internal_cache: :disabled,
       http_cache: :inherit,
       cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false},
       fetch: :bad_identity
     }}
  end

  @impl Source
  def fetch(_resolved, _opts, _runtime_opts) do
    raise "invalid identity must fail before fetch"
  end
end
