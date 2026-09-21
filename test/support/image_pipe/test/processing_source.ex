defmodule ImagePipe.Test.ProcessingSource do
  @moduledoc false
  @behaviour ImagePipe.Source

  alias ImagePipe.Source.{CacheSemantics, Resolved, Response}

  @impl true
  def validate_options(options), do: {:ok, options}

  @impl true
  def resolve(source, options, _runtime) do
    {:ok,
     %Resolved{
       adapter: :path,
       source_kind: :path,
       identity: [path: source.segments],
       internal_cache: :enabled,
       http_cache: :inherit,
       cache_semantics: %CacheSemantics{byte_identity: {:strong, source.segments}, stable?: true},
       fetch: {source.segments, options}
     }}
  end

  @impl true
  def fetch(%Resolved{fetch: {segments, options}}, _opts, _runtime) do
    test = Keyword.fetch!(options, :test)
    send(test, {:fetch, segments, self()})

    if "blocked" in segments do
      receive do
        :continue -> :ok
      end
    end

    bytes = Keyword.fetch!(options, :bytes)
    {:ok, %Response{stream: [bytes], close: fn -> send(test, {:closed, segments}) end}}
  end
end
