defmodule ImagePipe.Test.ProcessingSource do
  @moduledoc false
  @behaviour ImagePipe.Source

  @impl true
  def identifiers(_options),
    do: [ImagePipe.Source.Path, ImagePipe.Source.URL, ImagePipe.Source.Object]

  alias ImagePipe.Source.{CacheSemantics, Resolved, Response}

  @impl true
  def validate_options(options), do: {:ok, options}

  @impl true
  def resolve(source, options, _runtime) do
    {:ok,
     %Resolved{
       identity: [path: source.segments],
       internal_cache: :enabled,
       http_cache: :inherit,
       cache_semantics: %CacheSemantics{
         byte_identity: {:strong, source.segments},
         stable?: true,
         copy?: Keyword.get(options, :copy?, false)
       },
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

    {:ok,
     %Response{
       stream: Keyword.get(options, :stream, [bytes]),
       origin: Keyword.get(options, :origin),
       close: fn -> send(test, {:closed, segments}) end
     }}
  end
end
