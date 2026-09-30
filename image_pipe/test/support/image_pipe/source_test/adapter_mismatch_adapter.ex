defmodule ImagePipe.SourceTest.AdapterMismatchAdapter do
  @moduledoc false

  use Boundary, top_level?: true, deps: [ImagePipe.Source]

  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved

  @behaviour Source

  @impl Source
  def validate_options(opts), do: {:ok, opts}

  @impl Source
  def resolve(_source, _opts, _runtime_opts) do
    {:ok,
     %Resolved{
       adapter: :path,
       source_kind: :object,
       identity: [kind: :object, adapter: :foobar, scope: "custom", key: "cat.jpg"],
       internal_cache: :enabled,
       http_cache: :inherit,
       cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false},
       fetch: :wrong_adapter
     }}
  end

  @impl Source
  def fetch(_resolved, _opts, _runtime_opts) do
    raise "adapter mismatch must fail before fetch"
  end
end
